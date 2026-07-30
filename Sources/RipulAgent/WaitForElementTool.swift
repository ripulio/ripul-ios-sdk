import Foundation
#if canImport(UIKit)
import UIKit

/// Built-in `NativeTool` that closes the actuation loop: after `tap_element` /
/// `type_text` / `scroll_element` the agent calls `wait_for_element` instead of
/// blindly re-inspecting and racing the re-render. It polls the same walker the
/// other tools use and returns the moment the screen matches — element appeared
/// (default) or disappeared — or reports a timeout with a hint to re-inspect.
///
/// Addressing mirrors the family: snapshot handle (observation mode — a handle
/// stays valid for "is this exact view still on screen?" even after the tap
/// that invalidated it for actuation), accessibility id, or visible text.
public struct WaitForElementTool: NativeTool {
    public let name = "wait_for_element"
    public let description = "Wait until an element in the host app appears (default) or disappears, addressed "
        + "by a snapshot handle, accessibility id, or visible text. Call this right after tap_element / type_text / "
        + "scroll_element: it returns the moment the screen matches, so you never inspect a half-rendered tree. "
        + "Typical loop: inspect_screen → tap_element(handle) → wait_for_element(text or id of what should appear) "
        + "→ inspect_screen. Use state 'gone' with a handle to confirm a sheet/row was dismissed."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("handle", "Handle from the last inspect_screen (e.g. \"e7\") — observes that exact element (best with state 'gone')"),
        .selector("within", "Anchor container: only matches inside its subtree count (resolved fresh each poll)"),
        .string("id", "Accessibility id / uiKitIdentifier of the element"),
        .string("text", "Visible text to match (case-insensitive substring)"),
        .stringEnum("role", "Element role (ANDed with text/id)", values: ScreenElementFinder.roleVocabulary),
        .string("class", "Class-name substring (ANDed with the other predicates)"),
        .stringEnum("state", "Wait for the element to be 'visible' (default) or 'gone'", values: ["visible", "gone"]),
        .number("timeout", "Seconds to wait before giving up (default 10, max 30)")
    )

    /// Longer than the bridge default (30s): a 30s wait must return its own
    /// timeout result, not be killed mid-poll.
    public let timeout: TimeInterval = 40

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let id = args["id"] as? String
        let text = args["text"] as? String
        let handle = args["handle"] as? String
        let role = args["role"] as? String
        let className = args["class"] as? String
        let within = args["within"] as? [String: Any]
        let state = (args["state"] as? String ?? "visible").lowercased()
        let timeoutSeconds = min(max(args["timeout"] as? Double ?? 10, 0.5), 30)
        let hasQuery = [id, text, role, className].contains { $0?.isEmpty == false }
        guard (handle?.isEmpty == false) || hasQuery else {
            return ["success": false, "error": "Provide handle, or id/text/role/class (optionally scoped with within). Run inspect_screen to find elements."]
        }

        let wantGone = state == "gone"
        let start = Date()
        let deadline = start.addingTimeInterval(timeoutSeconds)
        while true {
            let found = lookup(id: id, text: text, handle: handle, role: role, className: className, within: within)
            if wantGone != (found != nil) {
                var result: [String: Any] = [
                    "success": true,
                    "state": wantGone ? "gone" : "visible",
                    "waited": Date().timeIntervalSince(start),
                ]
                if let found { result["element"] = ScreenElementFinder.describe(found) }
                return result
            }
            if Date() >= deadline {
                let what = handle.map { "handle '\($0)'" }
                    ?? id.map { "id '\($0)'" }
                    ?? "text '\(text ?? "")'"
                return ["success": false, "state": wantGone ? "gone" : "visible",
                        "error": "Timed out after \(Int(timeoutSeconds))s waiting for \(what) to become \(wantGone ? "gone" : "visible"). Run inspect_screen to see the current tree."]
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// One poll. Handle lookups use observation mode (staleness-for-actuation
    /// doesn't apply to watching); predicates use the same AND query as the
    /// actuation tools. The `within` anchor is re-resolved every poll — it may
    /// legitimately not exist yet on early polls, which simply misses.
    @MainActor
    private func lookup(id: String?, text: String?, handle: String?,
                        role: String?, className: String?, within: [String: Any]?) -> ScreenElementFinder.Match? {
        if let handle, !handle.isEmpty {
            return ScreenElementFinder.resolveHandle(handle, mode: .observation)
        }
        var anchor: UIView? = nil
        if let within {
            let (resolved, _) = ScreenElementFinder.resolveAnchor(within, mode: .observation)
            guard let resolved else { return nil }
            anchor = resolved
        }
        let q = ScreenElementFinder.Query(id: id, text: text, role: role, className: className, nth: nil)
        guard q.hasAnyPredicate else { return nil }
        return ScreenElementFinder.find(q, within: anchor).first
    }
}
#endif
