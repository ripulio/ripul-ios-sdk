# Native Introspection & the Headless Device Agent

> **Part of the [DevKit Program](../../docs/plans/devkit-program.md)** — Layer 3 · Native generalization: native introspection (Swift logs, view hierarchy, native state) + a headless relay peer. See the hub for the map, the surfaces glossary, and cross-cluster status.

> Let the agent reach an iOS app's **native** runtime — Swift logs, view hierarchy, native state, the app's own WKWebViews — not just the embedded web content, and reach it **without** a live foreground web app. The SDK becomes a device-introspection agent any iOS app links to and shows up as a CLI-selectable device.

This is the next chapter of [`devtools-sdk-extraction.md`](./devtools-sdk-extraction.md). That plan extracts **web-content** capture (console/network) and a **localhost** MCP server. This plan adds the two things it doesn't cover:

1. **Native introspection** — the agent sees the Swift side, not only the embedded web app's `console.*`/DOM.
2. **A headless native relay peer** — the app *process* is the CLI-reachable device, with no agent UI and no web app required.

It is also the SDK-embed realization of the audience [`../../docs/plans/devkit-self-hosted-dev-loop.md`](../../docs/plans/devkit-self-hosted-dev-loop.md) names as currently **unserved**: native iOS apps. That doc's "reverse tunnel" (route #2 — an outbound WebSocket the host treats as an MCP transport) is precisely the [`DeviceAgentClient`](#phase-c--headless-deviceagentclient-the-reverse-tunnel) below.

---

## Why now / why this is the right shape

The product axis is **content vs. shell**, not native vs. web:

- **Content** (chat transcript, CMS designer, AG Grid, published portals) is web-shaped, fast-moving, and shared across browser + iOS + macOS + portal output. It stays web.
- **Shell / interaction / OS / introspection** is where native wins, and Ripul already migrates these natively (native session list `SessionsSheet.swift`, native chat input, glass, swipe, push, Live Activities, CLI servers).

Device introspection is squarely a *shell/OS* concern, so it belongs in Swift. Two concrete payoffs:

- **Ripul unblinds its own native shell.** Today `device_console_logs` against the Ripul iPhone app returns the *web app's* console. Ripul's hardest bugs live in the part the web view can't see — the SwiftUI re-render jank, the `@Published`→WKWebView coupling, the swipe/animation state, glass rendering. A native device agent exposes the Swift side, so a CLI session sees **both halves** of the bridge in one device.
- **Any native iOS app becomes CLI-introspectable.** WAC already links the SDK and registers 22 native tools but is invisible to a CLI session. This makes it a first-class device.

---

## How introspection works today (and its two limits)

```
Claude CLI
  └─ MCP tool  device_console_logs / device_evaluate / …   (cli-tool-bridge-server.mjs)
       └─ host web app  window.__ripulPeerQuery(type, params, targeting)   (useRelayPeerQuery.ts)
            └─ relay  peer:query {requestId, originClientId, peerTarget}    (relayProtocol.ts)
                 └─ DEVICE web app  createMessageRouter → handlePeerQuery() (peerQueryHandlers.ts)   ◄── lives in JS
                      └─ (native data only) webkit.messageHandlers.agentBridge
                           └─ iOS SDK AgentBridge.getConsoleLogs / mcp:invoke (AgentBridge.swift)
                      ◄── peer:queryResponse {result, responderClientId}
```

**Limit 1 — capability is web-content-only.** `handlePeerQuery` answers about the *embedded web app*: its `console.*` (`AgentWebView.swift` injects the interceptor), its DOM (`queryElements`), its `fetch` log. The native hop is narrow: `NativeLogTee.swift` only shadows `NSLog` **inside the RipulAgent module**, so the buffer is the web app's console plus the SDK's own logs. The host app's `print`/`os.Logger`, its UIKit/SwiftUI view tree, and its *own* WKWebViews are all invisible.

**Limit 2 — transport requires a live web app.** The dispatcher and the relay peer identity (`clientId`) live in **web app JS**. So the "device" is really "an instance of the Ripul web app in a WKWebView," and it must be loaded and foregrounded. A headless native app (WAC with the panel closed; `RipulConfig.isAgentEnabled = false`) has no peer at all. iOS background suspension makes this worse.

