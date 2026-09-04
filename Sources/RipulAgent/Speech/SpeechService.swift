import Foundation
import AVFoundation
import Speech

/// On-device speech engine: AVSpeechSynthesizer for TTS, SFSpeechRecognizer +
/// AVAudioEngine for live transcription. Single source of truth for speech on
/// both platforms — the web-facing SpeechCapability and the native
/// SpeechSandboxScreen both drive this service, so the engine behaves
/// identically regardless of which surface invokes it.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class SpeechService: NSObject, ObservableObject {
    public static let shared = SpeechService()

    public struct Voice: Identifiable {
        public let id: String
        public let name: String
    }

    public enum TranscriptionEvent {
        case partial(String)
        case committed(String)
        /// Normalized RMS of a captured mic buffer (0…1), emitted continuously
        /// while capture runs. This is the ONLY signal that distinguishes "the
        /// user paused mid-thought" from "the transcript stream stalled" — a
        /// recognizer emits nothing in either case. Consumers that only care
        /// about text can ignore it.
        case audioLevel(Float)
        case error(String)
        case ended
    }

    public enum SpeechServiceError: LocalizedError {
        case speechRecognitionDenied
        case microphoneDenied
        case recognizerUnavailable
        case localeUnsupported(String)

        public var errorDescription: String? {
            switch self {
            case .speechRecognitionDenied: return "Speech recognition permission denied"
            case .microphoneDenied: return "Microphone permission denied"
            case .recognizerUnavailable: return "Speech recognizer unavailable for this locale"
            case .localeUnsupported(let id): return "Transcription model unavailable for locale \(id)"
            }
        }
    }

    // Observable state for native UI (leaf ObservableObject — observe only in
    // the sandbox screen, never in the host view hierarchy).
    @Published public private(set) var isSpeaking = false
    @Published public private(set) var isTranscribing = false
    @Published public private(set) var partialTranscript = ""
    @Published public private(set) var committedTranscript = ""

    /// Event hook for the capability adapter (web provider path). Native UI
    /// observes the @Published state instead.
    public var onTranscriptionEvent: ((TranscriptionEvent) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var onSpeakingFinished: (() -> Void)?
    /// Permission answered "yes" once this process. Both requests are XPC
    /// round-trips even when already granted, and they sit directly in front of
    /// engine start — in the voice loop every listen re-paid them, widening the
    /// window where the UI says "Listening" but no audio is captured yet.
    private var authorizationGranted = false
    /// Locales whose on-device model is confirmed installed. Same reasoning:
    /// the asset-inventory queries below are async and block engine start.
    private static var verifiedLocales: Set<String> = []
    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - TTS

    /// Current-language voices first, higher quality first within a language.
    public func listVoices() -> [Voice] {
        let currentLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .sorted { a, b in
                let aCurrent = a.language.hasPrefix(currentLanguage)
                let bCurrent = b.language.hasPrefix(currentLanguage)
                if aCurrent != bCurrent { return aCurrent }
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
            .map { voice in
                let quality: String
                switch voice.quality {
                case .premium: quality = " · premium"
                case .enhanced: quality = " · enhanced"
                default: quality = ""
                }
                return Voice(id: voice.identifier, name: "\(voice.name) (\(voice.language))\(quality)")
            }
    }

    /// Begins speaking immediately; returns once playback has started.
    /// `onFinished` fires when the utterance completes naturally (not on
    /// stopSpeaking(), which clears it).
    public func speak(text: String, voiceId: String?, onFinished: (() -> Void)? = nil) throws {
        onSpeakingFinished = nil
        synthesizer.stopSpeaking(at: .immediate)
        onSpeakingFinished = onFinished
        VoiceAudioSession.configureForPlayback()
        let utterance = AVSpeechUtterance(string: text)
        if let voiceId, let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            utterance.voice = voice
        } else if let regional = Self.defaultRegionalVoice() {
            // Follow the device region — a UK phone speaks en-GB, not the
            // synthesizer's en-US default.
            utterance.voice = regional
        }
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    public func pauseSpeaking() {
        synthesizer.pauseSpeaking(at: .word)
    }

    public func continueSpeaking() {
        synthesizer.continueSpeaking()
    }

    public func stopSpeaking() {
        onSpeakingFinished = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Live transcription

    /// Live transcription via SpeechAnalyzer/SpeechTranscriber (iOS 26+) —
    /// Apple's current-generation engine. Volatile results map to `partial`
    /// events; finalized results arrive incrementally per segment and map to
    /// `committed` events (matching the ElevenLabs provider's semantics).
    public func startTranscription() async throws {
        if isTranscribing {
            // Already capturing AND the engine is genuinely running — nothing
            // to do. But a capture whose engine died underneath us (audio
            // session stolen by playback, route change, interruption) leaves
            // this flag true with no audio flowing: the mic looks alive, the
            // caller's restart is swallowed by this guard, and it never
            // recovers. Tear that corpse down and rebuild.
            guard audioEngine?.isRunning != true else { return }
            resetEngine()
        }
        try await ensureAuthorization()

        let locale = Self.preferredTranscriptionLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        try await Self.ensureModel(for: transcriber, locale: locale)

        try VoiceAudioSession.configureForRecording()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        let converter: AVAudioConverter? = {
            guard let analyzerFormat, analyzerFormat != hwFormat else { return nil }
            return AVAudioConverter(from: hwFormat, to: analyzerFormat)
        }()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            if let rms = Self.rms(of: buffer) {
                Task { @MainActor [weak self] in
                    guard let self, self.isTranscribing else { return }
                    self.emit(.audioLevel(rms))
                }
            }
            if let converter, let analyzerFormat {
                let ratio = analyzerFormat.sampleRate / hwFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
                var fed = false
                var conversionError: NSError?
                converter.convert(to: converted, error: &conversionError) { _, status in
                    if fed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                if conversionError == nil {
                    builder.yield(AnalyzerInput(buffer: converted))
                }
            } else {
                builder.yield(AnalyzerInput(buffer: buffer))
            }
        }
        engine.prepare()
        try engine.start()

        audioEngine = engine
        self.analyzer = analyzer
        inputBuilder = builder
        partialTranscript = ""
        committedTranscript = ""
        isTranscribing = true

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self, self.isTranscribing else { return }
                        if result.isFinal {
                            if !text.isEmpty {
                                self.committedTranscript += (self.committedTranscript.isEmpty ? "" : " ") + text
                                self.emit(.committed(text))
                            }
                            self.partialTranscript = ""
                        } else {
                            self.partialTranscript = text
                            self.emit(.partial(text))
                        }
                    }
                }
                await MainActor.run { self?.finishTranscription(errorMessage: nil) }
            } catch {
                await MainActor.run { self?.finishTranscription(errorMessage: error.localizedDescription) }
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
    }

    /// Stops capture and finalizes: closing the input stream lets the
    /// analyzer flush remaining audio, so the last finalized segment still
    /// arrives before the results sequence ends. Watchdog covers a hang.
    public func stopTranscription() {
        guard isTranscribing else { return }
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        inputBuilder?.finish()
        let analyzer = self.analyzer
        Task { @MainActor [weak self] in
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            self?.finishTranscription(errorMessage: nil)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.isTranscribing else { return }
            self.finishTranscription(errorMessage: nil)
        }
    }

    private func finishTranscription(errorMessage: String?) {
        guard isTranscribing else { return }
        resetEngine()
        if let errorMessage {
            emit(.error(errorMessage))
        }
        emit(.ended)
    }

    /// Tear the capture stack down without announcing it. `finishTranscription`
    /// wraps this with the `.error`/`.ended` events; the restart path in
    /// `startTranscription` uses it bare — emitting `.ended` there would tell
    /// the caller its mic had stopped at the exact moment we are rebuilding it,
    /// and `VoiceModeController` answers `.ended` by scheduling another restart.
    private func resetEngine() {
        isTranscribing = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        inputBuilder?.finish()
        inputBuilder = nil
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
        VoiceAudioSession.releaseIfIdle()
    }

    /// Root-mean-square level of a capture buffer, 0…1. Nil for formats we
    /// can't read directly (the analyzer still gets the audio either way).
    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        return (sum / Float(frames)).squareRoot()
    }

    /// Best installed voice for the device locale (language + region, e.g.
    /// en-GB on a UK phone), preferring higher quality tiers (premium >
    /// enhanced > compact). Nil leaves the synthesizer's default in place.
    private static func defaultRegionalVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let voices = AVSpeechSynthesisVoice.speechVoices()
        var candidates: [AVSpeechSynthesisVoice] = []
        if let region = Locale.current.region?.identifier {
            let target = "\(language)-\(region)"
            candidates = voices.filter { $0.language.caseInsensitiveCompare(target) == .orderedSame }
        }
        if candidates.isEmpty {
            candidates = voices.filter { $0.language.hasPrefix("\(language)-") }
        }
        // Deterministic winner: regions usually offer several voices at the
        // SAME quality tier, and `.max` between ties is iteration-order
        // dependent while speechVoices() order is not stable — which rotated
        // the fallback voice between utterances. Break ties by identifier.
        return candidates.sorted {
            if $0.quality.rawValue != $1.quality.rawValue {
                return $0.quality.rawValue > $1.quality.rawValue
            }
            return $0.identifier < $1.identifier
        }.first
    }

    /// Locale for transcription: the speech-language preference when set
    /// (mapped to a concrete region), otherwise the device locale.
    private static func preferredTranscriptionLocale() -> Locale {
        let language = SpeechPreferences.speechLanguage
        guard language != "auto", !language.isEmpty else { return Locale.current }
        let mapped: [String: String] = [
            "en": "en-US", "de": "de-DE", "nl": "nl-NL", "fr": "fr-FR",
            "es": "es-ES", "it": "it-IT", "pt": "pt-PT",
        ]
        return Locale(identifier: mapped[language] ?? language)
    }

    /// Ensures the on-device transcription model for the locale is installed,
    /// downloading it on first use (one-time, size varies by language).
    private static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let tag = locale.identifier(.bcp47)
        if verifiedLocales.contains(tag) { return }
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == tag }) else {
            throw SpeechServiceError.localeUnsupported(locale.identifier)
        }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == tag }) {
            verifiedLocales.insert(tag)
            return
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        verifiedLocales.insert(tag)
    }

    private func emit(_ event: TranscriptionEvent) {
        onTranscriptionEvent?(event)
    }

    private func ensureAuthorization() async throws {
        if authorizationGranted { return }
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else { throw SpeechServiceError.speechRecognitionDenied }

        #if os(iOS)
        let granted = await AVAudioApplication.requestRecordPermission()
        #else
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard granted else { throw SpeechServiceError.microphoneDenied }
        // Revocation kills the app, so a granted answer holds for the process.
        authorizationGranted = true
    }
}

@available(iOS 26.0, macOS 26.0, *)
extension SpeechService: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            let callback = self.onSpeakingFinished
            self.onSpeakingFinished = nil
            callback?()
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onSpeakingFinished = nil
        }
    }
}
