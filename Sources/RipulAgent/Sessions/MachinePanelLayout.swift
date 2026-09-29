import SwiftUI

// MARK: - Layout model

public enum MachinePanelPlacement: String, Codable, CaseIterable {
    case tile
    case row
}

/// A user's arrangement of one machine's panel.
///
/// A sparse overlay, never a snapshot of the panel: ids it hasn't seen keep
/// their shipped placement and sort after everything the user arranged. So a
/// new script, or a new provider in providers.json, still shows up instead of
/// being swallowed by an older saved layout.
public struct MachinePanelLayout: Codable, Equatable {
    public var order: [String] = []
    public var hidden: [String] = []
    public var placement: [String: MachinePanelPlacement] = [:]

    public init() {}

    public var isEmpty: Bool { order.isEmpty && hidden.isEmpty && placement.isEmpty }
}

/// Per-machine layouts, device-local.
///
/// Keyed per machine because half the panel is machine-specific — the host's
/// own scripts — and an order over ids that only exist on one Mac means
/// nothing on another. Shared so every row on screen observes the same store,
/// and an edit in the customiser redraws the row behind it immediately.
@MainActor
public final class MachinePanelLayoutStore: ObservableObject {
    public static let shared = MachinePanelLayoutStore()

    private static let key = "ripul.machinePanelLayouts"
    private let defaults: UserDefaults

    @Published public private(set) var layouts: [String: MachinePanelLayout]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: MachinePanelLayout].self, from: data) {
            layouts = decoded
        } else {
            layouts = [:]
        }
    }

    public func layout(for machineId: String) -> MachinePanelLayout {
        layouts[machineId] ?? MachinePanelLayout()
    }

    public func set(_ layout: MachinePanelLayout, for machineId: String) {
        // An untouched layout is stored as nothing, so defaults keep tracking the code.
        if layout.isEmpty {
            layouts.removeValue(forKey: machineId)
        } else {
            layouts[machineId] = layout
        }
        if let data = try? JSONEncoder().encode(layouts) {
            defaults.set(data, forKey: Self.key)
        }
    }

    public func reset(machineId: String) {
        set(MachinePanelLayout(), for: machineId)
    }
}

// MARK: - Panel entries

/// One thing the machine panel can draw — a session tile, a host action, or a
/// housekeeping row — described once so the layout can decide how it renders.
struct MachinePanelEntry: Identifiable {
    let id: String
    let icon: String
    let label: String
    /// Supporting line, shown on tiles.
    let subtitle: String
    var tint: Color = .blue
    let defaultPlacement: MachinePanelPlacement
    /// Offline or disabled machines drop their actionable entries entirely.
    var available: Bool = true
    /// Can't be hidden — without it there's no way back (Customise, Enable).
    var essential: Bool = false
    /// Only makes sense one way round.
    var fixedPlacement: Bool = false
    var isLoading: Bool = false
    var isSucceeded: Bool = false
    var loadingLabel: String? = nil
    var succeededLabel: String? = nil
    let action: () -> Void

    func placement(in layout: MachinePanelLayout) -> MachinePanelPlacement {
        fixedPlacement ? defaultPlacement : (layout.placement[id] ?? defaultPlacement)
    }

    func isHidden(in layout: MachinePanelLayout) -> Bool {
        !essential && layout.hidden.contains(id)
    }
}

extension Array where Element == MachinePanelEntry {
    /// Stored order first; unseen ids keep their declared order after it.
    /// Swift's sort isn't stable, so declaration index is the tiebreak.
    func ordered(by layout: MachinePanelLayout) -> [MachinePanelEntry] {
        let rank = Dictionary(layout.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return enumerated()
            .sorted { lhs, rhs in
                let l = rank[lhs.element.id] ?? Int.max
                let r = rank[rhs.element.id] ?? Int.max
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }
}

extension MachinePanelLayout {
    /// Fold a reordered id list back in. Ids the editor couldn't show (a script
    /// on a machine that's offline right now) keep their place behind it.
    func reordered(_ ids: [String]) -> MachinePanelLayout {
        var copy = self
        let seen = Set(ids)
        copy.order = ids + order.filter { !seen.contains($0) }
        return copy
    }

    func settingHidden(_ id: String, _ hidden: Bool) -> MachinePanelLayout {
        var copy = self
        copy.hidden.removeAll { $0 == id }
        if hidden { copy.hidden.append(id) }
        return copy
    }

    func settingPlacement(_ placement: MachinePanelPlacement, for entry: MachinePanelEntry) -> MachinePanelLayout {
        var copy = self
        // Matching the default is stored as no override, so the entry keeps
        // tracking the code if its shipped placement ever changes.
        if placement == entry.defaultPlacement {
            copy.placement.removeValue(forKey: entry.id)
        } else {
            copy.placement[entry.id] = placement
        }
        return copy
    }
}
