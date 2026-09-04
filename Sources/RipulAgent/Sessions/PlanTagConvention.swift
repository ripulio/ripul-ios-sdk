import Foundation

/// Machine-written session↔plan link tags (`plan:<slug>@<hash6>`).
///
/// The key is computed in TypeScript and arrives finished — on
/// `PlanDetail.planKey` and inside session tags. Never derive one here; a
/// second hash implementation is a parity bug waiting to happen.
///
/// These tags are identity, not user labels: every tag UI filters them out,
/// and the tags editor re-attaches them on save so a round-trip through the
/// sheet cannot silently unlink a session from its plan.
public enum PlanTagConvention {
    public static let prefix = "plan:"

    public static func isPlanTag(_ tag: String) -> Bool {
        tag.hasPrefix(prefix)
    }

    /// The user-editable subset of a session's tags.
    public static func userTags(_ tags: [String]) -> [String] {
        tags.filter { !isPlanTag($0) }
    }
}
