# Ripul AI Agent — iOS Reference App

## Why tool-enable your app?

Most apps already have powerful capabilities — calendars, health data, file management, smart home controls, payments — but users access them through buttons, menus, and forms they have to learn. Tool-enabling your app means exposing those same capabilities to an AI agent that can act on behalf of the user through natural language.

Instead of navigating three screens to create a calendar event, the user says *"Schedule a team standup every weekday at 9am."* Instead of scrolling through settings, they say *"Turn on do not disturb and dim the lights."* The agent understands intent, calls your native APIs, and the app just does what the user asked.

What this delivers:

- **Natural language as UI** — Users describe what they want instead of figuring out how to do it. Complex multi-step workflows become a single sentence.
- **Zero new UI to build** — The agent *is* the interface. You don't design screens for every new capability; you register a tool and the agent handles the interaction.
- **Composable actions** — The agent can chain multiple tools together in ways you never explicitly programmed. A calendar tool + a contacts tool = "Schedule lunch with Sarah at our usual place."
- **Your existing code, unchanged** — Tool wrappers are thin adapters around APIs you already have. Your service layer, models, and business logic stay exactly as they are.

This reference app demonstrates the pattern with a **calendar assistant**: a native week-view calendar backed by EventKit, with a floating Ripul AI Agent that can list, create, delete, and search calendar events on the user's behalf. The same pattern applies to any native capability you want to expose.

## Installation

Add the RipulAgent SDK to your Xcode project via Swift Package Manager:

```
https://github.com/ripulio/ripul-ios-sdk
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ripulio/ripul-ios-sdk", from: "1.0.0"),
]
```

Then `import RipulAgent` in any file that uses the SDK.

## Project Structure

```
├── Package.swift                        ← SPM package manifest
├── Sources/
│   └── RipulAgent/                      ← Ripul SDK (Swift Package)
│       ├── AgentBridge.swift                Message bridge between native and web agent
│       ├── AgentWebView.swift               WKWebView wrapper with JS bridge injection
│       ├── AgentView.swift                  Drop-in SwiftUI view for presenting the agent
│       ├── AgentConfiguration.swift         URL/theme/auth configuration for the agent
│       └── NativeTool.swift                 Protocol for registering native tools
│
└── Examples/
    └── RipulAgentDemo/                  ← Demo app (calendar assistant)
        └── RipulAgentDemo/
            ├── _Your_Tools/
            │   └── YourTools.swift          Thin wrappers that register your APIs as tools
            ├── AppServices.swift            Your app's existing APIs (e.g. CalendarService)
            ├── CalendarView.swift           Native weekly calendar UI
            ├── ContentView.swift            App entry point with tab navigation
            ├── GuideView.swift              In-app integration guide
            ├── AdvancedView.swift           Advanced topics demo (minimize, prompts)
            ├── SettingsView.swift           Agent configuration (site key, base URL)
            └── RipulAgentDemoApp.swift      @main App struct
```

### What's what

| Folder / File | Who writes it | Purpose |
|---------------|--------------|---------|
| `Sources/RipulAgent/` | **Ripul** (the SDK) | Handles embedding, communication protocol, tool discovery/invocation. Add via SPM. |
| `_Your_Tools/` | **You** (new code) | The *only* new code you write. Thin wrappers that register your existing APIs as agent-callable tools. |
| Everything else | **You** (existing code) | Your normal app — views, models, services. Nothing agent-specific here. |

## How It Works

### 1. Your app already has APIs

Your app has internal services — in this example, `CalendarService` wraps EventKit:

```swift
// AppServices.swift — your existing code, nothing agent-specific

final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    func fetchEvents(from start: Date, to end: Date) -> [EKEvent] { ... }
    func createEvent(title:startDate:endDate:notes:location:isAllDay:) throws -> EKEvent { ... }
    func deleteEvent(identifier: String) throws -> Bool { ... }
    func searchEvents(query: String, from start: Date, to end: Date) -> [EKEvent] { ... }
}
```

### 2. You write thin tool wrappers

Each tool conforms to `NativeTool` — a protocol with a few properties:

