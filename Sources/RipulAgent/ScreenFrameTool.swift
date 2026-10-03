import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - screen_frame

/// One frame of the host app's screen for a live viewer: a small JPEG plus the
/// window size in points — the space `touch` takes, so a tap on the picture
/// maps straight to a touch. A viewer polls with `since` set to the last
/// frame's id and gets `unchanged` without an image while nothing moves.
public struct ScreenFrameTool: NativeTool {
    public let name = "screen_frame"
    public let description = "One frame of the host app's screen for a live view: a JPEG (base64) and the window "
        + "size in points, the space touch uses. Pass since=<the previous frame's id>: if the screen hasn't "
        + "changed the result is unchanged:true with no image. Excludes the Ripul dev-assistant overlay."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("since", "The previous frame's id; an unchanged screen then returns no image"),
        .integer("maxDimension", "Long side of the image in pixels (240–1200, default 640)"),
        .number("quality", "JPEG quality 0.2–0.9 (default 0.5)"),
        .string("purpose", "\"liveview\" when a Live View viewer asks; leave out otherwise"),
        .string("viewer", "The Live View viewer's name, shown on this device while it watches")
    )
    public var timeout: TimeInterval { 10 }

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        #if canImport(UIKit)
        if let refusal = LiveStreamHost.shared.relayRefusal(args) {
            return ["success": false, "error": refusal]
        }
        guard let window = RipulChrome.appWindow() else {
            return ["success": false, "error": "No app window on screen"]
        }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return ["success": false, "error": "The app window has no size"]
        }
        let maxDimension = CGFloat(min(max((args["maxDimension"] as? NSNumber)?.intValue ?? 640, 240), 1200))
        let quality = CGFloat(min(max((args["quality"] as? NSNumber)?.doubleValue ?? 0.5, 0.2), 0.9))
        let factor = min(1, maxDimension / max(bounds.width, bounds.height))
        let size = CGSize(width: (bounds.width * factor).rounded(), height: (bounds.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        // 8-bit sRGB: the default wide-colour buffer made drawing about 2.5x
        // slower on an iPhone 15 (139 ms against 52 ms at 430x932), and JPEG
        // keeps 8 bits anyway.
        format.preferredRange = .standard
        format.opaque = true
        let started = CACurrentMediaTime()
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
        }
        let drawn = CACurrentMediaTime()
        guard let jpeg = image.jpegData(compressionQuality: quality) else {
            return ["success": false, "error": "Could not encode the frame"]
        }
        let id = ScreenFrameID.of(jpeg)
        var result: [String: Any] = ["success": true, "frame": id,
                                     "captureMs": ((drawn - started) * 1000).rounded(),
                                     "encodeMs": ((CACurrentMediaTime() - drawn) * 1000).rounded(),
                                     "width": Double(bounds.width), "height": Double(bounds.height),
                                     "installId": RipulLiveViewIdentity.installId,
                                     "model": RipulLiveViewIdentity.model,
                                     "modelName": RipulLiveViewIdentity.modelName,
                                     "app": RipulLiveViewIdentity.appName,
                                     "system": UIDevice.current.systemVersion]
        if let since = args["since"] as? String, since == id {
            result["unchanged"] = true
        } else {
            result["jpeg"] = jpeg.base64EncodedString()
            result["pixelWidth"] = Int(size.width)
            result["pixelHeight"] = Int(size.height)
        }
        return result
        #else
        return ["success": false, "error": "screen_frame needs UIKit"]
        #endif
    }
}

/// A frame's identity: FNV-1a over its JPEG bytes. The same pixels encode to
/// the same bytes, so an unchanged screen keeps its id.
enum ScreenFrameID {
    static func of(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// Which install of the SDK a frame came from, so a viewer can tell that a
/// device it lists is the phone it's running on (the relay names every
/// iPhone of an account alike).
public enum RipulLiveViewIdentity {
    private static let key = "ripul.liveview.installId"

    public static var installId: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    /// The hardware identifier, e.g. "iPhone16,2" (a simulator reports the one it simulates).
    public static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// What people call the model ("iPhone 15 Pro Max"). iOS won't give an app
    /// the name the owner chose for the phone, so this is the best label there is.
    public static var modelName: String { name(forModel: model) }

    /// The app's own name, as on the home screen.
    public static var appName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "App"
    }

    /// "iPhone 15 Pro Max" for "iPhone16,2"; the family, or the identifier itself, for one not listed.
    public static func name(forModel model: String) -> String {
        let names: [String: String] = [
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE", "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air", "iPhone18,5": "iPhone 17e",
        ]
        if let known = names[model] { return known }
        for family in ["iPhone", "iPad", "Mac"] where model.hasPrefix(family) { return family }
        return model
    }
}
