import Foundation

/// A native-only fence around credential entry. Epoch checks also discard the
/// result of a tool which was already awaiting work when the sheet opened.
@MainActor
enum SecureInputProtection {
    private static var sessions = Set<UUID>()
    private(set) static var epoch: UInt64 = 0
    static var isActive: Bool { !sessions.isEmpty }
    nonisolated static let message = "Device tools are paused while the person enters a private key. Check connection status after they finish."
    static let began = Notification.Name("ripul.secureInput.began")

    struct Paused: LocalizedError { var errorDescription: String? { SecureInputProtection.message } }

    static func begin() -> UUID {
        let id = UUID()
        sessions.insert(id)
        epoch &+= 1
        NotificationCenter.default.post(name: began, object: nil)
        return id
    }

    static func end(_ id: UUID) {
        if sessions.remove(id) != nil { epoch &+= 1 }
    }

    static func check(since previous: UInt64? = nil) throws {
        guard !isActive, previous == nil || previous == epoch else { throw Paused() }
    }
}
