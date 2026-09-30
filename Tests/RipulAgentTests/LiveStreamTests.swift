import Network
import VideoToolbox
import XCTest
@testable import RipulAgent

final class LiveStreamWireTests: XCTestCase {
    func testFrameRoundTripsAndHeadersEnforceTheLimit() {
        let payload = Data("{\"session\":\"s\"}".utf8)
        let framed = LiveStreamWire.frame(.hello, payload)
        XCTAssertEqual(framed.count, LiveStreamWire.headerLength + payload.count)
        let header = LiveStreamWire.header(framed.prefix(5), limit: LiveStreamWire.maxToApp)
        XCTAssertEqual(header?.type, .hello)
        XCTAssertEqual(header?.length, payload.count)
        XCTAssertEqual(LiveStreamWire.json(framed.dropFirst(5))["session"] as? String, "s")
        XCTAssertNil(LiveStreamWire.header(framed.prefix(5), limit: payload.count - 1), "Over the limit")
        XCTAssertNil(LiveStreamWire.header(Data([0, 0, 0, 0, 1]), limit: 100), "Unknown type")
        XCTAssertNil(LiveStreamWire.header(Data([1, 0, 0]), limit: 100), "Short header")
    }

    func testFormatAndVideoPayloads() {
        let sps = Data([0x67, 1, 2, 3]), pps = Data([0x68, 4])
        let format = LiveStreamWire.format(sps: sps, pps: pps)
        XCTAssertEqual(LiveStreamWire.parseFormat(format)?.sps, sps)
        XCTAssertEqual(LiveStreamWire.parseFormat(format)?.pps, pps)
        XCTAssertNil(LiveStreamWire.parseFormat(format.dropLast()))
        XCTAssertNil(LiveStreamWire.parseFormat(format + Data([9])), "Trailing bytes")

        let avcc = Data([0, 0, 0, 2, 0x65, 0x88])
        let video = LiveStreamWire.video(keyframe: true, presentationMicros: 1_234_567, avcc: avcc)
        let parsed = LiveStreamWire.parseVideo(video)
        XCTAssertEqual(parsed?.keyframe, true)
        XCTAssertEqual(parsed?.presentationMicros, 1_234_567)
        XCTAssertEqual(parsed?.avcc, avcc)
        XCTAssertEqual(LiveStreamWire.parseVideo(LiveStreamWire.video(keyframe: false, presentationMicros: 0, avcc: avcc))?.keyframe, false)
        XCTAssertNil(LiveStreamWire.parseVideo(Data([1, 0, 0])))
    }

    func testAddressRoutes() {
        XCTAssertEqual(LiveStreamAddresses.route(for: "192.168.0.228"), .lan)
        XCTAssertEqual(LiveStreamAddresses.route(for: "10.1.2.3"), .lan)
        XCTAssertEqual(LiveStreamAddresses.route(for: "172.20.10.2"), .lan)
        XCTAssertEqual(LiveStreamAddresses.route(for: "100.101.102.103"), .tailnet)
        XCTAssertNil(LiveStreamAddresses.route(for: "100.128.0.1"))
        XCTAssertNil(LiveStreamAddresses.route(for: "8.8.8.8"))
        XCTAssertNil(LiveStreamAddresses.route(for: "172.32.0.1"))
        XCTAssertNil(LiveStreamAddresses.route(for: "192.168.00.1"), "Not canonical")
        XCTAssertNil(LiveStreamAddresses.route(for: "192.168.1"))
    }
}

/// Real TLS over loopback: the handshake, the key and session checks, and
/// that a listener lets exactly one viewer in.
final class LiveStreamConnectionTests: XCTestCase {
    private func listening() async throws -> (LiveStreamListener, UInt16) {
        let listener = LiveStreamListener()
        let port = try await listener.start()
        XCTAssertGreaterThan(port, 0)
        return (listener, port)
    }

