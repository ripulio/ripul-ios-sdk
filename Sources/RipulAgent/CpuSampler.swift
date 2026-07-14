import Foundation
import SwiftUI

// MARK: - CpuSampler
//
// Granular, per-thread CPU sampler for the *app process* (not the WebKit
// content process). Thermal state lags heat by seconds-to-minutes and only
// has four buckets; this reads the kernel's per-thread `cpu_usage` at a few Hz
// so you can see the instant a core spikes AND which named thread is burning.
//
// Two outputs:
//   1. Live @Published state (total %, main-thread %, top threads, peak) for a
//      readout/HUD.
//   2. Edge-bracketed spike logs to the bridge console (via `onSpike`), so the
//      spike shows up in `host_console_logs` with a timestamp and the names of
//      the threads responsible — even when nobody is looking at the screen.
//
// Note: this only sees THIS process. The web app's JS runs in a separate
// `com.apple.WebKit.WebContent` process and will NOT appear here. That's by
// design — this is the "native is running hot" instrument.
public final class CpuSampler: ObservableObject {

    public struct ThreadSample: Identifiable, Equatable {
        public let id: UInt32          // mach thread port (task namespace)
        public let name: String
        public let percent: Double
        public let isMain: Bool
    }

    // Live state (updated on the main thread).
    @Published public private(set) var totalPercent: Double = 0
    @Published public private(set) var mainThreadPercent: Double = 0
    @Published public private(set) var threads: [ThreadSample] = []
    @Published public private(set) var peakPercent: Double = 0
    @Published public private(set) var peakThreadName: String = "—"
    @Published public private(set) var peakAt: Date?
    @Published public private(set) var isRunning: Bool = false
    /// Rolling history of total% for a sparkline (most-recent last).
    @Published public private(set) var history: [Double] = []

    /// Device-wide CPU busy % across all processes (0-100 of total capacity).
    /// Compared with `nativeSharePercent` to attribute heat: system high while
    /// native is low ⇒ the WebView / other processes (not our Swift code).
    @Published public private(set) var systemPercent: Double = 0
    /// This app process as a share of total device capacity (`totalPercent / cores`),
    /// so it's directly comparable to `systemPercent`.
    @Published public private(set) var nativeSharePercent: Double = 0
    /// Device capacity used by everything that ISN'T this app process —
    /// `max(0, systemPercent - nativeSharePercent)`. On a foregrounded app this is
    /// dominated by the WKWebView's WebContent + WebKit.GPU processes.
    public var webOtherPercent: Double { max(0, systemPercent - nativeSharePercent) }
    /// False if `host_statistics(HOST_CPU_LOAD_INFO)` isn't permitted on this OS
    /// build — in which case the system/web split is unavailable.
    @Published public private(set) var systemAvailable: Bool = true

    /// Averages accumulated between a mark-start and mark-end, for A/B tests.
    public struct CpuMeasurement: Equatable {
        public let avgTotal: Double
        public let avgMain: Double
        public let avgSystem: Double
        public let avgWeb: Double
        public let peakTotal: Double
        public let durationSec: Double
        public let samples: Int
    }
    /// True while a measurement window is open. Toggle with `toggleMeasurement()`.
    @Published public private(set) var isMeasuring = false
    /// Running average while measuring; the final window average after stopping.
    @Published public private(set) var measurement: CpuMeasurement?

    /// Called on the main thread when a spike starts, continues, or clears.
    /// Wire this to the bridge console so spikes land in `host_console_logs`.
    public var onSpike: ((String) -> Void)?

    /// Total process CPU% at/above which we consider it a spike. Can exceed
    /// 100% on multi-core (each busy core contributes up to 100%).
    public var spikeThreshold: Double = 80

    private let queue = DispatchQueue(label: "io.ripul.cpu-sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var mainThreadPort: mach_port_t = 0
    private let historyCap = 90

    // Measurement-window accumulators (main thread).
    private var mStart: Date?
    private var mSumTotal = 0.0, mSumMain = 0.0, mSumSystem = 0.0, mSumWeb = 0.0, mPeak = 0.0
    private var mCount = 0

    // Time-delta baselines (updated each sample, on `queue`).
    private var prevProcCpu: Double?        // cumulative process CPU seconds
    private var prevWallNs: UInt64 = 0      // CLOCK_UPTIME_RAW nanoseconds
    private var prevThreadCpu: [UInt32: Double] = [:]   // port -> cumulative CPU seconds
    /// Previous host CPU tick totals (user, system, idle, nice) for the device-wide delta.
    private var prevCpuTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private let cpuCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    // Spike bracketing state (main-thread only).
    private var elevated = false
    private var elevatedSince: Date?
    private var lastSpikeLog: Date?
    private var elevatedPeak: Double = 0

    public init() {}

    /// Start sampling. `intervalMs` in [50, 1000]; 200ms (5Hz) is a good
    /// balance of granularity vs. overhead.
    public func start(intervalMs: Int = 200) {
        stop()
        // Reset delta baselines so the first interval measures cleanly.
        queue.async { [weak self] in
            self?.prevProcCpu = nil
            self?.prevWallNs = 0
            self?.prevThreadCpu = [:]
            self?.prevCpuTicks = nil
        }
        // Capture the main thread's mach port so we can attribute main-thread
        // load. pthread_mach_thread_np returns the port in the task namespace,
        // matching what task_threads() enumerates.
        DispatchQueue.main.async { [weak self] in
            self?.mainThreadPort = pthread_mach_thread_np(pthread_self())
        }

        let clamped = max(50, min(1000, intervalMs))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(clamped),
                   repeating: .milliseconds(clamped),
                   leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.sample() }
        timer = t
        t.resume()
        isRunning = true
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        guard isRunning else { return }
        isRunning = false
    }

