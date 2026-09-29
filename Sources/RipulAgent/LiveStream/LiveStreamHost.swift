#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import CoreVideo
import IOSurface

// MARK: - live_stream_offer

/// Starts a direct Live View session: the app listens once, on a port only
/// the viewer that asked can use, and streams its window as H.264 to it —
/// see `LiveStreamHost`. The viewer makes the session key and sends it here
/// through the account's relay, so the reply carries no secret.
public struct LiveStreamOfferTool: NativeTool {
    public let name = "live_stream_offer"
    public let description = "Used by Ripul's Live View viewer to open a direct video connection to this app. "
        + "Returns the session, port and addresses to connect to with the key the viewer supplied. Not "
        + "useful to an agent: use screen_frame and touch to see and drive the app."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("key", "The viewer's one-time session key: 32 random bytes, base64", required: true),
        .string("viewer", "What the viewer is, as shown on this device (\"Peter's iPhone 17\")"),
        .string("viewerId", "The viewer's install id, so it can replace its own session"),
        .integer("maxLongSide", "Long side of the picture in pixels (320–2800, default 1280)"),
        .integer("fps", "Pictures per second while the screen changes (1–30, default 15)"),
        .integer("bitrate", "Bits per second (250000–8000000, default 2500000)"),
        .number("captureScale", "Redrawing only: pixels a point to capture at, 0.5–2 (default 1; 2 for a long side over 1600)"),
        .stringEnum("capture", "Experimental, debug builds: server has the render server draw the window off the "
                    + "main thread; surface takes its picture on the main thread; draw redraws it in the app "
                    + "(default). Each falls back to the next.", values: ["draw", "surface", "server"])
    )
    public var timeout: TimeInterval { 10 }

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        await LiveStreamHost.shared.offer(args)
    }
}

// MARK: - The session

/// The app's side of Live View. One viewer at a time, either direct (an
/// offer, a single-use listener, then H.264 over `LiveStreamChannel`) or
/// through the relay (`screen_frame`/`touch` with purpose "liveview"). While
/// either is live, a pill with Stop shows at the top of the screen, in its
/// own window, so it never appears in the picture and a remote touch can't
/// press it. Stop ends the session and turns Live View away for a minute.
@MainActor
final class LiveStreamHost {
    static let shared = LiveStreamHost()

    /// How long an offer waits for its viewer.
    static let offerLifetime: TimeInterval = 30
    /// How long Stop turns Live View away.
    static let stopHold: TimeInterval = 60
    /// Encoded bytes a slow connection may hold before a picture is skipped.
    static let backlogLimit = 512 * 1024
    /// A picture this small (not a keyframe) means nothing moved.
    static let stillFrameBytes = 800
    /// A live finger is lifted (as cancelled) after this long without a word
    /// from the viewer, which repeats itself twice a second while it is down.
    static let pointerSilence: TimeInterval = 2.5
    /// The least time between a live finger's down and up: a tap's two ends can arrive together.
    static let pointerMinimumPress: TimeInterval = 0.04
    /// How long an encoder may hold a picture without giving one back before another kind is tried.
    static let encoderPatience: TimeInterval = 1.0
    /// What the viewer is told when no encoder here gives pictures back; it goes back to the relay.
    static let cannotEncodeReason = "This device can't encode video for a direct connection"

    private struct Settings {
        var maxLongSide = 1280
        var fps = 15
        var bitrate = 2_500_000
        var captureScale: CGFloat?
        /// Experimental: take the window from the render server (`LiveStreamSurfaceCapture`).
        var surface = false
        /// Experimental: the render server draws it off the main thread (`LiveStreamServerStreamer`).
        var server = false

        var capture: String { server ? "server" : surface ? "surface" : "draw" }

        /// What was asked for, as far as this build can do it.
        @MainActor
        mutating func ask(capture: String?) {
            surface = (capture == "surface" || capture == "server") && LiveStreamSurfaceCapture.isAvailable
            server = capture == "server" && LiveStreamServerCapture.isAvailable
        }
    }

    private var session: String?
    private var listener: LiveStreamListener?
    private var channel: LiveStreamChannel?
    private var viewerName = "Live View"
    private var viewerId: String?
    private var settings = Settings()
    private var encoder: LiveStreamEncoder?
    private var encoderKind = LiveStreamEncoder.Kind.first
    private var pixelSize = CGSize.zero
    private var captureSize = CGSize.zero
    private var pointSize = CGSize.zero
    private var captureLoop: Task<Void, Never>?
    private var streamer: LiveStreamServerStreamer?
    private let watch = LiveStreamMainThreadWatch()
    private let referencePool = LiveStreamPixelPool()
    private var readLoop: Task<Void, Never>?
    private var forceKeyframe = true
    private var stillFrames = 0
    private var lastTouch = Date.distantPast
    /// Seconds the last capture held the main thread.
    private var lastCapture: TimeInterval = 0
    private var recentTouchIds: [String] = []
    /// The fingers the viewer is driving as they move, while they are down, by the viewer's name for each.
    private var fingers: [String: LiveFinger] = [:]
    /// Places the hand's events on this device's clock; from the first finger down to the last up.
    private var handTimeline: LiveStreamPointerTimeline?
    /// When the viewer last said anything about the hand (seconds, media clock).
    private var handHeardAt: TimeInterval = 0
    private var pointerWatch: Task<Void, Never>?
    private var keyboardObservers: [NSObjectProtocol] = []

