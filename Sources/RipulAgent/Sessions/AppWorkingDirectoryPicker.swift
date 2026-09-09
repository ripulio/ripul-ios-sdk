import SwiftUI

public extension Notification.Name {
    static let ripulShowAppWorkingDirectory = Notification.Name("ripulShowAppWorkingDirectory")
}

/// The menu and its presenter share the bridge identity, so an embedded console
/// only opens its own sheet even when several channels exist in one app.
@available(iOS 26.0, macOS 26.0, *)
public struct AppWorkingDirectorySheet: ViewModifier {
    let bridge: AgentBridge
    @State private var isPresented = false

    public init(bridge: AgentBridge) { self.bridge = bridge }

    public func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ripulShowAppWorkingDirectory)) { notification in
                guard let source = notification.object as? AgentBridge, source === bridge else { return }
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                AppWorkingDirectoryPicker(bridge: bridge, onDismiss: { isPresented = false })
            }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct AppWorkingDirectoryPicker: View {
    let bridge: AgentBridge
    let onDismiss: () -> Void
    @State private var scope: WorkScopeState?
    @State private var isLoading = true
    @State private var error: String?

    private var directories: [String] {
        guard let scope else { return [] }
        var result = scope.options
        if scope.source == "chosen", let selected = scope.effective, !result.contains(selected) {
            result.append(selected)
        }
        return result
    }

    var body: some View {
        WorkingDirectoryPicker(
            title: "App Working Directory",
            explanation: "Remembered for this app. New sessions start in this folder; existing sessions keep their own directory. Choose Default to use the host’s default folder.",
            directories: directories,
            selection: scope?.source == "chosen" ? scope?.effective : nil,
            defaultPath: scope?.options.first,
            identifierPrefix: "AppWorkingDirectoryPicker",
            isLoading: isLoading,
            error: error,
            onRetry: { Task { await load() } },
            onPick: { path in Task { await save(path) } },
            onDismiss: onDismiss
        )
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        scope = await bridge.workScope(chatId: "")
        if scope == nil || scope?.machineName == nil {
            error = "Could not load folders from your host. Connect a machine and retry."
        }
        isLoading = false
    }

    private func save(_ path: String?) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        if await bridge.setWorkScope(path: path) {
            onDismiss()
        } else {
            error = "Could not save this app’s working directory. Please retry."
        }
        isLoading = false
    }
}
