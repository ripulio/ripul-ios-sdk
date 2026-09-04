import Foundation
import AVFoundation

/// Swift-side speech provider abstraction — the native mirror of the web
/// app's ISpeechProvider. The native chat surface (and the debug sandbox)
/// switch engines through this protocol exactly the way the web layer
/// switches through SpeechProviderFactory. Both ElevenLabs implementations
/// (web + native) share the same worker routes and key custody.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public protocol NativeSpeechProviding: AnyObject {
    var id: String { get }
    var label: String { get }
    func listVoices() async throws -> [SpeechService.Voice]
    /// Begins playback; returns once playback has started. `onPlaybackEnd`
    /// fires when playback finishes naturally (not on stopSpeaking()).
    func speak(text: String, voiceId: String?, onPlaybackEnd: (@MainActor () -> Void)?) async throws
    func stopSpeaking()
    /// Freeze playback mid-utterance; resumeSpeaking() continues from the
    /// same position. onPlaybackEnd does not fire while paused.
    func pauseSpeaking()
    func resumeSpeaking()
    func startTranscription(onEvent: @escaping @MainActor (SpeechService.TranscriptionEvent) -> Void) async throws
    func stopTranscription()
}

// MARK: - Apple (on-device)

/// Thin adapter over the shared SpeechService engine.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class AppleSpeechProvider: NativeSpeechProviding {
    public let id = "apple"
    public let label = "Apple (on-device)"

    public init() {}
    private let service = SpeechService.shared

    public func listVoices() async throws -> [SpeechService.Voice] {
        service.listVoices()
    }

    public func speak(text: String, voiceId: String?, onPlaybackEnd: (@MainActor () -> Void)?) async throws {
        try service.speak(text: text, voiceId: voiceId, onFinished: onPlaybackEnd)
    }

    public func pauseSpeaking() { service.pauseSpeaking() }
    public func resumeSpeaking() { service.continueSpeaking() }

    public func stopSpeaking() {
        service.stopSpeaking()
    }

    public func startTranscription(onEvent: @escaping @MainActor (SpeechService.TranscriptionEvent) -> Void) async throws {
        service.onTranscriptionEvent = onEvent
        do {
            try await service.startTranscription()
        } catch {
            service.onTranscriptionEvent = nil
            throw error
        }
    }

    public func stopTranscription() {
        service.stopTranscription()
    }
}

// MARK: - ElevenLabs (via worker)