    func testRightKeyAndSessionConnectAndTalkBothWays() async throws {
        let (listener, port) = try await listening()
        async let accepted = listener.accept(timeout: 5)
        let (viewer, address) = try await LiveStreamClient.connect(
            to: ["127.0.0.1"], port: port, key: listener.key, session: listener.session,
            hello: ["viewer": "test"], timeout: 3)
        let (app, hello) = try await accepted
        XCTAssertEqual(address, "127.0.0.1")
        XCTAssertEqual(hello["viewer"] as? String, "test")
        XCTAssertTrue(LiveStreamTLS.isProtected(app.connection))
        XCTAssertTrue(LiveStreamTLS.isProtected(viewer.connection))

        try await viewer.send(.touch, json: ["id": "g1", "action": "tap", "x": 10, "y": 20])
        let touch = try await app.receive()
        XCTAssertEqual(touch.type, .touch)
        XCTAssertEqual(LiveStreamWire.json(touch.payload)["id"] as? String, "g1")

        let video = LiveStreamWire.video(keyframe: true, presentationMicros: 42, avcc: Data(repeating: 7, count: 200_000))
        try await app.send(.video, video)
        let received = try await viewer.receive()
        XCTAssertEqual(received.type, .video)
        XCTAssertEqual(LiveStreamWire.parseVideo(received.payload)?.avcc.count, 200_000)
        XCTAssertEqual(app.pendingBytes, 0)
        app.close(); viewer.close()
    }

    func testTheListenerIsSingleUse() async throws {
        let (listener, port) = try await listening()
        async let accepted = listener.accept(timeout: 5)
        let first = try await LiveStreamClient.connect(to: ["127.0.0.1"], port: port, key: listener.key,
                                                       session: listener.session, timeout: 3)
        let (app, _) = try await accepted
        do {
            let second = try await LiveStreamClient.connect(to: ["127.0.0.1"], port: port, key: listener.key,
                                                            session: listener.session, timeout: 2)
            second.channel.close()
            XCTFail("A second viewer must not reach a used listener")
        } catch {}
        app.close(); first.channel.close()
    }

    func testAWrongKeyFailsAndTheRightViewerStillGetsIn() async throws {
        let (listener, port) = try await listening()
        async let accepted = listener.accept(timeout: 8)
        do {
            let wrong = try await LiveStreamClient.connect(to: ["127.0.0.1"], port: port, key: LiveStreamTLS.newKey(),
                                                           session: listener.session, timeout: 2)
            wrong.channel.close()
            XCTFail("A wrong key must not complete the handshake")
        } catch {}
        let right = try await LiveStreamClient.connect(to: ["127.0.0.1"], port: port, key: listener.key,
                                                       session: listener.session, timeout: 3)
        let (app, _) = try await accepted
        app.close(); right.channel.close()
    }

    func testAHelloForAnotherSessionIsRefused() async throws {
        let (listener, port) = try await listening()
        async let accepted = listener.accept(timeout: 8)
        // Right key, but the hello names another session: the handshake
        // completes, then the app closes the connection without admitting it.
        let parameters = LiveStreamTLS.parameters(key: listener.key, session: listener.session)
        let stranger = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        try await stranger.liveStreamReady(queue: DispatchQueue(label: "stranger"), timeout: 3)
        let channel = LiveStreamChannel(stranger, receiveLimit: LiveStreamWire.maxToViewer)
        try await channel.send(.hello, json: ["session": "someone-else"])
        do {
            _ = try await channel.receive()
            XCTFail("The app must close a hello for another session")
        } catch {}
        let right = try await LiveStreamClient.connect(to: ["127.0.0.1"], port: port, key: listener.key,
                                                       session: listener.session, timeout: 3)
        let (app, _) = try await accepted
        app.close(); right.channel.close()
    }

    func testPlainPreSharedKeyWithoutKeyExchangeIsRefused() async throws {
        let (listener, port) = try await listening()
        async let accepted = listener.accept(timeout: 4)
        // TLS_PSK_WITH_AES_128_GCM_SHA256 only: no ECDHE, so no forward secrecy.
        let parameters = LiveStreamTLS.parameters(key: listener.key, session: listener.session, suites: [0x00A8])
        let weak = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        let admitted: Bool
        do {
            try await weak.liveStreamReady(queue: DispatchQueue(label: "weak"), timeout: 3)
            XCTAssertFalse(LiveStreamTLS.isProtected(weak), "Must not negotiate a plain PSK suite")
            let channel = LiveStreamChannel(weak, receiveLimit: LiveStreamWire.maxToViewer)
            try await channel.send(.hello, json: ["session": listener.session])
            _ = try await channel.receive()
            admitted = true
        } catch {
            admitted = false
        }
        XCTAssertFalse(admitted)
        do {
            let (app, _) = try await accepted
            app.close()
            XCTFail("An unprotected connection must not be accepted")
        } catch {
            XCTAssertEqual(error as? LiveStreamError, .timedOut)
        }
    }

