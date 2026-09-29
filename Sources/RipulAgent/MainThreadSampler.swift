#if os(iOS) && DEBUG
import Foundation
import Darwin
import QuartzCore

/// Names what the main thread is doing, for two questions the slide probe and
/// stall monitor cannot answer on their own.
///
/// 1. **Swipe stutter.** While a chat/list slide is measured (`arm`), any time
///    the main thread stays awake past 30ms a background thread samples its
///    call stack every few ms; when it goes idle one `[STALLSTACK]` line names
///    the frames present in most samples. Hitches with no probe mark (the
///    ~90ms one early in a drag) become attributable.
/// 2. **Thermals.** Always on: once a minute, `[PERFMIN]` reports process CPU
///    time, how much of the minute the main thread was awake, the thermal
///    state, body re-render and publish counts, and — from a 20ms sample of
///    the main thread whenever it is awake — where its time went.
///
/// Stack capture: suspend the main thread, copy raw return addresses into a
/// buffer allocated beforehand (no malloc, no locks while suspended — the main
/// thread may hold them), resume, and only then symbolicate. Debug builds only.
public final class MainThreadSampler: @unchecked Sendable {
    public static let shared = MainThreadSampler()

    private var mainPort: thread_act_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    private let maxFrames = 48
    private let buffer: UnsafeMutablePointer<UInt>
    private var started = false

    // Written on main by the run loop observer, read by the sampler thread.
    // Aligned 8-byte loads/stores; exactness is not required for diagnostics.
    private let awakeSince = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private var armed = false

    // Main-thread only.
    private var busyMs: Double = 0
    private var counts: [String: Int] = [:]
    private var windowStart: CFTimeInterval = 0
    private var cpuAtWindowStart: Double = 0

    // Sampler-thread only.
    private var stallSamples: [[UInt]] = []
    private var stallStartedAt: Double = 0
    private var profile: [[UInt]] = []
    /// Guards `profile`, swapped out by the minute report on main. Taken only
    /// after the main thread has been resumed, so it cannot deadlock a capture.
    private let profileLock = NSLock()

    private init() {
        buffer = .allocate(capacity: maxFrames)
        awakeSince.pointee = 0
    }

    /// Start the per-minute report and the run loop observer. Call on main.
    public static func start() {
        MainActor.assumeIsolated { shared.startOnMain() }
    }

    /// While a slide is measured: capture stacks for main-thread stalls.
    public static func arm() { shared.armed = true }
    public static func disarm() { shared.armed = false }

    /// Count an event for the next `[PERFMIN]` line (main thread).
    public static func count(_ name: String) {
        guard Thread.isMainThread, shared.started else { return }
        shared.counts[name, default: 0] += 1
    }

