import Foundation
import Security

/// Secure storage for the long-lived machine token used by the host to keep
/// relay/session/heartbeat comms alive when the Clerk session has expired.
///
/// The token is stored in the keychain so it survives web-data purges and
/// app reinstalls (unlike UserDefaults). It is scoped to this installation
/// via the installation identity.
public enum MachineTokenStore {

    private static let service = "io.ripul.machine-token"

    private static func account() -> String {
        InstallationIdentity.id
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(),
        ]
    }

    /// Save a machine token and its metadata to the keychain.
    public static func setToken(_ token: String, userId: String, machineId: String, expiry: Date?) {
        let value: [String: Any] = [
            "token": token,
            "userId": userId,
            "machineId": machineId,
            "expiry": expiry?.timeIntervalSince1970 ?? NSNull(),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecValueData as String: data,
            ]
            SecItemUpdate(baseQuery() as CFDictionary, updateQuery as CFDictionary)
        }
    }

    /// The stored machine token, or nil if none exists.
    public static var token: String? {
        storedValue?["token"] as? String
    }

    /// Stored userId bound to the token.
    public static var userId: String? {
        storedValue?["userId"] as? String
    }

    /// Stored machineId bound to the token.
    public static var machineId: String? {
        storedValue?["machineId"] as? String
    }

    /// Token expiry, if known.
    public static var expiry: Date? {
        guard let stored = storedValue,
              let raw = stored["expiry"],
              !(raw is NSNull),
              let interval = raw as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    /// Delete the stored token. Called on logout / unregister.
    @discardableResult
    public static func deleteToken() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static var storedValue: [String: Any]? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