    func testTheListenerClosesAtItsDeadline() async throws {
        let (listener, port) = try await listening()
        do {
            _ = try await listener.accept(timeout: 0.5)
            XCTFail("Nobody connected")
        } catch {
            XCTAssertEqual(error as? LiveStreamError, .timedOut)
        }
        do {
            let late = try await LiveStreamClient.connect(to: ["127.0.0.1"], port: port, key: listener.key,
                                                          session: listener.session, timeout: 2)
            late.channel.close()
            XCTFail("The port must be closed after the deadline")
        } catch {}
    }

    func testOneUnreachableAddressDoesNotBlockAReachableOne() async throws {
        let (listener, port) = try await listening()
        async let accepted = listener.accept(timeout: 5)
        // 192.0.2.1 is TEST-NET-1: never routed, so it can only time out.
        let started = Date()
        let (viewer, address) = try await LiveStreamClient.connect(
            to: ["192.0.2.1", "127.0.0.1"], port: port, key: listener.key, session: listener.session, timeout: 3)
        XCTAssertEqual(address, "127.0.0.1")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        let (app, _) = try await accepted
        app.close(); viewer.close()
    }
}

/// H.264 through the whole path: encode, wire payloads, sample buffers, decode.
final class LiveStreamVideoTests: XCTestCase {
    private func picture(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer!)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * row + x * 4
                pixel[0] = UInt8(truncatingIfNeeded: x &+ Int(shade)); pixel[1] = UInt8(truncatingIfNeeded: y)
                pixel[2] = shade; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        return buffer!
    }

    private final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var frames: [LiveStreamEncodedFrame] = []
    }

    func testEncodedPicturesCrossTheWireAndDecode() throws {
        let collected = Collected()
        let encoder = try LiveStreamEncoder(width: 390, height: 844, fps: 15, bitrate: 2_000_000) { frame in
            collected.lock.withLock { collected.frames.append(frame) }
        }
        let first = picture(width: 390, height: 844, shade: 10)
        encoder.encode(first, micros: 0, keyframe: true)
        encoder.encode(picture(width: 390, height: 844, shade: 90), micros: 66_000, keyframe: false)
        for index in 2..<8 { encoder.encode(first, micros: UInt64(index) * 66_000, keyframe: false) }
        encoder.invalidate()
        let frames = collected.lock.withLock { collected.frames }
        XCTAssertEqual(frames.count, 8)
        XCTAssertTrue(frames[0].keyframe)
        XCTAssertFalse(frames[1].keyframe)
        let sets = try XCTUnwrap(frames[0].parameterSets)
        // A still screen encodes to next to nothing: the idle back-off relies on it.
        XCTAssertLessThan(frames[7].avcc.count, 1_000, "An unchanged picture should be tiny")

        let wireFormat = try XCTUnwrap(LiveStreamWire.parseFormat(LiveStreamWire.format(sps: sets.sps, pps: sets.pps)))
        let format = try XCTUnwrap(LiveStreamVideoFormat.description(sps: wireFormat.sps, pps: wireFormat.pps))
        XCTAssertEqual(LiveStreamVideoFormat.dimensions(format).width, 390)
        XCTAssertEqual(LiveStreamVideoFormat.dimensions(format).height, 844)

        var decompression: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: nil, outputCallback: nil,
                                                    decompressionSessionOut: &decompression), noErr)
        var decoded: [(Int, Int)] = []
        for frame in frames {
            let wire = try XCTUnwrap(LiveStreamWire.parseVideo(LiveStreamWire.video(
                keyframe: frame.keyframe, presentationMicros: frame.presentationMicros, avcc: frame.avcc)))
            let sample = try XCTUnwrap(LiveStreamVideoFormat.sample(avcc: wire.avcc, micros: wire.presentationMicros, format: format))
            VTDecompressionSessionDecodeFrame(decompression!, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, let image { decoded.append((CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))) }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decompression!)
        VTDecompressionSessionInvalidate(decompression!)
        XCTAssertEqual(decoded.count, 8)
        XCTAssertTrue(decoded.allSatisfy { $0 == (390, 844) })
    }

    /// The app captures at the screen's own size (a straight copy — resampling
    /// on the main thread is what made capture slow) and the encoder scales.
    func testTheEncoderScalesALargerCaptureDownToItsOwnSize() throws {
        let collected = Collected()
        let encoder = try LiveStreamEncoder(width: 590, height: 1280, fps: 15, bitrate: 2_000_000) { frame in
            collected.lock.withLock { collected.frames.append(frame) }
        }
        encoder.encode(picture(width: 1290, height: 2796, shade: 40), micros: 0, keyframe: true)
        encoder.invalidate()
        let frame = try XCTUnwrap(collected.lock.withLock { collected.frames.first })
        let sets = try XCTUnwrap(frame.parameterSets)
        let format = try XCTUnwrap(LiveStreamVideoFormat.description(sps: sets.sps, pps: sets.pps))
        XCTAssertEqual(LiveStreamVideoFormat.dimensions(format).width, 590)
        XCTAssertEqual(LiveStreamVideoFormat.dimensions(format).height, 1280)
    }
}

