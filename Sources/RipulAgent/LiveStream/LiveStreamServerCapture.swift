#if canImport(UIKit)
import Foundation
import UIKit
import CoreVideo
import IOSurface
import QuartzCore

// MARK: - The render server draws the window (experimental)

/// The window drawn by the render server into a buffer of ours, from any
/// thread: the app's main thread only says which window, twice a second.
/// `LiveStreamSurfaceCapture` asks UIKit for the same picture and so has to
/// wait for it on the main thread (15–26 ms a picture on an iPhone 15).
///
/// DEV-ONLY private API (`CARenderServerRenderLayerWithTransform`, the call
/// WebKit's own snapshots make), resolved at runtime and compiled into DEBUG
/// (and `RIPUL_DEVELOPER_BUILD`) builds only, like `TouchSynthesizer`. The call says nothing about whether
/// it drew, so a session checks its first picture against one the app drew
/// itself (`LiveStreamServerStreamer`).
enum LiveStreamServerCapture {
    /// Which window: its render context, its layer, and its size.
    struct Target: Sendable, Equatable {
        let context: UInt32
        let layer: UInt64
        let points: CGSize
        let screenScale: CGFloat
    }

    #if DEBUG || RIPUL_DEVELOPER_BUILD
    // void CARenderServerRenderLayerWithTransform(mach_port_t, uint32_t client_id, uint64_t layer_id,
    //                                             IOSurfaceRef, int32_t ox, int32_t oy, const CATransform3D *)
    private typealias Render = @convention(c) (mach_port_t, UInt32, UInt64, IOSurfaceRef, Int32, Int32,
                                               UnsafePointer<CATransform3D>) -> Void
    private typealias ContextID = @convention(c) (AnyObject, Selector) -> UInt32
    private static let contextSelector = NSSelectorFromString("_contextId")
    private static let function: Render? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CARenderServerRenderLayerWithTransform")
        else { return nil }
        return unsafeBitCast(symbol, to: Render.self)
    }()

    static var isAvailable: Bool { function != nil && UIWindow.instancesRespond(to: contextSelector) }

    @MainActor
    static func target(_ window: UIWindow) -> Target? {
        guard isAvailable, window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let context = unsafeBitCast(window.method(for: contextSelector), to: ContextID.self)(window, contextSelector)
        guard context != 0 else { return nil }
        let layer = UInt64(UInt(bitPattern: Unmanaged.passUnretained(window.layer).toOpaque()))
        return Target(context: context, layer: layer, points: window.bounds.size, screenScale: window.screen.scale)
    }

    /// Draws the window to fill `buffer` (IOSurface-backed BGRA). Any thread.
    static func render(_ target: Target, into buffer: CVPixelBuffer) -> Bool {
        guard let function, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return false }
        var transform = CATransform3DMakeScale(CGFloat(CVPixelBufferGetWidth(buffer)) / target.points.width,
                                               CGFloat(CVPixelBufferGetHeight(buffer)) / target.points.height, 1)
        function(mach_port_t(MACH_PORT_NULL), target.context, target.layer, surface, 0, 0, &transform)
        return true
    }
    #else
    static var isAvailable: Bool { false }
    @MainActor static func target(_ window: UIWindow) -> Target? { nil }
    static func render(_ target: Target, into buffer: CVPixelBuffer) -> Bool { false }
    #endif
}

/// Pixels of an 8-bit BGRA buffer.
enum LiveStreamPixels {
    /// How many of about a thousand evenly spread pixels aren't black.
    static func lit(_ buffer: CVPixelBuffer) -> Int {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return 0 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard width >= 32, height >= 32 else { return 0 }
        var count = 0
        for y in stride(from: height / 64, to: height, by: max(1, height / 32)) {
            for x in stride(from: width / 64, to: width, by: max(1, width / 32)) {
                let word = (base + y * row + x * 4).loadUnaligned(as: UInt32.self)
                if word & 0x00FF_FFFF != 0 { count += 1 }
            }
        }
        return count
    }

    /// A pool of IOSurface-backed BGRA buffers of one size.
    static func pool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                attributes as CFDictionary, &pool)
        return pool
    }

    static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        return CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess ? buffer : nil
    }
}

// MARK: - How the app itself is doing

