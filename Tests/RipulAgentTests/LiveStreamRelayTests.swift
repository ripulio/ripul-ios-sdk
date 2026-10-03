import Network
import XCTest
@testable import RipulAgent

/// Stands in for the worker's `SupportRoom`: a WebSocket server on this Mac
/// that hands each binary message from one of its two connections to the
/// other, untouched, as the room does.
private final class LoopbackRoom: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.ripul.test.room")
    private var ends: [NWConnection] = []

    init() throws {
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.ends.append(connection)
            connection.start(queue: self.queue)
            self.read(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = LiveStreamOnce()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func read(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil, let context else { return }
            let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .binary, let data, let other = self.ends.first(where: { $0 !== connection }) {
                self.put(data, .binary, to: other)
            }
            self.read(connection)
        }
    }

    private func put(_ data: Data, _ opcode: NWProtocolWebSocket.Opcode, to connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "test",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Something from the room itself, to every end.
    func say(_ data: Data, _ opcode: NWProtocolWebSocket.Opcode) {
        queue.async { self.ends.forEach { self.put(data, opcode, to: $0) } }
    }

    func stop() {
        listener.cancel()
        queue.async { self.ends.forEach { $0.cancel() } }
    }
}

final class LiveStreamRelayTests: XCTestCase {
    private func room() async throws -> (LoopbackRoom, URL) {
        let room = try LoopbackRoom()
        let port = try await room.start()
        return (room, URL(string: "http://127.0.0.1:\(port)")!)
    }

    func testTheRoomsAddress() {
        // Straight to the API host: the app host's /api path turns WebSockets away.
        let secure = LiveStreamRelay.url(code: "482913", role: .customer, token: "abc-DEF_123")
        XCTAssertEqual(secure?.absoluteString,
                       "wss://llm-proxy.ripul.io/v1/support/sessions/482913/ws?role=customer&token=abc-DEF_123")
        let local = LiveStreamRelay.url(server: URL(string: "http://127.0.0.1:8787")!, code: "000001",
                                        role: .supporter, token: "t")
        XCTAssertEqual(local?.absoluteString, "ws://127.0.0.1:8787/v1/support/sessions/000001/ws?role=supporter&token=t")
    }

    func testFramesCrossARoomBothWaysOneToAMessage() async throws {
        let (room, api) = try await room()
        defer { room.stop() }
        let customer = try await LiveStreamRelay.connect(server: api, code: "482913", role: .customer, token: "c", timeout: 5)
        let supporter = try await LiveStreamRelay.connect(server: api, code: "482913", role: .supporter, token: "s", timeout: 5)
        defer {
            customer.close()
            supporter.close()
        }

        try await supporter.send(.hello, json: ["viewer": "Helen"])
        let hello = try await customer.receive()
        XCTAssertEqual(hello.type, .hello)
        XCTAssertEqual(LiveStreamWire.json(hello.payload)["viewer"] as? String, "Helen")

        // A keyframe's worth: more than one network read, still one frame.
        let picture = LiveStreamWire.video(keyframe: true, presentationMicros: 42,
                                           avcc: Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try await customer.send(.config, json: ["width": 430, "height": 932])
        customer.enqueue(.video, picture)
        let config = try await supporter.receive()
        XCTAssertEqual(config.type, .config)
        let video = try await supporter.receive()
        XCTAssertEqual(video.type, .video)
        XCTAssertEqual(video.payload, picture)

        supporter.enqueue(.pointer, Data(#"{"id":"finger","phase":"down","x":10,"y":20,"t":0}"#.utf8))
        let pointer = try await customer.receive()
        XCTAssertEqual(pointer.type, .pointer)
        XCTAssertEqual(LiveStreamWire.json(pointer.payload)["phase"] as? String, "down")
    }

    func testWhatIsNotAFrameIsSkippedAndTheRoomIsHeard() async throws {
        let (room, api) = try await room()
        defer { room.stop() }
        let customer = try await LiveStreamRelay.connect(server: api, code: "482913", role: .customer, token: "c", timeout: 5)
        defer { customer.close() }

        room.say(Data("not for us".utf8), .text)
        room.say(Data([1, 2]), .binary)                         // too short to be a frame
        room.say(LiveStreamWire.frame(.config, Data()).withFirst(200), .binary)   // a kind nobody knows
        customer.keepAlive()
        room.say(LiveStreamWire.frame(.room, json: ["event": "peer", "role": "supporter", "present": true,
                                                    "name": "Helen Helper"]), .binary)
        let heard = try await customer.receive()
        XCTAssertEqual(heard.type, .room)
        XCTAssertEqual(LiveStreamWire.json(heard.payload)["name"] as? String, "Helen Helper")
    }

    func testAFrameThatLiesAboutItsLengthEndsTheSession() async throws {
        let (room, api) = try await room()
        defer { room.stop() }
        let customer = try await LiveStreamRelay.connect(server: api, code: "482913", role: .customer, token: "c", timeout: 5)
        defer { customer.close() }

        var lying = LiveStreamWire.frame(.pointer, Data("{}".utf8))
        lying.append(contentsOf: [0, 0, 0])
        room.say(lying, .binary)
        do {
            _ = try await customer.receive()
            XCTFail("A message that isn't exactly one frame was taken for one")
        } catch {
            XCTAssertEqual(error as? LiveStreamError, .malformed)
        }
    }

    func testARoomThatIsNotThereIsAnError() async throws {
        do {
            let channel = try await LiveStreamRelay.connect(server: URL(string: "http://127.0.0.1:9")!, code: "482913",
                                                            role: .customer, token: "c", timeout: 3)
            channel.close()
            XCTFail("Connected to nothing")
        } catch {
            // Refused or timed out: either way it is said, not hung on.
        }
    }
}

private extension Data {
    /// The same bytes with another first byte: a frame of another kind.
    func withFirst(_ byte: UInt8) -> Data {
        var copy = Data(self)
        copy[copy.startIndex] = byte
        return copy
    }
}