    private struct LiveFinger {
        let slot: Int
        var point: CGPoint
        /// When it came down here (seconds, media clock).
        let downAt: TimeInterval
        /// It came down at the edge of the screen (see `TouchSynthesizer.Finger`).
        let fromEdge: Bool
    }
    private var stoppedUntil: Date?
    private var relayViewer: (name: String, seen: Date)?
    private var relayWatch: Task<Void, Never>?
    private let pool = LiveStreamPixelPool()
    private let indicator = LiveStreamIndicator()
    private var stats = Stats()
    private var observers: [NSObjectProtocol] = []

    private struct Stats {
        var since = Date()
        var encoded = 0
        var skipped = 0
        var bytes = 0
        var captureSeconds = 0.0
        var submitSeconds = 0.0
        var captures = 0
        var failedDraws = 0
        var blankDraws = 0
        var surfaceFormat = ""
    }

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { LiveStreamHost.shared.end("The app went to the background") }
        })
    }

    private var isStopped: Bool {
        if let stoppedUntil, stoppedUntil > Date() { return true }
        stoppedUntil = nil
        return false
    }

    private static let stoppedMessage = "Live View was stopped on this device. Try again in a minute."

    // MARK: Offer

    func offer(_ args: [String: Any]) async -> [String: Any] {
        guard UIApplication.shared.applicationState == .active else {
            return ["success": false, "error": "The app isn't in the foreground"]
        }
        if isStopped { return ["success": false, "error": Self.stoppedMessage] }
        guard let encoded = args["key"] as? String, let key = Data(base64Encoded: encoded), key.count == 32 else {
            return ["success": false, "error": "key must be 32 bytes, base64"]
        }
        let viewer = String((args["viewer"] as? String ?? "Live View").prefix(60))
        let viewerId = args["viewerId"] as? String
        if session != nil {
            guard let viewerId, viewerId == self.viewerId else {
                return ["success": false, "error": "This app is already being viewed from \(viewerName)"]
            }
            end("Replaced by a new connection from the same viewer")
        }
        func clamp(_ key: String, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
            min(max((args[key] as? NSNumber)?.intValue ?? fallback, range.lowerBound), range.upperBound)
        }
        settings = Settings(maxLongSide: clamp("maxLongSide", 320...2800, 1280), fps: clamp("fps", 1...30, 15),
                            bitrate: clamp("bitrate", 250_000...8_000_000, 2_500_000))
        settings.captureScale = (args["captureScale"] as? NSNumber).map { CGFloat(min(max($0.doubleValue, 0.5), 2)) }
        settings.ask(capture: args["capture"] as? String)

        let addresses = LiveStreamAddresses.current()
        guard !addresses.isEmpty else {
            return ["success": false, "error": "This device has no Wi-Fi or Tailscale address for a direct connection"]
        }
        let id = UUID().uuidString
        let listener = LiveStreamListener(session: id, key: key)
        let port: UInt16
        do {
            port = try await listener.start()
        } catch {
            return ["success": false, "error": "Couldn't listen for a direct connection: \(error.localizedDescription)"]
        }
        // Another offer may have landed while this one was starting.
        guard session == nil else {
            listener.cancel()
            return ["success": false, "error": "This app is already being viewed from \(viewerName)"]
        }
        session = id
        self.listener = listener
        viewerName = viewer
        self.viewerId = viewerId
        indicator.show("Live View · connecting \(viewer)…") { [weak self] in self?.stopByUser() }
        Task { [weak self] in
            do {
                let accepted = try await listener.accept(timeout: Self.offerLifetime)
                self?.begin(session: id, channel: accepted.channel, hello: accepted.hello)
            } catch {
                if self?.session == id { self?.end("No viewer connected", sendBye: false) }
            }
        }
        var result = frameIdentity()
        result["success"] = true
        result["session"] = id
        result["port"] = Int(port)
        result["addresses"] = addresses.map { ["address": $0.address, "route": $0.route.rawValue] }
        result["expiresIn"] = Self.offerLifetime
        return result
    }

    private func frameIdentity() -> [String: Any] {
        var result: [String: Any] = ["installId": RipulLiveViewIdentity.installId, "model": RipulLiveViewIdentity.model,
                                     "modelName": RipulLiveViewIdentity.modelName, "app": RipulLiveViewIdentity.appName,
                                     "system": UIDevice.current.systemVersion]
        if let window = RipulChrome.appWindow() {
            result["width"] = Double(window.bounds.width)
            result["height"] = Double(window.bounds.height)
        }
        return result
    }

    // MARK: Streaming

    private func begin(session id: String, channel: LiveStreamChannel, hello: [String: Any]) {
        guard session == id else {
            channel.close()
            return
        }
        listener = nil
        self.channel = channel
        if let name = hello["viewer"] as? String, !name.isEmpty { viewerName = String(name.prefix(60)) }
        indicator.show("Live View · \(viewerName)") { [weak self] in self?.stopByUser() }
        forceKeyframe = true
        stats = Stats()
        readLoop = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let (type, payload) = try await channel.receive()
                    guard let self, self.session == id else { return }
                    await self.handle(type, payload, on: channel)
                }
            } catch {
                if let self, self.session == id { self.end("The connection dropped", sendBye: false) }
            }
        }
        watch.start()
        watchKeyboard(on: channel)
        startCapture(session: id, on: channel)
    }

    /// Starts capturing the way the settings say, in place of any way running.
    private func startCapture(session id: String, on channel: LiveStreamChannel) {
        captureLoop?.cancel()
        captureLoop = nil
        streamer?.stop()
        streamer = nil
        if let old = encoder { Task.detached { old.invalidate() } }
        encoder = nil
        if settings.server {
            var identity = frameIdentity()
            identity["touch"] = TouchSynthesizer.isAvailable
            identity["pointer"] = TouchSynthesizer.isAvailable
            identity["fingers"] = TouchSynthesizer.isAvailable ? TouchSynthesizer.mostFingers : 0
            identity["keyboard"] = true
            let streamer = LiveStreamServerStreamer(
                channel: channel,
                settings: .init(maxLongSide: settings.maxLongSide, fps: settings.fps, bitrate: settings.bitrate),
                identity: (try? JSONSerialization.data(withJSONObject: identity)) ?? Data("{}".utf8), watch: watch,
                target: { RipulChrome.appWindow().flatMap(LiveStreamServerCapture.target) },
                reference: { [weak self] in
                    // The app's own drawing of the window, small: what the first capture must resemble.
                    guard let self, let window = RipulChrome.appWindow() else { return nil }
                    let width = max(32, Int(window.bounds.width / 4) * 2), height = max(32, Int(window.bounds.height / 4) * 2)
                    guard let (buffer, drew, _) = self.referencePool.draw(window, width: width, height: height), drew
                    else { return nil }
                    return LiveStreamPixels.lit(buffer)
                },
                unavailable: { [weak self] reason in
                    guard let self, self.session == id, self.settings.server else { return }
                    nwarn("[LiveView] capture off the main thread is not usable, using the main thread: \(reason)")
                    self.settings.server = false
                    self.startCapture(session: id, on: channel)
                },
                cannotEncode: { [weak self] in
                    guard let self, self.session == id else { return }
                    nwarn("[LiveView] no encoder gives pictures back; ending the direct session")
                    self.end(Self.cannotEncodeReason, unsupported: true)
                })
            self.streamer = streamer
            streamer.start()
            return
        }
        captureLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.session == id else { return }
                self.tick(on: channel)
                // Capture holds the main thread (iPhone 15: 15-25 ms from the
                // render server, 50-80 ms redrawing at 1x): keep it to about a
                // third of the main thread, whatever rate was asked for.
                let rate = self.isBusy ? Double(self.settings.fps) : 2
                let interval = max(1 / rate, self.lastCapture * 3)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Full rate while pictures change or just after a touch; about two a second on a still screen.
    private var isBusy: Bool { stillFrames < 5 || Date().timeIntervalSince(lastTouch) < 1.5 }

    private func tick(on channel: LiveStreamChannel) {
        if let stalled = encoder, stalled.stalledFor > Self.encoderPatience {
            // It took a picture and gives none back: the next kind, or give up.
            guard let next = stalled.kind.next else {
                nwarn("[LiveView] no encoder gives pictures back; ending the direct session")
                end(Self.cannotEncodeReason, unsupported: true)
                return
            }
            nwarn("[LiveView] the \(stalled.kind.rawValue) encoder gave nothing back; trying \(next.rawValue)")
            encoderKind = next
            encoder = nil
            Task.detached { stalled.invalidate() }   // it may wait on the picture it never finished
        }
        if let encoder, encoder.isBehind || channel.pendingBytes > Self.backlogLimit {
            stats.skipped += 1
            return
        }
        guard let window = RipulChrome.appWindow(), window.bounds.width > 0, window.bounds.height > 0 else { return }
        let points = window.bounds.size
        func even(_ value: CGFloat, _ scale: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded(.down) * 2) }
        if settings.surface {
            captureSurface(window, points: points, on: channel)
            return
        }
        // drawHierarchy's cost grows with the pixels drawn (iPhone 15: 52-78 ms
        // at 1x, 150-168 ms at 2x) and at the full 3x it fails outright,
        // drawing nothing. So 1x, or 2x for a sharp picture; the encoder
        // scales from there, off the main thread.
        let native = settings.captureScale ?? (settings.maxLongSide > 1600 ? 2 : 1)
        let captured = CGSize(width: even(points.width, native), height: even(points.height, native))
        let scale = min(native, CGFloat(settings.maxLongSide) / max(points.width, points.height))
        let pixels = CGSize(width: even(points.width, scale), height: even(points.height, scale))
        captureSize = captured
        if encoder == nil || pixels != pixelSize || points != pointSize {
            startEncoder(pixels: pixels, points: points, on: channel)
        }
        guard let encoder else { return }
        let started = CACurrentMediaTime()
        guard let (buffer, drew, blank) = pool.draw(window, width: Int(captured.width), height: Int(captured.height))
        else { return }
        let drawn = CACurrentMediaTime()
        lastCapture = drawn - started
        if blank { stats.blankDraws += 1 }
        guard drew else {
            // Never send a picture that wasn't drawn; draw less next time.
            stats.failedDraws += 1
            settings.captureScale = max(0.5, native / 2)
            return
        }
        encoder.encode(buffer, micros: UInt64(drawn * 1_000_000), keyframe: forceKeyframe)
        stats.captureSeconds += drawn - started
        stats.submitSeconds += CACurrentMediaTime() - drawn
        stats.captures += 1
        forceKeyframe = false
        sendStatsIfDue(on: channel)
    }

    /// Experimental capture: the render server's picture of the window, at
    /// the screen's own size; the encoder scales it to the picture size.
    private func captureSurface(_ window: UIWindow, points: CGSize, on channel: LiveStreamChannel) {
        let scale = min(window.screen.scale, CGFloat(settings.maxLongSide) / max(points.width, points.height))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded(.down) * 2) }
        let pixels = CGSize(width: even(points.width), height: even(points.height))
        let started = CACurrentMediaTime()
        guard let captured = LiveStreamSurfaceCapture.capture(window) else {
            // Not there after all (an iOS update can take it away): redraw instead.
            stats.failedDraws += 1
            settings.surface = false
            return
        }
        let drawn = CACurrentMediaTime()
        lastCapture = drawn - started
        captureSize = CGSize(width: CVPixelBufferGetWidth(captured.buffer), height: CVPixelBufferGetHeight(captured.buffer))
        stats.surfaceFormat = captured.format
        if captured.blank { stats.blankDraws += 1 }
        if encoder == nil || pixels != pixelSize || points != pointSize {
            startEncoder(pixels: pixels, points: points, on: channel)
        }
        guard let encoder else { return }
        encoder.encode(captured.buffer, micros: UInt64(drawn * 1_000_000), keyframe: forceKeyframe)
        stats.captureSeconds += drawn - started
        stats.submitSeconds += CACurrentMediaTime() - drawn
        stats.captures += 1
        forceKeyframe = false
        sendStatsIfDue(on: channel)
    }

    private func startEncoder(pixels: CGSize, points: CGSize, on channel: LiveStreamChannel) {
        if let old = encoder { Task.detached { old.invalidate() } }
        encoder = nil
        do {
            encoder = try LiveStreamEncoder(width: Int32(pixels.width), height: Int32(pixels.height),
                                            fps: settings.fps, bitrate: settings.bitrate,
                                            kind: encoderKind) { [weak self] frame in
                if frame.keyframe, let sets = frame.parameterSets {
                    channel.enqueue(.format, LiveStreamWire.format(sps: sets.sps, pps: sets.pps))
                }
                channel.enqueue(.video, LiveStreamWire.video(keyframe: frame.keyframe,
                                                             presentationMicros: frame.presentationMicros, avcc: frame.avcc))
                let still = !frame.keyframe && frame.avcc.count < LiveStreamHost.stillFrameBytes
                let bytes = frame.avcc.count
                Task { @MainActor in self?.encoded(bytes: bytes, still: still) }
            }
        } catch {
            end(Self.cannotEncodeReason, unsupported: true)
            return
        }
        encoderKind = encoder?.kind ?? encoderKind
        pixelSize = pixels
        pointSize = points
        forceKeyframe = true
        var config = frameIdentity()
        config["width"] = Double(points.width)
        config["height"] = Double(points.height)
        config["pixelWidth"] = Int(pixels.width)
        config["pixelHeight"] = Int(pixels.height)
        config["fps"] = settings.fps
        config["bitrate"] = settings.bitrate
        config["touch"] = TouchSynthesizer.isAvailable
        config["capture"] = settings.capture
        config["encoder"] = encoderKind.rawValue
        config["pointer"] = TouchSynthesizer.isAvailable
        config["fingers"] = TouchSynthesizer.isAvailable ? TouchSynthesizer.mostFingers : 0
        config["keyboard"] = true
        channel.enqueue(.config, (try? JSONSerialization.data(withJSONObject: config)) ?? Data("{}".utf8))
    }

    private func encoded(bytes: Int, still: Bool) {
        stats.encoded += 1
        stats.bytes += bytes
        stillFrames = still ? stillFrames + 1 : 0
    }

    private func sendStatsIfDue(on channel: LiveStreamChannel) {
        let elapsed = Date().timeIntervalSince(stats.since)
        guard elapsed >= 2 else { return }
        let app = watch.reading()
        let payload: [String: Any] = [
            "fps": Double(stats.encoded) / elapsed,
            "captureMs": stats.captures > 0 ? stats.captureSeconds / Double(stats.captures) * 1000 : 0,
            "submitMs": stats.captures > 0 ? stats.submitSeconds / Double(stats.captures) * 1000 : 0,
            "kbps": Double(stats.bytes * 8) / elapsed / 1000,
            "skipped": stats.skipped,
            "captures": stats.captures, "failedDraws": stats.failedDraws, "blankDraws": stats.blankDraws,
            "captureSize": "\(Int(captureSize.width))x\(Int(captureSize.height))",
            "capture": settings.capture, "surfaceFormat": stats.surfaceFormat,
            "encodeFailures": encoder?.failures ?? 0, "encoder": encoderKind.rawValue,
            "appFps": app.fps, "worstGapMs": app.worstGapMs, "thermal": LiveStreamMainThreadWatch.thermal(),
            "pixelWidth": Int(pixelSize.width), "pixelHeight": Int(pixelSize.height),
        ]
        channel.enqueue(.stats, (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
        stats = Stats()
    }

    private func handle(_ type: LiveStreamMessage, _ payload: Data, on channel: LiveStreamChannel) async {
        switch type {
        case .touch:
            let json = LiveStreamWire.json(payload)
            let id = json["id"] as? String ?? UUID().uuidString
            // At most once: a gesture repeated after a reconnect is not replayed.
            guard !recentTouchIds.contains(id) else {
                try? await channel.send(.touchResult, json: ["id": id, "success": false, "duplicate": true])
                return
            }
            recentTouchIds.append(id)
            if recentTouchIds.count > 64 { recentTouchIds.removeFirst() }
            var args = json
            args.removeValue(forKey: "id")
            lastTouch = Date()
            streamer?.touchedNow()
            let result = (try? await TouchTool().execute(args: args)) as? [String: Any] ?? ["success": false]
            var reply: [String: Any] = ["id": id, "success": result["success"] as? Bool ?? false]
            if let error = result["error"] { reply["error"] = error }
            try? await channel.send(.touchResult, json: reply)
        case .pointer:
            await handlePointer(LiveStreamWire.json(payload))
        case .key:
            lastTouch = Date()
            streamer?.touchedNow()
            LiveStreamTyping.apply(LiveStreamWire.json(payload))
        case .control:
            let json = LiveStreamWire.json(payload)
            if json["scrollToTop"] as? Bool == true, let window = ScreenElementFinder.hostWindow() {
                lastTouch = Date()
                streamer?.touchedNow()
                LiveStreamScrollToTop.perform(in: window)
            }
            if json["keyframe"] as? Bool == true {
                forceKeyframe = true
                streamer?.requestKeyframe()
            }
            var changed = false
            func set(_ key: String, _ range: ClosedRange<Int>, _ value: inout Int) {
                guard let asked = (json[key] as? NSNumber)?.intValue else { return }
                let clamped = min(max(asked, range.lowerBound), range.upperBound)
                if clamped != value {
                    value = clamped
                    changed = true
                }
            }
            set("maxLongSide", 320...2800, &settings.maxLongSide)
            set("fps", 1...30, &settings.fps)
            set("bitrate", 250_000...8_000_000, &settings.bitrate)
            if let capture = json["capture"] as? String {
                let before = settings.capture
                settings.ask(capture: capture)
                if settings.capture != before, let session {
                    startCapture(session: session, on: channel)
                    return
                }
            }
            if changed {
                if let streamer {
                    streamer.update(.init(maxLongSide: settings.maxLongSide, fps: settings.fps, bitrate: settings.bitrate))
                } else {
                    if let old = encoder { Task.detached { old.invalidate() } }
                    encoder = nil
                }
            }
        case .ping:
            try? await channel.send(.pong, payload)
        case .bye:
            end(LiveStreamWire.json(payload)["reason"] as? String ?? "The viewer left", sendBye: false)
        default:
            break
        }
    }

    // MARK: Live touches

    /// Fingers driven by the viewer as they move there: down, their moves, up.
    /// Each message is one moment of the hand; it goes to the app as one
    /// touch event carrying every finger that is down.
    private func handlePointer(_ json: [String: Any]) async {
        guard TouchSynthesizer.isAvailable, let window = ScreenElementFinder.hostWindow() else { return }
        // One finger may come bare, as {id, phase, x, y, t}.
        let said = json["fingers"] as? [[String: Any]] ?? [json]
        let offset = (json["t"] as? NSNumber)?.doubleValue ?? 0
        let bounds = window.bounds
        let heard = CACurrentMediaTime()
        lastTouch = Date()
        streamer?.touchedNow()

        var phases: [String: TouchSynthesizer.Phase] = [:]
        var pressedBriefly = 0.0
        for finger in said {
            guard let id = finger["id"] as? String, let phase = finger["phase"] as? String else { continue }
            var point = fingers[id]?.point
            if let x = (finger["x"] as? NSNumber)?.doubleValue, let y = (finger["y"] as? NSNumber)?.doubleValue {
                point = CGPoint(x: min(max(x, 0), bounds.maxX - 1), y: min(max(y, 0), bounds.maxY - 1))
            }
            switch phase {
            case "down":
                guard fingers[id] == nil, let point, fingers.count < TouchSynthesizer.mostFingers,
                      let slot = (0..<TouchSynthesizer.mostFingers).first(where: { slot in
                          !fingers.values.contains { $0.slot == slot }
                      }) else { continue }
                if fingers.isEmpty {
                    handTimeline = LiveStreamPointerTimeline(start: mach_absolute_time(),
                                                             ticksPerMillisecond: TouchSynthesizer.ticksPerMillisecond)
                }
                fingers[id] = LiveFinger(slot: slot, point: point, downAt: heard,
                                         fromEdge: TouchSynthesizer.isAtEdge(point, of: window))
                phases[id] = .down
            case "move":
                guard var live = fingers[id], let point else { continue }
                // The same point again is the viewer saying the finger is still there.
                if point != live.point {
                    live.point = point
                    fingers[id] = live
                    phases[id] = .moved
                }
            case "up", "cancel":
                guard var live = fingers[id] else { continue }
                if let point { live.point = point }
                fingers[id] = live
                phases[id] = phase == "up" ? .up : .cancelled
                if phase == "up" { pressedBriefly = max(pressedBriefly, Self.pointerMinimumPress - (heard - live.downAt)) }
            default:
                continue
            }
        }
        handHeardAt = heard
        guard !phases.isEmpty else { return }
        if pressedBriefly > 0 {
            // A tap's down and up can arrive together; UIKit needs them apart.
            try? await Task.sleep(nanoseconds: UInt64(pressedBriefly * 1_000_000_000))
        }
        let hand = fingers.compactMap { id, finger -> TouchSynthesizer.Finger? in
            TouchSynthesizer.Finger(slot: finger.slot, point: finger.point, phase: phases[id] ?? .held,
                                    fromEdge: finger.fromEdge)
        }
        let time = handTimeline?.time(offsetMilliseconds: offset, now: mach_absolute_time())
        try? TouchSynthesizer.hand(hand, in: window, time: phases.values.contains(.down) && fingers.count == 1 ? nil : time)
        for (id, phase) in phases where phase == .up || phase == .cancelled { fingers.removeValue(forKey: id) }
        if fingers.isEmpty {
            handTimeline = nil
            pointerWatch?.cancel()
            pointerWatch = nil
            ScreenSnapshotStore.shared.invalidate()
        } else if pointerWatch == nil {
            watchFingers()
        }
    }

    /// Ends the fingers that are still down, as cancelled: the app must not
    /// take a gesture nobody finished for a tap.
    private func liftFingers() {
        pointerWatch?.cancel()
        pointerWatch = nil
        guard !fingers.isEmpty else { return }
        let hand = fingers.values.map {
            TouchSynthesizer.Finger(slot: $0.slot, point: $0.point, phase: .cancelled, fromEdge: $0.fromEdge)
        }
        fingers.removeAll()
        handTimeline = nil
        guard let window = ScreenElementFinder.hostWindow() else { return }
        try? TouchSynthesizer.hand(hand, in: window)
        ScreenSnapshotStore.shared.invalidate()
    }

    private func watchFingers() {
        pointerWatch?.cancel()
        pointerWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !self.fingers.isEmpty else { return }
                if CACurrentMediaTime() - self.handHeardAt > Self.pointerSilence {
                    self.liftFingers()
                    return
                }
            }
        }
    }

    // MARK: Keyboard

    /// Tells the viewer when the keyboard comes up or goes away here, and
    /// what kind it is, so the viewer can show its own in its place: this
    /// device's keyboard belongs to the system and is in no picture.
    private func watchKeyboard(on channel: LiveStreamChannel) {
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { channel.enqueue(.keyboard, LiveStreamTyping.keyboard(visible: true)) }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { channel.enqueue(.keyboard, LiveStreamTyping.keyboard(visible: false)) }
            },
        ]
        // It may be up already.
        if LiveStreamTyping.focused() is UIKeyInput {
            channel.enqueue(.keyboard, LiveStreamTyping.keyboard(visible: true))
        }
    }

    // MARK: Ending

    /// `unsupported` tells the viewer not to try a direct connection to this device again.
    func end(_ reason: String, sendBye: Bool = true, unsupported: Bool = false) {
        liftFingers()
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        keyboardObservers.removeAll()
        let channel = self.channel
        listener?.cancel()
        captureLoop?.cancel()
        streamer?.stop()
        streamer = nil
        watch.stop()
        readLoop?.cancel()
        if let last = encoder { Task.detached { last.invalidate() } }
        encoderKind = .first
        session = nil
        listener = nil
        self.channel = nil
        encoder = nil
        viewerId = nil
        pixelSize = .zero
        pointSize = .zero
        stillFrames = 0
        recentTouchIds.removeAll()
        if let channel {
            Task {
                if sendBye { try? await channel.send(.bye, json: ["reason": reason, "unsupported": unsupported]) }
                channel.close()
            }
        }
        if relayViewer == nil { indicator.hide() }
    }

    private func stopByUser() {
        stoppedUntil = Date().addingTimeInterval(Self.stopHold)
        relayViewer = nil
        relayWatch?.cancel()
        end("Stopped on the \(RipulLiveViewIdentity.modelName)")
        indicator.hide()
    }

    // MARK: Relay viewers

    /// For `screen_frame` and `touch`: nil to go ahead, or why not. Calls
    /// marked purpose "liveview" come from a viewer (agents' calls don't):
    /// they keep the pill up, and are turned away after Stop.
    func relayRefusal(_ args: [String: Any]) -> String? {
        guard args["purpose"] as? String == "liveview" else { return nil }
        if isStopped { return Self.stoppedMessage }
        let name = String((args["viewer"] as? String ?? "Live View").prefix(60))
        relayViewer = (name, Date())
        if session == nil {
            indicator.show("Live View · \(name)") { [weak self] in self?.stopByUser() }
        }
        if relayWatch == nil {
            relayWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, let viewer = self.relayViewer else { return }
                    if Date().timeIntervalSince(viewer.seen) > 4 {
                        self.relayViewer = nil
                        self.relayWatch = nil
                        if self.session == nil { self.indicator.hide() }
                        return
                    }
                }
            }
        }
        return nil
    }
}

