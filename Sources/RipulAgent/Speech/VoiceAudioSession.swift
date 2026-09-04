import Foundation
import AVFoundation

/// Single owner of the shared `AVAudioSession` across the speech layer.
///
/// Playback and capture used to configure the session independently: TTS set
/// `.playback` (which has no input route) and STT set `.playAndRecord`. In a
/// hands-free conversation both run against the SAME underlying session and
/// the same `SpeechService` singleton, so speaking an ack silently tore down
/// the live mic's input tap. Transcription events stopped arriving, and
/// `VoiceModeController`'s silence window read that as "the user stopped
/// talking" and auto-sent mid-sentence. Deactivation had the mirror problem:
/// whichever side finished first called `setActive(false)` out from under the
/// other.
///
/// So: while a conversation holds the session (`begin()` … `end()`), the
/// category is configured ONCE for both directions and neither playback nor
/// capture may re-configure or deactivate it. Outside a conversation — one-shot
/// read-aloud, chat dictation — the per-use configuration below applies as
/// before.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public enum VoiceAudioSession {

    /// True while a hands-free conversation owns the session.
    public private(set) static var isHeld = false

    #if os(iOS)
    private static var routeObserver: NSObjectProtocol?

    /// Force the speaker when we would otherwise land on the earpiece.
    ///
    /// `.voiceChat` mode prefers the built-in receiver, because it is built for
    /// phone calls held to your face. `.defaultToSpeaker` in the category
    /// options is meant to counter that and does not reliably do so, so the
    /// route has to be overridden once the session is actually live. The result
    /// was a hands-free mode playing out of the earpiece — audible only if you
    /// hold the phone to your ear, which is the opposite of hands-free.
    ///
    /// Guarded on the route actually being the receiver: forcing the speaker
    /// while AirPods or headphones are connected would yank audio away from
    /// them.
    private static func preferSpeakerOverReceiver(_ reason: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        guard session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) else {
            nlog("[VOICE] route(\(reason)) = \(outputs) — no override needed")
            return
        }
        do {
            try session.overrideOutputAudioPort(.speaker)
            let after = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
            nlog("[VOICE] route(\(reason)) \(outputs) -> \(after) after speaker override")
        } catch {
            // Previously `try?`. Swallowing this is why the first attempt at
            // the earpiece fix could fail in total silence.
            nerror("[VOICE] speaker override failed (\(reason)): \(error.localizedDescription)")
        }
    }
    #endif

    /// Capture configuration: the mic is live, so we need `.playAndRecord` and
    /// the voice-processing unit for echo cancellation.
    ///
    /// `.videoChat`, NOT `.voiceChat`: both run voice processing, but
    /// `.voiceChat` is modelled on a phone call held to your face and defaults
    /// to the built-in receiver, while `.videoChat` is modelled on hands-free
    /// FaceTime and defaults to the speaker. That mode default beat
    /// `.defaultToSpeaker` in the options and put a hands-free conversation in
    /// the earpiece.
    public static func conversationCapture() {
        guard isHeld else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord else { return }
        try? session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
        )
        try? session.setActive(true, options: [])
        preferSpeakerOverReceiver("capture")
        #endif
    }

    /// Playback configuration, used while the agent speaks.
    ///
    /// The mic is off during playback — there is no barge-in — so keeping the
    /// capture category up bought nothing and cost a lot. A `.playAndRecord`
    /// session running voice processing renders output at telephony level and
    /// on the CALL volume channel: quiet, thin, and unresponsive to the volume
    /// buttons even with the route correctly on the speaker. That is the
    /// "sounds like the earpiece, and the volume does nothing" report, with the
    /// route log saying Speaker the whole time.
    ///
    /// `.playback` with `.spokenAudio` is plain media audio — full level, media
    /// volume, no echo-cancellation attenuation.
    public static func conversationPlayback() {
        guard isHeld else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playback else { return }
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
        nlog("[VOICE] playback session: vol=\(session.outputVolume) route=\(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","))")
        #endif
    }

    /// Take ownership for a voice conversation. The category is swapped between
    /// capture and playback at the loop's own transitions — never underneath a
    /// live mic, which is the failure this type was created to prevent.
    public static func begin() {
        isHeld = true
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
        )
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        preferSpeakerOverReceiver("begin")
        // The override is per-route, so unplugging headphones or dropping a
        // Bluetooth link lands back on the earpiece unless it is re-asserted.
        // Re-applying on route change also covers the user picking a target
        // themselves and later disconnecting it.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { _ in
            Task { @MainActor in preferSpeakerOverReceiver("routeChange") }
        }
        #endif
    }

    /// Release the conversation's claim and deactivate.
    public static func end() {
        isHeld = false
        #if os(iOS)
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Configure for one-shot playback. No-op while a conversation holds the
    /// session — switching to `.playback` there would kill the live mic.
    public static func configureForPlayback() {
        guard !isHeld else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true, options: [])
        #endif
    }

    /// Configure for standalone capture (chat dictation, sandbox). No-op while
    /// a conversation holds the session.
    public static func configureForRecording() throws {
        guard !isHeld else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Deactivate after a one-shot. No-op while a conversation holds the
    /// session — tearing it down mid-conversation is the bug this type exists
    /// to prevent.
    public static func releaseIfIdle() {
        guard !isHeld else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