```swift
protocol NativeTool {
    var name: String { get }             // Tool name the agent sees
    var description: String { get }      // What the tool does (natural language)
    var inputSchema: [String: Any] { get } // JSON Schema for the input
    var isBlocking: Bool { get }         // true = waits for user interaction (default: false)
    func execute(args: [String: Any]) async throws -> Any  // Call your API
}
```

The SDK provides a **type-safe schema builder** so you never write raw JSON Schema strings:

```swift
let inputSchema = ToolSchema.object(
    .string("title", "Event title", required: true),
    .string("startDate", "ISO 8601 start time", required: true),
    .string("notes", "Optional notes"),
    .bool("isAllDay", "All-day event"),
    .number("priority", "Priority 1-5"),
    .integer("count", "Number of items")
)
```

And **arg extraction helpers** for the `execute` method:

```swift
try string("title", from: args)             // required string — throws if missing
try date("startDate", from: args)            // required ISO 8601 date — throws if missing/invalid
try optionalDate("endDate", from: args)      // optional date — nil if absent, throws if invalid
optionalString("notes", from: args)          // optional string — nil if absent
bool("isAllDay", from: args)                 // bool with default false
```

A complete wrapper looks like this:

```swift
// _Your_Tools/YourTools.swift — the only new code you write
import RipulAgent

struct CreateEventTool: NativeTool {
    let name = "create_event"
    let description = "Creates a new calendar event."
    let inputSchema = ToolSchema.object(
        .string("title", "Event title", required: true),
        .string("startDate", "ISO 8601 start time", required: true),
        .string("endDate", "ISO 8601 end time", required: true),
        .string("notes", "Optional notes"),
        .bool("isAllDay", "All-day event")
    )

    func execute(args: [String: Any]) async throws -> Any {
        let title = try string("title", from: args)
        let start = try date("startDate", from: args)
        let end = try date("endDate", from: args)

        let event = try CalendarService.shared.createEvent(
            title: title, startDate: start, endDate: end,
            notes: optionalString("notes", from: args),
            isAllDay: bool("isAllDay", from: args)
        )
        return ["success": true, "event": event.asDictionary]
    }
}
```

Collect all tools in a registry:

```swift
enum YourTools {
    static let all: [NativeTool] = [
        ListEventsTool(),
        CreateEventTool(),
        DeleteEventTool(),
        SearchEventsTool(),
    ]
}
```

### 3. Register tools and embed the agent

In your view, create a bridge, register your tools, and add the `AgentWebView`:

```swift
import RipulAgent

struct ContentView: View {
    @StateObject private var bridge = AgentBridge()

    var body: some View {
        AgentWebView(configuration: agentConfiguration, bridge: bridge)
            .task {
                bridge.register(YourTools.all)  // ← one line to register
            }
    }
}
```

Or use the convenience `AgentView` which handles loading states and theme sync:

```swift
AgentView(configuration: config, tools: YourTools.all)
```

That's it. The Ripul AI Agent framework handles:
- Embedding the agent in a WKWebView
- JS bridge injection (`window.parent` override for iframe detection)
- Handshake and capability negotiation
- MCP tool discovery (agent asks "what tools exist?")
- MCP tool invocation (agent calls a tool, framework routes to your `execute()`)
- Result/error delivery back to the agent
- Theme synchronization (light/dark mode)

## Agent Communication Protocol

The framework uses a message-based protocol over `window.postMessage` / `WKScriptMessageHandler`:

```
App → Agent:  agent-framework:handshake:ack    (capabilities, including mcp: true)
App → Agent:  agent-framework:mcp:tools        (tool definitions broadcast)
Agent → App:  agent-framework:mcp:discover     (request tool list)
App → Agent:  agent-framework:mcp:tools        (response with definitions)
Agent → App:  agent-framework:mcp:invoke       (call a tool: {toolName, args, requestId})
App → Agent:  agent-framework:mcp:result       (success: {result, requestId})
App → Agent:  agent-framework:mcp:error        (failure: {error, requestId})
App → Agent:  agent-framework:theme:set        (light/dark/system)
Agent → App:  agent-framework:theme:ready      (web app has applied theme)
Agent → App:  agent-framework:widget:minimize  (user wants to close the agent panel)
```

## Configuration

`AgentConfiguration` controls how the agent loads:

