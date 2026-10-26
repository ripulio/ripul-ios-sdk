# Native tools on a fresh simulator

A simulator developer build can expose its `RipulToolRegistry` through the local
Ripul Host before either the app or the Ripul console signs in. The in-app agent
keeps its existing bridge; both transports call `AgentBridge.invokeNativeTool`,
which applies the same audience and secure-input checks.
SDK screen tools also come from one shared factory. Cloud tool collections and
published macros still require their signed-in console and are not added to the
local connection.

In the host app, after its window is ready:

```swift
#if targetEnvironment(simulator) && (DEBUG || RIPUL_DEVELOPER_TOOLS || RIPUL_DEVELOPER_BUILD)
RipulSimulatorTools.start(registry: MyAppTools.registry)
#endif
```

Borrow a simulator with Trainyard, build and install the app, then launch it from
the agent's chat with:

```bash
node ripul-native-app/scripts/launch-simulator-tools.mjs <udid> <bundle-id>
```

The launcher reads `RIPUL_CHAT_ID` and `RIPUL_BRIDGE_PORT` (default 3456). If a
coding runtime has not supplied the chat variable, get its ID from `chat_context`
and set it explicitly. Never infer the chat from another agent's process.

The launcher prints a unique `simulator-local-…` device handle. Use that handle
with `device_list_targets`, `device_inspect_screen` and the app's discovered
`device_…` tools. Expand the ordinary MCP tool categories as needed. An explicit
`device_set_working_device` selection also works; releasing that local device
revokes its connection. Release the Trainyard simulator lease separately.

Developer tools are the default. `--test-end-user-tools` explicitly enables the
SDK's existing end-user testing mode for this connection: business tools act on
real app state and results are marked `absorbed`. This does not grant those
tools to an end-user channel or change another bridge's testing mode.

## Connection and boundaries

1. The launcher uses the Mac's existing local-host authorization to request a
   two-minute, single-use ticket, bound to its chat, simulator UDID and bundle ID.
2. `simctl launch` supplies the ticket and a loopback endpoint through environment
   variables. Credentials are absent from command arguments and launcher output.
3. The SDK exchanges the ticket for a per-connection credential, advertises its
   gated tool schemas and polls for work. There is no listener inside the app.
4. The host adds those schemas before normal MCP curation, across Claude, Codex
   and Antigravity. It routes calls only to the launching chat's connection.

Only the exact app connection endpoints accept the scoped app credential. It
cannot authorize general host requests. Relaunching rotates the connection and
device handle; a stale or disconnected target fails without choosing another
device. The connection is in memory, and a host restart requires relaunching
through the helper. Queued calls that time out are removed; delivered calls that
lose their reply report an uncertain outcome and are never replayed.

The entire SDK transport is compiled only for simulator developer builds. Both
the SDK store scanner and WAC's store scanner reject its marker in a binary.
`RIPUL_DEVELOPER_TOOLS` is sufficient for semantic tools; private touch injection
still needs the existing developer-build switch.

This connection does not bypass app authentication, operating-system permission
dialogs, secure inputs or tool-specific checks. It does not enroll physical
phones. Persona sign-in and other app automation commands can be registered as
developer `NativeTool`s separately and will then appear through both transports.