final class LiveStreamPointerTests: XCTestCase {
    func testEventsKeepTheSpacingTheFingerGaveThemHoweverTheyArrive() {
        // 1000 ticks a millisecond; the finger came down at tick 5_000_000.
        var timeline = LiveStreamPointerTimeline(start: 5_000_000, ticksPerMillisecond: 1000)
        // Three moves, 16 ms apart on the viewer, all arriving together 60 ms after the down.
        let now: UInt64 = 5_060_000
        XCTAssertEqual(timeline.time(offsetMilliseconds: 16, now: now), 5_016_000)
        XCTAssertEqual(timeline.time(offsetMilliseconds: 32, now: now), 5_032_000)
        XCTAssertEqual(timeline.time(offsetMilliseconds: 48, now: now), 5_048_000)
    }

    func testTimesNeverRunAheadOfNowOrGoBackwards() {
        var timeline = LiveStreamPointerTimeline(start: 1_000, ticksPerMillisecond: 1000)
        // The viewer's clock says 50 ms, but only 20 ms have passed here.
        XCTAssertEqual(timeline.time(offsetMilliseconds: 50, now: 21_000), 21_000)
        // An earlier time after a later one still moves forward.
        XCTAssertEqual(timeline.time(offsetMilliseconds: 10, now: 30_000), 21_001)
        // Nonsense from the wire does no harm.
        XCTAssertEqual(timeline.time(offsetMilliseconds: -5, now: 30_000), 21_002)
        XCTAssertEqual(timeline.time(offsetMilliseconds: .nan, now: 30_000), 21_003)
        XCTAssertEqual(timeline.time(offsetMilliseconds: .infinity, now: 40_000), 21_004)
    }