// MARK: - Capture

/// The app window, drawn into IOSurface-backed 8-bit BGRA buffers the
/// encoder takes (and scales) without a copy. Same public API as `screen_frame`: no prompt, and
/// only the app's own window — not the keyboard, the status bar or SDK chrome.
@MainActor
final class LiveStreamPixelPool {
    private var pool: CVPixelBufferPool?
    private var size = (width: 0, height: 0)

    /// The buffer, whether drawHierarchy said it drew, and whether a sample of pixels came out all zero.
    func draw(_ window: UIWindow, width: Int, height: Int) -> (CVPixelBuffer, Bool, Bool)? {
        if pool == nil || size != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                    attributes as CFDictionary, &pool)
            size = (width, height)
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // UIKit draws top-down; a bitmap context counts from the bottom.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        let drew = window.drawHierarchy(in: CGRect(x: 0, y: 0, width: width, height: height), afterScreenUpdates: false)
        UIGraphicsPopContext()
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
        let row = CVPixelBufferGetBytesPerRow(buffer) / 4
        var blank = true
        for y in stride(from: height / 8, to: height, by: height / 4) {
            for x in stride(from: width / 8, to: width, by: width / 4) where base[y * row + x] & 0x00FF_FFFF != 0 {
                blank = false
            }
        }
        return (buffer, drew, blank)
    }
}

