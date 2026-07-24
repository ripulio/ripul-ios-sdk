import Foundation

/// A remote host machine (a Mac running the Ripul CLI host) discovered via the
/// relay. The session list pairs with one of these to drive Claude on it.
///
/// Persisted state (cache, user-assigned icons, disabled set) goes through an
/// injected `RipulSessionCache` rather than a hardcoded `UserDefaults`, so a
/// third-party host can keep these keys in an isolated suite.
struct RemoteMachine: Identifiable, Codable, Equatable {
    let machineId: String
    let displayName: String
    let userId: String
    let roomId: String
    let registeredAt: String
    let lastSeenAt: String
    let meta: [String: String]?

    var id: String { machineId }

    var isOnline: Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: lastSeenAt) else { return false }
        return Date().timeIntervalSince(date) < 300 // 5 minute TTL
    }

    // MARK: - Cache

    private static let cacheKey = "ripulCachedMachines"

    static func loadCached(cache: RipulSessionCache) -> [RemoteMachine] {
        guard let data = cache.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([RemoteMachine].self, from: data)) ?? []
    }

    static func saveToCache(_ machines: [RemoteMachine], cache: RipulSessionCache) {
        if let data = try? JSONEncoder().encode(machines) {
            cache.set(data, forKey: cacheKey)
        }
    }

    // MARK: - Machine icons

    private static let iconsKey = "ripulMachineIcons"
    static let iconsDidChangeNotification = Notification.Name("ripulMachineIconsChanged")

    /// User-assigned SF Symbol icon for this machine, or nil for the default.
    func icon(cache: RipulSessionCache) -> String? {
        Self.machineIconMap(cache: cache)[machineId]
    }

    /// All machine icon assignments: [machineId: sfSymbolName].
    static func machineIconMap(cache: RipulSessionCache) -> [String: String] {
        cache.dictionary(forKey: iconsKey) as? [String: String] ?? [:]
    }

    /// Set or clear the icon for a machine.
    static func setIcon(_ icon: String?, for machineId: String, cache: RipulSessionCache) {
        var map = machineIconMap(cache: cache)
        if let icon {
            map[machineId] = icon
        } else {
            map.removeValue(forKey: machineId)
        }
        cache.set(map, forKey: iconsKey)
        NotificationCenter.default.post(name: iconsDidChangeNotification, object: nil)
    }

    /// Build a lookup from machine display name -> icon, using cached machines.
    /// Useful for session rows that only know the machine's display name.
    static func iconsByDisplayName(machines: [RemoteMachine]? = nil, cache: RipulSessionCache) -> [String: String] {
        let iconMap = machineIconMap(cache: cache)
        let source = machines ?? loadCached(cache: cache)
        var result: [String: String] = [:]
        for m in source {
            if let icon = iconMap[m.machineId] {
                result[m.displayName] = icon
            }
        }
        return result
    }

    // MARK: - Disabled machines

    private static let disabledKey = "ripulDisabledMachineIds"

    func isDisabled(cache: RipulSessionCache) -> Bool {
        Self.disabledMachineIds(cache: cache).contains(machineId)
    }

    static func disabledMachineIds(cache: RipulSessionCache) -> Set<String> {
        Set(cache.stringArray(forKey: disabledKey) ?? [])
    }

    static func setDisabled(_ machineId: String, disabled: Bool, cache: RipulSessionCache) {
        var ids = disabledMachineIds(cache: cache)
        if disabled { ids.insert(machineId) } else { ids.remove(machineId) }
        cache.set(Array(ids), forKey: disabledKey)
    }
}
