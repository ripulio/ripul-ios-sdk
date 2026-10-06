import Foundation
import AVFoundation
import Speech

/// Listens for "stop" while the phone is talking, so a hands-free listener can
/// cut a readout short without touching anything.
///
/// Experimental, behind `SpeechPreferences.sayStopToInterrupt`. Runs Apple's
/// on-device recognizer — free, and no audio leaves the phone — on its own
/// engine. The conversation's own transcription is down during playback, and
/// sharing `SpeechService`'s engine would tangle the two.
///
/// There is no echo cancellation. Voice processing is what made playback
/// quiet and stuck on the call volume, so with this on, playback runs as
/// `.playAndRecord` in the default mode instead (`VoiceAudioSession
/// .conversationPlayback`). The mic therefore hears the readout too, and
/// `StopWordPolicy` ignores a command word the phone is itself saying. Whether
/// a voice carries over the speaker well enough is what the experiment tests.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class StopWordListener {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    /// Bumped on every start and stop, so a start still awaiting its model
    /// check can't bring the mic up after it was cancelled.
    private var generation = 0
    private(set) var isRunning = false

    func start(speaking: String, onStop: @escaping @MainActor () -> Void) {
        stop()
        generation += 1
        let attempt = generation
        isRunning = true
        Task { @MainActor [weak self] in
            do {
                try await self?.run(attempt: attempt, speaking: speaking, onStop: onStop)
            } catch {
                nlog("[VOICE] stop-word listener unavailable: \(error.localizedDescription)")
                guard let self, self.generation == attempt else { return }
                self.stop()
            }
        }
    }

    func stop() {
        generation += 1
        isRunning = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        input?.finish()
        input = nil
        results?.cancel()
        results = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }

    private func run(attempt: Int, speaking: String, onStop: @escaping @MainActor () -> Void) async throws {
        #if os(iOS)
        // Only when playback left an input route open. Under `.playback` there
        // is no mic, and starting an engine would reconfigure the session
        // underneath the readout.
        guard AVAudioSession.sharedInstance().category == .playAndRecord else {
            nlog("[VOICE] stop-word listener skipped: playback has no input route")
            stop()
            return
        }
        try SpeechPrivacyRequirements.validate(requiresSpeechRecognition: true)
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            nlog("[VOICE] stop-word listener skipped: speech recognition not authorized")
            stop()
            return
        }
        let locale = SpeechService.preferredTranscriptionLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        try await SpeechService.ensureModel(for: transcriber, locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard generation == attempt else { return }

        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        let converter: AVAudioConverter? = {
            guard let analyzerFormat, analyzerFormat != hwFormat else { return nil }
            return AVAudioConverter(from: hwFormat, to: analyzerFormat)
        }()
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
            guard let converter, let analyzerFormat else {
                builder.yield(AnalyzerInput(buffer: buffer))
                return
            }
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
            if conversionError == nil { builder.yield(AnalyzerInput(buffer: converted)) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.analyzer = analyzer
        input = builder
        nlog("[VOICE] stop-word listener live")

        results = Task { @MainActor [weak self] in
            // Counts, never the words: enough to tell "heard nothing" from
            // "heard you but took it for the phone" when a stop doesn't land.
            var resultCount = 0
            var echoCount = 0
            do {
                for try await result in transcriber.results {
                    guard let self, self.generation == attempt else { return }
                    resultCount += 1
                    if resultCount == 1 { nlog("[VOICE] stop-word listener hearing audio") }
                    switch StopWordPolicy.verdict(heard: String(result.text.characters), whileSpeaking: speaking) {
                    case .none:
                        continue
                    case .echo:
                        echoCount += 1
                        if echoCount == 1 { nlog("[VOICE] stop-word listener ignored a command word as the phone's own voice") }
                        continue
                    case .command:
                        nlog("[VOICE] stop word heard during playback (after \(resultCount) results)")
                        self.stop()
                        onStop()
                        return
                    }
                }
                nlog("[VOICE] stop-word listener finished: \(resultCount) results, \(echoCount) echoes")
            } catch {
                nlog("[VOICE] stop-word recognition ended: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: sequence)
        #else
        // A Mac plays through speakers with nothing to tell its own voice from
        // the user's; not attempted.
        stop()
        #endif
    }
}