/// ElevenLabs from native Swift: TTS/voices proxy through the worker's
/// /v1/speech/* routes (API key stays server-side), realtime STT mints a
/// single-use token from the worker and streams mic PCM16 straight to the
/// ElevenLabs WebSocket — the same wire protocol the web provider uses.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class ElevenLabsNativeSpeechProvider: NSObject, NativeSpeechProviding, AVAudioPlayerDelegate {
    public let id = "elevenlabs"
    public let label = "ElevenLabs"

    public enum ProviderError: LocalizedError {
        case notAuthenticated
        case httpError(Int, String)
        case voiceRequired
        case unsupportedSampleRate(Double)
        case microphoneDenied

        public var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "No auth token available for the worker API"
            case .httpError(let code, let body): return "Worker API error \(code): \(body)"
            case .voiceRequired: return "ElevenLabs requires a voice selection"
            case .unsupportedSampleRate(let rate): return "Unsupported capture rate \(Int(rate)) Hz"
            case .microphoneDenied: return "Microphone permission denied"
            }
        }
    }

    private static let supportedPcmRates: Set<Int> = [8000, 16000, 22050, 24000, 44100, 48000]

    /// Audio-thread → socket handoff. The mic is brought up before the
    /// WebSocket exists (see `startTranscription`), so chunks recorded in the
    /// meantime are held here, in order, and flushed on attach. Lock-guarded
    /// rather than actor-isolated: the tap runs on the audio thread and must
    /// not hop actors, which would reorder the audio.
    private final class PendingAudioSink: @unchecked Sendable {
        /// 4096 frames ≈ 85 ms at 48 kHz, so 200 chunks ≈ 17 s of audio — well
        /// past any plausible handshake, and a hard stop if one never lands.
        private static let maxChunks = 200

        private let lock = NSLock()
        private var socket: URLSessionWebSocketTask?
        private var pending: [String] = []
        private var closed = false

        func push(_ text: String) {
            lock.lock()
            if closed {
                lock.unlock()
                return
            }
            if let socket {
                lock.unlock()
                socket.send(.string(text)) { _ in }
                return
            }
            if pending.count < Self.maxChunks { pending.append(text) }
            lock.unlock()
        }

        func attach(_ socket: URLSessionWebSocketTask) {
            lock.lock()
            guard !closed else {
                lock.unlock()
                return
            }
            self.socket = socket
            let backlog = pending
            pending = []
            lock.unlock()
            for text in backlog { socket.send(.string(text)) { _ in } }
        }

        func close() {
            lock.lock()
            closed = true
            socket = nil
            pending = []
            lock.unlock()
        }
    }

    private let tokenProvider: () -> String?
    /// Forces the host to mint a NEW token, rather than handing back the
    /// cached one `tokenProvider` returns. Optional: surfaces that some
    /// construction sites (the sandbox, settings screens) have no bridge to
    /// refresh through, and those keep the old passive behaviour.
    private let tokenRefresher: (() async -> String?)?
    /// Every token the worker has rejected this session, not just the last
    /// one. A single slot could not tell "the host is still serving the dead
    /// token" from "the host is serving a DIFFERENT dead token" — and the
    /// second case is what a conversation crossing two expiry boundaries
    /// looks like. Tokens never come back to life, so this only ever grows
    /// more accurate.
    ///
    /// Bounded FIFO: only the handful in play around an expiry boundary
    /// matter, and forgetting an ancient one costs at most one 401 that the
    /// retry path already handles.
    private var deadTokens: [String] = []
    private static let maxDeadTokens = 8
    /// Token we minted ourselves after a rejection. Used only while the host
    /// is still serving a dead one.
    private var mintedToken: String?
    /// Ceiling on a mint. The refresher round-trips into the web view's JS
    /// engine to reach Clerk, and `callAsyncJavaScript` has no timeout of its
    /// own — so when the web view is suspended (backgrounded app, locked
    /// screen: the *normal* hands-free case) an un-deadlined mint hangs the
    /// speech call outright instead of failing it into the Apple-voice
    /// fallback.
    private static let mintTimeoutNanos: UInt64 = 5_000_000_000

    private func markDead(_ token: String) {
        guard !deadTokens.contains(token) else { return }
        deadTokens.append(token)
        if deadTokens.count > Self.maxDeadTokens { deadTokens.removeFirst() }
    }

    /// A token the worker just accepted is by definition not dead — clears a
    /// stale entry so one 401 can't poison a token the host later re-serves.
    private func markAlive(_ token: String) {
        deadTokens.removeAll { $0 == token }
    }

    /// One-shot latch so a mint and its deadline can race without resuming the
    /// continuation twice. MainActor-confined, hence unlocked.
    @MainActor
    private final class Latch {
        private var claimed = false
        func claim() -> Bool {
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// Mints a fresh token, giving up after `mintTimeoutNanos`.
    ///
    /// Cancellation is not enough here: the refresher ends in a
    /// `callAsyncJavaScript` continuation that does not observe cancellation,
    /// so cancelling the task would leave us awaiting it anyway. The deadline
    /// therefore has to race the mint rather than interrupt it.
    private func mintFreshToken() async -> String? {
        guard let tokenRefresher else { return nil }
        let latch = Latch()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            Task { @MainActor in
                let token = await tokenRefresher()
                if latch.claim() { continuation.resume(returning: token) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.mintTimeoutNanos)
                if latch.claim() { continuation.resume(returning: nil) }
            }
        }
    }
    private let baseURL = AgentConfiguration.defaultBaseURL
    private var player: AVAudioPlayer?
    private var wsTask: URLSessionWebSocketTask?
    private var audioEngine: AVAudioEngine?
    private var audioSink: PendingAudioSink?
    private var onEvent: (@MainActor (SpeechService.TranscriptionEvent) -> Void)?
    private var transcribing = false
    private var onPlaybackEnd: (@MainActor () -> Void)?
    private var cachedDefaultVoiceId: String?

    public init(
        tokenProvider: @escaping () -> String?,
        tokenRefresher: (() async -> String?)? = nil
    ) {
        self.tokenProvider = tokenProvider
        self.tokenRefresher = tokenRefresher
        super.init()
    }

    /// The token to send. Prefers whatever the host currently holds, and only
    /// falls back to one we minted ourselves while the host is still serving a
    /// token the worker has already rejected.
    private func currentToken() -> String? {
        let hosted = tokenProvider()
        if let hosted, !deadTokens.contains(hosted) {
            // The host's poll has caught up — drop ours and trust it again.
            mintedToken = nil
            return hosted
        }
        if let mintedToken, !deadTokens.contains(mintedToken) { return mintedToken }
        // Everything we hold is known-dead. Send one anyway rather than
        // failing here: the 401 path is what mints, and it cannot run if we
        // never make the request.
        return mintedToken ?? hosted
    }

    // MARK: HTTP helpers

    /// - Parameter token: Sends exactly this token instead of resolving one.
    ///   The retry path needs it: it validates a specific candidate, and
    ///   re-deriving through `currentToken()` could hand back a different —
    ///   possibly already-rejected — token than the one it approved.
    private func request(
        path: String,
        method: String,
        jsonBody: [String: Any]? = nil,
        token override: String? = nil
    ) throws -> (URLRequest, String) {
        guard let token = override ?? currentToken() else { throw ProviderError.notAuthenticated }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        return (request, token)
    }

    /// Calls a worker speech route, minting a fresh token and retrying once if
    /// the worker rejects the one we sent.
    ///
    /// Auth tokens are short-lived and the host refreshes them on a poll, but
    /// this provider captured a *closure* at voice-mode entry and re-reads it
    /// per request. A conversation that crosses an expiry boundary therefore
    /// 401s on every speech call until the poll happens to catch up.
    ///
    /// The passive version of this retry — re-read the closure, retry only if
    /// it yields something different — could not fix that. Inside the expiry
    /// window the host is still serving the dead token by definition, so the
    /// guard fell straight through to the error every time. Observed on device
    /// 2026-08-24: two 401s 1.8 s apart, both dropping mid-conversation to the
    /// Apple voice, and another five minutes later. So the retry now asks the
    /// host to MINT one (`getToken({ skipCache: true })` via the bridge) rather
    /// than hoping a newer one has already landed.
    private func send(path: String, method: String, jsonBody: [String: Any]? = nil) async throws -> Data {
        let (first, usedToken) = try request(path: path, method: method, jsonBody: jsonBody)
        do {
            let payload = try await data(for: first)
            markAlive(usedToken)
            return payload
        } catch ProviderError.httpError(let code, let body) where code == 401 || code == 403 {
            markDead(usedToken)
            // The host's poll may already have landed a newer one between our
            // two calls; that costs nothing to check.
            var next = tokenProvider()
            if next == nil || deadTokens.contains(next!) {
                next = await mintFreshToken()
                if let next { mintedToken = next }
            }
            guard let fresh = next, !deadTokens.contains(fresh) else {
                throw ProviderError.httpError(code, body)
            }
            // Sends exactly the candidate the guard approved. Re-deriving via
            // currentToken() here could pick a DIFFERENT token: once a token we
            // minted ourselves went dead, currentToken() read the host's
            // differing token as "the host has moved on" and returned it — even
            // when that was the token rejected an expiry boundary earlier. The
            // retry then went out already-dead, 401'd, and threw. Reachable
            // whenever the host's 30s poll is stalled (a suspended web view —
            // a locked screen, which is the normal hands-free case) while our
            // own minted token ages out.
            let (retry, _) = try request(path: path, method: method, jsonBody: jsonBody, token: fresh)
            let payload = try await data(for: retry)
            markAlive(fresh)
            return payload
        }
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw ProviderError.httpError(status, body)
        }
        return data
    }

    // MARK: Voices + TTS

    public func listVoices() async throws -> [SpeechService.Voice] {
        try await catalog().map { SpeechService.Voice(id: $0.id, name: $0.name) }
    }

    private struct CatalogVoice: Decodable {
        let id: String
        let name: String
        let labels: [String: String]?
    }

    private func catalog() async throws -> [CatalogVoice] {
        struct VoicesResponse: Decodable { let voices: [CatalogVoice] }
        let data = try await send(path: "api/v1/speech/voices", method: "GET")
        return try JSONDecoder().decode(VoicesResponse.self, from: data).voices
    }

    /// UserDefaults key prefix for the persisted region-default voice id.
    public func speak(text: String, voiceId: String?, onPlaybackEnd: (@MainActor () -> Void)?) async throws {
        let resolvedVoiceId: String
        if let voiceId {
            resolvedVoiceId = voiceId
        } else if let pinned = SpeechPreferences.pinnedVoiceId {
            // The site key's voice profile chose a voice — honour it over the
            // catalog default.
            resolvedVoiceId = pinned
        } else {
            // No caller-chosen voice: resolve the region default ONCE and
            // persist it. The catalog endpoint returns voices in unstable
            // order, so re-picking "first match" per provider instance
            // rotated through the region's voices session to session — the
            // persisted id (with a deterministic name sort underneath) keeps
            // one stable voice per region.
            if cachedDefaultVoiceId == nil {
                let key = SpeechPreferences.elevenDefaultVoiceKeyPrefix + SpeechPreferences.preferredAccent()
                if let saved = SpeechPreferences.store.string(forKey: key) {
                    cachedDefaultVoiceId = saved
                } else {
                    let voices = try await catalog()
                    let accent = SpeechPreferences.preferredAccent()
                    let matches = voices.filter {
                        ($0.labels?["accent"] ?? "").lowercased().contains(accent)
                    }
                    if let picked = (matches.isEmpty ? voices : matches)
                        .min(by: { $0.name < $1.name })?.id {
                        cachedDefaultVoiceId = picked
                        SpeechPreferences.store.set(picked, forKey: key)
                    }
                }
            }
            guard let cached = cachedDefaultVoiceId else { throw ProviderError.voiceRequired }
            resolvedVoiceId = cached
        }
        let expressiveness = SpeechPreferences.speechExpressiveness
        let audio: Data
        do {
            audio = try await send(
                path: "api/v1/speech/synthesize",
                method: "POST",
                jsonBody: [
                    "text": text,
                    "voiceId": resolvedVoiceId,
                    "voiceSettings": [
                        "speed": SpeechPreferences.speechPace,
                        // Expressiveness fans out to two ElevenLabs knobs:
                        // more style, less stability as it rises.
                        "style": 0.6 * expressiveness,
                        "stability": 0.9 - 0.6 * expressiveness,
                    ],
                ]
            )
        } catch {
            // A stale persisted region default (voice since removed from the
            // account) would 4xx forever — drop it so the next attempt
            // re-picks from the live catalog. This attempt still throws so
            // the caller's Apple fallback covers the current utterance.
            // Only voice-shaped errors clear the pick — 401/402/403 are
            // auth/funding problems, not a bad voice id.
            if voiceId == nil, SpeechPreferences.pinnedVoiceId == nil,
               case ProviderError.httpError(let code, _) = error,
               [400, 404, 422].contains(code) {
                cachedDefaultVoiceId = nil
                SpeechPreferences.store.removeObject(
                    forKey: SpeechPreferences.elevenDefaultVoiceKeyPrefix + SpeechPreferences.preferredAccent())
            }
            throw error
        }
        VoiceAudioSession.configureForPlayback()
        self.onPlaybackEnd = onPlaybackEnd
        player = try AVAudioPlayer(data: audio)
        player?.delegate = self
        player?.play()
    }

    public func pauseSpeaking() { player?.pause() }
    public func resumeSpeaking() { player?.play() }

    public func stopSpeaking() {
        onPlaybackEnd = nil
        player?.stop()
        player = nil
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let callback = self.onPlaybackEnd
            self.onPlaybackEnd = nil
            self.player = nil
            callback?()
        }
    }

    // MARK: Realtime STT

    /// Brings the mic up FIRST, then mints the token and opens the socket.
    ///
    /// The original order did the network work first and started capture last,
    /// so the entire round trip — an authenticated token mint plus a WebSocket
    /// handshake, comfortably a second on cellular — sat between the UI saying
    /// "Listening" and any audio being recorded. Everything said in that window
    /// was gone. Now capture starts immediately and chunks recorded before the
    /// socket attaches are held in order and flushed the moment it does.
    public func startTranscription(onEvent: @escaping @MainActor (SpeechService.TranscriptionEvent) -> Void) async throws {
        guard !transcribing else { return }

        #if os(iOS)
        guard await AVAudioApplication.requestRecordPermission() else { throw ProviderError.microphoneDenied }
        #else
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ProviderError.microphoneDenied }
        #endif

        try VoiceAudioSession.configureForRecording()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = Int(format.sampleRate)
        guard Self.supportedPcmRates.contains(sampleRate) else {
            VoiceAudioSession.releaseIfIdle()
            throw ProviderError.unsupportedSampleRate(format.sampleRate)
        }

        // Captured strongly by the tap so the audio thread never reaches back
        // through `self` for the socket (it may not exist yet).
        let sink = PendingAudioSink()
        self.onEvent = onEvent
        audioSink = sink
        audioEngine = engine
        transcribing = true

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var pcm = [Int16](repeating: 0, count: frames)
            var energy: Float = 0
            for i in 0..<frames {
                let sample = max(-1.0, min(1.0, channel[i]))
                energy += sample * sample
                pcm[i] = Int16(max(-32768, min(32767, Int32(sample * 32767))))
            }
            // Mic energy tells the caller the user is still talking even when
            // the transcript stream has gone quiet — see TranscriptionEvent.
            if frames > 0 {
                let rms = (energy / Float(frames)).squareRoot()
                Task { @MainActor [weak self] in
                    guard let self, self.transcribing else { return }
                    self.onEvent?(.audioLevel(rms))
                }
            }
            let payloadData = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
            let payload: [String: Any] = [
                "message_type": "input_audio_chunk",
                "audio_base_64": payloadData.base64EncodedString(),
                "sample_rate": sampleRate,
            ]
            if let json = try? JSONSerialization.data(withJSONObject: payload),
               let text = String(data: json, encoding: .utf8) {
                sink.push(text)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownCapture()
            throw error
        }

        // Mic is hot from here — the handshake below no longer costs the user
        // the start of their sentence.
        struct TokenResponse: Decodable { let token: String }
        let singleUseToken: String
        do {
            let tokenData = try await send(path: "api/v1/speech/realtime-token", method: "POST")
            singleUseToken = try JSONDecoder().decode(TokenResponse.self, from: tokenData).token
        } catch {
            teardownCapture()
            throw error
        }
        // stopTranscription() while the token was in flight.
        guard transcribing else { return }

        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var queryItems = [
            URLQueryItem(name: "token", value: singleUseToken),
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
        ]
        let language = SpeechPreferences.speechLanguage
        if language != "auto", !language.isEmpty {
            queryItems.append(URLQueryItem(name: "language_code", value: language))
        }
        for keyterm in SpeechPreferences.speechKeyterms {
            queryItems.append(URLQueryItem(name: "keyterms", value: keyterm))
        }
        components.queryItems = queryItems
        let ws = URLSession.shared.webSocketTask(with: components.url!)
        wsTask = ws
        ws.resume()
        listen()
        sink.attach(ws)
    }

    /// Tears the mic down without emitting `.ended` — used when start-up fails
    /// after capture is already running. The caller is throwing, and the
    /// controller answers `.ended` by scheduling a restart.
    private func teardownCapture() {
        transcribing = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioSink?.close()
        audioSink = nil
        onEvent = nil
        VoiceAudioSession.releaseIfIdle()
    }

    public func stopTranscription() {
        finish(error: nil)
    }

    private func listen() {
        wsTask?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                Task { @MainActor [weak self] in
                    guard let self, self.transcribing else { return }
                    var detail = error.localizedDescription
                    if let task = self.wsTask, task.closeCode != .invalid {
                        let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        detail += " [ws close \(task.closeCode.rawValue)\(reason.isEmpty ? "" : ": " + reason)]"
                    }
                    self.finish(error: detail)
                }
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                Task { @MainActor [weak self] in
                    if let text { self?.handleFrame(text) }
                }
                Task { @MainActor [weak self] in
                    self?.listen()
                }
            }
        }
    }

    private func handleFrame(_ frame: String) {
        guard transcribing,
              let data = frame.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = json["message_type"] as? String else { return }
        let text = json["text"] as? String ?? ""
        switch kind {
        case "partial_transcript":
            onEvent?(.partial(text))
        case "committed_transcript", "committed_transcript_with_timestamps":
            if !text.isEmpty { onEvent?(.committed(text)) }
        default:
            // Failures arrive as frames (auth_error, quota_exceeded, …) right
            // before the server closes the socket. Surface the server's own
            // words — the close alone only yields a useless POSIX
            // "Socket is not connected".
            if kind.contains("error") || kind == "quota_exceeded" {
                let detail = (json["error"] as? String)
                    ?? (json["message"] as? String)
                    ?? kind
                finish(error: "ElevenLabs: \(detail)")
            }
        }
    }

    private func finish(error: String?) {
        guard transcribing else { return }
        transcribing = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioSink?.close()
        audioSink = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        VoiceAudioSession.releaseIfIdle()
        if let error { onEvent?(.error(error)) }
        onEvent?(.ended)
        onEvent = nil
    }
}
