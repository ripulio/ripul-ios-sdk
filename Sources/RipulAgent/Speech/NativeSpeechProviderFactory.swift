import Foundation

@available(iOS 26.0, macOS 26.0, *)
@MainActor
public enum NativeSpeechProviderFactory {
    public static func elevenLabs(tokenProvider: @escaping () -> String?,
                                  tokenRefresher: (() async -> String?)? = nil) -> ElevenLabsNativeSpeechProvider {
        // Once selected, the device-key route stays selected even if a key is
        // removed. It must never switch billing/custody to a saved Ripul token.
        if BundledAgentRuntime.isEnabled || DeviceSpeechCredentials.isConfigured {
            return ElevenLabsNativeSpeechProvider(tokenProvider: { nil }, deviceKeyProvider: { try DeviceSpeechCredentials.read() })
        }
        return ElevenLabsNativeSpeechProvider(tokenProvider: tokenProvider, tokenRefresher: tokenRefresher)
    }
    public static func dictation(tokenProvider: @escaping () -> String?,
                                 tokenRefresher: (() async -> String?)? = nil) -> any NativeSpeechProviding {
        if SpeechPreferences.dictationProviderId == "elevenlabs",
           !BundledAgentRuntime.isEnabled || DeviceSpeechCredentials.isConfigured {
            return elevenLabs(tokenProvider: tokenProvider, tokenRefresher: tokenRefresher)
        }
        return AppleSpeechProvider()
    }
    public static func speaking(tokenProvider: @escaping () -> String?,
                                tokenRefresher: (() async -> String?)? = nil) -> any NativeSpeechProviding {
        if BundledAgentRuntime.isEnabled && !DeviceSpeechCredentials.isConfigured { return AppleSpeechProvider() }
        return elevenLabs(tokenProvider: tokenProvider, tokenRefresher: tokenRefresher)
    }
}
