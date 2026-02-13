import SwiftUI

struct GuideView: View {
    var body: some View {
        List {
            Section {
                Text("This guide explains how to tool-enable your iOS app with the Ripul AI Agent — exposing your native APIs so an embedded AI agent can discover and invoke them through natural language.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Why tool-enable your app?") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Most apps already have powerful capabilities — calendars, health data, file management, smart home controls — but users access them through buttons, menus, and forms they have to learn.")

                    Text("Tool-enabling means exposing those same capabilities to an AI agent that acts on behalf of the user through natural language.")

                    Text("Instead of navigating three screens to create a calendar event, the user says:")

                    Text("\"Schedule a team standup every weekday at 9am.\"")
                        .italic()
                        .foregroundStyle(.purple)

                    Text("The agent understands intent, calls your native APIs, and the app does what the user asked.")
                }
                .font(.subheadline)

                benefitRow(
                    icon: "text.bubble",
                    title: "Natural language as UI",
                    detail: "Users describe what they want instead of figuring out how to do it."
                )

                benefitRow(
                    icon: "hammer",
                    title: "Zero new UI to build",
                    detail: "Register a tool and the agent handles the interaction. No new screens needed."
                )

                benefitRow(
                    icon: "link",
                    title: "Composable actions",
                    detail: "The agent chains tools in ways you never explicitly programmed."
                )

                benefitRow(
                    icon: "checkmark.shield",
                    title: "Your existing code, unchanged",
                    detail: "Tool wrappers are thin adapters around APIs you already have."
                )
            }

            Section("How it works") {
                stepRow(number: 1, title: "Your app already has APIs", detail: "Your existing services — CalendarService, HealthKit wrappers, network layers — stay exactly as they are. Nothing agent-specific.")

                stepRow(number: 2, title: "Write thin tool wrappers", detail: "Each tool conforms to the NativeTool protocol: a name, description, JSON Schema, and an execute method that calls your API.")

                codeBlock("""
                struct CreateEventTool: NativeTool {
                    let name = "create_event"
                    let description = "Creates a calendar event."
                    let inputSchema = ToolSchema.object(
                        .string("title", "Event title",
                                required: true),
                        .string("startDate", "ISO 8601 time",
                                required: true)
                    )

                    func execute(args: [String: Any])
                        async throws -> Any
                    {
                        let title = try string("title",
                                               from: args)
                        let start = try date("startDate",
                                             from: args)
                        let event = try CalendarService
                            .shared.createEvent(
                                title: title,
                                startDate: start,
                                endDate: start
                            )
                        return ["success": true,
                                "event": event.asDictionary]
                    }
                }
                """)

                stepRow(number: 3, title: "Register and embed", detail: "One line registers your tools. The framework handles discovery, invocation, and result delivery.")

                codeBlock("""
                bridge.register(YourTools.all)
                """)
            }

            Section("Schema builder") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The SDK provides a type-safe schema builder so you never write raw JSON Schema:")
                        .font(.subheadline)
                }

