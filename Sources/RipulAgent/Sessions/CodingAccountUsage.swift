import Foundation

/// Credential-free quota information, scoped to one saved account on one host.
/// Timestamps are Unix seconds; absent windows mean the provider did not report them.
public struct CodingAccountUsage: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let usedPercent: Double
        public let resetsAt: Double?

        public init(id: String, label: String, usedPercent: Double, resetsAt: Double? = nil) {
            self.id = id; self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt
        }
    }
    public var plan: String?
    public var windows: [Window]
    public var updatedAt: Double?
    public var error: String?

    public init(plan: String? = nil, windows: [Window] = [], updatedAt: Double? = nil, error: String? = nil) {
        self.plan = plan; self.windows = windows; self.updatedAt = updatedAt; self.error = error
    }

    public static func planName(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "free", "free_workspace": return "Free"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "max": return "Max"
        case "max_5x", "default_claude_max_5x": return "Max 5×"
        case "max_20x", "default_claude_max_20x": return "Max 20×"
        case "team": return "Team"
        case "self_serve_business_prolite", "self_serve_business_usage_based": return "Business"
        case "enterprise", "enterprise_cbp_usage_based", "enterprise_cbp_automation": return "Enterprise"
        case "edu", "education", "edu_plus", "edu_pro": return "Education"
        default: return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
