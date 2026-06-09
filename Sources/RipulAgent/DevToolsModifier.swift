import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Public API

public extension Notification.Name {
    /// Post this notification to open the DevTools viewer.
    /// Any view in the hierarchy can trigger it — the `.ripulDevTools()` modifier
    /// listens and presents the sheet (iOS) or floating window (macOS).
    static let ripulShowDevTools = Notification.Name("ripulShowDevTools")
}

@available(iOS 16.0, macOS 13.0, *)
public extension View {
    /// Attaches the Ripul DevTools viewer (Console, Network, Tools tabs).
    ///
    /// - On iOS: presents as a sheet.
    /// - On macOS: opens a floating NSWindow.
    ///
    /// Trigger by posting `Notification.Name.ripulShowDevTools`, or call
    /// `DevToolsAction.show` from the environment.
    ///
    /// ```swift
    /// AgentView(bridge: bridge)
    ///     .ripulDevTools(bridge: bridge)
    /// ```
    func ripulDevTools(bridge: AgentBridge) -> some View {
        modifier(DevToolsModifier(bridge: bridge))
    }
}

// MARK: - Environment action

/// An action that descendant views can pull from the environment to
/// show or hide the DevTools viewer without needing to know how it's presented.
@available(iOS 16.0, macOS 13.0, *)
public struct DevToolsAction {
    let handler: (Bool) -> Void

    public func show() { handler(true) }
    public func hide() { handler(false) }
}

@available(iOS 16.0, macOS 13.0, *)
private struct DevToolsActionKey: EnvironmentKey {
    static let defaultValue: DevToolsAction? = nil
}

@available(iOS 16.0, macOS 13.0, *)
public extension EnvironmentValues {
    var devToolsAction: DevToolsAction? {
        get { self[DevToolsActionKey.self] }
        set { self[DevToolsActionKey.self] = newValue }
    }
}

// MARK: - Modifier

@available(iOS 16.0, macOS 13.0, *)
struct DevToolsModifier: ViewModifier {
    @ObservedObject var bridge: AgentBridge
    @State private var showSheet = false

    func body(content: Content) -> some View {
        content
            .onAppear { registerBuiltInTools() }
            .environment(\.devToolsAction, DevToolsAction { show in
                if show { present() } else { dismiss() }
            })
            .onReceive(NotificationCenter.default.publisher(for: .ripulShowDevTools)) { _ in
                present()
            }
            #if os(iOS)
            .sheet(isPresented: $showSheet) {
                NavigationStack {
                    ConsoleLogViewer(bridge: bridge)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showSheet = false }
                            }
                        }
                }
            }
            #endif
    }

    private func registerBuiltInTools() {
        bridge.registerBuiltInTools([
            ConsoleLogsTool(bridge: bridge),
            NetworkLogsTool(bridge: bridge),
        ])
    }

    private func present() {
        #if os(iOS)
        showSheet = true
        #elseif os(macOS)
        openDevToolsWindow(bridge: bridge)
        #endif
    }

    private func dismiss() {
        #if os(iOS)
        showSheet = false
        #elseif os(macOS)
        closeDevToolsWindow()
        #endif
    }
}

// MARK: - macOS floating window

#if os(macOS)
/// Key for finding the DevTools window by identifier.
private let devToolsWindowID = "ripul-devtools-console"

@available(macOS 13.0, *)
private func openDevToolsWindow(bridge: AgentBridge) {
    // If the window already exists, just bring it forward.
    if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == devToolsWindowID }) {
        existing.makeKeyAndOrderFront(nil)
        return
    }

    let hostingView = NSHostingView(rootView: ConsoleLogViewer(bridge: bridge))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.identifier = NSUserInterfaceItemIdentifier(devToolsWindowID)
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.title = "Console Logs"
    window.level = .floating
    window.center()
    window.makeKeyAndOrderFront(nil)
}

private func closeDevToolsWindow() {
    NSApp.windows
        .first { $0.identifier?.rawValue == devToolsWindowID }?
        .close()
}
#endif