> The macOS `host_*` path (`ClaudeCliServer.swift` localhost MCP) sidesteps the relay but is same-machine only — useless for reaching an iPhone, where the CLI isn't on the device. The [DevKit "iOS reality check"](../../docs/plans/devkit-self-hosted-dev-loop.md) confirms localhost/IPC/debug-protocol routes are all foreclosed on iOS. The only viable iOS transport is an outbound connection to the relay.

---

## Target architecture: a headless native Device Agent

Pull the relay peer + dispatcher down into Swift so the **app process** is the device. No agent UI, no web app needed.

```
Any iOS app (Ripul, WAC, third-party)
  └─ links ripul-ios-sdk
       └─ RipulDeviceAgent.start(appId:"wac-ios", identity:, auth:.siteKey(…))
            └─ DeviceAgentClient            outbound WS relay peer  (port of SessionChannelClient transport)
                 └─ DeviceIntrospectionRouter   native peer:query dispatch (Swift twin of peerQueryHandlers.ts)
                      ├─ console_logs    → RipulLog ring buffer (host routes its print/NSLog/os.Logger here)
                      ├─ view_hierarchy  → ViewInspectorOverlay.InspectedView serialized to JSON
                      ├─ native_state    → reflection (Mirror/KVC) over a registered root / picked view
                      ├─ evaluate_script → host-registered WKWebView ("main" = the app's own web view)
                      ├─ page_info       → host-provided current route/screen descriptor
                      └─ list/invoke     → the app's registered NativeTools (WAC's 22 for free)
```

Host adoption — a few lines, no UI:

```swift
RipulDeviceAgent.shared.configure(
    appId: "wac-ios",
    identity: .init(displayName: "Pete — WAC", installId: persistedUUID),
    auth: .siteKey(RipulConfig.siteKey, origin: RipulConfig.originHeader))
RipulDeviceAgent.shared.registerLogSource(RipulLog.buffer)          // console_logs
RipulDeviceAgent.shared.registerWebView(customWebVC.webView, as: "main") // evaluate_script target
RipulDeviceAgent.shared.registerTools(WACNativeTools.all)           // list/invoke
RipulDeviceAgent.shared.enableViewInspector()                       // view_hierarchy + native_state
RipulDeviceAgent.shared.start()                                     // connect as relay peer (dev/debug builds)
```

### Design choice: introspection capabilities are NativeTools

Everything except the raw log buffer is exposed as a `NativeTool` (the existing `ConsoleLogsTool`/`NetworkLogsTool` pattern). Why: the web dispatcher's `listTools`/`invokeTool` already forwards to native tools via `mcp:invoke`, **and** the macOS `DevToolsMCPServer` (extraction Ph3) serves the same tools. So a new introspection capability is reachable over *every* transport — `host_*` (localhost, macOS), `device_*` (relay-via-web-app, today), and the new headless relay peer — with no per-transport code. Auto-register them when the device agent / dev tools are enabled.

---

## What exists vs. net-new

| Piece | Status | Where |
|---|---|---|
| Web `console.*`/network capture into a buffer | ✅ exists | `AgentWebView.swift`, `AgentBridge.swift` (`consoleLogs`/`networkLogs`) |
| `ConsoleLogsTool` / `NetworkLogsTool` (built-in NativeTools) | ✅ exists (extraction Ph2) | SDK |
| Localhost MCP server (`host_*`, macOS) | extraction Ph3 (pending) | `DevToolsMCPServer.swift` (planned) |
| Relay peer:query dispatcher | ✅ exists **in JS** | `peerQueryHandlers.ts`, `createMessageRouter.ts` |
| `device_*` discovery/prefix/cache | ✅ exists | `FrameMCPBridge.ts` |
| Native WS transport (heartbeat, reconnect/backoff, stable clientId) | ✅ exists (for session sync) | `SessionChannelClient.swift` |
| View-hierarchy capture w/ reflection (text, image, control actions, property/ivar names, VC chain) | ✅ exists, **no network exit** | `ViewInspectorOverlay.swift` (`InspectedView`), `RipulViewExplorer.swift` |
| Native `NSLog` tee | ⚠️ exists but **module-private, SDK-only** | `NativeLogTee.swift` |
| **Public host log buffer** (`RipulLog`) | ❌ net-new | Phase A |
| **Native introspection NativeTools** (view hierarchy, native state, registered-webview eval) | ❌ net-new | Phase B |
| **Headless native relay peer** (`DeviceAgentClient` + `DeviceIntrospectionRouter`) | ❌ net-new | Phase C |
| **`appId` device targeting** on web/relay | ❌ net-new | Phase D |

