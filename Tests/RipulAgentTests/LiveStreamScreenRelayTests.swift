import Network
import XCTest
@testable import RipulAgent

final class LiveStreamScreenRelayTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })

    // MARK: The seal

    func testAFrameSealedByOneEndOpensAtTheOther() throws {
        let viewer = LiveStreamSeal(key: key, side: .viewer)
        let source = LiveStreamSeal(key: key, side: .source)
        let hello = LiveStreamWire.frame(.hello, json: ["session": "s1", "viewer": "iPhone"])
        let sealed = try viewer.seal(hello)
        XCTAssertEqual(sealed.count, hello.count + LiveStreamSeal.overhead)
        XCTAssertNil(sealed.range(of: Data("session".utf8)), "The room can read the frame")
        XCTAssertEqual(try source.open(sealed), hello)

        let picture = LiveStreamWire.frame(.video, Data(repeating: 9, count: 1000))
        XCTAssertEqual(try viewer.open(try source.seal(picture)), picture)
    }

    func testAFrameOutOfTurnDoesNotOpen() throws {
        let viewer = LiveStreamSeal(key: key, side: .viewer)
        let source = LiveStreamSeal(key: key, side: .source)
        let first = try viewer.seal(Data("one".utf8))
        let second = try viewer.seal(Data("two".utf8))
        // The room can't drop one and pass on the next, or play one twice.
        XCTAssertThrowsError(try source.open(second))
        XCTAssertEqual(try source.open(first), Data("one".utf8))
        XCTAssertThrowsError(try source.open(first))
        XCTAssertEqual(try source.open(second), Data("two".utf8))
    }

    func testAChangedByteAnotherKeyOrAnEchoDoesNotOpen() throws {
        let viewer = LiveStreamSeal(key: key, side: .viewer)
        var changed = try viewer.seal(Data("click at 10,20".utf8))
        changed[changed.startIndex + 12] ^= 1
        XCTAssertThrowsError(try LiveStreamSeal(key: key, side: .source).open(changed))

        let stranger = LiveStreamSeal(key: Data(repeating: 1, count: 32), side: .viewer)
        XCTAssertThrowsError(try LiveStreamSeal(key: key, side: .source).open(try stranger.seal(Data("hi".utf8))))

        // A room sending a viewer's own frame back to it.
        let echo = try viewer.seal(Data("hi".utf8))
        XCTAssertThrowsError(try LiveStreamSeal(key: key, side: .viewer).open(echo))
        XCTAssertThrowsError(try viewer.open(Data([0, 0, 0])))
    }

    // MARK: The room's address

    func testTheRoomsAddress() {
        let room = "AbCdEfGhIjKlMnOpQrStU_"
        let secure = LiveStreamScreenRelay.url(room: room, side: .viewer, token: "abc-DEF_123")
        XCTAssertEqual(secure?.absoluteString,
                       "wss://llm-proxy.ripul.io/v1/screen-relay/rooms/\(room)/ws?role=viewer&token=abc-DEF_123")
        let local = LiveStreamScreenRelay.url(server: URL(string: "http://127.0.0.1:8787")!, room: room,
                                              side: .source, token: "t")
        XCTAssertEqual(local?.absoluteString, "ws://127.0.0.1:8787/v1/screen-relay/rooms/\(room)/ws?role=source&token=t")
        XCTAssertNil(LiveStreamScreenRelay.url(room: "../support/sessions/1", side: .source, token: "t"))
        XCTAssertFalse(LiveStreamScreenRelay.isRoomId("AbCdEfGhIjKlMnOpQrStU/"))
        XCTAssertTrue(LiveStreamScreenRelay.isRoomId(room))
    }

    // MARK: Through a room

    func testASessionCrossesARoomSealedBothWays() async throws {
        let room = try LoopbackRoom()
        let port = try await room.start()
        defer { room.stop() }
        let api = URL(string: "http://127.0.0.1:\(port)")!
        let id = "AbCdEfGhIjKlMnOpQrStU_"
        let mac = try await LiveStreamScreenRelay.connect(server: api, room: id, side: .source, token: "s", key: key, timeout: 5)
        let phone = try await LiveStreamScreenRelay.connect(server: api, room: id, side: .viewer, token: "v", key: key, timeout: 5)
        defer {
            mac.close()
            phone.close()
        }
        XCTAssertTrue(phone.isRelayed)

        try await phone.send(.hello, json: ["session": "s1", "viewer": "iPhone 17"])
        let hello = try await mac.receive()
        XCTAssertEqual(hello.type, .hello)
        XCTAssertEqual(LiveStreamWire.json(hello.payload)["session"] as? String, "s1")

        // A keyframe's worth, then input back, in order.
        let picture = LiveStreamWire.video(keyframe: true, presentationMicros: 42,
                                           avcc: Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try await mac.send(.config, json: ["width": 1920, "height": 1080])
        mac.enqueue(.video, picture)
        let config = try await phone.receive()
        XCTAssertEqual(config.type, .config)
        let video = try await phone.receive()
        XCTAssertEqual(video.type, .video)
        XCTAssertEqual(video.payload, picture)
        phone.enqueue(.mouse, Data(#"{"action":"down","x":10,"y":20,"t":0}"#.utf8))
        phone.enqueue(.mouse, Data(#"{"action":"up","x":10,"y":20,"t":1}"#.utf8))
        let down = try await mac.receive(), up = try await mac.receive()
        XCTAssertEqual(LiveStreamWire.json(down.payload)["action"] as? String, "down")
        XCTAssertEqual(LiveStreamWire.json(up.payload)["action"] as? String, "up")

        // What the room saw: nothing it could read.
        let carried = room.carriedSoFar
        XCTAssertEqual(carried.count, 5)
        for message in carried {
            XCTAssertNil(message.range(of: Data("iPhone 17".utf8)))
            XCTAssertNil(message.range(of: Data("\"action\"".utf8)))
        }
    }

    func testARoomThatChangesAFrameEndsTheSession() async throws {
        let room = try LoopbackRoom()
        let port = try await room.start()
        defer { room.stop() }
        let api = URL(string: "http://127.0.0.1:\(port)")!
        let phone = try await LiveStreamScreenRelay.connect(server: api, room: "AbCdEfGhIjKlMnOpQrStU_", side: .viewer,
                                                            token: "v", key: key, timeout: 5)
        defer { phone.close() }
        // The room speaking for the Mac: a frame it made up, not sealed with the key.
        room.say(LiveStreamWire.frame(.config, json: ["width": 1, "height": 1]), .binary)
        do {
            _ = try await phone.receive()
            XCTFail("A frame the Mac didn't seal was taken")
        } catch {
            XCTAssertEqual(error as? LiveStreamError, .malformed)
        }
    }
}
