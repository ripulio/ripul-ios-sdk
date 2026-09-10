#if canImport(UIKit)
import UIKit
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

/// A native share sheet whose offered files can be verified by developer tools.
/// Use inside SwiftUI `.sheet`; UIKit hosts can use `makeController(fileURLs:)`.
/// Only explicitly offered files are readable. No private UIKit/KVC inspection.
public struct RipulShareSheet: UIViewControllerRepresentable {
    public let fileURLs: [URL]
    public init(fileURLs: [URL]) { self.fileURLs = fileURLs }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        Self.makeController(fileURLs: fileURLs)
    }
    public func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    @MainActor public static func makeController(fileURLs: [URL]) -> UIActivityViewController {
        InspectableShareController(fileURLs: fileURLs)
    }
}

@MainActor
final class InspectableShareController: UIActivityViewController {
    let offeredFileURLs: [URL]
    init(fileURLs: [URL]) {
        offeredFileURLs = fileURLs
        super.init(activityItems: fileURLs, applicationActivities: nil)
    }
}

@MainActor
enum ShareSheetInspection {
    /// Weak keys: a closed presentation cannot be retained or acted on later.
    private static let identities = NSMapTable<UIActivityViewController, NSString>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    static func identity(_ controller: UIActivityViewController) -> String {
        if let id = identities.object(forKey: controller) { return id as String }
        let id = UUID().uuidString
        identities.setObject(id as NSString, forKey: controller)
        return id
    }

    static func find(in root: UIViewController?) -> UIActivityViewController? {
        guard let root, !root.isBeingDismissed else { return nil }
        if let presented = find(in: root.presentedViewController) { return presented }
        if let activity = root as? UIActivityViewController, activity.viewIfLoaded?.window != nil { return activity }
        for child in root.children.reversed() where child.viewIfLoaded?.window != nil {
            if let activity = find(in: child) { return activity }
        }
        return nil
    }

    static func file(_ url: URL, includeText: Bool) -> [String: Any] {
        var result: [String: Any] = ["filename": url.lastPathComponent]
        guard url.isFileURL else {
            result["error"] = "Offered item is not a local file"
            return result
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
            guard values.isRegularFile == true else {
                result["error"] = "Offered item is not a regular file"
                return result
            }
            result["byte_count"] = values.fileSize
            result["content_type"] = values.contentType?.identifier
            // Bound IO even if a file grows after resourceValues was read.
            let limit = 1_048_576
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            result["readable"] = true
            result["truncated"] = data.count > limit
            if data.count <= limit {
                result["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if includeText {
                    if let text = String(data: data, encoding: .utf8) { result["text"] = text }
                    else { result["text_error"] = "File is not UTF-8 text" }
                }
            } else {
                result["content_error"] = "File exceeds 1 MiB inspection limit; full text and hash unavailable"
            }
        } catch {
            result["readable"] = false
            result["error"] = error.localizedDescription
        }
        return result
    }

    static func inspect(_ controller: UIActivityViewController, includeText: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "success": true, "presented": true,
            "presentation_id": identity(controller),
            "controller": String(describing: type(of: controller)),
            "items_inspectable": controller is InspectableShareController,
            "system_activity_controls_inspectable": false,
            "limitation": "iOS renders destination activities remotely. This tool verifies the offered files and can dismiss the share sheet; it does not select destinations or send files."
        ]
        if let tracked = controller as? InspectableShareController {
            result["files"] = tracked.offeredFileURLs.map { file($0, includeText: includeText) }
        } else {
            result["items_error"] = "Host has not used RipulShareSheet; UIKit does not expose activityItems for reading"
        }
        return result
    }

    static func dismiss(_ controller: UIActivityViewController, expectedID: String?) async -> [String: Any] {
        guard expectedID == identity(controller) else {
            return ["success": false, "error": "Missing or stale presentation_id. Inspect the share sheet first."]
        }
        guard controller.viewIfLoaded?.window != nil, !controller.isBeingDismissed else {
            return ["success": false, "error": "Share sheet is no longer visible"]
        }
        guard controller.presentedViewController == nil else {
            return ["success": false, "error": "A destination or dialog is open above the share sheet. Dismiss that dialog first."]
        }
        controller.dismiss(animated: true)
        // UIKit can decline a dismissal during a transition without calling a completion.
        // Bound the wait and report observed visibility rather than an assumed success.
        for _ in 0..<30 {
            if controller.viewIfLoaded?.window == nil { break }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return ["success": false, "error": "Dismissal observation cancelled"] }
        }
        return ["success": controller.viewIfLoaded?.window == nil,
                "dismissed": controller.viewIfLoaded?.window == nil,
                "presentation_id": identity(controller)]
    }
}

public struct ShareSheetTool: NativeTool {
    public let name = "share_sheet"
    public let description = "DEVELOPER. Inspect or dismiss the host's currently presented iOS share sheet. With RipulShareSheet, inspect returns the actual offered filenames, sizes, types, SHA-256 and optional UTF-8 text (up to 1 MiB per file). Other share sheets report items unavailable. Dismiss requires the presentation_id from inspect to avoid closing a different presentation. Does not choose a destination or send anything; iOS remote activity buttons are not accessible in-process."
    public let inputSchema = ToolSchema.object(
        .string("action", "inspect | dismiss; default inspect"),
        .string("presentation_id", "Required for dismiss; use the ID returned by inspect"),
        .bool("include_text", "Include offered UTF-8 file contents, default false")
    )
    @MainActor public func execute(args: [String: Any]) async throws -> Any {
        let action = args["action"] as? String ?? "inspect"
        guard ["inspect", "dismiss"].contains(action) else {
            return ["success": false, "error": "Expected inspect or dismiss"]
        }
        guard let window = RipulChrome.appWindow() else {
            return ["success": false, "error": "No host window available"]
        }
        guard let controller = ShareSheetInspection.find(in: window.rootViewController) else {
            return ["success": action == "inspect", "presented": false, "message": "No host share sheet is presented"]
        }
        if action == "dismiss" {
            return await ShareSheetInspection.dismiss(controller, expectedID: args["presentation_id"] as? String)
        }
        return ShareSheetInspection.inspect(controller, includeText: args["include_text"] as? Bool ?? false)
    }
}
#endif
