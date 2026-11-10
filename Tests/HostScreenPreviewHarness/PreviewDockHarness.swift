import SwiftUI
@testable import RipulAgent

/// The window's dock with a stand-in app: a tab view, as the Ripul app's shell
/// is, beside which the simulator panel docks when dragged into the right edge
/// of a wide window. Run on an iPad in landscape (`PreviewDockUITests`).
struct PreviewDockHarness: View {
    @StateObject private var dock = PreviewDockState(store: PreviewDockHarness.store)
    @StateObject private var state = SimulatorPreviewState()

    /// A fresh divider each launch.
    private static let store: UserDefaults = {
        let store = UserDefaults(suiteName: "PreviewDockHarness")!
        store.removePersistentDomain(forName: "PreviewDockHarness")
        return store
    }()

    var body: some View {
        RipulPreviewDockLayout(dock: dock) {
            PreviewDockHarnessApp(dock: dock)
                .overlay { if #available(iOS 26.0, *) { PreviewDockIndicator(dock: dock) } }
                .overlay { SimulatorHarnessOverlay(state: state).ignoresSafeArea(.container) }
        }
        .onAppear {
            state.dock = dock
            dock.content = { _ in
                AnyView(Color.ripul(.success).ignoresSafeArea()
                    .overlay { Text("Docked simulator").font(.ripul(.title)).foregroundStyle(.ripul(.onAccent)) })
            }
            dock.onRelease = { [state] surface, reopen in
                if case .simulator(let simulator) = surface { state.returnFromDock(simulator, open: reopen) }
            }
            state.open(SimulatorTarget(udid: "08E561AA-A868-4196-AF4A-3501D80DF965"), machineId: "host", chatId: "chat")
        }
    }
}

private struct PreviewDockHarnessApp: View {
    @ObservedObject var dock: PreviewDockState

    var body: some View {
        TabView {
            Tab("Agents", systemImage: "bubble.left.and.bubble.right") { PreviewDockHarnessScreen(dock: dock) }
            Tab("Files", systemImage: "folder") { Text("Files") }
            Tab("Settings", systemImage: "gear") { Text("Settings") }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

/// What a screen inside the app sees: its size class and width.
private struct PreviewDockHarnessScreen: View {
    @ObservedObject var dock: PreviewDockState
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 16) {
                Text(sizeClass == .compact ? "compact" : "regular")
                    .accessibilityIdentifier("PreviewDockHarness.sizeClass")
                Text("\(Int(geometry.size.width.rounded()))")
                    .accessibilityIdentifier("PreviewDockHarness.width")
                // For a picture of the indicator, which shows only mid-drag.
                Button(dock.hovering == nil ? "Show where it docks" : "Hide where it docks") {
                    dock.hover(.simulator, dock.hovering == nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
