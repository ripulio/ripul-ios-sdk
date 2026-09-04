import Foundation
import Combine
import SwiftUI
import MediaPlayer
#if os(iOS)
import UIKit
import AudioToolbox
#elseif os(macOS)
import AppKit
#endif

/// Hands-free voice conversation loop:
/// listening → sending → thinking → speaking → listening.
///
/// - Listening: live transcription (provider follows the dictation
///   preference). A silence window after the last speech event auto-sends.
/// - Thinking: the agent turn runs (minutes are normal in Ripul); reply text
///   arrives over native chat forwarding, which the controller enables
///   independently of the debug scroller.
/// - Speaking: the completion prose is read aloud (ElevenLabs default voice,
///   Apple fallback). No barge-in in v1 — the mic is off while speaking,
///   which also prevents the speaker→mic feedback loop. Tap to interrupt.
///
/// The class itself is availability-free (SDK floor < 26): all speech-layer
/// use is behind #available with providers stored type-erased, mirroring
/// NativeChatInput's dictation pattern.
@MainActor
public final class VoiceModeController: ObservableObject {
    public enum Phase: Equatable {
        case inactive
        case listening
        case sending
        case thinking
        case speaking
        /// Conversation frozen by the user (AirPods squeeze, lock-screen
        /// pause): mic off, playback held mid-utterance, agent turn (if any)
        /// still running but its reply held until resume.
        case paused
        case notice(String)
    }

    @Published public private(set) var phase: Phase = .inactive {
        didSet {
            // Leaving .speaking discards the clip — skip, stop, notice and
            // every listening path route through here, so this is the one
            // place the flag can't be forgotten. `.paused` is excluded: a
            // frozen utterance still has audio loaded, and resuming it must
            // not have to re-derive that.
            if phase != .speaking, phase != .paused { playbackLive = false }
            updateNowPlaying()
        }
    }
    /// In-flight partial for the current utterance (grey in the UI).
    @Published public private(set) var partialText = ""
    /// Committed segments of the current utterance.
    @Published public private(set) var committedText = ""
    /// Elapsed seconds in the thinking phase (agent working).
    @Published public private(set) var thinkingSeconds = 0

    /// Where the live conversation is drawn. Runtime state, not a setting:
    /// `SpeechPreferences.voiceModeStyle` decides how a session OPENS, this
    /// decides where it is right now. Minimising has to be reachable
    /// mid-conversation — wanting to see the chat is not a reason to hang up,
    /// and the X was previously the only way out of the full-screen view.
    public enum Presentation { case fullscreen, compact }
    @Published public var presentation: Presentation = .fullscreen

    public var isActive: Bool { phase != .inactive }

    /// Silence before the utterance auto-sends. 1.8 s: forgiving of
    /// thinking-out-loud pauses (1.4 s chopped hesitant speech mid-thought in
    /// testing).
    ///
    /// Measured from the last evidence the user is still speaking — a
    /// transcript event OR mic energy above the room's noise floor. It used to
    /// be measured from the last transcript event alone, which conflated "the
    /// user went quiet" with "the recognizer went quiet": a stalled socket, a
    /// restarting engine or an audio session stolen by playback all read as
    /// silence and sent mid-sentence.
    private static let silenceWindow: TimeInterval = 1.8

    /// Ceiling on how long mic energy alone may hold the send open past the
    /// last transcript. Without it, a noisy room never sends.
    private static let maxEnergyHold: TimeInterval = 6.0

    /// Absolute noise gate — below this, a frame is silence regardless of what
    /// the adaptive floor has drifted to.
    private static let minSpeechRms: Float = 0.012

    /// How long the recognizer must have produced nothing before loud audio is
    /// treated as room noise rather than the user. This is what separates "a
    /// television is on" from "someone is mid-sentence": both are loud, only
    /// one produces words.
    private static let noiseAdaptDelay: TimeInterval = 2.0

