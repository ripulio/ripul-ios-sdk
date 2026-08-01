#if os(iOS)
import SwiftUI
import UIKit

// MARK: - RipulElementTap

/// An element the user double-tapped under the inspector reticule. The SDK stays
/// host-agnostic: it detects the gesture and reports WHAT was tapped — what the tap
/// MEANS (a theme remap, a navigation probe, a debug dump, …) is entirely the host's
/// call via `RipulViewExplorer.elementTapAction`.
public struct RipulElementTap {
    /// The element the action should apply to: the token-anchor (`.uiKitIdentifier`
    /// stamp) view when the pick resolved to one, else the picked view itself. This is
    /// the same view the inspector's Edit tab reads design tokens from.
    public let view: UIView
    /// The raw picked view under the reticule (deepest hit), before token-anchor
    /// resolution — same as `view` for plain UIKit elements.
    public let targetView: UIView
    /// Where the RETICULE was — the same point `view` was resolved from — in
    /// the HOST window's coordinates, the space `view`/`targetView` live in, so
    /// it can be converted against them directly (macro recording and the
    /// actuation engine's point path both do).
    ///
    /// Deliberately NOT the touch location. The crosshair is a relative,
    /// accelerated cursor, so the finger is wherever the hand rests and says
    /// nothing about the target.
    public let point: CGPoint

    public init(view: UIView, targetView: UIView, point: CGPoint) {
        self.view = view
        self.targetView = targetView
        self.point = point
    }
}

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

// MARK: - Overlay window
//
// The explorer mounts in its OWN window, not as a child of the top-most view
// controller: a host-side panel added directly to the key window (WAC's
// RecordMenu sidebar is a plain `window.addSubview`) would otherwise cover
// it. Level is one above the dev-assistant overlay's (`alert + 1`), so while
// active the explorer outranks every host panel AND the dev chrome.
//
// Being a `RipulChromeWindow` is what keeps that true: it declines key-ness,
// so a host resolving "the key window" gets the app's window and mounts its
// panels there — under us — instead of inside us. See RipulChromeWindow.swift.

@available(iOS 16.0, *)
final class RipulExplorerOverlayWindow: RipulChromeWindow {
    // Full-capture while the explorer is active: the touch layer IS the
    // interaction (reticule drag, tap-to-fire, HUD). No passthrough needed.
}

@available(iOS 16.0, *)
@MainActor
public enum RipulViewExplorer {

    /// The overlay window hosting the live explorer, or `nil` when not shown.
    /// STRONG: a standalone UIWindow has no owner — the previous `weak`
    /// reference let it deallocate the moment present() returned, leaving
    /// the explorer invisible (the old embedded VC survived because its
    /// parent VC retained it via addChild; a standalone window has no such
    /// owner). Teardown is explicit via dismiss().
    private static var window: RipulExplorerOverlayWindow?
    /// The HOST window the explorer inspects and drives — retained for the
    /// lifetime of the presentation (picking hit-tests this window, not the
    /// explorer's own).
    private static var hostWindow: UIWindow?

    /// Whether the explorer is currently on screen.
    public static var isPresented: Bool { window != nil }

    /// Optional host-defined action invoked when the user double-taps the element
    /// currently highlighted by the inspector reticule. The SDK only reports the tapped
    /// element (`RipulElementTap`); the host decides what the gesture means (e.g. a
    /// theme remap). When nil, double-taps are ignored. Set before calling
    /// `present()`/`toggle()`.
    public static var elementTapAction: ((RipulElementTap) -> Void)?

    /// Optional host-defined action invoked when the user taps the Console button
    /// in the View Explorer HUD. The host decides how to present its console/log
    /// viewer. When nil, the Console button is hidden.
    public static var consoleAction: (() -> Void)?

    /// Optional host-defined action invoked when the user finishes recording a
    /// macro (the Macro tab's Stop & Save flow — see
    /// `docs/plans/automation-macros/phase-2-recording-ui.md`). The SDK never
    /// performs network I/O itself, same principle as `elementTapAction`: it
    /// builds the `RipulMacro` value and hands it off; persisting it (e.g. via
    /// a `MacroClient`) is entirely the host's call. When nil, recording still
    /// works — Save is a no-op with an on-screen "not configured" notice.
    public static var macroRecordedAction: ((RipulMacro) -> Void)?

    /// Present the View Explorer over the given window (defaults to the key
    /// window). No-op if it's already showing. Returns `false` only if no
    /// suitable window/view controller could be found to host it.
    /// `recording: true` opens it already in macro-record mode (the Macro
    /// tab armed) — used by the macro library's "Record new" entry point.
    @discardableResult
    public static func present(in window: UIWindow? = nil, recording: Bool = false) -> Bool {
        guard self.window == nil else { return true }
        guard let target = window ?? RipulChrome.appWindow(),
              let scene = target.windowScene else { return false }

        hostWindow = target
        let win = RipulExplorerOverlayWindow(windowScene: scene)
        win.frame = scene.screen.bounds
        win.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
        win.backgroundColor = .clear
        let hosting = UIHostingController(rootView: RipulViewExplorerRoot(
            hostWindow: target,
            startRecording: recording,
            onDismiss: { dismiss() }
        ))
        hosting.view.backgroundColor = .clear
        win.installRoot(hosting)
        win.isHidden = false
        self.window = win
        return true
    }

    /// Remove the View Explorer if shown.
    public static func dismiss() {
        guard let win = window else { return }
        win.relinquishKey()
        win.isHidden = true
        window = nil
        hostWindow = nil
    }

    /// Show if hidden, hide if shown.
    @discardableResult
    public static func toggle(in window: UIWindow? = nil, recording: Bool = false) -> Bool {
        if isPresented { dismiss(); return false }
        return present(in: window, recording: recording)
    }

}

// MARK: - Root wrapper

/// Owns the `isActive` state for a launcher-presented overlay and bridges the
/// overlay's self-dismiss (Exit button) back to `RipulViewExplorer.dismiss()`.
/// `hostWindow` is the window the explorer inspects and drives — the picking
/// hit-test runs against it, not the explorer's own overlay window.
@available(iOS 16.0, *)
private struct RipulViewExplorerRoot: View {
    @State private var isActive = true
    var hostWindow: UIWindow?
    var startRecording = false
    let onDismiss: () -> Void

    var body: some View {
        ViewInspectorOverlay(isActive: $isActive,
                             elementTapAction: RipulViewExplorer.elementTapAction,
                             consoleAction: RipulViewExplorer.consoleAction,
                             macroRecordedAction: RipulViewExplorer.macroRecordedAction,
                             startRecording: startRecording,
                             hostWindow: hostWindow)
            .onChange(of: isActive) { active in
                if !active { onDismiss() }
            }
    }
}
#endif