                codeBlock("""
                ToolSchema.object(
                    .string("title", "Event title",
                            required: true),
                    .string("notes", "Optional notes"),
                    .bool("isAllDay", "All-day event"),
                    .number("priority", "Priority 1-5"),
                    .integer("count", "Number of items")
                )
                """)
            }

            Section("Arg extraction helpers") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Built-in helpers for parsing arguments in your execute method:")
                        .font(.subheadline)
                }

                codeBlock("""
                try string("title", from: args)
                try date("startDate", from: args)
                try optionalDate("endDate", from: args)
                optionalString("notes", from: args)
                bool("isAllDay", from: args)
                """)
            }

            Section("Error handling") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Errors thrown from execute() are sent to the agent as mcp:error. The agent uses your error message to decide what to do next — retry, ask the user, or explain the failure.")
                        .font(.subheadline)

                    Text("Enrich errors with context rather than letting raw system errors bubble up:")
                        .font(.subheadline)
                }

                codeBlock("""
                do {
                    let event = try CalendarService
                        .shared.createEvent(...)
                    return ["success": true]
                } catch {
                    throw ToolError.invalidArgs(
                        "Failed to create event: "
                        + "\\(error.localizedDescription). "
                        + "Check that a calendar is "
                        + "configured."
                    )
                }
                """)
            }

            Section("Site key") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The site key identifies your app to the Ripul AI Agent platform. It connects your embedded agent to your account's configuration — system prompt, model settings, and usage tracking.")
                        .font(.subheadline)

                    Text("Format: pk_live_... (production) or pk_test_... (development)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Link(destination: URL(string: "https://ripul.io")!) {
                    HStack {
                        Label("Get a site key at ripul.io", systemImage: "globe")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Project structure") {
                structureRow("AgentFramework/", detail: "Ripul SDK — do not modify", icon: "shippingbox")
                structureRow("_Your_Tools/", detail: "Your tool wrappers — the only new code", icon: "wrench")
                structureRow("AppServices.swift", detail: "Your existing APIs (e.g. CalendarService)", icon: "gearshape.2")
                structureRow("ContentView.swift", detail: "App entry point with agent embedding", icon: "rectangle.on.rectangle")
            }

            // MARK: - Advanced Topics

            Section {
                Label("Advanced Topics", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.purple)

                Text("Once you have the basics working, these patterns help you build a polished integration.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Hiding the agent after a tool action") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("When a tool changes the visible UI — filling a form, navigating to a screen — the agent panel gets in the way. Minimize it so the user sees the result.")
                        .font(.subheadline)

                    Text("Give your tool a reference to the bridge and set wantsMinimize when the work is done:")
                        .font(.subheadline)
                }

                codeBlock("""
                struct FillProfileTool: NativeTool {
                    let bridge: AgentBridge

                    func execute(args: [String: Any])
                        async throws -> Any
                    {
                        ProfileService.shared.update(
                            name: try string("name",
                                             from: args)
                        )

                        // Minimize the agent
                        bridge.wantsMinimize = true
                        return ["success": true]
                    }
                }
                """)

                benefitRow(
                    icon: "checkmark.circle",
                    title: "When to minimize",
                    detail: "Fills a form, navigates screens, triggers camera/media, or completes a workflow the user should review."
                )

                benefitRow(
                    icon: "xmark.circle",
                    title: "When NOT to minimize",
                    detail: "Reads data (agent presents results), background actions, or failures (agent should explain the error)."
                )
            }

            Section("Passing the bridge to tools") {
                VStack(alignment: .leading, spacing: 8) {
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
                            SearchTool(),
                        ]
                    }
                }

                bridge.register(
                    YourTools.all(bridge: bridge)
                )
                """)
            }

            Section("Custom presentation") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AgentView auto-dismisses on minimize. For custom animations — slide-up panel, drawer, floating card — use AgentWebView and observe the bridge:")
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
                    Text("This demo uses this pattern — the agent slides up from the bottom and stays preloaded for instant re-opening.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Pre-filling prompts") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pass a prompt in the configuration to pre-fill the agent's input with context — great for contextual actions like long-pressing an event or a \"Help with this\" button:")
                        .font(.subheadline)
                }

                codeBlock("""
                AgentConfiguration(
                    baseURL: agentURL,
                    siteKey: siteKey,
                    prompt: "I'm looking at "
                        + "'\\(event.title)' on "
                        + "\\(event.startDate.formatted())"
                )
                """)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Try the interactive demo in the Advanced tab.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Components

    private func benefitRow(icon: String, title: String, detail: String) -> some View {
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

    private func stepRow(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.purple))
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

    private func codeBlock(_ code: String) -> some View {
        Text(code)
            .font(.system(.caption2, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func structureRow(_ name: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.purple)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium).monospaced())
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
        GuideView()
            .navigationTitle("Guide")
    }
}
