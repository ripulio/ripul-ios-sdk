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