    private weak var bridge: AgentBridge?
    private var sttProvider: Any?
    private var ttsProvider: Any?
    private var ttsFallback: Any?
    private var runningSink: AnyCancellable?
    private var lastRunning = false
    private var silenceTicker: Task<Void, Never>?
    /// Monotonic clock (never wall time — that jumps) for the send decision.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// Last evidence the user is still speaking: a transcript event, mic energy
    /// above the floor, or capture coming up after a restart.
    private var lastVoiceActivityAt: TimeInterval = 0
    /// Last actual transcript event, so energy can't hold the send open forever.
    private var lastTranscriptAt: TimeInterval = 0
    /// True only while the engine is genuinely capturing. The window cannot
    /// expire while the mic is down (dropped socket, engine restart) — that gap
    /// is not the user being silent, and sending into it truncated the
    /// utterance to whatever had been transcribed before the drop.
    ///
    /// Published because it is also the honest answer to "can I talk yet?".
    /// `phase` flips to `.listening` the instant the overlay opens, but the mic
    /// is not up until permission round-trips, the audio session, the model
    /// check and `AVAudioEngine.start()` (plus, on ElevenLabs, a token mint and
    /// a WebSocket) have all completed. Speaking into that window is simply
    /// lost, so the UI must not claim to be listening during it.
    @Published public private(set) var captureLive = false
    /// True once audio for the current utterance has actually begun — the
    /// speaking-phase counterpart to `captureLive`, and true for the same
    /// reason.
    ///
    /// `phase` flips to `.speaking` the moment we have a reply to read, but
    /// the default provider synthesizes over the network and NOT as a stream:
    /// the whole clip is generated server-side and downloaded before the first
    /// sample plays. On a long completion that gap runs to seconds, and the UI
    /// spent all of it saying "Speaking — tap to skip" over silence.
    ///
    /// Stays true across a pause (the clip is loaded, merely frozen); only
    /// consulted while the phase is `.speaking`.
    @Published public private(set) var playbackLive = false {
        didSet { updateNowPlaying() }
    }
    /// Adaptive noise floor (EMA of quiet frames) so the speech threshold
    /// tracks the room rather than a fixed constant.
    private var noiseFloor: Float = VoiceModeController.minSpeechRms
    private var thinkingTicker: Task<Void, Never>?
    private var replyWaitTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// Message ids present at send time — the reply is the newest assistant
    /// prose NOT in this set.
    private var baselineIds: Set<String> = []
    /// Ambient speech (send acks, progress round-ups) — spoken without
    /// changing phase, so the thinking state machine keeps running.
    private var ambientBusy = false
    /// Assistant prose already read aloud this turn — progress messages and
    /// the completion alike, so nothing is ever spoken twice.
    private var narratedMessageIds: Set<String> = []
    /// Prose waiting to be read. Queued rather than spoken on arrival so a
    /// burst of progress messages is read in order instead of being dropped
    /// by the `ambientBusy` guard.
    private var narrationQueue: [String] = []
    private var narratedThisTurn: Bool { !narratedMessageIds.isEmpty }
    /// True once the current STT provider has produced any transcription —
    /// distinguishes "connection never came up" from a mid-session drop.
    private var sttDelivered = false
    /// One automatic ElevenLabs→Apple swap per activation.
    private var sttFellBack = false
    /// Consecutive mic failures with nothing transcribed; bounded so a mic
    /// that can never start doesn't loop notices forever.
    private var micFailureCount = 0
    private var lastRoundupSecond = 0
    /// `thinkingSeconds` at the last piece of AUDIBLE narration — prose the
    /// pump queued, or agent speech from the `speak` tool. The round-up waits
    /// this out rather than standing down for the whole turn.
    private var lastNarrationSecond = 0
    private var roundupStepBaseline = 0

    private enum PausedContext { case listening, speaking, thinking }
    private var pausedFrom: PausedContext = .listening
    /// Reply that completed while paused — spoken on resume.
    private var pendingReply: String?

    /// Registered remote-command targets, removed precisely on deactivate.
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var remoteCommandsActive = false

    public init() {}

    // MARK: - Lifecycle

    /// Starts the hands-free loop. When `initialUtterance` carries text (the
    /// composer was holding a typed message on long-press), that text stands
    /// in for the first spoken utterance: it takes the same send path the
    /// silence window would, so the reply is spoken and the loop continues.
    /// - Parameter presentation: Forces how this session OPENS, ignoring the
    ///   preference. Siri passes `.compact` because a voice command is a
    ///   request to talk *while looking at* the conversation, and because the
    ///   preference chain (stored ?? profile ?? fallback, with the profile
    ///   pushed from the web) has three layers a caller cannot see. Nil keeps
    ///   the preference, which is what the mic long-press wants.
    public func start(
        bridge: AgentBridge,
        tokenProvider: (() -> String?)?,
        initialUtterance: String? = nil,
        presentation forced: Presentation? = nil
    ) {
        guard phase == .inactive else { return }
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        self.bridge = bridge
        // The preference chooses the opening presentation; the overlay's own
        // controls take over from here.
        let fromPreference: Presentation = SpeechPreferences.voiceModeStyle == "compact" ? .compact : .fullscreen
        presentation = forced ?? fromPreference
        // Logged because "why did it open full screen" is otherwise a
        // three-layer question with no visible answer.
        bridge.handleConsoleLog(
            "LOG: [VOICE] start presentation=\(presentation) preference=\(SpeechPreferences.voiceModeStyle) forced=\(forced.map(String.init(describing:)) ?? "none")"
        )

        let tokens: () -> String? = { tokenProvider?() ?? MachineTokenStore.token }
        // Forces Clerk to mint a token instead of returning its cached one.
        // A voice conversation easily outlives a token, and the host's poll
        // refreshes on its own schedule — without this, every speech call
        // inside the expiry window fails and drops to the Apple voice.
        let mintToken: () async -> String? = { [weak bridge] in
            guard let bridge else { return nil }
            let result = try? await bridge.callAsyncJavaScript(
                "return (await window.Clerk?.session?.getToken({ skipCache: true })) || '';"
            )
            let minted = (result as? String) ?? ""
            return minted.isEmpty ? nil : minted
        }
        switch SpeechPreferences.dictationProviderId {
        case "elevenlabs":
            sttProvider = ElevenLabsNativeSpeechProvider(tokenProvider: tokens, tokenRefresher: mintToken)
        default:
            sttProvider = AppleSpeechProvider()
        }
        // Speaking is quality-first regardless of the dictation preference.
        ttsProvider = ElevenLabsNativeSpeechProvider(tokenProvider: tokens, tokenRefresher: mintToken)
        ttsFallback = AppleSpeechProvider()

        // Reply text rides native chat forwarding — enabled here explicitly;
        // the debug scroller has its own toggle for the same channel.
        bridge.evaluateJavaScript("window.__ripulSetNativeChatForwarding?.(true)")

        sttDelivered = false
        sttFellBack = false
        micFailureCount = 0
        pendingReply = nil
        setCaptureLive(false)
        noiseFloor = Self.minSpeechRms
        noteTranscript()

        // One audio session for the whole conversation. Playback and capture
        // alternate constantly here; letting each configure the session for
        // itself is what let a spoken ack tear down the live mic.
        VoiceAudioSession.begin()
        startSilenceTicker()

        lastRunning = bridge.isAgentRunning
        runningSink = bridge.$isAgentRunning.sink { [weak self] running in
            Task { @MainActor [weak self] in
                self?.handleRunningChange(running)
            }
        }

        // Agent-authored speech: the `speak` tool publishes here.
        VoiceModeCoordinator.shared.beginSession { [weak self] text in
            self?.handleAgentSpeech(text)
        }

        activateRemoteCommands()

        let typed = initialUtterance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if typed.isEmpty {
            beginListening(keepText: false)
        } else {
            // Seeded utterance rides the same slot a spoken one would, so the
            // overlay shows what was "said" and sendUtterance's modality:
            // "voice" submit marks the turn for the speak-back rider.
            committedText = typed
            sendUtterance()
        }
    }