---

## Phases

Ordered for incremental value: A–B deliver to Ripul immediately over the *existing* transports; C removes the web-app dependency (the real generalization); D–E are consumers. Each phase is independently shippable and testable.

### Phase A — Public native log capture (`RipulLog`)

**Goal:** the log buffer includes the **host app's** native logs, not just the embedded web app's console + SDK `NSLog`.

**What ships**
- `RipulLog.swift` (SDK): a public ring-buffer facade — `RipulLog.log(_:level:)`, plus `RipulLog.captureStdout()` / an `os.Logger` tee so existing `print`/`NSLog`/`os.Logger` call sites flow in with minimal host edits.
- Generalize `NativeLogTee.swift` from module-private to a host-routable sink that writes into the same `AgentBridge.consoleLogs` buffer `ConsoleLogsTool` already reads.

**What changes in Ripul:** route the native shell's logs (session list, swipe controller, glass) into `RipulLog`.

**How to test:** macOS — `host_console_logs` from the CLI returns native Swift log lines interleaved with web console. iOS — same once a transport exists (Phase C), or via the existing web-app path today.

**Status: pending**

### Phase B — Native introspection capabilities (over existing transports)

**Goal:** the agent can read the native view tree, native state, and evaluate against the app's *own* web views — reachable today via `host_*` (macOS) and `device_*` (relay-via-web-app).

