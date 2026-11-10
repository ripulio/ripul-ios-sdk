import Foundation
import Combine

/// Single-active-audio read-aloud controller for native chat assistant panels.
///
/// Tapping "Speak" on an assistant panel asks the stateless Haiku command
/// orchestrator (`POST /api/v1/commands/speak`) to adapt the panel — including
/// any markdown or structured tables, links, tabs, code blocks, and question
/// options — into natural spoken prose before synthesizing it via the active
/// speaking provider (ElevenLabs / Phonon, with on-device Apple fallback).
@MainActor
public final class NativeChatReadAloudController: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case loading
        case playing
    }

    public enum Mode: String, Sendable {
        case quick
        case detailed
    }

    public static let shared = NativeChatReadAloudController()

    @Published public private(set) var activeMessageId: String?
    @Published public private(set) var phase: Phase = .idle

    /// Optional host-supplied token provider (wired by `AgentView` when present).
    /// Falls back to `MachineTokenStore.token` and the web view's Clerk session.
    public var externalTokenProvider: (() -> String?)?

    var urlSession: URLSession
    var baseURL: URL

    private var generation: UInt64 = 0
    private var activeTask: Task<Void, Never>?
    private var activeProvider: Any?
    private var summaryCache: [String: String] = [:]
    private var cachedClerkToken: String?

    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func state(for messageId: String) -> Phase {
        activeMessageId == messageId ? phase : .idle
    }

    public func stop() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        if #available(iOS 26.0, macOS 26.0, *) {
            (activeProvider as? any NativeSpeechProviding)?.stopSpeaking()
        }
        activeProvider = nil
        if activeMessageId != nil { activeMessageId = nil }
        if phase != .idle { phase = .idle }
    }

    public func toggle(message: NativeChatMessage, mode: Mode = .quick, bridge: AgentBridge?) {
        if activeMessageId == message.id, phase != .idle {
            stop()
            return
        }
        play(message: message, mode: mode, bridge: bridge)
    }

    public func play(message: NativeChatMessage, mode: Mode = .quick, bridge: AgentBridge?) {
        let rawText = Self.panelText(for: message)
        guard !rawText.isEmpty else { return }

        stop()
        generation &+= 1
        let currentGen = generation
        activeMessageId = message.id
        phase = .loading

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let spoken = await self.summarizeForSpeech(
                panelText: rawText,
                messageId: message.id,
                mode: mode,
                bridge: bridge
            )
            guard !Task.isCancelled, self.generation == currentGen else { return }
            guard !spoken.isEmpty else {
                self.stop()
                return
            }
            await self.speakText(spoken, generation: currentGen, bridge: bridge)
        }
    }

    /// Assembles the full readable representation of an assistant panel so
    /// tables, tabbed sections, links, code blocks, and question options are
    /// all visible to the Haiku speech summarizer.
    public static func panelText(for message: NativeChatMessage) -> String {
        var sections: [String] = []

        let primary = (message.askUser?.question.isEmpty == false ? message.askUser?.question : nil) ?? message.content
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrimary.isEmpty {
            sections.append(trimmedPrimary)
        }

        let tabs = !message.tabs.isEmpty ? message.tabs : (message.askUser?.tabs ?? [])
        for tab in tabs {
            let body = tab.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            sections.append("### \(tab.label)\n\(body)")
        }

        if let table = message.table ?? message.askUser?.table, !table.columns.isEmpty {
            let header = "| " + table.columns.map(\.label).joined(separator: " | ") + " |"
            let divider = "| " + table.columns.map { _ in "---" }.joined(separator: " | ") + " |"
            let rows = table.rows.map { row in
                "| " + table.columns.map { col in row[col.key] ?? "" }.joined(separator: " | ") + " |"
            }
            sections.append(([header, divider] + rows).joined(separator: "\n"))
        }

        if let options = message.askUser?.options, !options.isEmpty {
            let lines = options.map { option -> String in
                if let desc = option.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                    return "- \(option.label): \(desc)"
                }
                return "- \(option.label)"
            }
            sections.append("Options:\n" + lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Calls the stateless Haiku orchestrator (`POST /api/v1/commands/speak`)
    /// to summarize the panel for speech, falling back to `/api/v1/commands/orchestrate`
    /// if the worker route is not yet deployed (404), and finally to
    /// `VoiceModeController.sanitizeForSpeech` if offline or unauthenticated.
    func summarizeForSpeech(
        panelText: String,
        messageId: String,
        mode: Mode = .quick,
        bridge: AgentBridge?
    ) async -> String {
        let trimmed = panelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let cacheKey = "\(messageId)\u{0}\(mode.rawValue)\u{0}\(trimmed)"
        if let cached = summaryCache[cacheKey] {
            return cached
        }

        // If the message already contains an explicit <spoken> block, honour it
        // for quick overview mode; detailed mode summarizes the full panel.
        if mode == .quick, let explicit = VoiceModeController.extractSpokenBlock(trimmed) {
            let cleaned = VoiceModeController.sanitizeForSpeech(explicit)
            if !cleaned.isEmpty {
                summaryCache[cacheKey] = cleaned
                return cleaned
            }
        }

        if !BundledAgentRuntime.isEnabled,
           let token = await resolveAuthToken(bridge: bridge, forceRefresh: false) {
            if let summarized = await requestHaikuSpeechSummary(
                panelText: trimmed,
                mode: mode,
                token: token,
                bridge: bridge
            ) {
                let cleaned = VoiceModeController.sanitizeForSpeech(summarized)
                if !cleaned.isEmpty {
                    summaryCache[cacheKey] = cleaned
                    return cleaned
                }
            } else {
                bridge?.handleConsoleLog("LOG: [READ-ALOUD] Haiku summary unavailable; falling back to local speech sanitization")
            }
        } else if !BundledAgentRuntime.isEnabled {
            bridge?.handleConsoleLog("LOG: [READ-ALOUD] No auth token available for Haiku summary; falling back to local speech sanitization")
        }

        return VoiceModeController.sanitizeForSpeech(trimmed)
    }

    private func requestHaikuSpeechSummary(
        panelText: String,
        mode: Mode,
        token: String,
        bridge: AgentBridge?
    ) async -> String? {
        let clipped = String(panelText.prefix(12000))
        let currentBaseURL = baseURL
        let currentSession = urlSession
        let speakResult = await NativeChatReadAloudNetwork.postSpeakEndpoint(
            baseURL: currentBaseURL,
            urlSession: currentSession,
            text: clipped,
            mode: mode,
            token: token
        )
        switch speakResult {
        case .success(let speech):
            return speech
        case .unauthorized:
            if let fresh = await resolveAuthToken(bridge: bridge, forceRefresh: true) {
                if case .success(let speech) = await NativeChatReadAloudNetwork.postSpeakEndpoint(
                    baseURL: currentBaseURL,
                    urlSession: currentSession,
                    text: clipped,
                    mode: mode,
                    token: fresh
                ) {
                    return speech
                }
            }
            return nil
        case .notFound:
            // Backwards-compatible fallback via /api/v1/commands/orchestrate when
            // talking to an older worker before /v1/commands/speak is deployed.
            let clerkToken = await resolveClerkToken(bridge: bridge, forceRefresh: false) ?? token
            return await NativeChatReadAloudNetwork.postOrchestrateFallback(
                baseURL: currentBaseURL,
                urlSession: currentSession,
                text: clipped,
                mode: mode,
                token: clerkToken
            )
        case .failed:
            return nil
        }
    }

    private func resolveAuthToken(bridge: AgentBridge?, forceRefresh: Bool) async -> String? {
        if !forceRefresh {
            if let token = externalTokenProvider?(), !token.isEmpty { return token }
            if let machineToken = MachineTokenStore.token, !machineToken.isEmpty { return machineToken }
            if let cachedClerkToken, !cachedClerkToken.isEmpty { return cachedClerkToken }
        }
        if let clerk = await resolveClerkToken(bridge: bridge, forceRefresh: forceRefresh) {
            return clerk
        }
        return externalTokenProvider?() ?? MachineTokenStore.token
    }

    private func resolveClerkToken(bridge: AgentBridge?, forceRefresh: Bool) async -> String? {
        guard let bridge else { return nil }
        let script = forceRefresh
            ? "return (await window.Clerk?.session?.getToken({ skipCache: true })) || '';"
            : "return (await window.Clerk?.session?.getToken()) || '';"
        let result = try? await bridge.callAsyncJavaScript(script)
        let token = ((result as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        cachedClerkToken = token
        return token
    }

    private func speakText(_ text: String, generation currentGen: UInt64, bridge: AgentBridge?) async {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            stop()
            return
        }

        // Prime cached Clerk token if no synchronous token provider is set yet.
        if externalTokenProvider?() == nil, MachineTokenStore.token == nil {
            _ = await resolveClerkToken(bridge: bridge, forceRefresh: false)
        }
        guard !Task.isCancelled, self.generation == currentGen else { return }

        let tokens: () -> String? = { [weak self] in
            self?.externalTokenProvider?() ?? MachineTokenStore.token ?? self?.cachedClerkToken
        }
        let refresher: () async -> String? = { [weak self, weak bridge] in
            await self?.resolveClerkToken(bridge: bridge, forceRefresh: true)
        }

        let provider = NativeSpeechProviderFactory.speaking(
            tokenProvider: tokens,
            tokenRefresher: refresher
        )
        activeProvider = provider
        let onEnd: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == currentGen else { return }
            self.stop()
        }

        do {
            try await provider.speak(
                text: text,
                voiceId: nil,
                modelId: SpeechPreferences.ttsModelId(for: .readAloud),
                onPlaybackEnd: onEnd
            )
            guard self.generation == currentGen else {
                provider.stopSpeaking()
                return
            }
            self.phase = .playing
        } catch {
            guard !Task.isCancelled, self.generation == currentGen else { return }
            // Mirror web ReadAloudController: if cloud TTS fails and the user did
            // not pin a device key, fall back once to Apple on-device speech.
            if !DeviceSpeechCredentials.isConfigured, provider.id != "apple" {
                let fallback = AppleSpeechProvider()
                activeProvider = fallback
                do {
                    try await fallback.speak(
                        text: text,
                        voiceId: nil,
                        modelId: nil,
                        onPlaybackEnd: onEnd
                    )
                    guard self.generation == currentGen else {
                        fallback.stopSpeaking()
                        return
                    }
                    self.phase = .playing
                    return
                } catch {}
            }
            self.stop()
        }
    }
}

private enum NativeChatReadAloudNetwork {
    enum SpeakEndpointOutcome: Sendable {
        case success(String)
        case unauthorized
        case notFound
        case failed
    }

    static func postSpeakEndpoint(
        baseURL: URL,
        urlSession: URLSession,
        text: String,
        mode: NativeChatReadAloudController.Mode,
        token: String
    ) async -> SpeakEndpointOutcome {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/commands/speak"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text, "mode": mode.rawValue]) else { // main-thread-ok: small panel request body outside MainActor
            return .failed
        }
        request.httpBody = body

        do {
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .unauthorized }
            if status == 404 { return .notFound }
            guard (200..<300).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // main-thread-ok: small JSON response decoded after await urlSession.data
                  let speech = (json["speech"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !speech.isEmpty else {
                return .failed
            }
            return .success(speech)
        } catch {
            return .failed
        }
    }

    static func postOrchestrateFallback(
        baseURL: URL,
        urlSession: URLSession,
        text: String,
        mode: NativeChatReadAloudController.Mode,
        token: String
    ) async -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/commands/orchestrate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let sentence: String
        let speechDescription: String
        switch mode {
        case .quick:
            sentence = "Speak for someone who cannot see anything: give a quick one-paragraph overview (two to four short sentences of plain prose) of the chat panel in the lists section to be read aloud. Say what a thing is instead of reading its filename or path, round numbers naturally, give a count and one or two takeaways instead of reading tables or lists row by row, and never read out tables, markdown, code, filenames, paths, hashes, IDs, version numbers, or URLs."
            speechDescription = "One short paragraph (two to four short sentences) of plain spoken prose ready for text-to-speech, with no tables, code, filenames, paths, URLs, hashes, IDs, or markdown."
        case .detailed:
            sentence = "Speak for someone who cannot see anything: give a detailed spoken summary of the chat panel in the lists section that stays close to the original wording, structure, and points from start to finish. Explain what any table shows and walk through its key findings conversationally instead of reading cells or rows, round complicated numbers and decimals naturally, describe files and code in plain words instead of reading filenames, paths, or syntax, and never read out raw tables, markdown, code, filenames, paths, hashes, IDs, version numbers, or URLs."
            speechDescription = "Natural spoken prose covering the full substance and flow of the panel for text-to-speech, with no raw tables, complicated numbers, filenames, paths, URLs, hashes, IDs, code, or markdown."
        }

        let payload: [String: Any] = [
            "sentence": sentence,
            "lists": "Panel:\n1. \(text)",
            "tools": [
                [
                    "name": "set_speech",
                    "description": "Return a spoken summary of the chat panel for a listener who cannot see the screen.",
                    "inputs": [
                        [
                            "name": "speech",
                            "kind": "text",
                            "description": speechDescription,
                            "isRequired": true,
                        ],
                    ],
                ],
            ],
            "fallbackTool": "set_speech",
            "addressWords": [] as [String],
            "model": "haiku",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { // main-thread-ok: small panel request body outside MainActor
            return nil
        }
        request.httpBody = body

        do {
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // main-thread-ok: small JSON response decoded after await urlSession.data
                  let calls = json["calls"] as? [[String: Any]],
                  let first = calls.first,
                  let texts = first["texts"] as? [String: Any],
                  let speech = (texts["speech"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !speech.isEmpty else {
                return nil
            }
            return speech
        } catch {
            return nil
        }
    }
}
