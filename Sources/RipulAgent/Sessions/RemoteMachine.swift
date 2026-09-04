import Foundation

/// A remote host machine (a Mac running the Ripul CLI host) discovered via the
/// relay. The session list pairs with one of these to drive Claude on it.
///
/// Persisted state (cache, user-assigned icons, disabled set) goes through an
/// injected `RipulSessionCache` rather than a hardcoded `UserDefaults`, so a
/// third-party host can keep these keys in an isolated suite.
public struct RemoteMachine: Identifiable, Codable, Equatable {
    public let machineId: String
    public let displayName: String
    public let userId: String
    public let roomId: String
    public let registeredAt: String
    public let lastSeenAt: String
    public let meta: [String: String]?

    public var id: String { machineId }

    public var isOnline: Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: lastSeenAt) else { return false }
        return Date().timeIntervalSince(date) < 300 // 5 minute TTL
    }

    // MARK: - Host kind

    /// True when this machine is a plain browser hosting through the Ripul
    /// extension (Chrome tabs, no window mirror), false for the native app.
    /// Prefers the registered `hostKind` meta; falls back to user-agent
    /// sniffing for machines registered by builds that predate it.
    public var isBrowserHost: Bool {
        if let kind = meta?["hostKind"] { return kind == "browser" }
        guard let ua = meta?["userAgent"], !ua.isEmpty else { return false }
        return !ua.contains("RipulNative")
    }

    /// Human label for a browser host ("Chrome"), nil for native hosts.
    public var browserLabel: String? {
        guard isBrowserHost else { return nil }
        switch meta?["browser"] {
        case "chrome": return "Chrome"
        case "edge": return "Edge"
        case "opera": return "Opera"
        default: return "Browser"
        }
    }

    /// Default SF Symbol when the user hasn't assigned an icon.
    public var defaultIconName: String {
        isBrowserHost ? "globe" : "desktopcomputer"
    }

    /// Declared capabilities from registry meta (`caps`, comma-separated).
    /// Surfaces filter machines by the capability they consume: the machines
    /// panel wants `cli` (chat hosting), Remote Tabs wants `tabs`, the Dock
    /// wants `windows`, Processes wants `processes`. Machines registered by
    /// builds that predate `caps` infer from host kind: native hosts get the
    /// full set, browser hosts get tabs only.
    public var capabilities: Set<String> {
        if let raw = meta?["caps"], !raw.isEmpty {
            return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        return isBrowserHost
            ? ["tabs"]
            : ["cli", "files", "tabs", "windows", "processes"]
    }

    /// Does this machine serve the given capability?
    public func can(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    /// The physical machine a browser host runs on (loopback-probed at
    /// registration). Nil for native hosts and for browsers with no local
    /// Ripul app to ask — those surface as top-level machines.
    public var hostMachineId: String? {
        meta?["hostMachineId"]
    }

    // MARK: - Cache

    private static let cacheKey = "ripulCachedMachines"

    public static func loadCached(cache: RipulSessionCache) -> [RemoteMachine] {
        guard let data = cache.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([RemoteMachine].self, from: data)) ?? []
    }

    public static func saveToCache(_ machines: [RemoteMachine], cache: RipulSessionCache) {
        if let data = try? JSONEncoder().encode(machines) {
            cache.set(data, forKey: cacheKey)
        }
    }

    // MARK: - Machine icons

    private static let iconsKey = "ripulMachineIcons"
    public static let iconsDidChangeNotification = Notification.Name("ripulMachineIconsChanged")

    /// User-assigned SF Symbol icon for this machine, or nil for the default.
    public func icon(cache: RipulSessionCache) -> String? {
        Self.machineIconMap(cache: cache)[machineId]
    }

    /// All machine icon assignments: [machineId: sfSymbolName].
    public static func machineIconMap(cache: RipulSessionCache) -> [String: String] {
        cache.dictionary(forKey: iconsKey) as? [String: String] ?? [:]
    }

    /// Set or clear the icon for a machine.
    public static func setIcon(_ icon: String?, for machineId: String, cache: RipulSessionCache) {
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
    public static func iconsByDisplayName(machines: [RemoteMachine]? = nil, cache: RipulSessionCache) -> [String: String] {
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

    public func isDisabled(cache: RipulSessionCache) -> Bool {
        Self.disabledMachineIds(cache: cache).contains(machineId)
    }

    public static func disabledMachineIds(cache: RipulSessionCache) -> Set<String> {
        Set(cache.stringArray(forKey: disabledKey) ?? [])
    }

    public static func setDisabled(_ machineId: String, disabled: Bool, cache: RipulSessionCache) {
        var ids = disabledMachineIds(cache: cache)
        if disabled { ids.insert(machineId) } else { ids.remove(machineId) }
        cache.set(Array(ids), forKey: disabledKey)
    }
}
