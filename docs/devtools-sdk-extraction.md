# DevTools SDK Extraction Plan

> **Part of the [DevKit Program](../../docs/plans/devkit-program.md)** — Layer 2 · SDK packaging: extract web-content capture + a generic localhost MCP server into the SDK. See the hub for the map, the surfaces glossary, and cross-cluster status.

> Extract Ripul's in-app developer tools into a reusable SDK so any app can embed console logs, network monitoring, and MCP tool exposure.

Ripul is the first consumer — every phase replaces Ripul's own code with the SDK API, proving the extraction works before any external developer touches it.

## Current State

### Already in `ripul-ios-sdk` (RipulAgent)

| File | What it does |
|------|-------------|
| `AgentWebView.swift` | Injects JS that intercepts `console.*` and network requests in any WKWebView |
| `AgentBridge.swift` | Receives intercepted logs via `agentLog` / `agentNetwork` message handlers, stores in rolling buffers (`consoleLogs`, `networkLogs`) |
| `ConsoleLogViewer.swift` | Full SwiftUI viewer — Console tab, Network tab, Tools tab. Filter, search, expand, copy. |
| `ConsoleLogRenderers.swift` | Pluggable renderer registry for typed log entries |
| `NativeTool.swift` | Protocol + ToolSchema builder for defining tools the agent can call |

### Still in `ripul-native-app` (needs extraction)

| File | What it does |
|------|-------------|
| `Shared/ConsoleLogsTool.swift` | NativeTool that queries `bridge.consoleLogs` with filters — exposed to CLI as `host_console_logs` |
| `macOS/ClaudeCliServer.swift` | Localhost HTTP server bridging NativeTools to Claude CLI |
| `macOS/CodexCliServer.swift` | Same pattern for Codex CLI |
| `macOS/AntigravityCliServer.swift` | Same pattern for Antigravity CLI |
| `macOS/ContentView.swift` → `rebuildTools()` | Assembles and registers all NativeTools with the bridge |

### No `NetworkLogsTool` exists yet

The network tab is view-only. There's no NativeTool that lets CLI query network logs the way `ConsoleLogsTool` does for console.

### How Ripul presents ConsoleLogViewer today (5 call sites)

1. **iOS ContentView** — `.sheet` triggered by `glassTopBarLongPress` notification
2. **ConnectingOverlay** — `.sheet` triggered by error-state button
3. **SignInOverlay** — `.sheet` triggered by error-state button
4. **SettingsScreen (iOS)** — `.sheet` from settings menu
5. **SettingsScreen (macOS)** — opens a floating `NSWindow`

All follow the same pattern: `@State var showConsoleLogs = false` → `.sheet { NavigationStack { ConsoleLogViewer(bridge:) } }`.

---

## Phase 1: DevTools ViewModifier

**Goal:** Single `.ripulDevTools(bridge:)` modifier that handles ConsoleLogViewer presentation. Ripul adopts it, deleting duplicated sheet/window code.

### What ships

New file in SDK: `DevToolsModifier.swift`

```swift
// Usage:
SomeView()
    .ripulDevTools(bridge: bridge)
```

The modifier:
- Adds a `.sheet` (iOS) or floating `NSWindow` (macOS) presenting `ConsoleLogViewer`
- Listens for `Notification.Name.ripulShowDevTools` to trigger presentation
- Provides `DevToolsAction` environment key so any descendant can open/close programmatically
- Wraps in `NavigationStack` with a Done button (matches current UX)

### What changes in Ripul

| File | Change |
|------|--------|
| `iOS/ContentView.swift` | Remove `showingConsoleLogs` state + `.sheet` + notification listener. Add `.ripulDevTools(bridge:)`. |
| `Shared/SettingsScreen.swift` | Remove `showingConsoleLogs` state + `.sheet` + `openConsoleWindow()`. Post `ripulShowDevTools` notification instead. |
| `Shared/Overlays.swift` | **No change** — error-overlay sheets are contextual UX, not the default dev tools entry point. |

### How to test

1. Build `RipulApp` (iOS) → long-press glass bar → Console Logs sheet appears
2. Build `RipulMac` (macOS) → Settings → Console Logs → floating window appears
3. Console tab shows logs, Network tab shows requests — identical behavior to before
4. Error overlays still show their own Console Logs button + sheet — unaffected

### Status: COMPLETE (9be507c)

- `DevToolsModifier.swift` added to SDK
- iOS ContentView: `.ripulDevTools(bridge:)` replaces manual sheet
- macOS ContentView: `.ripulDevTools(bridge:)` added
- SettingsScreen: posts `ripulShowDevTools` notification, `openConsoleWindow()` deleted
- Both platforms build clean

---

## Phase 2: Built-in Tools (ConsoleLogsTool + NetworkLogsTool)

**Goal:** Move `ConsoleLogsTool` into the SDK. Create `NetworkLogsTool`. Auto-register both when dev tools are enabled.

### What ships