    public func stop() {
        cancelTasks()
        runningSink = nil
        stopAllSpeech()
        // Forwarding stays on only if the debug scroller wants the channel.
        if let bridge, !bridge.nativeChatScrollerEnabled {
            bridge.evaluateJavaScript("window.__ripulSetNativeChatForwarding?.(false)")
        }
        deactivateRemoteCommands()
        VoiceModeCoordinator.shared.endSession()
        setCaptureLive(false)
        if #available(iOS 26.0, macOS 26.0, *) {
            VoiceAudioSession.end()
        }
        pendingReply = nil
        narratedMessageIds = []
        narrationQueue = []
        partialText = ""
        committedText = ""
        thinkingSeconds = 0
        phase = .inactive
    }

    // MARK: - Headphone / remote controls

    /// While voice mode is active, Ripul owns the Now Playing session:
    /// AirPods stem presses (play/pause/next) route to the same
    /// context-sensitive action as tapping the overlay — skip the readout
    /// while speaking, send-now while listening. Released on exit so music
    /// apps regain the controls.
    private func activateRemoteCommands() {
        guard !remoteCommandsActive else { return }
        remoteCommandsActive = true
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            let target = command.addTarget { _ in
                Task { @MainActor in action() }
                return .success
            }
            commandTargets.append((command, target))
        }
        // Media semantics: pause freezes the conversation, play resumes it,
        // a single AirPods squeeze (toggle) does whichever applies. The
        // context action (skip readout / send now) moves to next-track — a
        // double squeeze.
        bind(center.pauseCommand) { [weak self] in self?.pauseConversation() }
        bind(center.playCommand) { [weak self] in
            guard let self else { return }
            if self.phase == .paused { self.resumeConversation() } else { self.handleTap() }
        }
        bind(center.togglePlayPauseCommand) { [weak self] in
            guard let self else { return }
            if self.phase == .paused { self.resumeConversation() } else { self.pauseConversation() }
        }
        bind(center.nextTrackCommand) { [weak self] in self?.handleTap() }
        updateNowPlaying()
    }

    private func deactivateRemoteCommands() {
        guard remoteCommandsActive else { return }
        remoteCommandsActive = false
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlaying() {
        guard remoteCommandsActive else { return }
        let title: String
        switch phase {
        case .listening: title = "Listening"
        case .sending: title = "Sending"
        case .thinking: title = "Working…"
        case .speaking: title = playbackLive ? "Speaking" : "Preparing speech…"
        case .paused: title = "Paused"
        case .notice(let message): title = message
        case .inactive: title = "Voice mode"
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Ripul voice conversation",
            // Only claim the transport is running once audio truly is — the
            // lock screen draws a pause button off this.
            MPNowPlayingInfoPropertyPlaybackRate: phase == .speaking && playbackLive ? 1.0 : 0.0,
        ]
    }

    /// Whether there is an utterance to send right now — drives the overlay's
    /// send button. Anything other than listening already has a turn in
    /// flight, and an empty transcript would submit nothing.
    public var canSendNow: Bool {
        guard phase == .listening else { return false }
        return !(committedText + " " + partialText)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send the current utterance immediately instead of waiting out the
    /// silence window. The window is tuned to tolerate thinking-out-loud
    /// pauses, which necessarily makes it slow when you already know you're
    /// finished — this is the override for that.
    public func sendNow() {
        guard canSendNow else { return }
        sendUtterance()
    }

    /// Tap anywhere on the overlay: skip playback, or force-send while listening.
    public func handleTap() {
        switch phase {
        case .speaking:
            stopAllSpeech()
            beginListening(keepText: false)
        case .listening:
            sendUtterance()
        case .paused:
            resumeConversation()
        default:
            break
        }
    }

    /// Freeze the conversation: mic off (utterance text kept), playback held
    /// mid-word, a running agent turn left to finish quietly.
    public func pauseConversation() {
        switch phase {
        case .listening:
            setCaptureLive(false)
            if #available(iOS 26.0, macOS 26.0, *) {
                (sttProvider as? any NativeSpeechProviding)?.stopTranscription()
            }
            pausedFrom = .listening
            phase = .paused
        case .speaking:
            pauseAllSpeech()
            pausedFrom = .speaking
            phase = .paused
        case .thinking:
            pausedFrom = .thinking
            phase = .paused
        case .notice:
            // Notices auto-resume to listening after ~2 s; pausing holds
            // that off (the typed-command keyboard opened mid-notice) —
            // resume lands back in listening with the transcript kept.
            noticeTask?.cancel()
            pausedFrom = .listening
            phase = .paused
        default:
            break
        }
    }

    public func resumeConversation() {
        guard phase == .paused else { return }
        switch pausedFrom {
        case .listening:
            beginListening(keepText: true)
        case .speaking:
            phase = .speaking
            if #available(iOS 26.0, macOS 26.0, *) {
                (ttsProvider as? any NativeSpeechProviding)?.resumeSpeaking()
                (ttsFallback as? any NativeSpeechProviding)?.resumeSpeaking()
            }
        case .thinking:
            if let reply = pendingReply {
                pendingReply = nil
                speak(reply)
            } else if bridge?.isAgentRunning == true {
                phase = .thinking
                startThinkingTicker()
            } else {
                // Turn finished while paused with nothing held back (the
                // agent spoke pre-pause, or produced no prose) — listen.
                beginListening(keepText: false)
            }
        }
    }

    // MARK: - Typed commands

    /// A typed command mid-session, treated exactly as if it had been
    /// spoken: it rides the same send path the silence window would
    /// (modality "voice" — the reply is spoken back). Submitting while
    /// speaking barges in (playback stops); from paused it doubles as the
    /// resume; while thinking it queues as a mid-run steer.
    public func submitTypedUtterance(_ text: String) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, isActive, phase != .sending else { return }
        setCaptureLive(false)
        noticeTask?.cancel()
        // Interrupt any in-flight readout — a typed command is an explicit
        // barge-in, same as tapping while it speaks.
        stopAllSpeech()
        ambientBusy = false
        // The typed command replaces any half-heard transcript: it IS the
        // utterance, shown in the overlay's committed slot. sendUtterance
        // submits with modality "voice", marking the turn for speak-back.
        partialText = ""
        committedText = typed
        sendUtterance()
    }

    private func cancelTasks() {
        silenceTicker?.cancel(); silenceTicker = nil
        thinkingTicker?.cancel(); thinkingTicker = nil
        replyWaitTask?.cancel(); replyWaitTask = nil
        noticeTask?.cancel(); noticeTask = nil
    }

    private func stopAllSpeech() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        (sttProvider as? any NativeSpeechProviding)?.stopTranscription()
        (ttsProvider as? any NativeSpeechProviding)?.stopSpeaking()
        (ttsFallback as? any NativeSpeechProviding)?.stopSpeaking()
    }

    /// Freeze playback mid-utterance on whichever provider owns it.
    private func pauseAllSpeech() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        (ttsProvider as? any NativeSpeechProviding)?.pauseSpeaking()
        (ttsFallback as? any NativeSpeechProviding)?.pauseSpeaking()
    }

    // MARK: - Listening

    private func beginListening(keepText: Bool) {
        guard #available(iOS 26.0, macOS 26.0, *),
              let stt = sttProvider as? any NativeSpeechProviding else {
            phase = .inactive
            return
        }
        if !keepText {
            partialText = ""
            committedText = ""
        }
        phase = .listening
        // Back to the capture category before the engine starts. Safe here and
        // only here: nothing is capturing yet, and `captureLive` keeps the UI
        // honest about the extra beat this costs.
        VoiceAudioSession.conversationCapture()
        // The mic is not up yet. Until it is, the send decision must not run —
        // and the clock restarts from capture, so a slow engine start doesn't
        // eat into the user's window.
        setCaptureLive(false)
        noteTranscript()
        Task { @MainActor [weak self] in
            do {
                try await stt.startTranscription { [weak self] event in
                    self?.handleTranscription(event)
                }
                guard let self, self.phase == .listening else { return }
                self.setCaptureLive(true)
                self.noteTranscript()
            } catch {
                self?.showNotice("Mic failed: \(error.localizedDescription)")
            }
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func handleTranscription(_ event: SpeechService.TranscriptionEvent) {
        guard phase == .listening else { return }
        switch event {
        case .partial(let text):
            sttDelivered = true
            micFailureCount = 0
            setCaptureLive(true)
            partialText = text
            noteTranscript()
        case .committed(let text):
            sttDelivered = true
            micFailureCount = 0
            setCaptureLive(true)
            if !text.isEmpty {
                committedText = committedText.isEmpty ? text : committedText + " " + text
            }
            partialText = ""
            noteTranscript()
        case .audioLevel(let rms):
            // Audio is flowing, so the engine is genuinely up — this is the
            // most reliable proof of that we get.
            setCaptureLive(true)
            let threshold = max(Self.minSpeechRms, noiseFloor * 3)
            if rms <= threshold {
                // Quiet frame — this is the room. Fall fast so a lull
                // re-baselines quickly.
                noiseFloor += (rms - noiseFloor) * 0.25
            } else if Self.now - lastTranscriptAt >= Self.noiseAdaptDelay {
                // Loud, but the recognizer has produced nothing for a while:
                // a fan, a road, a television. Absorb it slowly so a noisy room
                // still reaches a send.
                noiseFloor += (rms - noiseFloor) * 0.002
            }
            // The third case — loud WHILE words are arriving — deliberately
            // leaves the floor alone. It used to adapt on every loud frame, so
            // a long utterance fed the user's own voice into the floor until
            // `noiseFloor * 3` overtook their speaking level and they stopped
            // counting as speech. Modelled: 10.4 s at an rms of 0.08, and only
            // 5.6 s for a quiet speaker. Past that the silence window expired
            // mid-sentence and sent — truncating exactly the long, unhurried
            // utterances it was widened to protect.
            guard !ambientBusy else { return }
            if rms > threshold {
                lastVoiceActivityAt = Self.now
            }
        case .error(let message):
            setCaptureLive(false)
            // The overlay notice is transient and user-facing; the full cause
            // (server error frames, close codes) goes to the console buffer so
            // device_console_logs can answer "why" after the fact.
            nerror("[VOICE] STT error: \(message)")
            micFailureCount += 1
            if !sttDelivered, !sttFellBack, sttProvider is ElevenLabsNativeSpeechProvider {
                // The cloud mic never came up (network wobble, WS rejection).
                // Swap to on-device — the notice-expiry restart picks up the
                // new provider — instead of re-dialing the same failure.
                sttFellBack = true
                sttProvider = AppleSpeechProvider()
                showNotice("Cloud mic unavailable — using on-device dictation")
            } else if micFailureCount >= 5 {
                // Even on-device can't start (permissions?). Exit cleanly
                // rather than showing the same notice forever.
                stop()
            } else {
                showNotice(message)
            }
        case .ended:
            // Engine ended on its own while we still want the mic — restart,
            // preserving whatever the user already said. The mic is down for
            // the whole restart (a token mint plus a WS handshake, on
            // ElevenLabs), which is emphatically not the user falling silent.
            setCaptureLive(false)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.phase == .listening else { return }
                self.beginListening(keepText: true)
            }
        }
    }

    private func noteTranscript() {
        let stamp = Self.now
        lastTranscriptAt = stamp
        lastVoiceActivityAt = stamp
    }

    /// Publishes capture state on the edges only. The `.audioLevel` path sets
    /// this ~12 times a second, and `captureLive` is `@Published` on a
    /// controller that `AgentView.body` observes — an unguarded write would
    /// re-render the view hosting the WKWebView at buffer rate.
    ///
    /// The false→true edge is the "you can talk now" moment, so it also fires
    /// a haptic: hands-free means not watching the screen for the cue.
    private func setCaptureLive(_ live: Bool) {
        guard captureLive != live else { return }
        captureLive = live
        if live { announceMicLive() }
    }

    /// The "you can talk now" cue, on both channels.
    ///
    /// A haptic alone is the wrong instrument for a hands-free mode: it only
    /// lands if the phone is actually in your hand, and it does not exist at
    /// all on macOS — so the Mac had no go-live cue whatsoever. The chime
    /// reaches you through whatever the audio route already is, AirPods
    /// included, which is where a hands-free listener's attention is.
    ///
    /// Safe to play into a live mic. The conversation session runs
    /// `.voiceChat`, which has echo cancellation, and the send decision cannot
    /// trip on the tone regardless: `evaluateSilence` bails while the
    /// transcript is empty, which it always is the moment capture opens.
    private func announceMicLive() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // 1113 is the system "begin recording" tone — the one Voice Memos
        // uses to mean exactly this.
        AudioServicesPlaySystemSound(1113)
        #elseif os(macOS)
        NSSound(named: "Tink")?.play()
        #endif
    }

    /// Polls the send decision rather than arming a one-shot timer per
    /// transcript event. A one-shot cannot represent "the mic went down at
    /// t+0.4 and came back at t+2.1" — it just fires at t+1.8 into the gap.
    private func startSilenceTicker() {
        silenceTicker?.cancel()
        silenceTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { return }
                self.evaluateSilence()
            }
        }
    }

    /// Auto-send once the user has actually stopped talking. Every guard here
    /// is a state that previously looked like silence and sent mid-sentence.
    private func evaluateSilence() {
        guard phase == .listening, captureLive, !ambientBusy else { return }
        let text = (committedText + " " + partialText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let stamp = Self.now
        // Normal case: genuine silence. Escape hatch: energy keeps insisting
        // someone is talking but nothing has been transcribed for a long time
        // (noisy room, someone else speaking) — send what we have.
        guard stamp - lastVoiceActivityAt >= Self.silenceWindow
            || stamp - lastTranscriptAt >= Self.maxEnergyHold else { return }
        sendUtterance()
    }

    // MARK: - Sending + thinking

    private func sendUtterance() {
        let text = (committedText + " " + partialText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let bridge else { return }
        setCaptureLive(false)
        if #available(iOS 26.0, macOS 26.0, *) {
            (sttProvider as? any NativeSpeechProviding)?.stopTranscription()
        }
        phase = .sending
        baselineIds = Set(bridge.nativeChat.messages.map(\.id))
        Task { @MainActor [weak self] in
            guard let self, let bridge = self.bridge else { return }
            let ok = await bridge.submitMessage(text, modality: "voice")
            guard self.phase == .sending else { return }
            if ok {
                self.enterThinking()
            } else {
                self.showNotice("Send failed")
            }
        }
    }

    private func enterThinking() {
        phase = .thinking
        VoiceModeCoordinator.shared.markTurnStarted()
        thinkingSeconds = 0
        lastRoundupSecond = 0
        lastNarrationSecond = 0
        roundupStepBaseline = 0
        ambientBusy = false
        narratedMessageIds = []
        narrationQueue = []
        // Acknowledge that the message went in — silence after sending is the
        // most disorienting moment of a voice session.
        playSendAccepted()
        startThinkingTicker()
    }

    private func startThinkingTicker() {
        thinkingTicker?.cancel()
        thinkingTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.phase == .thinking else { return }
                self.thinkingSeconds += 1
                self.pumpNarration()
                self.maybeSpeakRoundup()
            }
        }
    }

    /// Speech the agent authored via the `speak` tool. It preempts our
    /// canned acks and round-ups — agent-written narration is always better
    /// than a client-side guess at what's happening.
    private func handleAgentSpeech(_ text: String) {
        guard isActive, phase != .speaking, phase != .paused else { return }
        // The agent has taken over narration for this turn; drop anything the
        // prose pump had queued rather than reading it out behind the agent's
        // own words (pumpNarration stops feeding the queue from here on).
        narrationQueue.removeAll()
        lastNarrationSecond = thinkingSeconds
        stopAmbientSpeech()
        speakAmbient(text, force: true)
    }

    /// "Sent, and it's working" — the bookend to `announceMicLive()`.
    ///
    /// This used to be a spoken phrase drawn at random from a small list ("On
    /// it.", "Okay, give me a minute."). Two problems. It read as contrived,
    /// because it was: canned filler rotating to disguise the fact that it is
    /// always the same event. And it overclaimed — "just handling that" implies
    /// the request was understood, when the only thing that has actually
    /// happened is a successful submit.
    ///
    /// A tone claims nothing, lands in a fraction of the time, and pairs with
    /// the mic-live cue into a two-tone language: rising = your turn to talk,
    /// falling = got it, working. Deliberately the record-stop tone, so the two
    /// are heard as a matched pair rather than two unrelated noises.
    private func playSendAccepted() {
        #if os(iOS)
        AudioServicesPlaySystemSound(1114)
        #elseif os(macOS)
        NSSound(named: "Pop")?.play()
        #endif
    }

    /// Reads the agent's in-flight prose aloud as it arrives.
    ///
    /// A turn used to be silent between the send ack and the completion: the
    /// "here's what I found, now doing X" messages an agent emits while it
    /// works were added to the chat and never voiced, so the only thing a
    /// listener heard during a multi-minute run was a canned step count. They
    /// are now queued and spoken in arrival order.
    ///
    /// Safe to speak on sight: prose crosses the bridge as a complete `add`
    /// with its full `content` (only `thinking` streams in deltas), so there
    /// is no half-written sentence to catch.
    ///
    /// Skipped entirely when the agent is narrating deliberately through the
    /// `speak` tool — that is a purpose-written voice track, and reading its
    /// prose on top would say everything twice.
    private func pumpNarration() {
        guard phase == .thinking, !VoiceModeCoordinator.shared.spokeThisTurn else { return }
        for message in newProseRows() where !narratedMessageIds.contains(message.id) {
            narratedMessageIds.insert(message.id)
            if let spoken = Self.narrationText(for: message.content) {
                narrationQueue.append(spoken)
                // Only audible narration silences the fallback round-up. A
                // message that sanitized away to nothing produced no speech,
                // so it must not buy silence.
                lastNarrationSecond = thinkingSeconds
            }
        }
        guard !ambientBusy, !narrationQueue.isEmpty else { return }
        speakAmbient(narrationQueue.removeFirst())
    }

    /// Occasional spoken progress during long turns — deliberately NOT one
    /// per tool call: first round-up after ~30 s, then every ~45 s, and only
    /// when new steps actually happened since the last one.
    private func maybeSpeakRoundup() {
        // Suppressed by RECENT narration, not by any narration. This gate used
        // to be a pair of whole-turn latches (`spokeThisTurn`, `narratedThisTurn`)
        // that, once set, stayed set: one sentence written at second five bought
        // silence for the remaining four minutes of a long turn. That is exactly
        // the disorienting dead air the round-up exists to fill — and the fallback
        // was disabled precisely when it was needed most. So the agent has to
        // have gone quiet for a full interval before the count speaks up.
        let interval = lastRoundupSecond == 0 ? 30 : 45
        guard thinkingSeconds - lastRoundupSecond >= interval else { return }
        guard thinkingSeconds - lastNarrationSecond >= interval else { return }
        let steps = newStepRows()
        guard steps.count > roundupStepBaseline else { return }
        lastRoundupSecond = thinkingSeconds
        roundupStepBaseline = steps.count
        // Count only, never the step's name. A row's `label`/`method` is a tool
        // identifier written to be read on a screen — "Bash", "mcp__ripul_tools
        // __host_browser_run_js" — and speaking it aloud produces noise rather
        // than progress. This phrase is the fallback for an agent that isn't
        // narrating; how far along it is, is the whole of what it can honestly
        // convey.
        let noun = steps.count == 1 ? "step" : "steps"
        speakAmbient("Still working. \(steps.count) \(noun) so far.")
    }

    /// Tool/step rows for this turn: new since send, no prose content.
    private func newStepRows() -> [NativeChatMessage] {
        guard let bridge else { return [] }
        return bridge.nativeChat.messages.filter { message in
            message.role == .assistant
                && message.content.isEmpty
                && message.askUser == nil
                && !baselineIds.contains(message.id)
        }
    }

    /// Speaks without touching phase (used during .thinking). Skipped when a
    /// previous ambient utterance is still playing; the reply speak path
    /// preempts ambient speech outright.
    private func stopAmbientSpeech() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        (ttsProvider as? any NativeSpeechProviding)?.stopSpeaking()
        (ttsFallback as? any NativeSpeechProviding)?.stopSpeaking()
        ambientBusy = false
    }

    private func speakAmbient(_ text: String, force: Bool = false) {
        guard #available(iOS 26.0, macOS 26.0, *), force || !ambientBusy else { return }
        // Only when the mic is down. `handleAgentSpeech` can land here while
        // .listening, and swapping the category out from under a live capture
        // is exactly the teardown VoiceAudioSession exists to prevent.
        if phase != .listening { VoiceAudioSession.conversationPlayback() }
        ambientBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let done: @MainActor () -> Void = { [weak self] in
                self?.ambientBusy = false
            }
            do {
                guard let tts = self.ttsProvider as? any NativeSpeechProviding else {
                    throw CocoaError(.featureUnsupported)
                }
                try await tts.speak(text: text, voiceId: nil, onPlaybackEnd: done)
            } catch {
                nerror("[VOICE] ambient TTS failed, falling back to Apple: \(error.localizedDescription)")
                do {
                    guard let fallback = self.ttsFallback as? any NativeSpeechProviding else { throw error }
                    try await fallback.speak(text: text, voiceId: nil, onPlaybackEnd: done)
                } catch {
                    nerror("[VOICE] ambient Apple fallback failed: \(error.localizedDescription)")
                    self.ambientBusy = false
                }
            }
        }
    }

    private func handleRunningChange(_ running: Bool) {
        let wasRunning = lastRunning
        lastRunning = running
        // Note: awaitingInput (permission prompts) keeps isAgentRunning true,
        // so this edge only fires on genuine turn completion.
        guard wasRunning, !running else { return }
        if phase == .paused, pausedFrom == .thinking {
            // Finished while frozen: capture the reply quietly; resume speaks it.
            replyWaitTask?.cancel()
            replyWaitTask = Task { @MainActor [weak self] in
                for _ in 0..<10 {
                    guard let self, self.phase == .paused else { return }
                    if let reply = self.findNewReply() {
                        self.pendingReply = reply
                        return
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            return
        }
        guard phase == .thinking else { return }
        // Tier 1: the agent narrated the answer itself via the `speak` tool
        // (the tool description asks it to close with the answer). Reading
        // the written reply on top of that would say everything twice.
        if VoiceModeCoordinator.shared.spokeThisTurn {
            replyWaitTask?.cancel()
            replyWaitTask = Task { @MainActor [weak self] in
                // Let the agent's closing utterance finish before reopening
                // the mic, or we'd transcribe our own speaker.
                while let self, self.ambientBusy, self.isActive {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard let self, self.phase == .thinking else { return }
                self.beginListening(keepText: false)
            }
            return
        }

        // Tiers 2 and 3: no agent-authored speech this turn — fall back to
        // reading the completion (preferring a <spoken> lead if one exists).
        replyWaitTask?.cancel()
        replyWaitTask = Task { @MainActor [weak self] in
            // Forwarding may deliver the reply moments after the flag flips.
            for _ in 0..<10 {
                guard let self, self.phase == .thinking else { return }
                if let reply = self.findNewReply() {
                    self.speak(reply)
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let self, self.phase == .thinking else { return }
            guard self.narratedThisTurn else {
                self.showNotice("Turn finished (no reply text)")
                return
            }
            // Everything this turn was already read aloud as it arrived. Let
            // the last utterance (and anything still queued behind it) finish
            // before reopening the mic, or we'd transcribe our own speaker.
            // Bounded: a lost TTS completion callback would otherwise leave
            // `ambientBusy` stuck true and strand the loop with a dead mic.
            var ticks = 0
            while self.ambientBusy || !self.narrationQueue.isEmpty {
                guard self.isActive, ticks < 1800 else { break }
                ticks += 1
                self.pumpNarration()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard self.phase == .thinking else { return }
            self.beginListening(keepText: false)
        }
    }

    /// Assistant prose added since send, oldest first. The mirror of
    /// `newStepRows()`, which selects the content-*less* tool rows. Question
    /// cards (askUser with options) are excluded — those need the screen.
    private func newProseRows() -> [NativeChatMessage] {
        guard let bridge else { return [] }
        return bridge.nativeChat.messages.filter { message in
            message.role == .assistant
                && !message.content.isEmpty
                && message.askUser == nil
                && !baselineIds.contains(message.id)
        }
    }

    /// Newest assistant prose that wasn't present at send time AND hasn't
    /// already been read aloud as progress narration. Without the second
    /// clause, a closing message the pump happened to catch a beat before the
    /// turn ended would be spoken twice.
    private func findNewReply() -> String? {
        newProseRows().last(where: { !narratedMessageIds.contains($0.id) })?.content
    }

    // MARK: - Speaking

    private func speak(_ text: String) {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            beginListening(keepText: false)
            return
        }
        phase = .speaking
        // Preempt any in-flight ambient ack/round-up.
        stopAllSpeech()
        ambientBusy = false
        // stopAllSpeech() has just closed the mic, so the capture category is
        // no longer earning its keep — hand playback a real media session.
        VoiceAudioSession.conversationPlayback()
        // Voice rider protocol: prefer the model's purpose-composed <spoken>
        // block; fall back to sanitizing the full reply when absent.
        let spoken: String
        if let composed = Self.extractSpokenBlock(text) {
            spoken = Self.sanitizeForSpeech(composed)
        } else {
            spoken = Self.sanitizeForSpeech(text)
        }
        // A reply that is nothing but a code block now sanitizes to nothing —
        // the "Code block omitted." placeholder used to guarantee this was
        // non-empty. Handing an empty string to the synthesizer never fires
        // onPlaybackEnd, which would strand the loop in .speaking with a dead
        // mic. Nothing to say, so hand the mic straight back.
        guard !spoken.isEmpty else {
            beginListening(keepText: false)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resume: @MainActor () -> Void = { [weak self] in
                guard let self, self.phase == .speaking else { return }
                self.beginListening(keepText: false)
            }
            // `speak` returns once playback has actually started (protocol
            // contract), so this is the honest moment to claim we're speaking.
            // Synthesis is a multi-second window the user can act in, and
            // neither stopSpeaking() nor pauseSpeaking() could reach a player
            // that did not exist yet — so whatever they asked for has to be
            // applied here instead, to the clip that has only just begun.
            let playbackBegan: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                switch self.phase {
                case .speaking:
                    self.playbackLive = true
                case .paused where self.pausedFrom == .speaking:
                    // Frozen mid-synthesis: hold the clip at its start rather
                    // than letting it blurt out over a paused conversation.
                    self.pauseAllSpeech()
                    self.playbackLive = true
                default:
                    // Skipped, stopped, or barged in on.
                    self.stopAllSpeech()
                }
            }
            do {
                guard let tts = self.ttsProvider as? any NativeSpeechProviding else {
                    throw CocoaError(.featureUnsupported)
                }
                try await tts.speak(text: spoken, voiceId: nil, onPlaybackEnd: resume)
                playbackBegan()
            } catch {
                guard self.phase == .speaking else { return }
                nerror("[VOICE] reply TTS failed, falling back to Apple: \(error.localizedDescription)")
                do {
                    guard let fallback = self.ttsFallback as? any NativeSpeechProviding else { throw error }
                    try await fallback.speak(text: spoken, voiceId: nil, onPlaybackEnd: resume)
                    playbackBegan()
                } catch {
                    nerror("[VOICE] Apple fallback failed: \(error.localizedDescription)")
                    self.showNotice("Speech failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Notices

    private func showNotice(_ message: String) {
        guard isActive else { return }
        phase = .notice(message)
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self, case .notice = self.phase else { return }
            self.beginListening(keepText: true)
        }
    }

    /// Inner text of the reply's leading <spoken>…</spoken> block, if the
    /// model followed the voice rider protocol. Nil → caller falls back.
    static func extractSpokenBlock(_ text: String) -> String? {
        guard let open = text.range(of: "<spoken>"),
              let close = text.range(of: "</spoken>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        let inner = text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// Ceiling on a single mid-run progress readout. Uncapped, one long
    /// intermediate message (an analysis, a pasted plan, a diff walkthrough)
    /// would hold the conversation for minutes in the middle of a turn. The
    /// completion readout is deliberately NOT capped this way — that one is
    /// the answer, and the user asked for it.
    private static let maxNarrationChars = 600

    /// Shapes in-flight prose for speech: the model's `<spoken>` block when it
    /// composed one, otherwise the sanitized text clipped to a whole sentence
    /// within the budget. Nil when there is nothing left worth saying (a
    /// message that was pure markdown scaffolding, say).
    static func narrationText(for content: String) -> String? {
        let source = extractSpokenBlock(content) ?? content
        let spoken = sanitizeForSpeech(source)
        guard !spoken.isEmpty else { return nil }
        guard spoken.count > maxNarrationChars else { return spoken }
        let clipped = spoken.prefix(maxNarrationChars)
        if let lastSentence = clipped.lastIndex(where: { ".!?".contains($0) }) {
            return String(clipped[...lastSentence])
        }
        return String(clipped)
    }

    /// Markdown reads badly aloud — strip structure, keep prose.
    /// Mirrors the web ReadAloudController's sanitizeForSpeech.
    static func sanitizeForSpeech(_ markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(of: "</?spoken>", with: " ", options: .regularExpression)
        // Dropped silently, like images. Announcing the omission is commentary
        // on the rendering rather than content, and it interrupts the prose to
        // report something the listener cannot act on. Every other strip here
        // is already silent; this was the lone exception.
        text = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[*_~|]+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^>\\s?", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(4900))
    }
}