    func testAKindThisBuildDoesNotKnowIsSkipped() async throws {
        let listener = LiveStreamListener()
        let port = try await listener.start()
        async let accepted = listener.accept(timeout: 5)
        let (viewer, _) = try await LiveStreamClient.connect(to: ["127.0.0.1"], port: port, key: listener.key,
                                                             session: listener.session, timeout: 3)
        let (app, _) = try await accepted
        // Kind 200 doesn't exist: what a viewer built later might send.
        var unknown = Data([200, 0, 0, 0, 3])
        unknown.append(Data([1, 2, 3]))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            viewer.connection.send(content: unknown, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        try await viewer.send(.pointer, json: ["id": "f1", "phase": "down", "x": 10, "y": 20, "t": 0])
        let next = try await app.receive()
        XCTAssertEqual(next.type, .pointer)
        XCTAssertEqual(LiveStreamWire.json(next.payload)["phase"] as? String, "down")
        app.close(); viewer.close()
    }
}

final class LiveStreamEncoderKindTests: XCTestCase {
    /// Every kind has to give pictures back one for one: a sender waits for them.
    func testEveryKindGivesEachPictureBack() throws {
        for kind in LiveStreamEncoder.Kind.allCases {
            let lock = NSLock()
            var frames = 0
            let encoder = try LiveStreamEncoder(width: 320, height: 640, fps: 30, bitrate: 1_000_000, kind: kind) { _ in
                lock.withLock { frames += 1 }
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 640, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            for index in 0..<6 {
                encoder.encode(buffer!, micros: UInt64(index) * 33_000, keyframe: index == 0)
                let deadline = Date().addingTimeInterval(2)
                while encoder.pending > 0, Date() < deadline { usleep(2_000) }
                XCTAssertEqual(encoder.pending, 0, "\(encoder.kind.rawValue) held picture \(index)")
            }
            XCTAssertEqual(lock.withLock { frames }, 6, "asked for \(kind.rawValue), made \(encoder.kind.rawValue)")
            XCTAssertEqual(encoder.outputs, 6)
            encoder.invalidate()
        }
    }

    func testTheKindsFollowEachOther() {
        XCTAssertEqual(LiveStreamEncoder.Kind.lowLatency.next, .plain)
        XCTAssertEqual(LiveStreamEncoder.Kind.plain.next, .prompted)
        XCTAssertEqual(LiveStreamEncoder.Kind.prompted.next, .software)
        XCTAssertNil(LiveStreamEncoder.Kind.software.next)
        XCTAssertFalse(LiveStreamEncoder.Kind.lowLatency.finishesEachPicture)
        XCTAssertTrue(LiveStreamEncoder.Kind.software.finishesEachPicture)
    }
}

/// Version 2: every remote screen on one protocol.
final class LiveStreamProtocolTwoTests: XCTestCase {
    func testEveryNewKindRoundTripsOverTheWire() async throws {
        let listener = LiveStreamListener()
        let port = try await listener.start()
        async let accepted = listener.accept(timeout: 5)
        let (viewer, _) = try await LiveStreamClient.connect(
            to: ["127.0.0.1"], port: port, key: listener.key, session: listener.session,
            hello: ["viewer": "test", "protocol": 2, "wants": ["video"]], timeout: 3)
        let (source, hello) = try await accepted
        XCTAssertEqual(hello["protocol"] as? Int, 2)

        let toSource: [(LiveStreamMessage, [String: Any])] = [
            (.mouse, ["t": 0, "action": "down", "x": 10.5, "y": 20, "button": "left", "clicks": 1]),
            (.wheel, ["t": 16, "dx": 0, "dy": -12, "x": 10, "y": 20, "phase": "began"]),
            (.key, ["insert": "c", "modifiers": ["command"]]),
            (.key, ["special": "escape"]),
            (.clipboard, ["text": "copied", "revision": 3]),
            (.invoke, ["id": "i1", "method": "listMenus", "args": [] as [Any]]),
        ]
        for (kind, json) in toSource { try await viewer.send(kind, json: json) }
        for (kind, json) in toSource {
            let (type, payload) = try await source.receive()
            XCTAssertEqual(type, kind)
            XCTAssertEqual(NSDictionary(dictionary: LiveStreamWire.json(payload)), NSDictionary(dictionary: json))
        }

        let toViewer: [(LiveStreamMessage, [String: Any])] = [
            (.state, ["title": "Safari", "width": 1280, "height": 800, "crop": ["x": 0, "y": 40, "width": 1280, "height": 760]]),
            (.keyboard, ["visible": true, "type": 7]),
            (.dom, ["events": [["type": 2]], "full": true]),
            (.clipboard, ["text": "from the Mac", "revision": 4]),
            (.reply, ["id": "i1", "result": ["menus": [] as [Any]]]),
            (.controller, ["driving": false, "by": "iPhone 16"]),
        ]
        for (kind, json) in toViewer { try await source.send(kind, json: json) }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9])
        try await source.send(.still, LiveStreamWire.still(.init(presentationMicros: 9_000_001, fullWidth: 1800,
                                                                  fullHeight: 1344, jpeg: jpeg)))
        for (kind, json) in toViewer {
            let (type, payload) = try await viewer.receive()
            XCTAssertEqual(type, kind)
            XCTAssertEqual(NSDictionary(dictionary: LiveStreamWire.json(payload)), NSDictionary(dictionary: json))
        }
        let (stillType, stillPayload) = try await viewer.receive()
        XCTAssertEqual(stillType, .still)
        let still = try XCTUnwrap(LiveStreamWire.parseStill(stillPayload))
        XCTAssertEqual(still.presentationMicros, 9_000_001)
        XCTAssertEqual(still.jpeg, jpeg)
        XCTAssertTrue(still.isWhole)
        XCTAssertEqual(still.fullWidth, 1800)
        source.close(); viewer.close()
    }