    @MainActor private func startOnMain() {
        guard !started else { return }
        started = true
        mainPort = mach_thread_self()
        let main = pthread_self()  // startOnMain runs on the main thread
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(main))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(main))
        windowStart = CACurrentMediaTime()
        cpuAtWindowStart = Self.processCPUSeconds()

        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, Int.max) { [unowned self] _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                self.awakeSince.pointee = now
            } else {
                let since = self.awakeSince.pointee
                if since > 0 { self.busyMs += (now - since) * 1000 }
                self.awakeSince.pointee = 0
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)

        let thread = Thread { [unowned self] in self.samplerLoop() }
        thread.name = "ripul.main-sampler"
        thread.qualityOfService = .userInteractive
        thread.start()

        // Name what writes UserDefaults: every write re-evaluates @AppStorage
        // views and costs cfprefsd traffic. Diff snapshots per notification.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [unowned self] note in
            MainActor.assumeIsolated { self.noteDefaultsChange(note.object as? UserDefaults) }
        }

        let timer = Timer(timeInterval: 60, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { self.reportMinute() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Sampler thread

    private func samplerLoop() {
        var lastProfileSample = CACurrentMediaTime()
        while true {
            usleep(4_000)
            let now = CACurrentMediaTime()
            let since = awakeSince.pointee
            let awakeMs = since > 0 ? (now - since) * 1000 : 0

            if armed && awakeMs > 30 {
                if stallStartedAt != since { flushStall(); stallStartedAt = since }
                if stallSamples.count < 60, let stack = captureMain() { stallSamples.append(stack) }
            } else if !stallSamples.isEmpty && stallStartedAt != since {
                flushStall()
            }

            if since > 0 && now - lastProfileSample >= 0.02 {
                lastProfileSample = now
                if let stack = captureMain() {
                    profileLock.lock()
                    if profile.count < 4000 { profile.append(stack) }
                    profileLock.unlock()
                }
            }
        }
    }

    private func captureMain() -> [UInt]? {
        guard mainPort != 0, thread_suspend(mainPort) == KERN_SUCCESS else { return nil }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainPort, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        var n = 0
        if kr == KERN_SUCCESS {
            buffer[0] = Self.strip(UInt(state.__pc)); n = 1
            buffer[1] = Self.strip(UInt(state.__lr)); n = 2
            var fp = UInt(state.__fp)
            while n < maxFrames, fp >= stackLow, fp + 16 <= stackHigh, fp & 7 == 0 {
                let frame = UnsafePointer<UInt>(bitPattern: fp)!
                let next = frame[0]
                let ret = Self.strip(frame[1])
                if ret == 0 { break }
                buffer[n] = ret; n += 1
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainPort)
        guard n > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: buffer, count: n))
    }

    private static func strip(_ address: UInt) -> UInt { address & 0x0000_000F_FFFF_FFFF }

    private func flushStall() {
        defer { stallSamples = []; stallStartedAt = 0 }
        guard stallSamples.count >= 2 else { return }
        let ms = Double(stallSamples.count) * 4 + 30
        let summary = Self.summarize(stallSamples, top: 10, minShare: 0.4)
        let line = String(format: "[STALLSTACK] ~%.0fms samples=%d | %@", ms, stallSamples.count, summary)
        DispatchQueue.main.async { NSLog("%@", line) }
    }

    // MARK: Defaults writers (main)

    private var defaultsSnapshots: [ObjectIdentifier: [String: Any]] = [:]
    private var defaultsWrites: [String: Int] = [:]

    @MainActor private func noteDefaultsChange(_ defaults: UserDefaults?) {
        guard let defaults else { return }
        let id = ObjectIdentifier(defaults)
        let now = defaults.dictionaryRepresentation()
        if let before = defaultsSnapshots[id] {
            for (key, value) in now where !(before[key].map { ($0 as AnyObject).isEqual(value) } ?? false) {
                defaultsWrites[key, default: 0] += 1
            }
            for key in before.keys where now[key] == nil { defaultsWrites[key, default: 0] += 1 }
        } else {
            defaultsWrites["(first-snapshot)", default: 0] += 1
        }
        defaultsSnapshots[id] = now
    }

    // MARK: Minute report (main)

    @MainActor private func reportMinute() {
        let now = CACurrentMediaTime()
        let wall = now - windowStart
        let cpu = Self.processCPUSeconds()
        let cpuUsed = cpu - cpuAtWindowStart
        windowStart = now
        cpuAtWindowStart = cpu
        let busy = busyMs
        busyMs = 0
        let snapshot = counts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        counts = [:]
        let writes = defaultsWrites.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        defaultsWrites = [:]
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "?"
        }
        profileLock.lock()
        let samples = profile
        profile = []
        profileLock.unlock()
        // Symbolicating ~1,800 samples took 234ms on the main thread — the
        // instrument's own stall. Do it off main; only the counts are taken here.
        let header = String(format: "[PERFMIN] %.0fs cpu=%.1fs(%.0f%%) main-awake=%.0f%% thermal=%@ samples=%d | counts: %@ | defaults: %@",
                            wall, cpuUsed, cpuUsed / max(wall, 1) * 100, busy / max(wall * 1000, 1) * 100,
                            thermal, samples.count, snapshot, writes.isEmpty ? "-" : writes)
        DispatchQueue.global(qos: .utility).async {
            let hot = Self.summarize(samples, top: 12, minShare: 0.03)
            NSLog("%@", "\(header) | main: \(hot)")
        }
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    // MARK: Symbolication

    private typealias Demangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?
    private static let demangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        .map { unsafeBitCast($0, to: Demangle.self) }

    private static var symbolCache: [UInt: String] = [:]
    private static let symbolLock = NSLock()

    /// "image`symbol" for an address, demangled and shortened.
    private static func symbol(_ address: UInt) -> String {
        symbolLock.lock(); defer { symbolLock.unlock() }
        if let cached = symbolCache[address] { return cached }
        var info = Dl_info()
        var name = "?"
        if dladdr(UnsafeRawPointer(bitPattern: address > 0 ? address - 1 : address), &info) != 0 {
            let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
            var sym = info.dli_sname.map { String(cString: $0) } ?? "?"
            if let demangle, let out = sym.withCString({ demangle($0, strlen($0), nil, nil, 0) }) {
                sym = String(cString: out)
                free(out)
            }
            sym = sym.replacingOccurrences(of: "RipulAgent.", with: "").replacingOccurrences(of: "Ripul.", with: "")
            name = "\(image)`\(sym.prefix(110))"
        }
        symbolCache[address] = name
        return name
    }

    /// Frames present in at least `minShare` of samples, most common first,
    /// skipping run loop / dispatch plumbing that is present in every stack.
    private static func summarize(_ samples: [[UInt]], top: Int, minShare: Double) -> String {
        guard !samples.isEmpty else { return "-" }
        let plumbing = ["CFRunLoop", "__CFRunLoop", "_dispatch", "dispatch_", "UIApplicationMain", "GSEventRun",
                        "start", "main", "UIApplication _run", "_pthread", "thread_start", "?"]
        var tally: [String: Int] = [:]
        for stack in samples {
            var seen = Set<String>()
            for address in stack {
                let name = symbol(address)
                let bare = name.split(separator: "`").last.map(String.init) ?? name
                if plumbing.contains(where: { bare.hasPrefix($0) }) { continue }
                if seen.insert(name).inserted { tally[name, default: 0] += 1 }
            }
        }
        let floor = Int((Double(samples.count) * minShare).rounded(.up))
        return tally.filter { $0.value >= floor }
            .sorted { $0.value > $1.value }
            .prefix(top)
            .map { "\(Int(Double($0.value) / Double(samples.count) * 100))% \($0.key)" }
            .joined(separator: " | ")
    }
}
#else
/// Debug-only instrument; release and macOS builds keep the call sites.
public enum MainThreadSampler {
    public static func start() {}
    public static func arm() {}
    public static func disarm() {}
    public static func count(_ name: String) {}
}
#endif
