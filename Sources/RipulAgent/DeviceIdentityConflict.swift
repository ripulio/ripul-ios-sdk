#if os(iOS)
import UIKit
import WebKit

/// Another device holds this install's id, and the relay turned this one away.
///
/// A phone set up from another's backup comes with that phone's install id
/// (`InstallationIdentity`), so the two joined every relay room as one client
/// and took each other's place (Peter's iPhone Duo and 17 Pro Max, 1 November
/// 2026). The relay now keeps the device that holds the id and tells the other
/// why (`device-identity-conflict`). This tells the person and offers to give
/// this device an id of its own, and does it for them: a new id, the page's
/// identity script swapped, a reload. They stay signed in; to their Macs it is
/// a new device.
@MainActor
enum DeviceIdentityConflict {
    private static var asking = false
    /// After Not Now, asked again only after this long.
    private static var quietUntil = Date.distantPast

    static func ask(over webView: WKWebView?) {
        guard !asking, Date() >= quietUntil, let root = webView?.window?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let alert = UIAlertController(
            title: "This device shares its ID with another",
            message: "Another device signed in to your account is using this device's ID, usually because this one was set up from its backup. Only one of them can stay connected. Reset this device's ID to give it its own? You stay signed in, and your Macs will see it as a new device.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in
            asking = false
            quietUntil = Date().addingTimeInterval(10 * 60)
        })
        let reset = UIAlertAction(title: "Reset Device ID", style: .default) { [weak webView] _ in
            asking = false
            resetIdentity(of: webView)
        }
        alert.addAction(reset)
        alert.preferredAction = reset
        asking = true
        top.present(alert, animated: true)
    }

    /// A new id, and the page reloaded under it. The web view's other scripts
    /// are kept as they were; only the identity script is swapped.
    static func resetIdentity(of webView: WKWebView?) {
        let fresh = InstallationIdentity.reset()
        NSLog("[DeviceIdentity] reset this device's id (now ending %@)", String(fresh.suffix(4)))
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        let scripts = controller.userScripts
        controller.removeAllUserScripts()
        for script in scripts {
            controller.addUserScript(script.source.hasPrefix(AgentWebView.installationIdentityPrefix)
                                     ? AgentWebView.installationIdentityScript : script)
        }
        webView.reload()
    }
}
#endif