    public func resetPeak() {
        peakPercent = 0
        peakThreadName = "—"
        peakAt = nil
    }

    // MARK: - Sampling (runs on `queue`, off the main thread)
    //
    // Time-delta method: CPU% = Δ(cumulative CPU-seconds) / Δ(wall-clock) × 100.
    // This is what top/Xcode report and is unambiguous, unlike the kernel's
    // smoothed `thread_basic_info.cpu_usage` estimate (which over-reports).
    // 100% = one core fully busy for the whole interval; can exceed 100% total
    // across cores.

    private func sample() {
        let nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let procNow = processCpuSeconds()

        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return }
        defer {
            for i in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threadList[i])
            }
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threadList)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_act_t>.stride))
        }

        // THREAD_BASIC_INFO_COUNT is a sizeof macro not imported into Swift —
        // compute it from the layout.
        let infoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let mainPort = mainThreadPort

        // Snapshot every live thread's cumulative CPU seconds + identity.
        var curThreadCpu: [UInt32: Double] = [:]
        var name: [UInt32: String] = [:]
        var isMainMap: [UInt32: Bool] = [:]
        for i in 0..<Int(threadCount) {
            let mt = threadList[i]
            var info = thread_basic_info()
            var count = infoCount
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(mt, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            let cum = Self.tv(info.user_time) + Self.tv(info.system_time)
            let isMain = mainPort != 0 && mt == mainPort
            curThreadCpu[mt] = cum
            isMainMap[mt] = isMain
            name[mt] = Self.threadName(mt, isMain: isMain)
        }

        // First sample after start(): establish baseline, publish nothing yet.
        guard let prevProc = prevProcCpu, prevWallNs != 0 else {
            prevProcCpu = procNow
            prevWallNs = nowNs
            prevThreadCpu = curThreadCpu
            return
        }

        let elapsed = Double(nowNs &- prevWallNs) / 1_000_000_000
        guard elapsed > 0.001 else { return }

        // Whole-process % from task-level accounting (includes threads that
        // died within the interval — the authoritative headline number).
        let total = procNow.map { max(0, ($0 - prevProc) / elapsed * 100.0) } ?? 0

        // Per-thread % from each thread's own delta (attribution; new threads
        // have no baseline and are treated as 0 this round).
        var mainPct: Double = 0
        var samples: [ThreadSample] = []
        for (mt, cum) in curThreadCpu {
            let prev = prevThreadCpu[mt] ?? cum
            let pct = max(0, (cum - prev) / elapsed * 100.0)
            let isMain = isMainMap[mt] ?? false
            if isMain { mainPct = pct }
            if pct >= 0.5 {
                samples.append(ThreadSample(id: mt,
                                            name: name[mt] ?? "thread-\(mt)",
                                            percent: pct,
                                            isMain: isMain))
            }
        }

        prevProcCpu = procNow
        prevWallNs = nowNs
        prevThreadCpu = curThreadCpu

        // Device-wide CPU (all processes) so the HUD can attribute heat to native
        // vs the WebView. nativeShare is our app expressed on the same 0-100
        // capacity scale (total is sum-of-threads where 100% == one core).
        let sysBusy = readSystemBusy()
        let nativeShare = min(100, total / cpuCount)

        samples.sort { $0.percent > $1.percent }
        let top = Array(samples.prefix(8))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.totalPercent = total
            self.mainThreadPercent = mainPct
            self.threads = top
            self.nativeSharePercent = nativeShare
            self.systemAvailable = sysBusy.available
            if let sp = sysBusy.percent { self.systemPercent = sp }
            if total > self.peakPercent {
                self.peakPercent = total
                self.peakThreadName = top.first?.name ?? "—"
                self.peakAt = Date()
            }
            self.history.append(total)
            if self.history.count > self.historyCap {
                self.history.removeFirst(self.history.count - self.historyCap)
            }
            self.accumulateMeasurement(total: total, main: mainPct)
            self.evaluateSpike(total: total, main: mainPct, top: top)
        }
    }

    // MARK: - Measurement window (mark start / mark end -> average)

    /// Start a measurement window (resetting accumulators) or stop the current
    /// one (freezing `measurement` at the window average). Used to average CPU
    /// over a marked A/B test run.
    public func toggleMeasurement() {
        if isMeasuring {
            isMeasuring = false   // `measurement` already holds the window average
        } else {
            mStart = Date()
            mSumTotal = 0; mSumMain = 0; mSumSystem = 0; mSumWeb = 0; mPeak = 0; mCount = 0
            measurement = nil
            isMeasuring = true
        }
    }

    /// Fold the current sample into the open measurement window (main thread).
    private func accumulateMeasurement(total: Double, main: Double) {
        guard isMeasuring else { return }
        mSumTotal += total
        mSumMain += main
        mSumSystem += systemPercent
        mSumWeb += webOtherPercent
        mPeak = max(mPeak, total)
        mCount += 1
        let n = Double(max(1, mCount))
        measurement = CpuMeasurement(
            avgTotal: mSumTotal / n,
            avgMain: mSumMain / n,
            avgSystem: mSumSystem / n,
            avgWeb: mSumWeb / n,
            peakTotal: mPeak,
            durationSec: mStart.map { Date().timeIntervalSince($0) } ?? 0,
            samples: mCount
        )
    }

    /// Total process CPU seconds consumed so far: live threads
    /// (TASK_THREAD_TIMES_INFO) plus already-terminated threads
    /// (MACH_TASK_BASIC_INFO user/system time).
    private func processCpuSeconds() -> Double? {
        var basic = mach_task_basic_info()
        var bCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr1 = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(bCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &bCount)
            }
        }
        var times = task_thread_times_info()
        var tCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size
        )
        let kr2 = withUnsafeMutablePointer(to: &times) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(tCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &tCount)
            }
        }
        guard kr1 == KERN_SUCCESS, kr2 == KERN_SUCCESS else { return nil }
        return Self.tv(basic.user_time) + Self.tv(basic.system_time)
             + Self.tv(times.user_time) + Self.tv(times.system_time)
    }

    /// time_value_t (seconds + microseconds) → seconds.
    private static func tv(_ t: time_value_t) -> Double {
        Double(t.seconds) + Double(t.microseconds) / 1_000_000
    }

    /// Device-wide CPU busy % (0-100 of total capacity, all processes) via
    /// `host_statistics(HOST_CPU_LOAD_INFO)`. Delta-based across ticks; the first
    /// call establishes the baseline and returns nil. Returns `available:false`
    /// if the host call isn't permitted on this OS build.
    private func readSystemBusy() -> (percent: Double?, available: Bool) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (nil, false) }

        // cpu_ticks: (user, system, idle, nice) — cumulative across all cores.
        let user = info.cpu_ticks.0, system = info.cpu_ticks.1
        let idle = info.cpu_ticks.2, nice = info.cpu_ticks.3
        defer { prevCpuTicks = (user, system, idle, nice) }

        guard let prev = prevCpuTicks else { return (nil, true) }
        let busy = Double(user &- prev.user) + Double(system &- prev.system) + Double(nice &- prev.nice)
        let total = busy + Double(idle &- prev.idle)
        guard total > 0 else { return (nil, true) }
        return (busy / total * 100.0, true)
    }

    // MARK: - Spike bracketing (main thread)

    private func evaluateSpike(total: Double, main: Double, top: [ThreadSample]) {
        let now = Date()
        if total >= spikeThreshold {
            elevatedPeak = max(elevatedPeak, total)
            if !elevated {
                elevated = true
                elevatedSince = now
                lastSpikeLog = now
                logSpike("SPIKE START", total: total, main: main, top: top)
            } else if let last = lastSpikeLog, now.timeIntervalSince(last) >= 2.0 {
                lastSpikeLog = now
                logSpike("SPIKE ongoing", total: total, main: main, top: top)
            }
        } else if elevated && total < spikeThreshold * 0.7 {
            let dur = elevatedSince.map { now.timeIntervalSince($0) } ?? 0
            onSpike?(String(format: "LOG: [CPU] spike cleared after %.1fs — peak %.0f%%",
                            dur, elevatedPeak))
            elevated = false
            elevatedSince = nil
            elevatedPeak = 0
        }
    }

    private func logSpike(_ prefix: String, total: Double, main: Double, top: [ThreadSample]) {
        let list = top.prefix(4)
            .map { String(format: "%@ %.0f%%", $0.name, $0.percent) }
            .joined(separator: ", ")
        onSpike?(String(format: "WARN: [CPU] %@ — total=%.0f%% main=%.0f%% — %@",
                        prefix, total, main, list))
    }

    // MARK: - Thread naming

    private static func threadName(_ machThread: thread_act_t, isMain: Bool) -> String {
        if isMain { return "main-thread" }
        guard let pthread = pthread_from_mach_thread_np(machThread) else {
            return "thread-\(machThread)"
        }
        var buf = [CChar](repeating: 0, count: 64)
        if pthread_getname_np(pthread, &buf, buf.count) == 0 {
            let name = String(cString: buf)
            if !name.isEmpty { return name }
        }
        return "thread-\(machThread)"
    }
}
