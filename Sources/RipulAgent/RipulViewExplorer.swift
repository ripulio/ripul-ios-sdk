#if os(iOS)
import SwiftUI
import UIKit

// MARK: - RipulViewExplorer
//
// Host-agnostic launcher for the native View Explorer (`ViewInspectorOverlay`).
//
// The overlay must sit at the top of the *application's* window so it can
// hit-test every view in the running app — `ViewInspectorController` resolves
// the target via `self.window.hitTest(...)`, so the overlay has to live in the
// same window as the content it inspects. In a SwiftUI app you can just attach
// `.overlay { ViewInspectorOverlay(isActive:) }` to the root view. A UIKit host
// has no such root to hang an `.overlay` on, so this launcher does the mount for
// it: it embeds a `UIHostingController` carrying the overlay as a child of the
// top-most view controller in the key window, full-bleed and frontmost.
//
// Usage (from anywhere — a debug menu, a shake handler, a button):
//
//     if #available(iOS 16.0, *) { RipulViewExplorer.present() }
//
// The overlay's own "Exit" button tears itself down (it flips the `isActive`
// binding, which calls back into `dismiss()`), so callers usually only need
// `present()`.

@available(iOS 16.0, *)
@MainActor
public enum RipulViewExplorer {

    /// The controller hosting the live overlay, or `nil` when not shown.
    private static weak var host: UIViewController?

    /// Whether the explorer is currently on screen.
    public static var isPresented: Bool { host != nil }

    /// Optional host-defined action invoked when the user double-taps the element
    /// currently highlighted by the inspector reticule. Passes the inspected `UIView`
    /// so the host can present its own default action (e.g. a theme remap).
    /// When nil, double-taps are ignored. Set before calling `present()`/`toggle()`.
    public static var doubleTapAction: ((UIView) -> Void)?

    /// Optional host-defined action invoked when the user taps the Console button
    /// in the View Explorer HUD. The host decides how to present its console/log
    /// viewer. When nil, the Console button is hidden.
    public static var consoleAction: (() -> Void)?

    /// Present the View Explorer over the given window (defaults to the key
    /// window). No-op if it's already showing. Returns `false` only if no
    /// suitable window/view controller could be found to host it.
    @discardableResult
    public static func present(in window: UIWindow? = nil) -> Bool {
        guard host == nil else { return true }
        guard let target = window ?? keyWindow(),
              let root = target.rootViewController else { return false }

        let parent = topMostViewController(from: root)
        let hosting = UIHostingController(rootView: RipulViewExplorerRoot(onDismiss: { dismiss() }))
        hosting.view.backgroundColor = .clear
        // Tag so the inspector's hit-walks skip their own overlay subtree (this
        // host is a sibling of app content under the same VC, so the geometric
        // walk would otherwise re-enter it — see ViewInspectorController).
        hosting.view.tag = ripulViewExplorerOverlayTag
        // Don't block touches the overlay itself lets through (folded HUD etc.).
        hosting.view.frame = parent.view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        parent.addChild(hosting)
        parent.view.addSubview(hosting.view)
        parent.view.bringSubviewToFront(hosting.view)
        hosting.didMove(toParent: parent)

        host = hosting
        return true
    }

    /// Remove the View Explorer if shown.
    public static func dismiss() {
        guard let hosting = host else { return }
        hosting.willMove(toParent: nil)
        hosting.view.removeFromSuperview()
        hosting.removeFromParent()
        host = nil
    }

    /// Show if hidden, hide if shown.
    @discardableResult
    public static func toggle(in window: UIWindow? = nil) -> Bool {
        if isPresented { dismiss(); return false }
        return present(in: window)
    }

    // MARK: - Helpers

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // Prefer the foreground-active scene's key window, then any key window,
        // then any window at all.
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }),
           let key = active.windows.first(where: { $0.isKeyWindow }) ?? active.windows.first {
            return key
        }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.flatMap { $0.windows }.first
    }

    private static func topMostViewController(from root: UIViewController) -> UIViewController {
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

// MARK: - Root wrapper

/// Owns the `isActive` state for a launcher-presented overlay and bridges the
/// overlay's self-dismiss (Exit button) back to `RipulViewExplorer.dismiss()`.
@available(iOS 16.0, *)
private struct RipulViewExplorerRoot: View {
    @State private var isActive = true
    let onDismiss: () -> Void

    var body: some View {
        ViewInspectorOverlay(isActive: $isActive,
                             doubleTapAction: RipulViewExplorer.doubleTapAction,
                             consoleAction: RipulViewExplorer.consoleAction)
            .onChange(of: isActive) { active in
                if !active { onDismiss() }
            }
    }
}
#endif