// MARK: - Capture from the render server (experimental)

/// The window as the render server draws it, straight into an IOSurface at
/// the screen's own size: nothing is redrawn in this process, which is what
/// makes `drawHierarchy` slow. DEV-ONLY private API
/// (`-[UIWindow createIOSurface]`), resolved at runtime and compiled into
/// DEBUG (and `RIPUL_DEVELOPER_BUILD`) builds only, like `TouchSynthesizer`; elsewhere `isAvailable` is
/// false and capture redraws.
@MainActor
enum LiveStreamSurfaceCapture {
    #if DEBUG || RIPUL_DEVELOPER_BUILD
    private typealias Create = @convention(c) (AnyObject, Selector) -> Unmanaged<IOSurfaceRef>?
    private static let selector = NSSelectorFromString("createIOSurface")

    static var isAvailable: Bool { UIWindow.instancesRespond(to: selector) }

    /// The picture, its pixel format's four characters, and whether a sample of it is all zero.
    static func capture(_ window: UIWindow) -> (buffer: CVPixelBuffer, format: String, blank: Bool)? {
        guard window.responds(to: selector) else { return nil }
        let create = unsafeBitCast(window.method(for: selector), to: Create.self)
        guard let surface = create(window, selector)?.takeRetainedValue() else { return nil }
        var made: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &made) == kCVReturnSuccess,
              let buffer = made?.takeRetainedValue() else { return nil }
        let code = IOSurfaceGetPixelFormat(surface)
        let format = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
        // Sampled for 8-bit BGRA only; wide-colour surfaces (b3a8) pack pixels differently.
        var blank = code == kCVPixelFormatType_32BGRA
        if blank, IOSurfaceLock(surface, .readOnly, nil) == KERN_SUCCESS {
            let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
            let row = IOSurfaceGetBytesPerRow(surface)
            let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
            if width >= 8, height >= 8, row >= width * 4 {
                for y in stride(from: height / 8, to: height, by: height / 4) {
                    for x in stride(from: width / 8, to: width, by: width / 4) {
                        let word = UnsafeRawPointer(base + y * row + x * 4).loadUnaligned(as: UInt32.self)
                        if word & 0x00FF_FFFF != 0 { blank = false }
                    }
                }
            }
            IOSurfaceUnlock(surface, .readOnly, nil)
        }
        return (buffer, format, blank)
    }
    #else
    static var isAvailable: Bool { false }
    static func capture(_ window: UIWindow) -> (buffer: CVPixelBuffer, format: String, blank: Bool)? { nil }
    #endif
}

