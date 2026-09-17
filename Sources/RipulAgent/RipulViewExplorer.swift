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

    /// The view a tap would actually drive, when that differs from the selected
    /// element — a control inside it, or an interactive ancestor. Nil when the
    /// selection is itself pressable, or when nothing there is. Macro recording
    /// targets this; the theme actions keep using `view`.
    public let actionableView: UIView?

    public init(view: UIView, targetView: UIView, point: CGPoint, actionableView: UIView? = nil) {
        self.view = view
        self.targetView = targetView
        self.point = point
        self.actionableView = actionableView
    }
}

// MARK: - RipulViewExplorer
//
// Host-agnostic launcher for the native View Explorer (`ViewInspectorOverlay`).
//
// The launcher hosts a full-screen SwiftUI overlay in its own window and
// passes the host window to `ViewInspectorController` for picking. An app can
// also attach `.overlay { ViewInspectorOverlay(isActive:) }` to its own root.
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
// it. Its `alert + 4` level keeps it above host panels and the minimized
// dev assistant (`alert + 3`). Reopening the assistant raises it above the
// explorer; the assistant is never an inspection target. Folding or Interact
// mode lets touches pass through to the host.
//
// Being a `RipulChromeWindow` is what keeps that true: it declines key-ness,
// so a host resolving "the key window" gets the app's window and mounts its
// panels there — under us — instead of inside us. See RipulChromeWindow.swift.

@available(iOS 16.0, *)
final class RipulExplorerOverlayWindow: RipulChromeWindow {
    static let overlayLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 4)

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard rootViewController?.presentedViewController == nil else { return hit }
        // Route through the actual panel root. SwiftUI can return its full-screen
        // hosting view for a button gesture; treating that as either a full-screen
        // hit or a miss breaks the separate-window panel's touch routing.
        func panelHit(_ view: UIView) -> UIView? {
            guard !view.isHidden, view.alpha > 0.01 else { return nil }
            if let panel = view as? RipulFloatingPanelRootView {
                return panel.hitTest(panel.convert(point, from: self), with: event)
            }
            for child in view.subviews.reversed() {
                if let found = panelHit(child) { return found }
            }
            return nil
        }
        if let root = rootViewController?.view, let panel = panelHit(root) { return panel }
        // Minimized agent controls are interactive chrome, not inspection
        // targets. Decline this touch so UIKit delivers the entire gesture to
        // the agent's own window (including its row tap and drag recognizers).
        // Our visible panel/sheets retain priority where they cover the agent.
        if #available(iOS 26.0, *), let scene = windowScene {
            for case let agent as RipulDevOverlayWindow in scene.windows {
                guard !agent.isExpanded, !agent.isHidden,
                      agent.alpha > 0.01, agent.isUserInteractionEnabled,
                      agent.windowLevel.rawValue < windowLevel.rawValue else { continue }
                let agentPoint = agent.convert(point, from: self)
                if agent.interactiveFrame.contains(agentPoint),
                   agent.hitTest(agentPoint, with: event) != nil { return nil }
            }
        }
        if let capture = ViewInspectorController.live, capture.window === self,
           capture.capturesTouches, !capture.isHidden, capture.isUserInteractionEnabled {
            return capture
        }
        return nil
    }
}

@available(iOS 16.0, *)
@MainActor
public enum RipulViewExplorer {
    static weak var contextBridge: AgentBridge?

    private static var attachmentBridge: AgentBridge? {
        if let contextBridge { return contextBridge }
        // Host gestures and tool launches do not have the console's bridge to
        // pass in. Resolve its existing owner in this scene at attachment time:
        // minimizing preserves it, and closing/replacing it must not leave a
        // stale destination behind. Borrowed chat launchers have no bridge.
        if #available(iOS 26.0, *), let scene = hostWindow?.windowScene {
            let bridges = scene.windows.compactMap { window -> AgentBridge? in
                guard let window = window as? RipulDevOverlayWindow,
                      !window.isHidden, window.alpha > 0.01,
                      let root = window.rootViewController as? RipulDevOverlayRootVC else { return nil }
                return root.inspectorContextBridge
            }
            if bridges.count == 1 { return bridges[0] }
        }
        return nil
    }

    static func prepareSelectedElementAttachment() async throws -> ComposerContextAttachmentDraft {
        guard let bridge = attachmentBridge else { throw ComposerContextAttachmentError.noChat }
        guard let option = bridge.composerContexts.availableOptions.first(where: { $0.id == RipulComposerContext.selectedElement.id }) else {
            throw ComposerContextAttachmentError.selectedElementUnavailable
        }
        return try await bridge.composerContexts.prepareAttachment(option, for: bridge.currentSourceChatId)
    }

    /// Shared by picking and retained-selection paths. Embedded assistant
    /// chrome is never a target, including as a geometric fallback seed.
    static func canInspect(_ window: UIWindow) -> Bool {
        guard !window.isHidden, window.alpha > 0.01,
              !(window is RipulExplorerOverlayWindow) else { return false }
        if #available(iOS 26.0, *), window is RipulDevOverlayWindow { return false }
        return true
    }

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

    /// Present the View Explorer over the given host window (defaults to the app
    /// window), minimizing the embedded assistant. Reuses an existing explorer.
    /// Returns `false` only if no
    /// suitable window/view controller could be found to host it.
    /// `recording: true` opens it already in macro-record mode (the Macro
    /// tab armed) — used by the macro library's "Record new" entry point.
    @discardableResult
    public static func present(in window: UIWindow? = nil, recording: Bool = false, bridge: AgentBridge? = nil) -> Bool {
        guard let requested = window ?? RipulChrome.appWindow(),
              let scene = requested.windowScene,
              let target = canInspect(requested) ? requested : RipulChrome.appWindow(in: scene)
        else { return false }
        contextBridge = bridge
        // Launching from the assistant exposes the host. Reopening the assistant
        // later covers this same explorer without losing its selection or pin.
        if #available(iOS 26.0, *) {
            RipulDevAssistantOverlay.shared.minimizeForInspection(in: scene)
        }
        guard self.window == nil else { return true }

        hostWindow = target
        let win = RipulExplorerOverlayWindow(windowScene: scene)
        win.frame = scene.screen.bounds
        win.windowLevel = RipulExplorerOverlayWindow.overlayLevel
        win.backgroundColor = .clear
        let hosting = UIHostingController(rootView: RipulViewExplorerRoot(
            hostWindow: target,
            startRecording: recording,
            onDismiss: { dismiss() }
        ))
        hosting.view.backgroundColor = .clear
        hosting.view.tag = ripulViewExplorerOverlayTag
        win.installRoot(hosting)
        win.isHidden = false
        self.window = win
        return true
    }

    /// Remove the View Explorer if shown.
    public static func dismiss() {
        contextBridge = nil
        guard let win = window else { return }
        ViewInspectorController.live?.session?.close()
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
