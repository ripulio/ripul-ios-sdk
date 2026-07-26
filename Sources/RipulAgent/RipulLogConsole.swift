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
// Logs come from `AgentBridge.current`, the same buffer `device_console_logs` /
// `host_console_logs` read and the one `NativeLogTee` tees native `NSLog` into.
// A host that has never brought a bridge up yet gets an explanatory placeholder
// rather than an empty list, so "no logs" is never ambiguous.

@available(iOS 16.0, *)
@MainActor
public enum RipulLogConsole {

    /// The window carrying the live console, or `nil` when not shown.
    private static var window: UIWindow?

    /// Whether the log console is currently on screen.
    public static var isPresented: Bool { window != nil }

    /// Present the log console over the active scene. No-op if already showing.
    /// Returns `false` only if no window scene could be found to host it.
    @discardableResult
    public static func present() -> Bool {
        guard window == nil else { return true }
        guard let scene = activeWindowScene() else { return false }

        let win = UIWindow(windowScene: scene)
        // Above the app (and above a View-Explorer overlay, which is mounted inside
        // the app's own window), but marked so screen-inspection tools skip it —
        // the agent should always see the HOST app's screen, not this console.
        win.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        win.accessibilityIdentifier = RipulInspection.excludedOverlayWindowIdentifier
        win.backgroundColor = .systemBackground

        let host = UIHostingController(rootView: RipulLogConsoleRoot())
        win.rootViewController = host
        win.isHidden = false

        window = win
        return true
    }

    /// Remove the log console if shown.
    public static func dismiss() {
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
            Group {
                if let bridge = AgentBridge.current {
                    ConsoleLogViewer(bridge: bridge)
                } else {
                    noBridge
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { RipulLogConsole.dismiss() }
                        .uiKitIdentifier("RipulLogConsole.doneButton")
                }
            }
        }
    }

    /// Nothing has brought an `AgentBridge` up in this process yet, so there is no
    /// buffer to read. Say so, rather than showing an empty console that reads as
    /// "the app logged nothing".
    private var noBridge: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No log buffer yet")
                .font(.headline)
            Text("Logs are captured by an AgentBridge. Open the agent console once "
                 + "in this session and they'll appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Console Logs")
    }
}
#endif
