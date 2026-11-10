import XCTest
@testable import RipulAgent

/// A run started before a save can answer after the run the save started
/// (Multi-add refreshes seven queries at once): only the latest run's rows are
/// kept, so an older answer arriving last can't put back rows from before the
/// save. Android's twin is CmsRuntimeTest.anOlderRunAnsweringLastDoesNotReplaceANewerRunsRows.
@MainActor
final class CmsRuntimeRunOrderTests: XCTestCase {
    private final class SlowFirstProtocol: URLProtocol {
        nonisolated(unsafe) static var calls = 0
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "run-order.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.calls += 1
            let first = Self.calls == 1
            let value = first ? "before the save" : "after the save"
            let body = Data(#"{"ok":true,"rows":[{"v":"\#(value)"}]}"#.utf8)
            let respond = { [self] in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
            if first { DispatchQueue.global().asyncAfter(deadline: .now() + 0.6, execute: respond) } else { respond() }
        }
        override func stopLoading() {}
    }

    override func setUp() {
        super.setUp()
        SlowFirstProtocol.calls = 0
        URLProtocol.registerClass(SlowFirstProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(SlowFirstProtocol.self)
        super.tearDown()
    }

    private func rowValue(_ runtime: CmsRuntime) -> String? {
        guard case .ok(let result) = runtime.state(for: "my_calendar") else { return nil }
        return result.rows.first?["v"]?.stringValue
    }

    func testAnOlderRunAnsweringLastDoesNotReplaceANewerRunsRows() async throws {
        let client = CmsClient(config: CmsClientConfig(getToken: { "test-token" }, baseUrl: "https://run-order.test"))
        let runtime = CmsRuntime(cmsId: "c", client: client)
        runtime.ensureLoaded("my_calendar")          // slow: answers last, with the old rows
        try await Task.sleep(nanoseconds: 100_000_000)
        runtime.invalidate("my_calendar")            // the save's refetch: answers first
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rowValue(runtime), "after the save")
        try await Task.sleep(nanoseconds: 700_000_000) // the old run has answered by now
        XCTAssertEqual(SlowFirstProtocol.calls, 2)
        XCTAssertEqual(rowValue(runtime), "after the save", "the older answer must not put the old rows back")
    }
}
