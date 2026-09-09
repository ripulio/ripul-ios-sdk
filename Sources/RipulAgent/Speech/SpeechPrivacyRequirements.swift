import Foundation

/// Privacy declarations belong to the embedding executable, not the SDK's
/// resource bundle. Requesting access without them terminates the process;
/// Swift's do/catch cannot recover from that system privacy violation.
enum SpeechPrivacyRequirements {
    struct MissingUsageDescription: LocalizedError, Equatable {
        let key: String

        var errorDescription: String? {
            "Voice input isn't available because this app's speech access setup is incomplete. Please update the app or contact its developer. You can continue by typing."
        }
    }

    static func validate(requiresSpeechRecognition: Bool, bundle: Bundle = .main) throws {
        var keys = ["NSMicrophoneUsageDescription"]
        if requiresSpeechRecognition { keys.append("NSSpeechRecognitionUsageDescription") }
        for key in keys {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MissingUsageDescription(key: key)
            }
        }
    }
}
