# Native tool detail renderers

Tapping a tool lozenge in a supported native shell opens `ToolCallDetailsSheet`.
The sheet owns call selection, status, errors, and raw diagnostics. Its body uses
the SwiftUI library in `Sources/RipulAgent/ToolRenderers` on iOS and macOS.

The web library is the reference for content semantics:
`chrome-extension/src/logging/panels/components/renderers/registry.tsx` and
`resultRegistry.tsx`. Native layouts use native text, links, disclosure groups,
progress indicators, and image sheets rather than mounting the web components.

| Family | Native presentation |
| --- | --- |
| Bash, terminal/provider aliases | Command, working directory, output, labelled exit codes and stderr |
| Read, Write | Filename, full path, numbered source, read range in parameters |
| Edit, MultiEdit, apply_patch | Added/removed line diffs, individual replacement chunks or changed files |
| Grep, Glob | Pattern, search path, match count and rows |
| Host/device console logs | Severity, time, consecutive repeat counts, expandable stack traces |
| Device evaluate, executeCode | Reason, source, structured result |
| TodoWrite, update_plan | Progress and task states |
| Web search/fetch, HTTP | Query, URL, method, result links/snippets or Markdown response |
| Agent tools | Task description, Markdown prompt, response |
| Tool discovery, host status | Tool names/descriptions or machine/relay state with expandable fields |
| Screenshots/images | Image preview and enlargement |
| Other tools | Labelled values and expandable structured fields |

This is a read-only historical detail view. Opening it must never execute a tool,
answer a question, repeat speech, or change live task progress. Workflow-specific
web controls remain in the chat stream. Raw call/execution data remains available
under **Call information**.
Its JSON uses native syntax highlighting with light/dark palettes for keys,
strings, numbers, and literals. Highlighting preserves the original source;
selection and Copy retain its exact text, including escapes and large numbers.
JSON lines default to no wrapping and scroll horizontally. The local **Wrap**
switch in the code toolbar enables wrapping within the panel.

## Data contract and extension points

`toolCallDetails.ts` runs the existing web `normalizeToolCall` adapter and sends
`rendererName` plus `renderArguments`, retaining additional input fields. These
are optional in the native decoder so previously loaded clients still work with
the original `toolName` and serialized arguments/result. `NativeToolContent`
selects a renderer and unwraps MCP text/structured-content envelopes while
preserving recorded null, false, zero, and empty outputs.

To add a tool family, register names in `NativeToolRendererKind.resolve`, add its
view to `NativeToolCallRenderer`, and compose `NativeToolSection`,
`NativeToolCodeBlock`, `NativeToolParameters`, and `NativeToolValueView`. Keep
unconsumed parameters accessible. Code, diffs, matches, logs, and generic arrays
progressively reveal long outputs; copy actions retain the complete text.

Add a representative transport sample to `shared/tool-call-renderers.json`.
Both TypeScript normalization tests and Swift decoding tests use that fixture.
Codex patch samples include both raw patches and durable maps of changed files.
Hosted UI tests bundle the same fixture and render the actual SDK sheet.

## Checks

From `chrome-extension`:

```sh
npx vitest run src/logging/components/chat/v2/toolCallDetails.test.ts
node scripts/test-tool-groups.mjs
```

From `ripul-ios-sdk`:

```sh
swift test --filter 'NativeToolRendererTests|ToolCallDetailsTests'
bash scripts/test-host-screen-preview.sh <simulator-UDID> -only-testing:HostPreviewUITests/ToolCallDetailsUITests
```

Also build the native app's `RipulApp` (iOS) and `RipulMac` schemes against the
local SDK package. UI attachments cover commands, source, edits, Codex patches,
searches, logs, tasks, evaluation, and switching repeated calls.
