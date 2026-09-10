#if canImport(UIKit)
import UIKit

/// The same audit as View Explorer's Audit tab, without opening the overlay.
public struct ScreenAuditTool: NativeTool {
    public let name = "screen_audit"
    public let description = "DEVELOPER. Read the current host screen's View Explorer identity audit: named, automatic and anonymous controls, plus the full report. Uses the Audit tab's exact root and classifier. Does not navigate or open the explorer. Covers the loaded view tree and materialized SwiftUI accessibility elements; scroll/expand and audit again for other content. System remote views are not inspectable."
    public let inputSchema = ToolSchema.object()

    @MainActor public func execute(args: [String: Any]) async throws -> Any {
        guard let root = ScreenAudit.screenRoot() else {
            return ["success": false, "error": "No host screen available"]
        }
        root.layoutIfNeeded()
        let audit = ScreenAudit.run(on: root)
        return [
            "success": true,
            "sdk_version": ripulSDKVersion,
            "root_class": String(describing: type(of: root)),
            "total": audit.items.count, "named": audit.named,
            "auto": audit.auto, "anonymous": audit.anonymous,
            "zero_anonymous": !audit.items.isEmpty && audit.anonymous == 0,
            "scope": "Loaded host view tree; materialized SwiftUI accessibility elements. Excludes SDK chrome. Does not certify offscreen, collapsed or remote system content.",
            "items": audit.items.map { item in
                ["class": item.className, "identity": item.identity,
                 "bucket": item.bucket == .named ? "named" : item.bucket == .auto ? "auto" : "anonymous"]
            },
            "report": audit.report()
        ] as [String: Any]
    }
}
#endif
