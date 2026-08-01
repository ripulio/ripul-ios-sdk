#if os(iOS)
import SwiftUI
import UIKit

// MARK: - RipulLogConsole
//
// Host-agnostic launcher for the log console (`ConsoleLogViewer` — Console /
// Network / Tools), presented on its OWN window so it needs nothing else on
// screen. In particular it is not the agent/sessions console: hosts that embed
// `RipulAgentConsole` can reach its DevTools sheet via `.ripulShowDevTools`, but
// that requires the agent UI to be mounted and visible. This presenter is for
// "just show me the logs" — e.g. the View Explorer's Console button.
//
// Usage (from anywhere — a debug menu, a HUD button, a shake handler):
//
//     if #available(iOS 16.0, *) { RipulLogConsole.toggle() }
//
// Native logs come from `RipulLog`, the host-owned buffer that exists from process
// launch — so this works before anything has mounted, which is exactly when an
// early failure needs reading. When an `AgentBridge` also exists, its web console
// output is interleaved and the Network / Tools tabs appear alongside.

@available(iOS 16.0, *)
@MainActor
public enum RipulLogConsole {

    /// The window carrying the live console, or `nil` when not shown.
    private static var window: RipulChromeWindow?

    /// Whether the log console is currently on screen.
    public static var isPresented: Bool { window != nil }

    /// Present the log console over the active scene. No-op if already showing.
    /// Returns `false` only if no window scene could be found to host it.
    @discardableResult
    public static func present() -> Bool {
        guard window == nil else { return true }
        guard let scene = activeWindowScene() else { return false }

        // Above the app, and a chrome window — so it stays out of screen
        // inspection (the agent should always see the HOST's screen, not this
        // console) and declines key-ness, which is what stops host panels being
        // mounted inside it. See RipulChromeWindow.swift.
        let win = RipulChromeWindow(windowScene: scene)
        win.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        win.backgroundColor = .systemBackground

        let host = UIHostingController(rootView: RipulLogConsoleRoot())
        win.installRoot(host)
        win.isHidden = false

        window = win
        return true
    }

    /// Remove the log console if shown.
    public static func dismiss() {
        window?.relinquishKey()
        window?.isHidden = true
        window = nil
    }

    /// Show if hidden, hide if shown.
    @discardableResult
    public static func toggle() -> Bool {
        if isPresented { dismiss(); return false }
        return present()
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

// MARK: - Root

@available(iOS 16.0, *)
private struct RipulLogConsoleRoot: View {
    var body: some View {
        NavigationStack {
            // Bridge is optional by design — the native buffer stands alone.
            ConsoleLogViewer(bridge: AgentBridge.current)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { RipulLogConsole.dismiss() }
                            .uiKitIdentifier("RipulLogConsole.doneButton")
                    }
                }
        }
    }
}
#endif
