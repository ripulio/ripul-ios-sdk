import Foundation
import Security

/// A personal speech key belongs to this app/profile on this device. It is never
/// placed in web storage, a bridge message, a paired-Mac request or iCloud.
public enum DeviceSpeechCredentials {
    public static var profileScope = "default"
    public static let changed = Notification.Name("RipulDeviceSpeechCredentialsChanged")

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "RipulAgent") + ".device-speech",
         kSecAttrAccount as String: "elevenlabs." + profileScope,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    public enum CredentialError: LocalizedError {
        case invalidKey, keychain(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .invalidKey: return "Enter an ElevenLabs API key without spaces."
            case .keychain: return "The device could not access the speech key in Keychain. Unlock it and try again."
            }
        }
    }
    public static func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw CredentialError.keychain(status) }
        return value
    }
    public static var isConfigured: Bool { (try? read()) != nil }
    public static func validate(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 512,
              key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { throw CredentialError.invalidKey }
        return key
    }
    public static func save(_ value: String) throws {
        let key = try validate(value)
        let update = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = Data(key.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        didChange()
    }
    public static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
        didChange()
    }
    private static func didChange() {
        // A different account may have a different voice catalogue.
        SpeechPreferences.store.removeObject(forKey: SpeechPreferences.deviceVoiceIdKey)
        for key in SpeechPreferences.store.dictionaryRepresentation().keys where key.hasPrefix("elevenLabsDeviceDefaultVoiceId.") {
            SpeechPreferences.store.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