```swift
AgentConfiguration(
    baseURL: URL(string: "https://your-agent.example.com")!,
    siteKey: "pk_live_abc123...",    // your site key (see below)
    sessionToken: "user-jwt",       // optional — authenticated sessions
    theme: .system,                 // .light, .dark, or .system
    newChat: true,                  // start a fresh conversation
    prompt: "Help me with..."       // optional pre-filled prompt
)
```

Settings for `baseURL` and `siteKey` are persisted via `@AppStorage` and editable from the in-app Settings screen.

### Site Key

The **site key** identifies your app to the Ripul AI Agent platform. It connects your embedded agent to your account's configuration — including the agent's system prompt, model settings, and usage tracking.

Site keys use the format `pk_live_...` for production and `pk_test_...` for development.

**To get a site key:**

1. Sign up at [ripul.io](https://ripul.io)
2. Create a new project in the dashboard
3. Copy the site key from your project's settings page

The demo app ships with a pre-configured site key for testing. Replace it with your own before shipping to production.

## Adding Your Own Tools

1. **Keep your existing APIs as they are** — no changes needed to your service layer.

2. **Create a new file** (or add to `YourTools.swift`) with a struct conforming to `NativeTool`:
   - `name`: a snake_case identifier the agent will use
   - `description`: natural language explanation of what the tool does
   - `inputSchema`: a JSON Schema object describing expected parameters
   - `execute(args:)`: parse the args dictionary, call your API, return a result

3. **Add it to the registry**:
   ```swift
   enum MyTools {
       static let all: [NativeTool] = [
           MyNewTool(),
           // ...
       ]
   }
   ```

4. **Register at launch**:
   ```swift
   bridge.register(MyTools.all)
   ```

### Error handling

Any error thrown from `execute()` is caught by the framework and sent back to the agent as `mcp:error` with the error's `localizedDescription`. This means the agent sees your error message and can decide what to do next — retry with different arguments, ask the user for clarification, or explain what went wrong.

Because the agent acts on error messages, it's worth **enriching errors with context** rather than letting raw system errors bubble up. A generic "The operation couldn't be completed" gives the agent nothing to work with, while a message that explains *what failed* and *what to check* lets it self-correct:

```swift
func execute(args: [String: Any]) async throws -> Any {
    let title = try string("title", from: args)
    let start = try date("startDate", from: args)
    let end = try date("endDate", from: args)

    do {
        let event = try CalendarService.shared.createEvent(
            title: title, startDate: start, endDate: end
        )
        return ["success": true, "event": event.asDictionary]
    } catch {
        // Give the agent enough context to recover or explain the failure
        throw ToolError.invalidArgs(
            "Failed to create event '\(title)': \(error.localizedDescription). "
            + "Check that the device has a calendar configured and the dates are valid."
        )
    }
}
```

For simple input validation, throw `ToolError.invalidArgs("message")` directly — the arg extraction helpers already do this for missing or malformed parameters.

### Refreshing app UI after tool actions

If a tool modifies app state (e.g. creates a calendar event), post a notification so your views can refresh:

```swift
await MainActor.run {
    NotificationCenter.default.post(name: .calendarDidChange, object: nil)
}
```

## Advanced Topics

### Hiding the agent after a tool action

When a tool performs an action that changes the visible app UI — filling in a form, navigating to a new screen, opening a media player — the agent panel is in the way. The user needs to see the result, not the chat. In these cases, your tool should minimize the agent after it finishes.

The bridge exposes a published `wantsMinimize` property. Give your tool a reference to the bridge and set it when the work is done:

```swift
struct FillProfileTool: NativeTool {
    let bridge: AgentBridge

    let name = "fill_profile"
    let description = "Fills in the user profile form with the given details."
    let inputSchema = ToolSchema.object(
        .string("name", "Full name", required: true),
        .string("email", "Email address", required: true),
        .string("bio", "Short bio")
    )

    func execute(args: [String: Any]) async throws -> Any {
        let name = try string("name", from: args)
        let email = try string("email", from: args)

        // Update your app's form state
        ProfileService.shared.update(
            name: name,
            email: email,
            bio: optionalString("bio", from: args)
        )

        // Minimize the agent so the user sees the filled form
        bridge.wantsMinimize = true

        return ["success": true]
    }
}
```

Since the tool now needs a bridge reference, pass it during registration:

```swift
enum YourTools {
    static func all(bridge: AgentBridge) -> [NativeTool] {
        [
            FillProfileTool(bridge: bridge),
            // Tools that don't need to minimize stay as plain structs
            SearchTool(),
        ]
    }
}

// At registration time:
bridge.register(YourTools.all(bridge: bridge))
```

**When to minimize:**

- The tool fills in a form or edits visible content
- The tool navigates the user to a different screen
- The tool triggers a camera, media player, or full-screen modal
- The tool completes a multi-step workflow and the user should review the result

**When NOT to minimize:**

- The tool reads data (listing events, searching) — the agent is about to present the results in chat
- The tool performs a background action (sending a notification, toggling a setting) that doesn't change what's on screen
- The tool fails — keep the agent open so it can explain the error and retry

The agent panel slides back in when the user taps the agent button again. The bridge automatically resets `wantsMinimize` when it receives a `widget:restore` message from the agent.

### Custom presentation and animation

The convenience `AgentView` dismisses itself automatically when the agent requests minimize. For custom presentation — a slide-up panel, a side drawer, a floating card — use `AgentWebView` directly and observe `bridge.wantsMinimize`:

```swift
struct ContentView: View {
    @StateObject private var bridge = AgentBridge()
    @State private var showAgent = false

    var body: some View {
        ZStack {
            // Your app content
            MyMainView()

            // Agent panel with custom animation
            AgentWebView(configuration: config, bridge: bridge)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .offset(y: showAgent ? 0 : UIScreen.main.bounds.height)
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showAgent)
        }
        .task { bridge.register(YourTools.all) }
        .onChange(of: bridge.wantsMinimize) { _, minimize in
            if minimize {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    showAgent = false
                }
            }
        }
    }
}
```

This gives you full control over how and when the agent appears. The `AgentWebView` stays in the view hierarchy (preloaded), so re-opening is instant — no reload.

### Pre-filling prompts with context

Pass a `prompt` in the configuration to pre-fill the agent's input field with context about what the user is looking at:

```swift
AgentConfiguration(
    baseURL: agentURL,
    siteKey: siteKey,
    prompt: "I'm looking at the event '\(event.title)' on \(event.startDate.formatted())"
)
```

This is useful when launching the agent from a contextual action — a long-press on a calendar event, a "Help with this" button on a form, or a deep link. The user sees the prompt pre-filled and can send it immediately or edit it first.

### Blocking tools (user interaction)

Some tools need to wait for user interaction before returning a result — for example, presenting a native picker, a confirmation dialog, or a camera. By default the agent framework has a short request timeout, so these tools would fail before the user has a chance to respond.

Mark these tools as **blocking** and the framework will wait indefinitely for the result:

```swift
struct PickIndustryTool: NativeTool {
    let name = "pick_industry"
    let description = "Shows the industry picker for the user to select."
    let isBlocking = true  // ← no timeout — waits for user interaction
    let inputSchema = ToolSchema.object()

    func execute(args: [String: Any]) async throws -> Any {
        // Present a native picker, await user selection
        let selection = try await showNativePicker()
        return ["id": selection.id, "name": selection.name]
    }
}
```

The `isBlocking` flag is sent to the agent as `"blocking": true` in the MCP tool definition. The framework disables its request timeout for that tool invocation.

**When to use `isBlocking`:**

- Native pickers or selection screens
- Camera or photo library access
- Confirmation dialogs ("Are you sure?")
- Any tool that presents UI and waits for user input

**When NOT to use it:**

- API calls (even slow ones — they should have their own timeout)
- Background processing
- Tools that return immediately

## Requirements

- iOS 14+ (agent UI requires iOS 15+)
- Xcode 15+
- EventKit entitlement (for the calendar demo)

## Running the Demo

1. Open `Examples/RipulAgentDemo/RipulAgentDemo.xcodeproj` in Xcode
2. Select an iOS Simulator target
3. Build and run
4. Grant calendar access when prompted
5. Tap the sparkle button (bottom-right) to open the Ripul AI Agent
6. Try: "What events do I have this week?" or "Create a meeting tomorrow at 2pm"
