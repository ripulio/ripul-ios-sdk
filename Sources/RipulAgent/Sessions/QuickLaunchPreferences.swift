import Foundation
import SwiftUI

// MARK: - Quick-Launch Target

/// One quick-start shortcut: a MODEL the user can begin a session with.
///
/// Shortcuts used to be harness-aligned — one circle per CLI provider, wearing
/// the provider's SF Symbol, landing on whatever `defaultModelId` that provider
/// happened to carry. You could ask for "a Claude Code session"; you could not
/// ask for "an Opus session". The unit here is the catalog model instead, and
/// the harness is *derived* from it (`ModelInfo.type` → providerKey), so the
/// strip speaks the same model vocabulary as the session rows and the chat
/// lozenges — see `ModelIdentity`.
///
/// A target is CLI-backed when a provider resolves (it needs a machine to
/// launch on); otherwise it is an API target that streams through the LLM proxy
/// and can launch without one — though it still uses the paired-or-default
/// machine for repo tools, and it spends Ripul's platform API credits rather
/// than a harness sign-in. Launchability, execution locus, and billing are
/// three separate things; see `QuickLaunchPicker`.
public struct QuickLaunchTarget: Identifiable, Equatable {
    public let model: ModelInfo
    /// Resolved CLI harness key (e.g. "claude-cli"). Nil ⇒ API target.
    public let providerKey: String?
    /// Harness glyph, kept for the corner badge and as the icon fallback when
    /// `ModelIdentity` doesn't recognise the family.
    public let providerSymbol: String?
    public let providerColorHex: String?
    /// Model-aligned identity (glyph + colour). Nil when the family is unknown.
    public let identity: ModelIdentity?

    public var id: String { model.id }
    public var isCli: Bool { providerKey != nil }

    /// Requires a host to launch: CLI (needs the local binary) and axis-2
    /// subscription (needs the host's credential + local proxy). The picker
    /// gates these on a machine instead of offering them machine-free.
    public var requiresMachine: Bool { isCli || model.isSubscription }

    /// Short label for the settings picker — the model's identity where we have
    /// one ("Opus 4.8"), else the catalog name.
    public var displayLabel: String { identity?.label ?? model.name }

    /// Circle tint: model colour, falling back to the harness colour.
    public var color: Color {
        if let identity { return identity.color }
        if let hex = providerColorHex { return Color(hex: hex) }
        return Color(hex: ProviderConstants.ripul.color)
    }

    /// Resolve a target from a catalog model, or nil if it isn't launchable.
    public static func resolve(model: ModelInfo) -> QuickLaunchTarget {
        // CLI models carry their harness in `type` ("claude-cli"); fall back to
        // the model-id prefix table for catalog rows that predate `type`.
        //
        // The fallback is deliberately NOT gated on `model.isCli`. It used to
        // be, which made it dead code: `ModelInfo.isCli` tests
        // `type?.hasSuffix("-cli")`, so it is false for exactly the rows the
        // fallback exists to rescue — the ones with no `type` at all. The live
        // catalog's only Claude Code row (`claude-cli-raw-fable`) carries no
        // `type`, so every CLI target resolved to providerKey nil, was treated
        // as an API target, and was then dropped by `offerableTargets`. Net
        // effect: the quick-launch strip could only ever offer platform-billed
        // API models. `byModelId` is prefix-matched against the CLI providers
        // only (`claude-cli` / `codex-cli` / `antigravity-cli`), so running it
        // unconditionally cannot promote a backend row by accident.
        let def = ProviderConstants.byProviderKey(model.type ?? "")
            ?? ProviderConstants.byModelId(model.id)
        return QuickLaunchTarget(
            model: model,
            providerKey: def?.providerKey,
            providerSymbol: def?.sfSymbol,
            providerColorHex: def?.color,
            identity: ModelIdentity.resolve(modelId: model.id)
        )
    }
}

// MARK: - Quick-Launch Preferences

/// User-owned configuration for the quick-start strip: whether it shows at all,
/// whether its shortcuts are per-model circles or a single "New Session"
/// button, and which models appear in it, in which order.
///
/// Lives in the SDK (not the app) because `GlassSessionsList` ships to SDK
/// hosts too — the first-party Settings screen is only the *editor*. Storage
/// goes through `RipulSessionCache` so an embedded host's keys stay namespaced,
/// matching every other persisted session-list value.
///
/// Ordering is load-bearing: once shortcuts are per-model the catalog holds far
/// more entries than fit in a row, so the stored array IS the strip, left to
/// right.
public enum QuickLaunchPreferences {

