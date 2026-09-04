import Foundation

/// Speech configuration pushed down from the web app: the site key's voice
/// profile, already resolved. Mirrors the `agent-framework:voice:config`
/// message and the web-side `VoiceSettings`.
public struct VoiceProfileConfig: Equatable {
    public var profileId: String?
    public var profileName: String?
    public var ttsProviderId: String?
    public var voiceId: String?
    public var pace: Double?
    public var expressiveness: Double?
    public var sttProviderId: String?
    public var language: String?
    public var keyterms: [String]
    /// Master switch. False means the site key offers no speech at all — no
    /// composer mic, no read-aloud, no hands-free mode. The web resolver has
    /// already forced the flags below false when this is off, so nothing here
    /// has to check two of them.
    public var voiceEnabled: Bool
    public var readAloudEnabled: Bool
    public var voiceModeEnabled: Bool
    public var voiceModeStyle: String?
    public var autoSpeakReplies: Bool
    /// When false the profile is authoritative and local settings are ignored.
    public var allowUserOverride: Bool

    public init(
        profileId: String? = nil,
        profileName: String? = nil,
        ttsProviderId: String? = nil,
        voiceId: String? = nil,
        pace: Double? = nil,
        expressiveness: Double? = nil,
        sttProviderId: String? = nil,
        language: String? = nil,
        keyterms: [String] = [],
        voiceEnabled: Bool = true,
        readAloudEnabled: Bool = true,
        voiceModeEnabled: Bool = true,
        voiceModeStyle: String? = nil,
        autoSpeakReplies: Bool = false,
        allowUserOverride: Bool = true
    ) {
        self.profileId = profileId
        self.profileName = profileName
        self.ttsProviderId = ttsProviderId
        self.voiceId = voiceId
        self.pace = pace
        self.expressiveness = expressiveness
        self.sttProviderId = sttProviderId
        self.language = language
        self.keyterms = keyterms
        self.voiceEnabled = voiceEnabled
        self.readAloudEnabled = readAloudEnabled
        self.voiceModeEnabled = voiceModeEnabled
        self.voiceModeStyle = voiceModeStyle
        self.autoSpeakReplies = autoSpeakReplies
        self.allowUserOverride = allowUserOverride
    }
}

/// Speech-related preferences read by SDK chrome (chat dictation, voice mode,
/// read-aloud). The host app points `store` at its — possibly profile-scoped —
/// defaults at startup; defaults to .standard. Deliberately not availability
/// gated: it's plain UserDefaults, safe on every OS the SDK supports.
///
/// Every accessor layers three tiers, matching the web resolver exactly:
///
///   locked profile value  >  user's own setting  >  profile default  >  built-in
///
/// so a branded site key can pin its voice while a first-party surface still
/// lets the user choose. Nothing outside this type reads the profile, which is
/// why the whole SDK honours it without further changes.
public enum SpeechPreferences {

    /// ElevenLabs accent keyword matching the device region, so the default
    /// voice sounds local. Shared by the ElevenLabs provider (which picks and
    /// persists the default) and the speech capability (which reports it to
    /// the web layer so panel read-aloud uses the same voice).
    public static func preferredAccent() -> String {
        switch Locale.current.region?.identifier {
        case "GB": return "british"
        case "IE": return "irish"
        case "AU", "NZ": return "australian"
        default: return "american"
        }
    }

    static let elevenDefaultVoiceKeyPrefix = "elevenLabsDefaultVoiceId."

    /// The persisted region-default ElevenLabs voice, if one has been picked.
    /// Read-only: picking (a catalog fetch) stays in the provider.
    public static var persistedDefaultVoiceId: String? {
        store.string(forKey: elevenDefaultVoiceKeyPrefix + preferredAccent())
    }

    public static var store: UserDefaults = .standard

    /// The active site key's voice profile, pushed from the web app.
    public static var activeProfile: VoiceProfileConfig?

    private static var locked: Bool {
        guard let profile = activeProfile else { return false }
        return !profile.allowUserOverride
    }

    /// Resolve one setting across the tiers. `stored` is nil when the user has
    /// expressed no preference.
    private static func resolve<T>(profile: T?, stored: T?, fallback: T) -> T {
        if locked { return profile ?? stored ?? fallback }
        return stored ?? profile ?? fallback
    }

    public static let dictationProviderKey = "chatDictationProvider"