    func testStillPayloads() {
        let patch = LiveStreamWire.Still(presentationMicros: 42, x: 640, y: 96, fullWidth: 2560, fullHeight: 1600,
                                         jpeg: Data([7, 8, 9]))
        XCTAssertEqual(LiveStreamWire.parseStill(LiveStreamWire.still(patch)), patch)
        XCTAssertFalse(patch.isWhole)
        XCTAssertNil(LiveStreamWire.parseStill(Data(repeating: 0, count: 24)), "A header and no picture")
        var outside = patch
        outside.x = 2560
        XCTAssertNil(LiveStreamWire.parseStill(LiveStreamWire.still(outside)), "A patch outside its picture")
        var sizeless = patch
        sizeless.fullWidth = 0
        XCTAssertNil(LiveStreamWire.parseStill(LiveStreamWire.still(sizeless)))
    }

    /// An app built before version 2 says nothing of it: an app's screen that takes touches.
    func testAVersionOneConfigReadsAsAnAppScreen() {
        let config = LiveStreamConfig(json: ["width": 390.0, "height": 844.0, "pixelWidth": 590, "pixelHeight": 1280,
                                             "touch": true, "pointer": true, "keyboard": true])
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.source, .app)
        XCTAssertEqual(config.input, .touch)
        XCTAssertTrue(config.controls.isEmpty)
        XCTAssertFalse(config.stills)
        XCTAssertEqual(config.width, 390)
        XCTAssertEqual(config.pixelHeight, 1280)
    }

    func testAVersionTwoConfigSaysWhatTheSourceIs() {
        var json: [String: Any] = ["width": 1280, "height": 800, "pixelWidth": 2560, "pixelHeight": 1600]
        json.merge(LiveStreamConfig.fields(source: .macWindow, input: .mouse, controls: ["resize", "crop"], stills: true)) { $1 }
        // Through JSON, as it travels.
        let data = try! JSONSerialization.data(withJSONObject: json)
        let config = LiveStreamConfig(json: LiveStreamWire.json(data))
        XCTAssertEqual(config.version, 2)
        XCTAssertEqual(config.source, .macWindow)
        XCTAssertEqual(config.input, .mouse)
        XCTAssertEqual(config.controls, ["resize", "crop"])
        XCTAssertTrue(config.stills)
        XCTAssertEqual(config.width, 1280)
        // A source this build doesn't know reads as an app, not as nothing.
        XCTAssertEqual(LiveStreamConfig(json: ["protocol": 3, "source": "hologram"]).source, .app)
    }

    /// A version 1 app is handed a version 2 hello and a v2 control, and carries on.
    func testAVersionOnePeerIgnoresVersionTwoFields() async throws {
        let listener = LiveStreamListener()
        let port = try await listener.start()
        async let accepted = listener.accept(timeout: 5)
        let (viewer, _) = try await LiveStreamClient.connect(
            to: ["127.0.0.1"], port: port, key: listener.key, session: listener.session,
            hello: ["viewer": "v2", "protocol": 2, "wants": ["video", "dom"], "stills": true], timeout: 3)
        let (app, hello) = try await accepted
        // What a version 1 app reads from the hello is all still there.
        XCTAssertEqual(hello["session"] as? String, listener.session)
        XCTAssertEqual(hello["viewer"] as? String, "v2")
        // A v2-only kind first, then a v1 one: the v1 end skips what it can't
        // use by kind, so the pointer still arrives in order.
        try await viewer.send(.wheel, json: ["t": 0, "dx": 0, "dy": 5, "x": 1, "y": 1, "phase": "began"])
        try await viewer.send(.pointer, json: ["id": "f", "phase": "down", "x": 1, "y": 1, "t": 0])
        let first = try await app.receive()
        XCTAssertEqual(first.type, .wheel, "This build knows the kind; a v1 build skips it (testAKindThisBuildDoesNotKnowIsSkipped)")
        let second = try await app.receive()
        XCTAssertEqual(second.type, .pointer)
        app.close(); viewer.close()
    }

    func testStateMergesAndReportsOnlyWhatChanged() {
        var state = LiveStreamState(json: ["title": "Inbox", "url": "https://a.test", "loading": true,
                                           "width": 1280, "height": 800])
        XCTAssertEqual(state.title, "Inbox")
        XCTAssertEqual(state.loading, true)
        let before = state
        state.merge(["loading": false, "title": NSNull()])
        XCTAssertNil(state.title, "Null clears a field")
        XCTAssertEqual(state.loading, false)
        XCTAssertEqual(state.url, "https://a.test", "Unmentioned fields stay")
        let changes = state.changes(since: before)
        XCTAssertEqual(changes["loading"] as? Bool, false)
        XCTAssertTrue(changes["title"] is NSNull)
        XCTAssertNil(changes["url"])
        XCTAssertNil(changes["width"])
        XCTAssertTrue(state.changes(since: state).isEmpty)

        state.merge(["crop": ["x": 0, "y": 38, "width": 1280, "height": 762]])
        XCTAssertEqual(state.crop?["y"], 38)
        var viewerSide = before
        viewerSide.merge(state.changes(since: before))
        XCTAssertEqual(viewerSide, state, "A viewer that merges the changes ends up with the source's state")
    }

    func testAHeldButtonIsLetGoAfterSilence() {
        var input = LiveStreamHeldInput()
        XCTAssertFalse(input.expired(now: 100), "Nothing held")
        input.heard(action: "down", button: "left", x: 50, y: 60, at: 10)
        XCTAssertFalse(input.expired(now: 12))
        // The viewer repeats a still held button twice a second.
        input.heard(action: "move", button: "left", x: 50, y: 60, at: 12)
        XCTAssertFalse(input.expired(now: 14.4))
        XCTAssertTrue(input.expired(now: 14.6), "2.5 s without a word")
        XCTAssertEqual(input.releaseAll(), ["left"])
        XCTAssertEqual(input.point.x, 50)
        XCTAssertFalse(input.expired(now: 100), "Nothing left held")

        input.heard(action: "down", button: "right", x: 1, y: 2, at: 20)
        input.heard(action: "up", button: "right", x: 1, y: 2, at: 20.1)
        XCTAssertFalse(input.expired(now: 30), "Let go by the viewer: nothing to cancel")
        XCTAssertTrue(input.releaseAll().isEmpty)
    }

    /// Mouse and wheel events keep the viewer's spacing on the source's clock,
    /// however they arrive — the same timeline fingers use.
    func testMouseAndWheelTimelines() {
        // A drag: down, three moves 8 ms apart, arriving together 40 ms after the down.
        var drag = LiveStreamPointerTimeline(start: 1_000_000, ticksPerMillisecond: 1000)
        let now: UInt64 = 1_040_000
        XCTAssertEqual([8.0, 16, 24].map { drag.time(offsetMilliseconds: $0, now: now) }, [1_008_000, 1_016_000, 1_024_000])
        // A flick's momentum: events 16 ms apart, the last of them still in the future here.
        var wheel = LiveStreamPointerTimeline(start: 2_000_000, ticksPerMillisecond: 1000)
        XCTAssertEqual(wheel.time(offsetMilliseconds: 16, now: 2_020_000), 2_016_000)
        XCTAssertEqual(wheel.time(offsetMilliseconds: 32, now: 2_020_000), 2_020_000, "Never ahead of now")
        XCTAssertEqual(wheel.time(offsetMilliseconds: 48, now: 2_020_000), 2_020_001, "Nor backwards")
    }

    func testKeyNamesAreKnown() {
        for name in ["escape", "tab", "left", "pageDown", "f12", "return"] {
            XCTAssertTrue(LiveStreamKeys.specials.contains(name), name)
        }
        XCTAssertEqual(LiveStreamKeys.modifiers, ["command", "shift", "option", "control", "function"])
    }
}
