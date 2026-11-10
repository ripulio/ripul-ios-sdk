import XCTest
@testable import RipulAgent

private final class ReadAloudHTTPFixture: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class NativeChatReadAloudTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReadAloudHTTPFixture.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        ReadAloudHTTPFixture.handler = nil
        super.tearDown()
    }

    private func readBody(_ request: URLRequest) throws -> [String: Any] {
        let bytes: Data
        if let body = request.httpBody {
            bytes = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = stream.read(&buffer, maxLength: buffer.count)
            bytes = Data(buffer.prefix(max(0, count)))
        } else {
            bytes = Data()
        }
        return (try JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
    }

    @MainActor
    func testPanelTextIncludesProseTabsStructuredTableAndQuestionOptions() {
        var message = NativeChatMessage(
            id: "a-1",
            role: .assistant,
            content: "Here is the release summary with [build logs](https://demo.ripul.io/builds).",
            timestamp: 0
        )
        message.tabs = [
            NativeMessageTab(label: "iOS", content: "Built in 42s"),
            NativeMessageTab(label: "Web", content: "Deployed to Pages"),
        ]
        message.table = NativeMessageTable(
            columns: [
                .init(key: "target", label: "Target"),
                .init(key: "status", label: "Status"),
            ],
            rows: [
                ["target": "iPhone", "status": "Ready"],
                ["target": "Worker", "status": "Live"],
            ]
        )
        message.askUser = NativeAskUser(
            question: "",
            options: [
                .init(label: "Ship now", value: "ship", description: "Deploy both targets"),
            ],
            multiSelect: false,
            severity: nil,
            expectsResponse: true
        )

        let text = NativeChatReadAloudController.panelText(for: message)
        XCTAssertTrue(text.contains("Here is the release summary"))
        XCTAssertTrue(text.contains("### iOS\nBuilt in 42s"))
        XCTAssertTrue(text.contains("| Target | Status |"))
        XCTAssertTrue(text.contains("| iPhone | Ready |"))
        XCTAssertTrue(text.contains("- Ship now: Deploy both targets"))
    }

    @MainActor
    func testSummarizeForSpeechUsesHaikuSpeakEndpointAndCachesResultPerMode() async throws {
        var seenModes: [String] = []
        ReadAloudHTTPFixture.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/commands/speak")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let body = try self.readBody(request)
            XCTAssertTrue((body["text"] as? String)?.contains("| Target | Status |") == true)
            let mode = (body["mode"] as? String) ?? ""
            seenModes.append(mode)
            let speech = mode == "detailed"
                ? "Detailed spoken summary covering both targets in the release table."
                : "There are two targets in the table, and both are ready to ship."
            let data = try JSONSerialization.data(withJSONObject: ["speech": speech])
            return (200, data)
        }

        let controller = NativeChatReadAloudController(
            baseURL: URL(string: "https://demo.ripul.io")!,
            urlSession: session
        )
        controller.externalTokenProvider = { "test-token" }

        let panel = "| Target | Status |\n|---|---|\n| iPhone | Ready |\nSee [details](https://demo.ripul.io/docs)."
        let firstQuick = await controller.summarizeForSpeech(panelText: panel, messageId: "m-1", mode: .quick, bridge: nil)
        let secondQuick = await controller.summarizeForSpeech(panelText: panel, messageId: "m-1", mode: .quick, bridge: nil)
        let detailed = await controller.summarizeForSpeech(panelText: panel, messageId: "m-1", mode: .detailed, bridge: nil)

        XCTAssertEqual(firstQuick, "There are two targets in the table, and both are ready to ship.")
        XCTAssertEqual(secondQuick, firstQuick)
        XCTAssertEqual(detailed, "Detailed spoken summary covering both targets in the release table.")
        XCTAssertEqual(seenModes, ["quick", "detailed"], "Each mode should request its own summary and cache repeats")
    }

    @MainActor
    func testSummarizeForSpeechFallsBackToOrchestrateOn404AndSanitizeWhenOffline() async throws {
        var paths: [String] = []
        ReadAloudHTTPFixture.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/v1/commands/speak" {
                return (404, Data())
            }
            XCTAssertEqual(path, "/api/v1/commands/orchestrate")
            let data = try JSONSerialization.data(withJSONObject: [
                "calls": [
                    [
                        "name": "set_speech",
                        "numbers": [:],
                        "texts": ["speech": "Spoken summary from orchestrate fallback."],
                    ],
                ],
            ])
            return (200, data)
        }

        let controller = NativeChatReadAloudController(
            baseURL: URL(string: "https://demo.ripul.io")!,
            urlSession: session
        )
        controller.externalTokenProvider = { "clerk-token" }

        let fallbackSummary = await controller.summarizeForSpeech(
            panelText: "Check [the table](https://demo.ripul.io).",
            messageId: "m-404",
            bridge: nil
        )
        XCTAssertEqual(fallbackSummary, "Spoken summary from orchestrate fallback.")
        XCTAssertEqual(paths, ["/api/v1/commands/speak", "/api/v1/commands/orchestrate"])

        ReadAloudHTTPFixture.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let offlineSummary = await controller.summarizeForSpeech(
            panelText: "Read [the guide](https://demo.ripul.io) for **details**.",
            messageId: "m-offline",
            bridge: nil
        )
        XCTAssertEqual(offlineSummary, "Read the guide for details.")
    }
}