    /// Master on/off. Absent ⇒ on, so an upgrading install keeps its shortcuts.
    public static let enabledKey = "ripulQuickLaunchEnabled"
    /// Circles vs. the "New Session" button. Absent ⇒ OFF — the strip is one
    /// labelled button opening the full model picker; the per-model circles are
    /// opt-in from Settings.
    public static let circlesKey = "ripulQuickLaunchCircles"
    /// Ordered catalog model ids. Absent ⇒ seeded from the catalog.
    public static let modelIdsKey = "ripulQuickLaunchModelIds"

    /// Posted after any write so open lists re-read without polling.
    public static let didChangeNotification = Notification.Name("ripulQuickLaunchPreferencesDidChange")

    /// Catalog group holding the machine-free API chat models.
    public static let apiGroup = "Anthropic API"

    // MARK: Enabled

    public static func isEnabled(cache: RipulSessionCache) -> Bool {
        // `bool(forKey:)` can't distinguish "unset" from "false", and unset must
        // mean ON — otherwise every existing install silently loses its strip.
        (cache.object(forKey: enabledKey) as? Bool) ?? true
    }

    public static func setEnabled(_ enabled: Bool, cache: RipulSessionCache) {
        cache.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: Circles

    /// Whether the strip shows one circle per pinned model. Absent ⇒ false:
    /// the strip's only affordance is the "New Session" button, which opens the
    /// same full-catalog picker the circles trail. `bool(forKey:)` conflates
    /// unset with false — which is exactly the default here, so no
    /// `object(forKey:)` dance is needed beyond matching the other readers.
    public static func showCircles(cache: RipulSessionCache) -> Bool {
        (cache.object(forKey: circlesKey) as? Bool) ?? false
    }

    public static func setShowCircles(_ show: Bool, cache: RipulSessionCache) {
        cache.set(show, forKey: circlesKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: Selection

    /// The set shown when the user has never configured anything: each CLI
    /// provider's default model, in providers.json order, then the API models.
    /// This reproduces the pre-existing strip exactly, so turning model
    /// alignment on is not a visible regression on upgrade.
    public static func seededIds(models: [ModelInfo]) -> [String] {
        var ids: [String] = []
        for provider in ProviderConstants.cliProviders {
            guard let key = provider.providerKey else { continue }
            let defaultId = ProviderConstants.defaultModelId(for: key)
            // Prefer the declared default; if the catalog doesn't carry it, take
            // that harness's first model rather than dropping the shortcut.
            if models.contains(where: { $0.id == defaultId }) {
                ids.append(defaultId)
            } else if let first = models.first(where: { QuickLaunchTarget.resolve(model: $0).providerKey == key }) {
                ids.append(first.id)
            }
        }
        ids.append(contentsOf: models.filter { $0.group == apiGroup }.map(\.id))
        return ids
    }

    /// Stored order, or the seeded default when the user hasn't chosen.
    public static func selectedIds(models: [ModelInfo], cache: RipulSessionCache) -> [String] {
        cache.stringArray(forKey: modelIdsKey) ?? seededIds(models: models)
    }

    public static func setSelectedIds(_ ids: [String], cache: RipulSessionCache) {
        cache.set(ids, forKey: modelIdsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Drop back to catalog-derived defaults (forgets the user's curation).
    public static func resetSelection(cache: RipulSessionCache) {
        cache.removeObject(forKey: modelIdsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: Resolution

    /// The strip's contents, in user order. Ids that no longer resolve to a
    /// catalog model are skipped rather than removed — a model missing because
    /// the catalog hasn't loaded yet must not silently erase the user's pick.
    public static func targets(models: [ModelInfo], cache: RipulSessionCache) -> [QuickLaunchTarget] {
        guard isEnabled(cache: cache) else { return [] }
        let byId = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selectedIds(models: models, cache: cache).compactMap { id in
            guard let model = byId[id] else { return nil }
            return QuickLaunchTarget.resolve(model: model)
        }
    }

    /// Every model the picker may offer: the CLI catalog, the platform API
    /// group, and the "your subscription" (axis-2) models. Other backend groups
    /// are excluded — they're reachable from the model picker, but they aren't
    /// session *starters*.
    public static func offerableTargets(models: [ModelInfo]) -> [QuickLaunchTarget] {
        models
            .map(QuickLaunchTarget.resolve)
            .filter { $0.isCli || $0.model.isSubscription || $0.model.group == apiGroup }
    }
}