**What ships (all as auto-registered NativeTools)**
- `view_hierarchy` — serialize `ViewInspectorOverlay.InspectedView` (className, frame, a11y id, text, image/SF Symbol, control actions, reflected property/ivar names, VC chain) to JSON. Two modes: full-tree dump (depth-bounded) and point/selector pick. The capture machinery exists; this adds the JSON exit it lacks.
- `native_state` — reflection (Mirror + KVC + `objc_getIvar`, reusing `ViewInspectorOverlay`'s extractors) over a host-registered root object or a picked view.
- `evaluate_script` — `callAsyncJavaScript` against a **host-registered** WKWebView (registry keyed by name, e.g. WAC's `CustomWebViewVC`), distinct from the agent's own web view.
- A `WebViewRegistry` on the bridge + `registerWebView(_:as:)`.

**What changes (web):** only if a capability shouldn't be a tool — none expected, since `invokeTool` already forwards to native tools. Confirm `peerQueryHandlers.ts` `handleInvokeTool` surfaces the new tools (it routes to AgentBridge native tools today).

**How to test:** Ripul macOS — CLI calls `host_view_hierarchy` and gets the live SwiftUI/UIKit tree; `host_evaluate_script(webView:"main", js:…)` runs against a non-agent web view.

**Status: pending**

### Phase C — Headless `DeviceAgentClient` (the reverse tunnel)

**Goal:** the app process is a relay peer with **no web app required**. This is the piece that makes WAC (and any native app) a CLI-selectable device and is the largest net-new chunk.

**What ships**
- `DeviceAgentClient.swift` — outbound WS to the relay, registering as a **peer** (not host). Reuse `SessionChannelClient.swift`'s transport (heartbeat, exponential-backoff reconnect, stable `clientId`); swap the session-sync framing for the peer-presence + `peer:query` framing.
- `DeviceIntrospectionRouter.swift` — Swift twin of `peerQueryHandlers.ts`: dispatch `peer:query` by type, self-skip (mirror `__ripulHostBridgeClientId`), stamp `responderClientId`, honor `peerTarget`. `consoleLogs`/`networkLogs` read the buffers; `listTools`/`invokeTool` hit the NativeTool registry; native types resolve to the Phase-B tools.
- `RipulDeviceAgent` facade — `configure`/`register*`/`start`/`stop`, gating (below), capability opt-in.

**Background note:** an outbound WS suspends when the app backgrounds, same as the WKWebView does today (the known 15s timeout). For a *debug* tool, "bring app to foreground" is the accepted behavior. The native peer at least keeps buffering logs and answers instantly on resume, and can use a short background-execution window. Silent-push wake is a later option, not a v1 requirement.

**How to test:** a blank SwiftUI app links the SDK, calls `RipulDeviceAgent.start()`, **never presents an AgentView**, and shows up in a CLI session's device list; `device_console_logs(device:"…")` returns its native logs.

**Status: pending**

### Phase D — `appId` device targeting (web/relay)

**Goal:** target a device *by app* from the CLI (`device:"wac"`), and make the device list legible when several apps are connected.

**What ships**
- `relayProtocol.ts`: add `appId` (+ keep `displayName`) to peer presence and allow it in the `PeerQueryCommand` selector.
- `useRelayPeerQuery.ts`: the device selector matches `appId` as well as display-name substring; the "Connected device(s): …" error string includes app names.
- `FrameMCPBridge.ts`: the `device_*` wrapper's `device` selector param documents app targeting. Discovery is already dynamic, so Phase-B/C tools appear automatically via `listTools`.

**How to test:** Ripul + WAC connected simultaneously; `device_console_logs(device:"wac")` and `device:"ripul"` each hit the right process.

**Status: pending**

### Phase E — Consumers

**Goal:** prove the loop end-to-end on the two reference apps.

- **Ripul** adopts the device agent to introspect its own native shell (Phase A logs + Phase B view hierarchy of `SessionsSheet`/swipe). Validates "both halves in one device."
- **WAC** (first external consumer): route `print`/`NSLog`/`os.Logger` into `RipulLog`; register `CustomWebViewVC`'s web view; `RipulDeviceAgent.start()` behind a dev/`isDeviceBridgeEnabled` toggle (independent of `isAgentEnabled`). Its `WACNativeTools.all` (22 tools) become `device_*` automatically. Bump the SDK version pin (currently `0.2.12`, git URL).

**How to test:** from a CLI session, pull live native logs and view hierarchy from the WAC iPhone app with the agent panel closed.

**Status: pending**

---

## Cross-cutting: security & gating

This evaluates JS and reads logs/state in a running app. Non-negotiable:

- **Build/flag gated** — DEBUG / TestFlight, or an explicit developer-mode toggle. Off in App Store consumer builds by default.
- **Auth-scoped** — keep the siteKey + `Origin` allow-list that already gates relay access. A device peer authenticates with the same scope.
- **Per-capability opt-in** — the host chooses which of `{console_logs, network_logs, view_hierarchy, native_state, evaluate_script, tools}` to expose. Default to read-only introspection; arbitrary `evaluate_script` is a separate opt-in.
- **Note the site-key constraint** — pure site-key embeds are restricted toward chat/files (`shouldUseSiteKeyTokenForApi`). Verify/define whether a site-key-scoped token may register a device peer; the native client needs its own relay auth path regardless.

## Open questions

- **Device-peer auth on the relay** — does the relay accept a peer that authenticates by siteKey alone (WAC's case), or is a device-scoped token needed? This gates Phase C/D.
- **Background wake** — is silent-push wake worth it for v1, or is foreground-only acceptable (it is for debugging)?
- **`native_state` surface** — how much reflection to expose, and how to bound it (depth, allowlist of types) so dumps stay useful and safe.
- **Selector ergonomics** — `appId` vs. display name vs. `clientId` precedence when multiple installs of the same app are connected.

## Relation to the other plans

| Plan | Relationship |
|---|---|
| [`devtools-sdk-extraction.md`](./devtools-sdk-extraction.md) | This is its continuation. That extracts web-content capture + localhost MCP; this adds native capture + relay transport. Phase B introspection tools follow that plan's built-in-tool pattern. |
| [`../../docs/plans/dynamic-mcp-tool-bridge.md`](../../docs/plans/dynamic-mcp-tool-bridge.md) | The bridge mechanics (`host_*`/`device_*` discovery, `__ripulPeerQuery`). This plan adds native handlers behind the same surface; discovery is unchanged. |
| [`../../docs/plans/devkit-self-hosted-dev-loop.md`](../../docs/plans/devkit-self-hosted-dev-loop.md) | This is the SDK-embed path (route #1) + reverse tunnel (route #2) for the audience that doc marks "not served" — native iOS apps. It extends DevKit reach from web-app-in-container to native-app-via-SDK. |
