import SwiftUI

@MainActor
public struct AgentView: View {
    public let configuration: AgentConfiguration
    public var tools: [NativeTool] = []
    public weak var searchClickDelegate: SearchClickDelegate?
    @StateObject private var bridge = AgentBridge()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var showContent = false

    public init(
        configuration: AgentConfiguration,
        tools: [NativeTool] = [],
        searchClickDelegate: SearchClickDelegate? = nil
    ) {
        self.configuration = configuration
        self.tools = tools
        self.searchClickDelegate = searchClickDelegate
    }

    public var body: some View {
        ZStack {
            AgentWebView(configuration: configuration, bridge: bridge)

            if !showContent {
                Color(.systemBackground)
                ProgressView()
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: colorScheme) { _, newScheme in
            let theme: AgentTheme = newScheme == .dark ? .dark : .light
            bridge.setTheme(theme)
        }
        .onChange(of: bridge.wantsMinimize) { _, wantsMinimize in
            if wantsMinimize {
                dismiss()
            }
        }
        .onChange(of: bridge.isThemeReady) { _, ready in
            if ready { showContent = true }
        }
        .task {
            bridge.register(tools)
            bridge.searchClickDelegate = searchClickDelegate
            // Fallback: show content after 3s even if theme:ready never arrives
            try? await Task.sleep(for: .seconds(3))
            showContent = true
        }
    }
}