// MARK: - Indicator

/// "Live View · Peter's iPhone 17" with Stop, top centre, above everything.
/// After a few seconds it shrinks to a small "Live" mark, so it isn't over
/// the app's title; a tap brings it back. Its window takes touches on the
/// pill only; the rest go to the app.
@MainActor
final class LiveStreamIndicator {
    private var window: LiveStreamIndicatorWindow?
    private var model = LiveStreamIndicatorModel()

    func show(_ text: String, onStop: @escaping () -> Void) {
        model.text = text
        model.onStop = onStop
        model.open()
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        let created = LiveStreamIndicatorWindow(windowScene: scene)
        created.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 5)
        created.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        let host = UIHostingController(rootView: LiveStreamIndicatorPill(model: model))
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        root.addChild(host)
        root.view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: root.view.centerXAnchor),
            host.view.topAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.topAnchor, constant: 2),
        ])
        host.didMove(toParent: root)
        created.pill = host.view
        created.installRoot(root)
        created.isHidden = false
        window = created
    }

    func hide() {
        model.close()
        window?.isHidden = true
        window = nil
    }
}

@MainActor
@Observable
final class LiveStreamIndicatorModel {
    var text = ""
    /// Showing who is watching and Stop, not only the mark.
    var isOpen = true
    @ObservationIgnored var onStop: () -> Void = {}
    @ObservationIgnored private var shrinking: Task<Void, Never>?
    /// How long it stays open before shrinking to the mark.
    static let openFor: Duration = .seconds(4)

