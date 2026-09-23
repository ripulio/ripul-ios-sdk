import Foundation

/// Direct native BYOK transport. Fixed destinations, no redirects, no cookies,
/// no disk cache and no Ripul credential fallback. Error text never echoes keys,
/// request bodies, raw provider responses or single-use tokens.
final class ElevenLabsDirectAPI {
    enum Failure: LocalizedError {
        case missingKey, invalidRequest, http(Int), invalidResponse
        var errorDescription: String? {
            switch self {
            case .missingKey: return "Add your ElevenLabs key in Settings → Voice."
            case .invalidRequest: return "This speech request is not supported."
            case .invalidResponse: return "ElevenLabs returned an unexpected response. Try again."
            case .http(401): return "ElevenLabs rejected this API key. Check or replace it in Settings → Voice."
            case .http(403): return "This ElevenLabs key lacks permission for this operation. Enable Voices, Text to Speech and Speech to Text access."
            case .http(402), .http(429): return "ElevenLabs quota or rate limit reached. Check your ElevenLabs account and try again."
            case .http: return "ElevenLabs could not complete the request. Try again."
            }
        }
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private let apiKey: () throws -> String?
    private let session: URLSession
    init(apiKey: @escaping () throws -> String?, session: URLSession? = nil) {
        self.apiKey = apiKey
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }
    }
    static func isAuthorized(_ request: URLRequest) -> Bool { StandaloneNetworkPolicy.isDirectSpeechRequest(request) }
    func request(path: String, method: String, body: [String: Any]? = nil,
                 query: [URLQueryItem] = []) throws -> URLRequest {
        guard let value = try apiKey() else { throw Failure.missingKey }
        let key = try DeviceSpeechCredentials.validate(value)
        var url = URLComponents(string: "https://api.elevenlabs.io")!
        url.path = path; url.queryItems = query.isEmpty ? nil : query
        let request = NSMutableURLRequest(url: url.url!)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        StandaloneNetworkPolicy.authorizeDirectSpeech(request)
        let result = request as URLRequest
        guard Self.isAuthorized(result) else { throw Failure.invalidRequest }
        return result
    }
    private func data(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.http(0) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        return data
    }
    /// Adapts the existing native speech protocol; no change to capture/playback.
    func send(path: String, method: String, jsonBody: [String: Any]?) async throws -> Data {
        switch (path, method) {
        case ("api/v1/speech/voices", "GET"):
            var voices: [[String: Any]] = []
            var token: String?
            var seen = Set<String>()
            for _ in 0..<50 {
                var query = [URLQueryItem(name: "page_size", value: "100")]
                if let token { query.append(URLQueryItem(name: "next_page_token", value: token)) }
                let payload = try await data(request(path: "/v2/voices", method: "GET", query: query))
                guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      let page = object["voices"] as? [[String: Any]] else { throw Failure.invalidResponse }
                for voice in page {
                    guard let id = voice["voice_id"] as? String, let name = voice["name"] as? String else { continue }
                    voices.append(["id": id, "name": name, "labels": voice["labels"] as? [String: String] ?? [:]])
                }
                if object["has_more"] as? Bool != true { return try JSONSerialization.data(withJSONObject: ["voices": voices]) }
                guard let next = object["next_page_token"] as? String, !next.isEmpty, seen.insert(next).inserted else { throw Failure.invalidResponse }
                token = next
            }
            throw Failure.invalidResponse
        case ("api/v1/speech/realtime-token", "POST"):
            return try await data(request(path: "/v1/single-use-token/realtime_scribe", method: "POST"))
        case ("api/v1/speech/synthesize", "POST"):
            guard let text = jsonBody?["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 5000,
                  let voice = jsonBody?["voiceId"] as? String, !voice.isEmpty, voice.count <= 128,
                  voice.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw Failure.invalidRequest }
            return try await data(request(path: "/v1/text-to-speech/\(voice)/stream", method: "POST",
                body: ["text": text, "model_id": "eleven_multilingual_v2", "voice_settings": jsonBody?["voiceSettings"] as? [String: Any] ?? [:]],
                query: [URLQueryItem(name: "output_format", value: "mp3_44100_128")]))
        default: throw Failure.invalidRequest
        }
    }
}
