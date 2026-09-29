import Foundation

@MainActor
protocol RealtimeSpeechSocket: AnyObject {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func cancel()
}

@MainActor
final class URLSessionSpeechSocket: RealtimeSpeechSocket {
    private let task: URLSessionWebSocketTask
    init(_ task: URLSessionWebSocketTask) { self.task = task; task.resume() }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: throw URLError(.cannotDecodeContentData)
        }
    }
    func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}

/// Reconnectable transcription, deliberately independent of AVAudioEngine.
/// A single awaited send loop preserves ordering and backpressure. Manual
/// commits delimit 20–30 seconds of audio, cut at a pause where one exists.
/// Only one commit is outstanding, and no subsequent audio is sent before
/// its reply. Thus a received commit acknowledges an exact PCM boundary;
/// replay never depends on fuzzy text matching or word-timestamp rounding.
///
/// Segments are long on purpose. Every commit makes Scribe finalize that
/// segment on its own, and ElevenLabs warns that committing several times in
/// short sequence degrades the model. Committing at every one-second pause
/// (the first version of this stream) turned thinking pauses into full stops,
/// clipped soft trailing words ("int-") and made the model invent fillers
/// ("Mm-hmm ...") at the start of the next segment: 12 of 45 voice messages
/// in the following two days, against 1 of 247 before. Recovery does not need
/// short segments; it replays from the last acknowledged boundary either way.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class ElevenLabsTranscriptionStream {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Timing {
        var poll: UInt64 = 50_000_000
        var retry: UInt64 = 300_000_000
        var connectionTimeout: TimeInterval = 8
        var responseTimeout: TimeInterval = 12
        var recoveryLimit: TimeInterval = 60
        /// Delay between chunks while a backlog (audio recorded while
        /// connecting or reconnecting) is being sent: ~8× real time for 85 ms
        /// chunks, so on-screen text catches up in seconds rather than lagging.
        var catchUp: UInt64 = 10_000_000
        /// Seconds of audio before a pause may close a segment.
        var segmentTarget: TimeInterval = 20
        /// Quiet (seconds since the last voiced chunk) that counts as a pause.
        var segmentPause: TimeInterval = 0.8
        /// Hard cap. Scribe commits on its own after ~36 s, which this stream
        /// would treat as an unsolicited boundary, so stay well inside it.
        var segmentLimit: TimeInterval = 30
    }

    private let diagnosticID = UUID().uuidString
    private let audio: BufferedSpeechAudio
    private let connect: () async throws -> any RealtimeSpeechSocket
    private let event: (SpeechService.TranscriptionEvent) -> Void
    private let timing: Timing
    private var socket: (any RealtimeSpeechSocket)?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var ready = false
    private var established: Bool
    private var failures = 0
    private var connectingAt = Date()
    private var recoveryAt: Date?
    private var lastResponse = Date()
    private var pendingCommit: (frame: Int, at: Date)?
    private var sendingAt: Date?
    private var sentFrame = 0
    private var segmentStart = 0
    private var lastVoicedFrame = 0
    private var segmentHasVoice = false
    private var firstChunk = true
    private var previousText = ""
    /// Text of the segment just acknowledged, until the next segment's first
    /// genuine partial. See `isStalePartial`.
    private var lastCommittedText: String?
    private var recoveryTarget: Int?
    private var finishing = false
    private(set) var finished = false
    private(set) var failure: Failure?

    init(audio: BufferedSpeechAudio, previouslyConnected: Bool = false,
         timing: Timing = Timing(),
         connect: @escaping () async throws -> any RealtimeSpeechSocket,
         event: @escaping (SpeechService.TranscriptionEvent) -> Void) {
        self.audio = audio
        established = previouslyConnected
        self.timing = timing
        self.connect = connect
        self.event = event
    }

    private func log(_ message: String, level: RipulLogLevel = .log) {
        voiceDiagnostic("[VOICE-STT] \(message) stream=\(diagnosticID)", level: level)
    }

    func start() {
        log("start previouslyConnected=\(established)")
        event(.recovery("Connecting — still recording"))
        open(after: 0)
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                self.checkHealth()
                do { try await Task.sleep(nanoseconds: self.timing.poll) } catch { return }
            }
        }
    }

    func stop() {
        if !stopped { log("stop finished=\(finished) failed=\(failure != nil) bufferedMs=\((audio.snapshot.captured - audio.snapshot.confirmed) * 1000 / audio.sampleRate)") }
        stopped = true
        generation = UUID()
        receiver?.cancel(); sender?.cancel(); watchdog?.cancel()
        socket?.cancel(); socket = nil
        audio.clear()
    }

    /// Capture has already been frozen by the provider. Wait for the final
    /// acknowledged transcript, including any audio awaiting reconnection.
    func finish() async throws {
        audio.finishCapture()
        finishing = true
        log("finalizing bufferedMs=\((audio.snapshot.captured - audio.snapshot.confirmed) * 1000 / audio.sampleRate)")
        while !finished {
            if let failure { throw failure }
            if stopped { throw CancellationError() }
            try await Task.sleep(nanoseconds: timing.poll)
        }
        log("finalized")
    }

    private func open(after delay: UInt64) {
        log("connect attempt=\(failures + 1) delayMs=\(delay / 1_000_000)")
        let id = UUID()
        generation = id
        ready = false
        pendingCommit = nil
        sendingAt = nil
        sentFrame = audio.snapshot.confirmed
        segmentStart = sentFrame
        segmentHasVoice = false
        lastVoicedFrame = sentFrame
        firstChunk = true
        connectingAt = Date().addingTimeInterval(Double(delay) / 1_000_000_000)
        receiver = Task { @MainActor [weak self] in
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                guard let self, self.isCurrent(id) else { return }
                let connection = try await self.connect()
                guard self.isCurrent(id) else { connection.cancel(); return }
                self.socket = connection
                while self.isCurrent(id) {
                    let frame = try await connection.receive()
                    guard self.isCurrent(id) else { return }
                    self.receive(frame, generation: id)
                }
            } catch {
                guard let self, self.isCurrent(id) else { return }
                self.reconnect(error)
            }
        }
    }

    private func isCurrent(_ id: UUID) -> Bool { !stopped && generation == id }

    private func reconnect(_ error: Error, reason: StaticString = "transport") {
        guard !stopped else { return }
        failures += 1
        // Never log request URLs, tokens, provider bodies or audio/transcripts.
        log("disconnect reason=\(reason) \(voiceErrorMetadata(error)) attempt=\(failures) bufferedMs=\((audio.snapshot.captured - audio.snapshot.confirmed) * 1000 / audio.sampleRate)", level: .warn)
        if !established && failures >= 3 {
            fail("ElevenLabs is unavailable at startup. Please repeat any speech recorded while connecting.", reason: "startup_unavailable")
            return
        }
        if recoveryAt == nil { recoveryAt = Date() }
        receiver?.cancel(); sender?.cancel(); socket?.cancel(); socket = nil
        event(.recovery("Reconnecting — still recording"))
        // Leave the last partial visible while offline. Replay replaces it;
        // it is never promoted to committed text merely because a socket died.
        open(after: min(timing.retry * UInt64(failures), 3_000_000_000))
    }

    private func receive(_ frame: String, generation id: UUID) {
        guard let data = frame.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = json["message_type"] as? String else { return }
        switch kind {
        case "session_started":
            guard !ready else { return }
            log("connected recovering=\(recoveryAt != nil)")
            ready = true
            established = true
            lastResponse = Date()
            event(.connectionReady)
            if recoveryAt != nil {
                recoveryTarget = audio.snapshot.captured
                event(.recovery("Catching up — audio saved"))
            } else {
                event(.recovery(nil))
            }
            sender = Task { @MainActor [weak self] in
                do {
                    while let self, self.isCurrent(id), !self.finished {
                        let backlog = try await self.sendNext(generation: id)
                        try await Task.sleep(nanoseconds: backlog ? self.timing.catchUp : self.timing.poll)
                    }
                } catch {
                    guard let self, self.isCurrent(id) else { return }
                    self.reconnect(error)
                }
            }
        case "partial_transcript":
            lastResponse = Date()
            let text = json["text"] as? String ?? ""
            guard !isStalePartial(text) else { return }
            lastCommittedText = nil
            event(.partial(text))
        case "committed_transcript":
            // With manual commits and <=30s segments, an unsolicited commit
            // cannot safely acknowledge audio. Replay rather than guess.
            guard let commit = pendingCommit else {
                reconnect(Failure(message: "Unexpected transcription boundary"))
                return
            }
            let text = json["text"] as? String ?? ""
            audio.acknowledge(through: commit.frame)
            pendingCommit = nil
            segmentStart = commit.frame
            segmentHasVoice = false
            lastVoicedFrame = commit.frame
            lastResponse = Date()
            previousText = String((previousText + " " + text).suffix(49))
            lastCommittedText = text
            event(.committed(text))
            if let target = recoveryTarget, commit.frame >= target {
                let elapsed = Int(Date().timeIntervalSince(recoveryAt ?? Date()) * 1000)
                log("recovered elapsedMs=\(elapsed) replayThroughFrame=\(commit.frame)")
                recoveryTarget = nil
                recoveryAt = nil
                failures = 0
                event(.recovery(nil))
            }
            if finishing && commit.frame == audio.snapshot.captured { finished = true }
        case "committed_transcript_with_timestamps", "warning":
            break // Optional duplicate/enrichment, never a second acknowledgement.
        case "auth_error", "quota_exceeded", "unaccepted_terms", "invalid_request", "input_error", "chunk_size_exceeded":
            log("unavailable kind=\(kind)", level: .error)
            fail("ElevenLabs is unavailable. Check your account and key permissions. Some recorded speech could not be transcribed; review the text before continuing.", reason: "account_unavailable")
        default:
            if kind.contains("error") || ["rate_limited", "queue_overflow", "resource_exhausted", "session_time_limit_exceeded", "insufficient_audio_activity", "commit_throttled"].contains(kind) {
                log("retryable kind=\(["rate_limited", "queue_overflow", "resource_exhausted", "session_time_limit_exceeded", "insufficient_audio_activity", "commit_throttled"].contains(kind) ? kind : "provider_error")", level: .warn)
                reconnect(Failure(message: "Transcription service interrupted"))
            }
        }
    }

    /// Sends at most one audio chunk and, when a segment is complete, its
    /// commit. Returns true when more recorded audio is already waiting.
    @discardableResult
    /// Scribe can deliver a partial for a segment after that segment's
    /// committed transcript. The controller shows committed + partial, so a
    /// late partial repeats the whole segment: "A. Send command. A" once
    /// segments became utterance-length (a one-second segment only ever
    /// repeated a word). A partial is stale when the stream has finished, when
    /// no audio has been sent since the acknowledged commit (it cannot
    /// describe new speech), or when it is still just a prefix of the text
    /// that was committed. The committed text is never filtered, so dropping a
    /// genuine partial only delays the display of new words.
    private func isStalePartial(_ text: String) -> Bool {
        if finished { return true }
        if pendingCommit == nil && sentFrame == segmentStart && lastCommittedText != nil { return true }
        guard let committed = lastCommittedText else { return false }
        let partial = Self.normalized(text)
        return partial.isEmpty || Self.normalized(committed).hasPrefix(partial)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init).joined()
            .split(separator: " ").joined(separator: " ")
    }

    private func sendNext(generation id: UUID) async throws -> Bool {
        guard pendingCommit == nil, let socket else { return false }
        let state = audio.snapshot
        if finishing && state.captured == state.confirmed { finished = true; return false }
        if let chunk = audio.chunk(after: sentFrame) {
            var payload: [String: Any] = ["message_type": "input_audio_chunk",
                                          "audio_base_64": chunk.pcm.base64EncodedString(),
                                          "sample_rate": audio.sampleRate]
            if firstChunk, !previousText.isEmpty { payload["previous_text"] = previousText }
            firstChunk = false
            sentFrame = chunk.end
            if chunk.voiced {
                if !segmentHasVoice { lastResponse = Date() }
                lastVoicedFrame = chunk.end
                segmentHasVoice = true
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            sendingAt = Date()
            try await socket.send(text)
            guard isCurrent(id) else { return false }
            sendingAt = nil
        }
        let backlog = audio.chunk(after: sentFrame) != nil
        let length = sentFrame - segmentStart
        guard length > 0 else { return backlog }
        let rate = audio.sampleRate
        let seconds = Double(length) / Double(rate)
        let endOfCapture = finishing && sentFrame == audio.snapshot.captured
        let atRecoveryBoundary = recoveryTarget.map { sentFrame >= $0 } ?? false
        let quiet = segmentHasVoice && Double(sentFrame - lastVoicedFrame) >= Double(rate) * timing.segmentPause
        guard endOfCapture
            || seconds >= timing.segmentLimit
            || (seconds >= timing.segmentTarget && quiet)
            || (seconds >= 2 && atRecoveryBoundary) else { return backlog }
        // Scribe begins processing after 2s. Pad a short final segment with
        // silence; padding is transport-only and never advances the PCM ledger.
        let padding = max(0, rate * 2 - length)
        let payload: [String: Any] = ["message_type": "input_audio_chunk", "commit": true,
                                     "audio_base_64": Data(count: padding * 2).base64EncodedString(),
                                     "sample_rate": rate]
        pendingCommit = (sentFrame, Date()) // May receive the reply before send returns.
        sendingAt = Date()
        try await socket.send(String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
        if isCurrent(id) { sendingAt = nil }
        return false // Nothing more is sent until this commit is acknowledged.
    }

    private func checkHealth() {
        let now = Date()
        let state = audio.snapshot
        if state.overflow {
            fail("The 60-second audio buffer filled before ElevenLabs recovered. Recording stopped and some speech is missing. Review the text and repeat the missing part.", reason: "buffer_overflow", audioGap: true)
        } else if state.recording && now.timeIntervalSince(state.lastCapture) > 3 {
            fail("Microphone recording was interrupted. Some speech may be missing. Review the text and repeat the missing part.", reason: "capture_interrupted", audioGap: true)
        } else if let since = recoveryAt, now.timeIntervalSince(since) > timing.recoveryLimit {
            fail("ElevenLabs could not recover within 60 seconds. Some recorded speech could not be transcribed. Review the text and repeat the missing part.", reason: "recovery_deadline")
        } else if !ready && now.timeIntervalSince(connectingAt) > timing.connectionTimeout {
            reconnect(URLError(.timedOut), reason: "connection_timeout")
        } else if let sendingAt, now.timeIntervalSince(sendingAt) > timing.responseTimeout {
            reconnect(URLError(.timedOut), reason: "send_timeout")
        } else if let pendingCommit, now.timeIntervalSince(pendingCommit.at) > timing.responseTimeout {
            reconnect(URLError(.timedOut), reason: "commit_timeout")
        } else if ready && segmentHasVoice && now.timeIntervalSince(lastResponse) > timing.responseTimeout {
            reconnect(URLError(.timedOut), reason: "response_timeout")
        }
    }

    private func fail(_ message: String, reason: StaticString, audioGap: Bool = false) {
        guard !stopped else { return }
        failure = Failure(message: message)
        log("recovery stopped reason=\(reason) audioGap=\(audioGap) bufferedMs=\((audio.snapshot.captured - audio.snapshot.confirmed) * 1000 / audio.sampleRate)", level: .error)
        stop()
        event(audioGap ? .audioGap(message) : .error(message))
    }
}
