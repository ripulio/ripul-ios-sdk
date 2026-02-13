import SwiftUI
import RipulAgent

struct AdvancedView: View {
    @AppStorage("agentBaseURL") private var baseURLString = AgentConfiguration.defaultBaseURL.absoluteString
    @AppStorage("agentSiteKey") private var siteKey = "pk_live_2pakky4z3s9674wu9zvvgzze"
    @State private var promptText = "What events do I have this week? Summarize them briefly."
    @State private var showPromptAgent = false

    private var promptConfiguration: AgentConfiguration {
        AgentConfiguration(
            baseURL: URL(string: baseURLString) ?? AgentConfiguration.defaultBaseURL,
            siteKey: siteKey.isEmpty ? nil : siteKey,
            newChat: true,
            prompt: promptText
        )
    }

    var body: some View {
        List {
            Section {
                Text("Patterns for getting more out of the Ripul AI Agent SDK — hiding the agent after tool actions, custom animations, and launching with context.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Hiding the agent after a tool action") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("When a tool changes the visible UI — filling a form, navigating to a screen — the agent panel is in the way. Minimize it so the user sees the result.")
                        .font(.subheadline)

                    Text("Give your tool a reference to the bridge and set `wantsMinimize` when the work is done:")
                        .font(.subheadline)
                }

                codeBlock("""
                struct FillProfileTool: NativeTool {
                    let bridge: AgentBridge

                    let name = "fill_profile"
                    let description = "Fills the profile form."
                    let inputSchema = ToolSchema.object(
                        .string("name", "Full name",
                                required: true),
                        .string("email", "Email",
                                required: true)
                    )

                    func execute(args: [String: Any])
                        async throws -> Any
                    {
                        let name = try string("name",
                                              from: args)
                        let email = try string("email",
                                               from: args)
                        ProfileService.shared.update(
                            name: name, email: email
                        )

                        // Minimize the agent
                        bridge.wantsMinimize = true

                        return ["success": true]
                    }
                }
                """)

                tipRow(
                    icon: "checkmark.circle",
                    title: "When to minimize",
                    detail: "The tool fills a form, navigates to a screen, triggers a camera or media player, or completes a workflow the user should review."
                )

                tipRow(
                    icon: "xmark.circle",
                    title: "When NOT to minimize",
                    detail: "The tool reads data (the agent will present results in chat), performs a background action, or fails (keep the agent open to explain the error)."
                )
            }

            Section("Passing the bridge to tools") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tools that minimize the agent need a bridge reference. Change your registry from a static array to a function:")
                        .font(.subheadline)
                }

                codeBlock("""
                enum YourTools {
                    static func all(
                        bridge: AgentBridge
                    ) -> [NativeTool] {
                        [
                            FillProfileTool(bridge: bridge),
                            SearchTool(), // no bridge needed
                        ]
                    }
                }

                // At registration:
                bridge.register(
                    YourTools.all(bridge: bridge)
                )
                """)
            }

            Section("Custom presentation") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("The convenience AgentView auto-dismisses on minimize. For a custom animation — slide-up panel, drawer, floating card — use AgentWebView directly and observe the bridge:")
                        .font(.subheadline)
                }

                codeBlock("""
                .onChange(of: bridge.wantsMinimize) {
                    _, minimize in
                    if minimize {
                        withAnimation(.spring(
                            response: 0.35,
                            dampingFraction: 0.86
                        )) {
                            showAgent = false
                        }
                    }
                }
                """)

                VStack(alignment: .leading, spacing: 8) {
                    Text("This demo app uses this exact pattern — the agent panel slides up from the bottom and stays preloaded for instant re-opening.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Pre-filling prompts") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pass a `prompt` in the configuration to pre-fill the agent's input with context — useful for contextual actions like long-pressing an event or a \"Help with this\" button.")
                        .font(.subheadline)
                }

                codeBlock("""
                AgentConfiguration(
                    baseURL: agentURL,
                    siteKey: siteKey,
                    prompt: "I'm looking at '\\(event.title)'"
                        + " on \\(event.startDate.formatted())"
                )
                """)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Try it")
                        .font(.subheadline.weight(.semibold))

                    TextField("Enter a prompt…", text: $promptText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)

                    Button {
                        showPromptAgent = true
                    } label: {
                        Label("Launch Agent with Prompt", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            }
        }
        .sheet(isPresented: $showPromptAgent) {
            AgentView(
                configuration: promptConfiguration,
                tools: YourTools.all
            )
        }
    }

    // MARK: - Components

    private func codeBlock(_ code: String) -> some View {
        Text(code)
            .font(.system(.caption2, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func tipRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.purple)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        AdvancedView()
            .navigationTitle("Advanced")
    }
}
