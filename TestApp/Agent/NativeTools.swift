import UIKit

// MARK: - Tool Protocol

protocol NativeTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: Any] { get }
    func execute(args: [String: Any]) async throws -> Any
}

extension NativeTool {
    var definition: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]
    }
}

enum ToolError: Error {
    case invalidArgs(String)
    case failed(String)
}

// MARK: - Tool Registry

struct NativeToolRegistry {
    let tools: [NativeTool] = [
        GetDeviceInfoTool(),
        HapticFeedbackTool(),
        ShowAlertTool(),
        GetClipboardTool(),
        SetClipboardTool(),
        ShareTool(),
    ]

    var definitions: [[String: Any]] {
        tools.map { $0.definition }
    }

    func tool(named name: String) -> NativeTool? {
        tools.first { $0.name == name }
    }
}

// MARK: - get_device_info

struct GetDeviceInfoTool: NativeTool {
    let name = "get_device_info"
    let description = "Returns information about the iOS device including model, OS version, battery level, and screen dimensions."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
    ]

    @MainActor
    func execute(args: [String: Any]) async throws -> Any {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let screen = UIScreen.main
        return [
            "model": UIDevice.current.model,
            "name": UIDevice.current.name,
            "systemName": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "batteryLevel": UIDevice.current.batteryLevel,
            "batteryState": batteryStateString(UIDevice.current.batteryState),
            "screenWidth": screen.bounds.width,
            "screenHeight": screen.bounds.height,
            "screenScale": screen.scale,
        ] as [String: Any]
    }

    private func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: "unknown"
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        @unknown default: "unknown"
        }
    }
}

// MARK: - haptic_feedback

struct HapticFeedbackTool: NativeTool {
    let name = "haptic_feedback"
    let description = "Triggers haptic feedback on the device. Use this when you want to give the user a tactile response."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "style": [
                "type": "string",
                "enum": ["light", "medium", "heavy"],
                "description": "The intensity of the haptic feedback",
            ] as [String: Any],
        ] as [String: Any],
    ]

    @MainActor
    func execute(args: [String: Any]) async throws -> Any {
        let style = args["style"] as? String ?? "medium"
        let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle = switch style {
        case "light": .light
        case "heavy": .heavy
        default: .medium
        }
        let generator = UIImpactFeedbackGenerator(style: feedbackStyle)
        generator.impactOccurred()
        return ["success": true]
    }
}

// MARK: - show_alert

struct ShowAlertTool: NativeTool {
    let name = "show_alert"
    let description = "Shows a native iOS alert dialog to the user with a title and message. Waits for the user to dismiss it."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": [
                "type": "string",
                "description": "The alert title",
            ] as [String: Any],
            "message": [
                "type": "string",
                "description": "The alert message body",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["title", "message"],
    ]

    @MainActor
    func execute(args: [String: Any]) async throws -> Any {
        let title = args["title"] as? String ?? "Alert"
        let message = args["message"] as? String ?? ""

        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                continuation.resume(returning: ["dismissed": true] as [String: Any])
            })

            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = scene.windows.first?.rootViewController else {
                continuation.resume(returning: ["dismissed": false, "error": "No view controller"] as [String: Any])
                return
            }

            // Present on the topmost VC
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(alert, animated: true)
        }
    }
}

// MARK: - get_clipboard

struct GetClipboardTool: NativeTool {
    let name = "get_clipboard"
    let description = "Reads the current text content from the device clipboard."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
    ]

    @MainActor
    func execute(args: [String: Any]) async throws -> Any {
        let text = UIPasteboard.general.string ?? ""
        return ["text": text]
    }
}

// MARK: - set_clipboard

struct SetClipboardTool: NativeTool {
    let name = "set_clipboard"
    let description = "Copies text to the device clipboard."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "text": [
                "type": "string",
                "description": "The text to copy to clipboard",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["text"],
    ]

    @MainActor
    func execute(args: [String: Any]) async throws -> Any {
        guard let text = args["text"] as? String else {
            throw ToolError.invalidArgs("Missing required 'text' parameter")
        }
        UIPasteboard.general.string = text
        return ["success": true]
    }
}

// MARK: - share

struct ShareTool: NativeTool {
    let name = "share"
    let description = "Opens the native iOS share sheet to share text or a URL with other apps."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "text": [
                "type": "string",
                "description": "Text to share",
            ] as [String: Any],
            "url": [
                "type": "string",
                "description": "Optional URL to share",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["text"],
    ]

    @MainActor
    func execute(args: [String: Any]) async throws -> Any {
        let text = args["text"] as? String ?? ""
        var items: [Any] = [text]
        if let urlString = args["url"] as? String, let url = URL(string: urlString) {
            items.append(url)
        }

        return await withCheckedContinuation { continuation in
            let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = scene.windows.first?.rootViewController else {
                continuation.resume(returning: ["shared": false, "error": "No view controller"] as [String: Any])
                return
            }

            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            activityVC.completionWithItemsHandler = { _, completed, _, _ in
                continuation.resume(returning: ["shared": completed] as [String: Any])
            }
            topVC.present(activityVC, animated: true)
        }
    }
}