    /// Opens it, to shrink again by itself.
    func open() {
        isOpen = true
        shrinking?.cancel()
        shrinking = Task { [weak self] in
            try? await Task.sleep(for: Self.openFor)
            guard !Task.isCancelled else { return }
            self?.isOpen = false
        }
    }

    func close() {
        shrinking?.cancel()
        shrinking = nil
    }
}

final class LiveStreamIndicatorWindow: RipulChromeWindow {
    weak var pill: UIView?

    override var acceptsPresentation: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // A little beyond the pill: shrunk, it is a small thing to hit.
        guard let pill, pill.frame.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        return super.hitTest(point, with: event) ?? pill
    }
}

struct LiveStreamIndicatorPill: View {
    let model: LiveStreamIndicatorModel

    var body: some View {
        Group {
            if model.isOpen {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(model.text)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Button("Stop") { model.onStop() }
                        .font(.footnote.weight(.bold))
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.mini)
                        .uiKitIdentifier("LiveStreamIndicator.stop")
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 5)
            } else {
                Button { model.open() } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("Live").font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows who is watching, and Stop")
                .uiKitIdentifier("LiveStreamIndicator.mark")
            }
        }
        .modifier(LiveStreamIndicatorBackground())
        .animation(.snappy(duration: 0.25), value: model.isOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This app is being viewed with Live View")
        .uiKitIdentifier("LiveStreamIndicator.pill")
    }
}

private struct LiveStreamIndicatorBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
#endif
