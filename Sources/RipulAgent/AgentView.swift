import SwiftUI

@MainActor
public struct AgentView: View {
    public let configuration: AgentConfiguration
    public var tools: [NativeTool] = []
    public weak var searchClickDelegate: SearchClickDelegate?
    @StateObject private var bridge = AgentBridge()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    /// Configuration with validated site key config (session token + features).
    /// Nil until validation completes (or immediately set if no site key).
    @State private var readyConfig: AgentConfiguration?

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
        Group {
            if let config = readyConfig {
                AgentWebView(configuration: config, bridge: bridge)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .onChange(of: colorScheme) { _, newScheme in
            let theme: AgentTheme = newScheme == .dark ? .dark : .light
            bridge.setTheme(theme)
        }
        .onChange(of: bridge.wantsMinimize) { _, wantsMinimize in
            if wantsMinimize {
                dismiss()
            }
        }
        .task {
            bridge.register(tools)
            bridge.searchClickDelegate = searchClickDelegate

            // Validate the site key natively before loading the web view.
            // This mirrors the browser EmbedManager flow: the host validates
            // first and passes the full config (including theme) via URL params,
            // so the web app can render the correct theme on the first paint
            // without a dark flash.
            var config = configuration
            if let siteKey = config.siteKey, config.siteKeyConfig == nil {
                let result = await SiteKeyValidator.validate(
                    siteKey: siteKey, baseURL: config.baseURL
                )
                if let token = result.sessionToken {
                    config.sessionToken = token
                }
                config.siteKeyConfig = result.configJSON
            }
            readyConfig = config
        }
    }
}