| New/moved file | Description |
|---|---|
| `ConsoleLogsTool.swift` → SDK | Moved from `ripul-native-app/Shared/`. Description generalized (not "this Mac's Ripul app"). |
| `NetworkLogsTool.swift` (new in SDK) | Same pattern — queries `bridge.networkLogs` with method/status/URL filters. |
| `DevToolsModifier.swift` update | When `.ripulDevTools()` is applied, auto-registers both tools with `bridge.register()`. |

### What changes in Ripul

| File | Change |
|------|--------|
| `Shared/ConsoleLogsTool.swift` | Delete |
| `macOS/ContentView.swift` → `rebuildTools()` | Remove `ConsoleLogsTool(bridge:)` from the list — SDK handles it |

### How to test

1. From Claude CLI, call `host_console_logs` — returns filtered console entries (now served by SDK)
2. From Claude CLI, call `host_network_logs` — returns filtered network entries (new capability)
3. Ripul's `rebuildTools()` only has app-specific tools (Dock, Scripts, etc.)
4. iOS app still shows console/network in viewer — unchanged

### Status: COMPLETE (59b2d5f)

- `ConsoleLogsTool.swift` moved into SDK with generalized description
- `NetworkLogsTool.swift` created in SDK (method, status, URL, error filters + headers)
- `AgentBridge`: added `builtInTools` array + `registerBuiltInTools()` — survives `setTools()` calls
- `DevToolsModifier`: auto-registers both tools on `.onAppear`
- Deleted `ripul-native-app/Shared/ConsoleLogsTool.swift`
- macOS `rebuildTools()` no longer includes ConsoleLogsTool
- iOS `register()` no longer includes ConsoleLogsTool
- Both platforms build clean

---

## Phase 3: MCP Server in the SDK

**Goal:** Extract the localhost HTTP server into a generic `DevToolsMCPServer` in the SDK. Any app can start it and expose registered NativeTools to any MCP client.

### What ships

| New file | Description |
|---|---|
| `DevToolsMCPServer.swift` (SDK) | Generic HTTP server on a configurable port. Serves `tools/list` and `tools/call` endpoints. Takes registered `NativeTool`s from the bridge. |
| `DevToolsModifier.swift` update | Add `.ripulMCPServer(port:)` modifier or parameter to `.ripulDevTools()`. |

### What changes in Ripul

| File | Change |
|------|--------|
| `macOS/ClaudeCliServer.swift` | Becomes a thin wrapper: configures SDK's MCP server + manages the Claude CLI binary. Most HTTP serving code deletes. |
| `macOS/CodexCliServer.swift` | Same — thin wrapper for Codex binary. |
| `macOS/AntigravityCliServer.swift` | Same — thin wrapper for Antigravity binary. |

### How to test

1. Claude CLI connects → discovers all tools (built-in + app-specific)
2. Call `host_console_logs` and `host_network_logs` via CLI — both work
3. **Hello world test:** Create a blank SwiftUI app that imports `RipulAgent`, adds `.ripulDevTools()` + `.ripulMCPServer(port: 4000)`. Start an MCP client pointing at `localhost:4000` → it sees the built-in tools.
4. Ripul's CLI servers are ~50% smaller (HTTP plumbing deleted)

### Status: pending

---

## Phase 4: Any-WKWebView Support

**Goal:** Decouple from Ripul's web app so the SDK attaches to any WKWebView. A developer's own web app gets console + network capture automatically.

### What ships

| Change | Description |
|---|---|
| `DevToolsWebView.swift` (SDK) | Lightweight WKWebView wrapper that injects the capture JS without requiring AgentView or Ripul's web app. |
| `DevToolsModifier.swift` update | Accept either `AgentBridge` or a raw `WKWebView` — JS injection works in both modes. |
| Sample project | Minimal app demonstrating: load any URL in WKWebView → `.ripulDevTools()` → console/network capture works → MCP server exposes tools. |

### What changes in Ripul

Nothing — Ripul already uses `AgentView` which goes through `AgentWebView`. This phase proves the SDK works *without* AgentView.

### How to test

1. Sample app loads `https://example.com` in a plain WKWebView
2. Trigger `console.log("hello")` from JS → appears in ConsoleLogViewer
3. Page makes a fetch request → appears in Network tab
4. Claude CLI connects to MCP server → can query both log types
5. Zero dependency on Ripul's web app, Clerk auth, or agent framework

### Status: pending

---

## What each phase proves

| Phase | Ripul gets | External developer gets |
|-------|-----------|------------------------|
| 1 | Cleaner code — one modifier replaces 5 sheet/window setups | Nothing yet (internal) |
| 2 | Auto-registered tools, new network log CLI access | Tools are in the SDK (closer to embeddable) |
| 3 | Smaller CLI servers, shared MCP infrastructure | Can embed MCP server in their app, Claude CLI sees their tools |
| 4 | — | Full standalone dev tools for any WKWebView app |