/// The app's own main thread while it is being streamed: a display link
/// counts the frames it got to draw and the longest wait between two. A
/// capture that holds the main thread shows up here.
final class LiveStreamMainThreadWatch: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var worst: CFTimeInterval = 0
    private var since = CACurrentMediaTime()

    @MainActor
    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        lock.withLock { last = 0 }   // the wait since an earlier session isn't one
        _ = reading()
    }

    @MainActor
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        lock.withLock {
            if last > 0 { worst = max(worst, now - last) }
            last = now
            frames += 1
        }
    }

    /// Frames a second and the longest gap (ms) since the last reading.
    func reading() -> (fps: Double, worstGapMs: Double) {
        let now = CACurrentMediaTime()
        return lock.withLock {
            let result = (Double(frames) / max(now - since, 0.001), worst * 1000)
            frames = 0
            worst = 0
            since = now
            return result
        }
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

// MARK: - Streaming off the main thread

/// Captures with `LiveStreamServerCapture`, encodes and sends, all on its own
/// task. The session tells it what changes (settings, a touch, a keyframe
/// wanted) and hears back only if this way of capturing turns out not to work.
final class LiveStreamServerStreamer: @unchecked Sendable {
    struct Settings: Sendable, Equatable {
        var maxLongSide: Int
        var fps: Int
        var bitrate: Int
    }

    private let channel: LiveStreamChannel
    private let watch: LiveStreamMainThreadWatch
    private let identity: Data
    private let target: @MainActor @Sendable () -> LiveStreamServerCapture.Target?
    /// A small picture the app drew itself, as lit pixels: what the first capture is checked against.
    private let reference: @MainActor @Sendable () -> Int?
    private let unavailable: @MainActor @Sendable (String) -> Void
    /// No encoder on this device gives pictures back: the session can't go on.
    private let cannotEncode: @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var settings: Settings
    private var wantsKeyframe = true
    private var touched = CACurrentMediaTime() - 60
    private var stillFrames = 0
    private var encodedFrames = 0
    private var encodedBytes = 0
    private var task: Task<Void, Never>?

    /// `identity` is the app and device, as config's JSON.
    init(channel: LiveStreamChannel, settings: Settings, identity: Data, watch: LiveStreamMainThreadWatch,
         target: @escaping @MainActor @Sendable () -> LiveStreamServerCapture.Target?,
         reference: @escaping @MainActor @Sendable () -> Int?,
         unavailable: @escaping @MainActor @Sendable (String) -> Void,
         cannotEncode: @escaping @MainActor @Sendable () -> Void) {
        self.channel = channel
        self.settings = settings
        self.identity = identity
        self.watch = watch
        self.target = target
        self.reference = reference
        self.unavailable = unavailable
        self.cannotEncode = cannotEncode
    }

    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .userInitiated) { [self] in await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func update(_ new: Settings) { lock.withLock { settings = new } }
    func requestKeyframe() { lock.withLock { wantsKeyframe = true } }
    func touchedNow() { lock.withLock { touched = CACurrentMediaTime() } }

    private func run() async {
        var target: LiveStreamServerCapture.Target?
        var targetAt = 0.0
        var encoder: LiveStreamEncoder?
        var encoderFor: (Settings, LiveStreamServerCapture.Target, Int, Int)?
        var pool: CVPixelBufferPool?
        var kind = LiveStreamEncoder.Kind.first
        var checked = false
        var statsSince = CACurrentMediaTime()
        var captures = 0, skipped = 0, captureSeconds = 0.0
        defer { if let last = encoder { Task.detached { last.invalidate() } } }

        while !Task.isCancelled {
            let started = CACurrentMediaTime()
            if started - targetAt > 0.5 {
                target = await MainActor.run { self.target() }
                targetAt = started
            }
            guard let target else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let settings = lock.withLock { self.settings }
            let scale = min(target.screenScale, CGFloat(settings.maxLongSide) / max(target.points.width, target.points.height))
            let width = max(2, Int(target.points.width * scale / 2) * 2)
            let height = max(2, Int(target.points.height * scale / 2) * 2)

            if let stalled = encoder, stalled.stalledFor > LiveStreamHost.encoderPatience {
                // It took a picture and gives none back: the next kind, or give up.
                guard let next = stalled.kind.next else {
                    await cannotEncode()
                    return
                }
                nwarn("[LiveView] the \(stalled.kind.rawValue) encoder gave nothing back in "
                      + "\(Int(stalled.stalledFor * 1000)) ms; trying \(next.rawValue)")
                kind = next
                encoder = nil
                Task.detached { stalled.invalidate() }   // it may wait on the picture it never finished
            }

            if encoder == nil || encoderFor.map({ $0 != settings || $1 != target || $2 != width || $3 != height }) ?? true {
                if let old = encoder { Task.detached { old.invalidate() } }
                pool = LiveStreamPixels.pool(width: width, height: height)
                encoder = try? LiveStreamEncoder(width: Int32(width), height: Int32(height), fps: settings.fps,
                                                 bitrate: settings.bitrate, kind: kind) { [weak self, channel] frame in
                    if frame.keyframe, let sets = frame.parameterSets {
                        channel.enqueue(.format, LiveStreamWire.format(sps: sets.sps, pps: sets.pps))
                    }
                    channel.enqueue(.video, LiveStreamWire.video(keyframe: frame.keyframe,
                                                                 presentationMicros: frame.presentationMicros, avcc: frame.avcc))
                    guard let self else { return }
                    let still = !frame.keyframe && frame.avcc.count < LiveStreamHost.stillFrameBytes
                    self.lock.withLock {
                        self.encodedFrames += 1
                        self.encodedBytes += frame.avcc.count
                        self.stillFrames = still ? self.stillFrames + 1 : 0
                    }
                }
                guard let made = encoder, pool != nil else {
                    await cannotEncode()
                    return
                }
                kind = made.kind
                encoderFor = (settings, target, width, height)
                lock.withLock { wantsKeyframe = true }
                var config = LiveStreamWire.json(identity)
                config["width"] = Double(target.points.width)
                config["height"] = Double(target.points.height)
                config["pixelWidth"] = width
                config["pixelHeight"] = height
                config["fps"] = settings.fps
                config["bitrate"] = settings.bitrate
                config["capture"] = "server"
                config["encoder"] = kind.rawValue
                channel.enqueue(.config, (try? JSONSerialization.data(withJSONObject: config)) ?? Data("{}".utf8))
            }

            if let encoder, let pool {
                if encoder.isBehind || channel.pendingBytes > LiveStreamHost.backlogLimit {
                    skipped += 1
                } else if let buffer = LiveStreamPixels.buffer(from: pool) {
                    let before = CACurrentMediaTime()
                    let drew = LiveStreamServerCapture.render(target, into: buffer)
                    let after = CACurrentMediaTime()
                    if !checked {
                        // The call can't say it failed: compare with a picture the app drew itself, once.
                        checked = true
                        let lit = LiveStreamPixels.lit(buffer)
                        let drawn = await MainActor.run { self.reference() }
                        if !drew || (lit == 0 && (drawn ?? 0) >= 8) {
                            await unavailable("the render server drew nothing (\(lit) lit pixels, the app's own picture \(drawn ?? -1))")
                            return
                        }
                    }
                    let keyframe = lock.withLock { () -> Bool in
                        defer { wantsKeyframe = false }
                        return wantsKeyframe
                    }
                    encoder.encode(buffer, micros: UInt64(after * 1_000_000), keyframe: keyframe)
                    captures += 1
                    captureSeconds += after - before
                }
            }

            let now = CACurrentMediaTime()
            if now - statsSince >= 2 {
                let elapsed = now - statsSince
                let (frames, bytes) = lock.withLock { () -> (Int, Int) in
                    defer { encodedFrames = 0; encodedBytes = 0 }
                    return (encodedFrames, encodedBytes)
                }
                let app = watch.reading()
                let payload: [String: Any] = [
                    "fps": Double(frames) / elapsed, "kbps": Double(bytes * 8) / elapsed / 1000,
                    "captureMs": captures > 0 ? captureSeconds / Double(captures) * 1000 : 0, "submitMs": 0,
                    "captures": captures, "skipped": skipped, "failedDraws": 0, "blankDraws": 0,
                    "captureSize": "\(width)x\(height)", "capture": "server", "surfaceFormat": "BGRA",
                    "encodeFailures": encoder?.failures ?? 0, "encoder": kind.rawValue,
                    "pixelWidth": width, "pixelHeight": height,
                    "appFps": app.fps, "worstGapMs": app.worstGapMs, "thermal": LiveStreamMainThreadWatch.thermal(),
                ]
                channel.enqueue(.stats, (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
                statsSince = now
                captures = 0
                skipped = 0
                captureSeconds = 0
            }

            // Full rate while pictures change or a finger is about; five a
            // second on a still screen, and straight back at a touch.
            let wait: () -> Double = { [self] in
                let (still, touched, fps) = lock.withLock { (stillFrames, self.touched, self.settings.fps) }
                let busy = still < 5 || CACurrentMediaTime() - touched < 1.5
                return started + (busy ? 1 / Double(max(fps, 1)) : 0.2) - CACurrentMediaTime()
            }
            while !Task.isCancelled {
                let left = wait()
                if left <= 0.0005 { break }
                try? await Task.sleep(nanoseconds: UInt64(min(left, 0.012) * 1_000_000_000))
            }
        }
    }
}
#endif
