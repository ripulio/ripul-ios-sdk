import Foundation

#if canImport(UIKit)
import UIKit

/// Opens one of the host app's own deep links in the running app, handing it
/// straight to the app's URL handler (the host observes
/// `Notification.Name.ripulOpenAppURL` beside `onOpenURL`). Deterministic
/// navigation for on-device tests — e.g. `ripul://open-chat?id=<chat id>` or
/// `ripul://agents` — without taps, which resolve by point and can hit
/// whatever sits under an overlay.
///
/// Not via `UIApplication.open`: another installed app can claim the same
/// scheme (the Alice variant registers `ripul://` too), and iOS may hand the
/// URL to it instead — observed 2026-09-26.
public struct OpenAppURLTool: NativeTool {
    public let name = "open_app_url"
    public let description = "Open one of this app's own deep links in the running app (e.g. "
        + "ripul://open-chat?id=<chat id> to open a chat, ripul://agents for the Agents list). Only the app's "
        + "own URL schemes are accepted. Deterministic navigation for on-device tests; follow with "
        + "wait_for_element or inspect_screen to confirm where it landed."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("url", "A URL in one of this app's own schemes")
    )

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        guard let raw = args["url"] as? String, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased() else {
            return ["success": false, "error": "Pass url, e.g. ripul://agents"]
        }
        let own = ((Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]) ?? [])
            .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
            .map { $0.lowercased() }
        guard own.contains(scheme) else {
            return ["success": false, "error": "Only this app's own URL schemes are accepted: \(own.joined(separator: ", "))"]
        }
        NotificationCenter.default.post(name: .ripulOpenAppURL, object: url)
        return ["success": true, "url": raw, "delivered": "in-app"]
    }
}
#endif

public extension Notification.Name {
    /// Carries a `URL` (as `object`) for the host's own URL handler, in-app.
    static let ripulOpenAppURL = Notification.Name("ripulOpenAppURL")
}
