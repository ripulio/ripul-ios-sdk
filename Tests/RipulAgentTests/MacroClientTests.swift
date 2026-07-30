import XCTest
@testable import RipulAgent

/// Phase-3 (automation-macros): `RipulMacroClient`'s request shape and
/// response decoding, mocked via a globally-registered `URLProtocol` — the
/// same technique needed because `RipulMacroClient.send` uses
/// `URLSession.shared` directly (matching `ToolCollectionsClient`'s existing
/// hardcoded-session shape), not an injectable session.
final class MacroClientTests: XCTestCase {

    private final class MockURLProtocol: URLProtocol {
        static var handler: ((URLRequest) -> (Int, [String: Any]))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let (status, json) = handler(request)
            let data = try! JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override class func setUp() {
        URLProtocol.registerClass(MockURLProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
    }
    override func tearDown() {
        MockURLProtocol.handler = nil
    }

    private func sampleMacroJSON(id: String = "macro_abc_clock_in", published: Bool = false) -> [String: Any] {
        [
            "id": id,
            "name": "clock_in",
            "description": "Clocks in.",
            "steps": [
                ["id": "s1", "kind": "tap", "selector": ["id": "button.clockIn"], "recordedLabel": "Tap 'Clock In'"],
            ],
            "parameters": [],
            "published": published,
            "createdAt": "2026-07-30T00:00:00Z",
            "updatedAt": "2026-07-30T00:00:00Z",
        ]
    }

    // MARK: - Request shape

    func testCreateSendsPOSTWithBearerTokenAndCorrectBody() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (201, self.sampleMacroJSON())
        }
        let client = RipulMacroClient(tokenProvider: { "test-token" })
        let macro = RipulMacro(id: "local-temp-id", name: "clock_in", description: "Clocks in.",
                               steps: [MacroStep(kind: .tap, selector: MacroSelector(id: "button.clockIn"), recordedLabel: "Tap 'Clock In'")],
                               createdAt: Date(), updatedAt: Date())
        _ = try await client.create(macro)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/macros")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")

        let body = try XCTUnwrap(request.httpBodyOrStream())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "clock_in")
        XCTAssertEqual(json["description"] as? String, "Clocks in.")
        // published/id/createdAt/updatedAt are server-assigned — never sent.
        XCTAssertNil(json["published"])
        XCTAssertNil(json["id"])
    }

    func testUpdatePublishSendsOnlyThePublishedField() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (200, self.sampleMacroJSON(published: true))
        }
        let client = RipulMacroClient(tokenProvider: { "test-token" })
        _ = try await client.update(id: "macro_abc_clock_in", edit: RipulMacroEdit(published: true))

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/v1/macros/macro_abc_clock_in")
        let body = try XCTUnwrap(request.httpBodyOrStream())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["published"] as? Bool, true)
        XCTAssertNil(json["name"])
    }

    func testListWithNoSiteKeyOmitsTheQueryParameter() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (200, ["macros": [self.sampleMacroJSON()]])
        }
        let client = RipulMacroClient(tokenProvider: { "test-token" })
        _ = try await client.list()
        XCTAssertEqual(capturedRequest?.url?.query, nil)
    }

    func testListWithSiteKeyIncludesTheQueryParameter() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (200, ["macros": []])
        }
        let client = RipulMacroClient(tokenProvider: { "test-token" })
        _ = try? await client.list(siteKeyId: "sk_test")
        XCTAssertEqual(capturedRequest?.url?.query, "siteKeyId=sk_test")
    }

    // MARK: - Response decoding

    func testListDecodesMacrosIncludingISO8601Dates() async throws {
        MockURLProtocol.handler = { _ in (200, ["macros": [self.sampleMacroJSON()]]) }
        let client = RipulMacroClient(tokenProvider: { "test-token" })
        let macros = try await client.list()
        XCTAssertEqual(macros.count, 1)
        XCTAssertEqual(macros.first?.name, "clock_in")
        XCTAssertEqual(macros.first?.steps.first?.selector.id, "button.clockIn")
        XCTAssertNotNil(macros.first?.createdAt)
    }

    // MARK: - Errors

    func testServerErrorSurfacesTheResponseMessage() async {
        MockURLProtocol.handler = { _ in (409, ["error": "A macro with this name already exists"]) }
        let client = RipulMacroClient(tokenProvider: { "test-token" })
        let macro = RipulMacro(id: "x", name: "clock_in", description: "d", steps: [], createdAt: Date(), updatedAt: Date())
        do {
            _ = try await client.create(macro)
            XCTFail("Expected an error")
        } catch RipulMacroClientError.server(let status, let message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "A macro with this name already exists")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testNotSignedInNeverMakesANetworkCall() async {
        var called = false
        MockURLProtocol.handler = { _ in called = true; return (200, [:]) }
        let client = RipulMacroClient(tokenProvider: { nil })
        let macro = RipulMacro(id: "x", name: "clock_in", description: "d", steps: [], createdAt: Date(), updatedAt: Date())
        do {
            _ = try await client.create(macro)
            XCTFail("Expected an error")
        } catch RipulMacroClientError.notSignedIn {
            // expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertFalse(called)
    }
}

private extension URLRequest {
    /// `httpBody` is nil for requests that went through `URLSession`'s
    /// upload path even when set on the original request in some
    /// URLProtocol-mocked flows — httpBodyStream is the fallback.
    func httpBodyOrStream() -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}
