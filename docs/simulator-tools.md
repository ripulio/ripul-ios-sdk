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

Borrow a simulator with Trainyard, build and install the app, then connect it
from the agent's chat with the MCP tool every Claude, Codex and Antigravity chat
on the host has:

```
device_connect_simulator_app { simulator: "<udid or exact name>", bundleId?: "<bundle id>" }
```

The host does the launch itself (`macOS/SimulatorToolConnect.swift`), so it works
from any repository, with the chat taken from the call. It refuses a simulator
another chat has borrowed, and an app whose binary lacks the transport (it looks
for `RIPUL_SIMULATOR_TOOLS_TICKET`, as the store scanners do) before launching
anything. Leave out `bundleId` when only one installed app has the transport. It
returns the unique `simulator-local-…` handle and the app's tools, and makes the
connection the chat's working device (`makeWorkingDevice: false` keeps the old
one; then pass the handle as `device` on every call). The result's shape makes
the tool bridge re-list at once, so the app's `device_…` tools are callable in
the same turn. Releasing the local device with `device_set_working_device`
revokes its connection. Release the Trainyard simulator lease separately.

`device_list_targets` adds `simulatorApps`: the apps in booted simulators that
have the transport, whether this chat has connected each, and who has borrowed
its simulator. The agent guide (`chrome-extension/public/guides/devices.md`,
"Apps in a simulator") and the SDK guide (`sdk.md`, "Letting agents drive a
simulator build") say the same for agents in other people's repositories.

## A simulator borrowed from another Mac

A simulator borrowed with `ripul-train acquire simulators … --borrow` runs on
the Mac that lent it (docs/plans/work-follows-room.md, "Simulators from any
Mac"). `device_connect_simulator_app` takes its UDID, or the name of one this
chat borrowed, as it takes a local one (`macOS/SimulatorToolBorrowed.swift`):

- The host asks Trainyard (`POST /pool/borrowed` on its socket) whether the
  UDID is borrowed, and from which Mac. It refuses one another chat borrowed.
- The apps and the check for the transport are read on the lender
  (`POST /pool/borrowed/tools`, `op: apps`).
- The host makes its ticket as for a local launch. Trainyard launches the app
  there with that ticket and a loopback address on the lender, and carries the
  app's requests back to this host and the answers there, sealed on the Macs'
  direct line (`ripul-native-app/macOS/trainyard/fleet-simtools.mjs`). The
  connection, its chat and its tools are this host's, as for a local
  simulator, and the device tools reach the app in the same way.
- The answer is the same, plus where it ran: `ranOn` and `simulator.machine`.
  The target's label says "simulator on <Mac>", and every answer from the app
  carries `_simulatorMachine`, which the chat's picture-in-picture uses.
- `device_list_targets` lists the apps on this chat's borrowed simulators in
  `simulatorApps`, each with its `machine`.

A restart of the lender's Trainyard ends the line: connect again. Each call
crosses the direct line twice more than a local one.

## An app without the SDK, or the whole screen

`device_connect_simulator_app` with the `bundleId` of an app without the
transport (a store build, an older version, Apple's own apps), or with
`wholeDevice: true`, starts the device runner on the simulator instead
(`ripul-native-app/device-runner`, "A device for an agent's chat"). The
runner is a UI-test bundle: it takes the same single-use ticket for the chat
(bundle id `io.ripul.runner`) and talks to the host by the same routes, and it
answers `inspect_screen`, `tap_element`, `type_text`, `touch`,
`wait_for_element` and `set_value` with the same vocabulary as an SDK app,
plus `swipe`, `alert`, `press_button`, `launch_app`, `terminate_app` and
`screenshot`. Its element tree is XCUITest's, so it has no view controllers or
outlets, and an app's own tools come only through the SDK. `arguments` opens
the app named with launch arguments. It works on a borrowed simulator too, and
releasing the device stops it.

From a shell in this repository, the launcher does the same:

```bash
node ripul-native-app/scripts/launch-simulator-tools.mjs <udid> <bundle-id>
```

It reads `RIPUL_CHAT_ID` and `RIPUL_BRIDGE_PORT` (default 3456). If a coding
runtime has not supplied the chat variable, get its ID from `chat_context` and
set it explicitly. Never infer the chat from another agent's process. It prints
the handle, and does not change the working device.

Developer tools are the default. `--test-end-user-tools` explicitly enables the
SDK's existing end-user testing mode for this connection: business tools act on
real app state and results are marked `absorbed`. This does not grant those
tools to an end-user channel or change another bridge's testing mode.

## Connection and boundaries

1. The host makes a two-minute, single-use ticket bound to the chat, simulator
   UDID and bundle ID: in-process for the tool, or for the launcher through the
   Mac's existing local-host authorization.
2. `simctl launch` supplies the ticket and a loopback endpoint through environment
   variables. Credentials are absent from command arguments, tool results and
   launcher output.
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

## Live verification — 26 October 2026

Verified after the shared host restart with SDK `0.7.182`, host implementation
`13c477b81`, and WAC Dev `com.dev.WAC` version `3.0.0`, build `202610262020`.
The simulator was created for this check, with no copied app data or Ripul login.
The app was still at `DevBackendPickerVC`, with its first-launch ATT prompt
pending. The launcher registered a unique local handle and 35 developer tools
without `--test-end-user-tools`.

Through the normal MCP tools, `device_list_targets` listed the local simulator,
`device_inspect_screen` returned the server picker's native controls,
`device_backend_endpoint` reported the build-default backend, and
`device_get_app_diagnostics` confirmed the installed bundle and build. Discovery
and a backend-status invocation also passed through both native host MCP routes
(Claude on port 3456 and Codex on port 3458).

Releasing the explicit local handle removed it from discovery. A subsequent
backend-status call using that handle failed with “Nothing ran”; the chat's
existing working device was unchanged. The Trainyard simulator lease was then
returned. This verifies the connection and native tool transport, not WAC
sign-in or dismissal of operating-system prompts.
