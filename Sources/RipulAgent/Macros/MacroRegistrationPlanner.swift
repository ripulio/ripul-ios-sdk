import Foundation

/// Turns a fetched `[RipulMacro]` list into what should be registered where —
/// pure `RipulMacro` in, `RipulMacro` out, no `MacroTool`/UIKit involved, so
/// this is testable under plain `swift test` (mirrors the phase-0 lesson:
/// keep the DECISION logic ungated even though the thing it decides about —
/// `MacroTool`, wrapped by the caller — is UIKit-gated).
public enum MacroRegistrationPlanner {
    /// Collapses same-name duplicates (a race between two devices fetching
    /// and creating concurrently) to the most recently updated one — silent,
    /// not a crash, unlike `RipulToolRegistry.register`'s own duplicate-name
    /// handling, because THIS collision is a data race to fail past, not a
    /// programmer error to fail loudly on.
    public static func dedupByName(_ macros: [RipulMacro]) -> [RipulMacro] {
        var newest: [String: RipulMacro] = [:]
        for macro in macros {
            if let existing = newest[macro.name], existing.updatedAt >= macro.updatedAt { continue }
            newest[macro.name] = macro
        }
        // Stable-ish output order: by name, matching the backend's own `ORDER BY name`.
        return newest.values.sorted { $0.name < $1.name }
    }

    public struct Partition {
        /// Draft macros — `.developer` audience only.
        public let developer: [RipulMacro]
        /// Published macros — `.endUser` audience, reachable by the host's
        /// real end-user agent.
        public let endUser: [RipulMacro]
    }

    /// Dedup, then split by `published`. The one security-adjacent decision
    /// in this whole plan: an unpublished macro must never appear in
    /// `endUser`, regardless of how it got here.
    public static func plan(_ macros: [RipulMacro]) -> Partition {
        let deduped = dedupByName(macros)
        return Partition(
            developer: deduped.filter { !$0.published },
            endUser: deduped.filter { $0.published }
        )
    }
}
