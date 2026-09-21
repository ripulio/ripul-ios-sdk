import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import RipulAgent

private final class SpeechHTTPFixture: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

// The speech factory it exercises is iOS 26+; without this the whole test
// bundle fails to compile on a 26-or-newer-only toolchain.
@available(iOS 26.0, *)
final class DeviceSpeechTransportTests: XCTestCase {
    #if canImport(UIKit)
    @MainActor func testSecureKeyFieldsAreRedactedFromInspection() {
        let field = UITextField()
        field.isSecureTextEntry = true
        field.placeholder = "ElevenLabs API key"
        field.text = "private-test-key"
        let internalLabel = UILabel()
        internalLabel.text = field.text
        field.addSubview(internalLabel)
        XCTAssertEqual(InspectedView.textContent(of: field), "ElevenLabs API key")
        XCTAssertNil(InspectedView.textContent(of: internalLabel))
        field.isSecureTextEntry = false
        XCTAssertEqual(InspectedView.textContent(of: field), "private-test-key")
    }
    #endif
    private var session: URLSession!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechHTTPFixture.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() { session.invalidateAndCancel(); SpeechHTTPFixture.handler = nil }
    private func client(_ key: @escaping () throws -> String? = { "test-device-key" }) -> ElevenLabsDirectAPI {
        ElevenLabsDirectAPI(apiKey: key, session: session)
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func testMarkedRequestsPermitOnlyExactSpeechEndpoints() throws {
        let request = try client().request(path: "/v2/voices", method: "GET")
        XCTAssertTrue(ElevenLabsDirectAPI.isAuthorized(request))
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-device-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(StandaloneNetworkPolicy.denies(request.url!, standalone: true), "Unmarked requests remain blocked")
        XCTAssertFalse(ElevenLabsDirectAPI.isAuthorized(URLRequest(url: request.url!)))
        for url in ["https://api.elevenlabs.io.attacker.example/v2/voices", "http://api.elevenlabs.io/v2/voices", "https://api.elevenlabs.io:444/v2/voices", "https://api.elevenlabs.io/v1/user", "https://demo.ripul.io/api/v1/speech/voices"] {
            var forged = request; forged.url = URL(string: url)!
            XCTAssertFalse(ElevenLabsDirectAPI.isAuthorized(forged))
        }
        XCTAssertThrowsError(try client().request(path: "/v1/user", method: "GET"))
        XCTAssertThrowsError(try client().request(path: "/v2/voices", method: "POST"))
    }
    func testVoicePagesAreFetchedFromProviderAndNormalized() async throws {
        var calls = 0
        SpeechHTTPFixture.handler = { request in
            calls += 1
            XCTAssertTrue(ElevenLabsDirectAPI.isAuthorized(request), "Native authorization survives URLSession")
            XCTAssertEqual(request.url?.host, "api.elevenlabs.io")
            XCTAssertEqual(request.url?.path, "/v2/voices")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-device-key")
            if calls == 1 {
                return (200, try self.json(["voices": [["voice_id": "one", "name": "One"]], "has_more": true, "next_page_token": "next"]))
            }
            XCTAssertTrue(request.url!.query!.contains("next_page_token=next"))
            return (200, try self.json(["voices": [["voice_id": "two", "name": "Two", "labels": ["accent": "british"]]], "has_more": false]))
        }
        let result = try await client().send(path: "api/v1/speech/voices", method: "GET", jsonBody: nil)
        let decoded = try JSONSerialization.jsonObject(with: result) as! [String: [[String: Any]]]
        XCTAssertEqual(decoded["voices"]?.compactMap { $0["id"] as? String }, ["one", "two"])
        XCTAssertEqual(calls, 2)
    }
    func testSynthesisUsesProviderPayloadAndNeverSendsBearer() async throws {
        SpeechHTTPFixture.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-speech/voice_1/stream?output_format=mp3_44100_128")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            // URLSession can expose a body stream to URLProtocol.
            let bytes: Data
            if let body = request.httpBody { bytes = body }
            else {
                let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096); let count = stream.read(&buffer, maxLength: buffer.count)
                bytes = Data(buffer.prefix(count))
            }
            let body = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            XCTAssertEqual(body["model_id"] as? String, "eleven_multilingual_v2")
            XCTAssertEqual(body["text"] as? String, "A test reply")
            XCTAssertNotNil(body["voice_settings"])
            XCTAssertNil(body["voiceId"])
            return (200, Data([1, 2, 3]))
        }
        let audio = try await client().send(path: "api/v1/speech/synthesize", method: "POST", jsonBody: ["voiceId": "voice_1", "text": "A test reply", "voiceSettings": ["speed": 1.1]])
        XCTAssertEqual(audio, Data([1, 2, 3]))
    }
    func testRealtimeTokenIsMintedDirectly() async throws {
        SpeechHTTPFixture.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-device-key")
            return (200, try self.json(["token": "test-single-use"]))
        }
        let data = try await client().send(path: "api/v1/speech/realtime-token", method: "POST", jsonBody: nil)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("test-single-use"))
    }
    func testKeyRemovalStopsFutureRequestsWithoutFallback() async throws {
        var key: String? = "test-device-key"; var calls = 0
        let api = client { key }
        SpeechHTTPFixture.handler = { _ in calls += 1; return (200, try self.json(["token": "single-use"])) }
        _ = try await api.send(path: "api/v1/speech/realtime-token", method: "POST", jsonBody: nil)
        key = nil
        do { _ = try await api.send(path: "api/v1/speech/realtime-token", method: "POST", jsonBody: nil); XCTFail("Expected missing key") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Settings")) }
        XCTAssertEqual(calls, 1)
    }
    func testRejectedKeyDoesNotRetryOrExposeProviderResponse() async throws {
        var calls = 0
        SpeechHTTPFixture.handler = { _ in calls += 1; return (401, Data("test-device-key secret-provider-response".utf8)) }
        do { _ = try await client().send(path: "api/v1/speech/voices", method: "GET", jsonBody: nil); XCTFail("Expected rejection") }
        catch {
            XCTAssertFalse(error.localizedDescription.contains("test-device-key"))
            XCTAssertFalse(error.localizedDescription.contains("secret-provider-response"))
            XCTAssertTrue(error.localizedDescription.contains("rejected"))
        }
        XCTAssertEqual(calls, 1)
    }
    func testUnknownOperationAndVoiceTraversalNeverMakeNetworkRequest() async {
        SpeechHTTPFixture.handler = { _ in XCTFail("Unexpected request"); return (500, Data()) }
        for (path, body) in [("api/v1/user-secrets", [String: Any]()), ("api/v1/speech/synthesize", ["text": "hello", "voiceId": "../user"])] {
            do { _ = try await client().send(path: path, method: "POST", jsonBody: body); XCTFail("Expected invalid request") } catch { }
        }
    }
    func testCredentialInputRejectsHeaderInjection() throws {
        XCTAssertEqual(try DeviceSpeechCredentials.validate("  test-key  "), "test-key")
        for key in ["", "a\r\nheader:value", "a b", String(repeating: "x", count: 513)] { XCTAssertThrowsError(try DeviceSpeechCredentials.validate(key)) }
    }
    @MainActor func testKeychainIsProfileScopedAndRemovable() throws {
        let oldScope = DeviceSpeechCredentials.profileScope
        let oldStore = SpeechPreferences.store
        let suite = "speech-test-" + UUID().uuidString
        DeviceSpeechCredentials.profileScope = suite
        SpeechPreferences.store = UserDefaults(suiteName: suite)!
        defer {
            DeviceSpeechCredentials.profileScope = suite; try? DeviceSpeechCredentials.remove()
            DeviceSpeechCredentials.profileScope = oldScope
            SpeechPreferences.store.removePersistentDomain(forName: suite); SpeechPreferences.store = oldStore
        }
        SpeechPreferences.store.set("elevenlabs", forKey: SpeechPreferences.dictationProviderKey)
        XCTAssertEqual(NativeSpeechProviderFactory.dictation(tokenProvider: { "unused-ripul-token" }).id, "apple")
        XCTAssertEqual(NativeSpeechProviderFactory.speaking(tokenProvider: { "unused-ripul-token" }).id, "apple")
        try DeviceSpeechCredentials.save("test-keychain-key")
        XCTAssertEqual(NativeSpeechProviderFactory.dictation(tokenProvider: { nil }).id, "elevenlabs")
        XCTAssertEqual(NativeSpeechProviderFactory.speaking(tokenProvider: { nil }).id, "elevenlabs")
        XCTAssertEqual(try DeviceSpeechCredentials.read(), "test-keychain-key")
        XCTAssertFalse(SpeechPreferences.store.dictionaryRepresentation().values.contains { ($0 as? String) == "test-keychain-key" })
        DeviceSpeechCredentials.profileScope = suite + "-other"
        XCTAssertNil(try DeviceSpeechCredentials.read())
        DeviceSpeechCredentials.profileScope = suite
        try DeviceSpeechCredentials.remove()
        XCTAssertNil(try DeviceSpeechCredentials.read())
    }
}