    /// "apple" (default) or "elevenlabs". Profile ids use the web spelling
    /// ("apple-native"), normalized here.
    public static var dictationProviderId: String {
        let fromProfile = activeProfile?.sttProviderId.map { $0 == "apple-native" ? "apple" : $0 }
        return resolve(profile: fromProfile, stored: store.string(forKey: dictationProviderKey), fallback: "apple")
    }

    public static let speechLanguageKey = "speechLanguage"

    /// BCP-47-ish language for speech recognition: "en" (default), "de",
    /// "nl", … or "auto" for engine auto-detection. Pinning to a language
    /// stops ElevenLabs Scribe mis-detecting accented English as German.
    public static var speechLanguage: String {
        resolve(
            profile: activeProfile?.language,
            stored: store.string(forKey: speechLanguageKey),
            fallback: "en"
        )
    }

    public static let speechKeytermsKey = "speechKeyterms"

    /// Domain vocabulary the recognizer is biased toward (ElevenLabs Scribe
    /// keyterm prompting) — fixes product names the model otherwise normalizes
    /// ("Ripul" → "ripple").
    ///
    /// Merges profile and user terms rather than picking a winner: vocabulary
    /// is additive, and both the customer and the user are right about their
    /// own jargon.
    public static var speechKeyterms: [String] {
        let stored = store.string(forKey: speechKeytermsKey) ?? "Ripul"
        let userTerms = stored.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var merged: [String] = []
        for term in (activeProfile?.keyterms ?? []) + userTerms where !merged.contains(term) {
            merged.append(term)
        }
        return merged
    }

    public static let speechPaceKey = "speechPace"
    public static let speechExpressivenessKey = "speechExpressiveness"

    /// Speaking rate for ElevenLabs TTS (0.7–1.2, default 1.0).
    public static var speechPace: Double {
        // `double(forKey:)` returns 0 for "unset", which is also out of range —
        // treat it as no preference.
        let raw = store.double(forKey: speechPaceKey)
        let stored: Double? = raw == 0 ? nil : raw
        return min(1.2, max(0.7, resolve(profile: activeProfile?.pace, stored: stored, fallback: 1.0)))
    }

    /// Expressiveness 0–1 (default 0.35). Mapped to ElevenLabs style up /
    /// stability down in tandem — one user-facing knob over two raw ones.
    public static var speechExpressiveness: Double {
        let stored: Double? = store.object(forKey: speechExpressivenessKey) == nil
            ? nil
            : store.double(forKey: speechExpressivenessKey)
        return min(1.0, max(0.0, resolve(
            profile: activeProfile?.expressiveness,
            stored: stored,
            fallback: 0.35
        )))
    }

    public static let voiceModeStyleKey = "voiceModeStyle"

    /// "compact" (default) or "fullscreen" — how the hands-free voice mode
    /// presents: a docked panel that keeps the chat visible, or an immersive
    /// orb overlay.
    ///
    /// Compact is the default because hands-free is usually something you do
    /// ALONGSIDE the conversation rather than instead of it — you want to
    /// watch the replies land while you talk. The immersive view remains a
    /// tap away (`presentation` is runtime state, so it can be changed
    /// mid-conversation without hanging up), and both a voice profile and a
    /// stored local setting still override this.
    public static var voiceModeStyle: String {
        resolve(
            profile: activeProfile?.voiceModeStyle,
            stored: store.string(forKey: voiceModeStyleKey),
            fallback: "compact"
        )
    }

    /// Voice the profile pins for TTS, if any. Nil means "first catalog voice".
    public static var pinnedVoiceId: String? {
        activeProfile?.voiceId
    }

    /// Master switch: whether this site key offers speech at all. The three
    /// flags below are already false when this is, so only surfaces with no
    /// flag of their own — the composer mic — need to read it directly.
    public static var voiceEnabled: Bool {
        activeProfile?.voiceEnabled ?? true
    }

    /// Whether the read-aloud control should be offered at all.
    public static var readAloudEnabled: Bool {
        activeProfile?.readAloudEnabled ?? true
    }

    /// Whether hands-free voice mode should be offered at all.
    public static var voiceModeEnabled: Bool {
        activeProfile?.voiceModeEnabled ?? true
    }

    /// Whether replies are spoken without being asked.
    public static var autoSpeakReplies: Bool {
        activeProfile?.autoSpeakReplies ?? false
    }

    /// True when the active profile forbids local overrides — settings UI
    /// should present its controls as managed.
    public static var isManagedByProfile: Bool { locked }

    /// Name of the managing profile, for "managed by ..." copy.
    public static var managingProfileName: String? {
        locked ? activeProfile?.profileName : nil
    }
}
