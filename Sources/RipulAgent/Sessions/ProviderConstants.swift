import SwiftUI

// MARK: - JSON Model

struct ProviderDef: Codable {
    let id: String
    let providerKey: String?
    let label: String
    let fullLabel: String?
    let keywords: [String]
    let color: String
    let sfSymbol: String
    let modelPrefixes: [String]
    let defaultModelId: String?

    // Not in JSON, but useful downstream
    let webIcon: String?

    /// Whether this provider represents a CLI (has a providerKey).
    var isCli: Bool { providerKey != nil }

    /// Full display label (e.g. "Claude Code"), falling back to short label.
    var displayLabel: String { fullLabel ?? label }

    /// Model prefix for filtering (e.g. "claude-cli-raw-"), derived from modelPrefixes.
    var modelIdPrefix: String? {
        guard let first = modelPrefixes.first else { return nil }
        return first + "-raw-"
    }

    enum CodingKeys: String, CodingKey {
        case id, providerKey, label, fullLabel, keywords, color, sfSymbol, modelPrefixes, defaultModelId, webIcon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        providerKey = try c.decodeIfPresent(String.self, forKey: .providerKey)
        label = try c.decode(String.self, forKey: .label)
        fullLabel = try c.decodeIfPresent(String.self, forKey: .fullLabel)
        keywords = try c.decode([String].self, forKey: .keywords)
        color = try c.decode(String.self, forKey: .color)
        sfSymbol = try c.decode(String.self, forKey: .sfSymbol)
        modelPrefixes = try c.decode([String].self, forKey: .modelPrefixes)
        defaultModelId = try c.decodeIfPresent(String.self, forKey: .defaultModelId)
        webIcon = try c.decodeIfPresent(String.self, forKey: .webIcon)
    }
}

private struct ProvidersFile: Codable {
    let providers: [ProviderDef]
    let defaultColor: String
    let defaultLabel: String
}

// MARK: - ProviderConstants

/// Provider constants derived from shared/providers.json (single source of truth).
/// The same JSON is consumed by the web app via providerConstants.ts.
///
/// Loaded from the SDK's own bundle (`Bundle.module`), which packages
/// `Resources/providers.json`.
enum ProviderConstants {

    // MARK: Loaded data

    private static let data: ProvidersFile = {
        // Prefer the SDK's packaged resource; fall back to the host app bundle.
        let url = Bundle.module.url(forResource: "providers", withExtension: "json")
            ?? Bundle.main.url(forResource: "providers", withExtension: "json")
            ?? Bundle.allBundles.lazy.compactMap { $0.url(forResource: "providers", withExtension: "json") }.first
        guard let url,
              let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ProvidersFile.self, from: raw)
        else {
            // Fallback so the app never crashes if the resource is missing during development.
            return ProvidersFile(providers: [], defaultColor: "#94a3b8", defaultLabel: "Session")
        }
        return decoded
    }()

    static let providers: [ProviderDef] = data.providers
    static let defaultLabel: String = data.defaultLabel

    // MARK: Well-known providers

    /// Resolved definition for Claude Code sessions.
    static let claude = providers.first(where: { $0.id == "claudeCode" })!
    /// Resolved definition for Codex sessions.
    static let codex = providers.first(where: { $0.id == "codex" })!
    /// Resolved definition for Antigravity sessions.
    static let antigravity = providers.first(where: { $0.id == "antigravity" })!
    /// Resolved definition for Ripul agent sessions.
    static let ripul = providers.first(where: { $0.id == "ripul" })!

    /// Legacy persistence label for Claude Code sessions stored in UserDefaults.
    /// Existing sessions were saved with this value — used for matching, not display.
    static let claudeCodeLegacyLabel = "Claude Code"
    /// Persistence label for Codex sessions stored in UserDefaults.
    static let codexLegacyLabel = "Codex"
    /// Persistence label for Antigravity sessions stored in UserDefaults.
    static let antigravityLegacyLabel = "Antigravity"

    /// All CLI providers (those with a providerKey).
    static let cliProviders: [ProviderDef] = providers.filter { $0.isCli }

    /// The first CLI provider — used as fallback when no provider is specified.
    static let defaultCliProvider: ProviderDef = cliProviders[0]

    // MARK: CLI Lookup

    /// Look up a CLI provider by its providerKey (e.g. "claude-cli").
    static func byProviderKey(_ key: String) -> ProviderDef? {
        cliProviders.first { $0.providerKey == key }
    }

    /// Infer CLI provider from a model ID string (e.g. "antigravity-cli-raw-default" → antigravity).
    static func byModelId(_ modelId: String?) -> ProviderDef? {
        guard let modelId else { return nil }
        return cliProviders.first { $0.modelPrefixes.contains(where: { modelId.hasPrefix($0) }) }
    }

    /// Whether a providerKey or provider string refers to a CLI provider.
    static func isCliProvider(_ key: String?) -> Bool {
        guard let key else { return false }
        return cliProviders.contains { $0.providerKey == key }
    }

    /// Default model ID for a CLI provider (e.g. "claude-cli" → "claude-cli-raw-sonnet").
    static func defaultModelId(for providerKey: String) -> String {
        byProviderKey(providerKey)?.defaultModelId ?? "\(providerKey)-raw-default"
    }

    /// Legacy persistence label for a provider key (e.g. "claude-cli" → "Claude Code").
    static func legacyLabel(for providerKey: String) -> String {
        byProviderKey(providerKey)?.displayLabel ?? providerKey
    }

    // MARK: Resolution

    /// Resolve a provider definition from the raw `provider` / `providerLabel` strings
    /// that come from `RemoteSessionInfo` or `ChatSession`.
    static func resolve(provider: String?, providerLabel: String?) -> ProviderDef? {
        let raw = provider ?? ""
        let label = providerLabel ?? ""

        // 1. Exact match on providerKey (e.g. "claude-cli")
        if let match = providers.first(where: { $0.providerKey == raw }) {
            return match
        }
        // 2. Exact match on label (e.g. "Claude")
        if let match = providers.first(where: { $0.label == label }) {
            return match
        }
        // 3. Keyword match (case-insensitive)
        let combined = (raw + " " + label).lowercased()
        for p in providers where !p.keywords.isEmpty {
            if p.keywords.contains(where: { combined.contains($0) }) {
                return p
            }
        }
        // 4. Default provider (ripul — the one with no keywords)
        return providers.first(where: { $0.keywords.isEmpty })
    }

    // MARK: Convenience accessors

    static func color(for provider: String?, providerLabel: String?) -> Color {
        guard let def = resolve(provider: provider, providerLabel: providerLabel) else {
            return Color(hex: data.defaultColor)
        }
        return Color(hex: def.color)
    }

    static func icon(for provider: String?, providerLabel: String?) -> String {
        resolve(provider: provider, providerLabel: providerLabel)?.sfSymbol ?? "message.fill"
    }

    static func label(for provider: String?, providerLabel: String?) -> String {
        resolve(provider: provider, providerLabel: providerLabel)?.label ?? data.defaultLabel
    }
}

// MARK: - Color hex init

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
