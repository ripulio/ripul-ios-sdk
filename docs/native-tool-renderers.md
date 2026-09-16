# Native tool detail renderers

Tapping any tool lozenge in a supported native shell opens `ToolCallDetailsSheet`
with every tool call in that row, including other tool kinds. The title is
"Tool calls" and membership follows the row's original call order, independent
of which lozenge was tapped. Browser details use the same independent disclosure
list. Changing labels or merging lozenges does not replace an open request.
The sheet lists calls newest first as independent disclosures, retaining their
original call numbers. Panels use the Files screen's shared glass background,
rounded corners and leading chevron. Each header shows a status badge, action
title, tool icon and a secondary command, file path, query or task summary.
The most recent call belonging to the tapped lozenge starts open and scrolls into
view, with every other call still in the list. The bridge supplies its stable
`initialCallId`; missing/removed targets fall back to the latest call in the row.
This initial focus never reopens or scrolls a call on streaming updates.
Any number of calls can stay open together. Live
results preserve expansion choices, and newly arriving calls start closed.
New panels slide and fade in at the top while existing panels move down over
0.35 seconds. The animation tracks call IDs, so result updates do not replay it
or change the initial focus. Reduce Motion disables the arrival animation.
Closed calls do not construct their output renderers or run syntax highlighting.
The sheet owns expansion, status, errors, and raw diagnostics. Its body uses
the SwiftUI library in `Sources/RipulAgent/ToolRenderers` on iOS and macOS.

Shell calls use the executable as their display identity: Python, Node, Xcode,
Grep and the existing Git action labels. Claude Bash, Codex exec_command/shell
aliases and Gemini run_command share the web normalizer. Chat badges group by
that identity and send the same label, native symbol, colour and command summary
in `commandPresentation`. When a row would show more than five distinct lozenges,
compound shell lozenges use their first meaningful executable and merge matching
labels/counts. This threshold is calculated before compaction, includes ordinary
tools, and counts lozenges rather than executions. It is not a five-item cap:
distinct first commands remain distinct. Detail disclosures always retain full
command identities. Swift does not independently parse shell syntax.
Lozenges show a count badge only when they represent more than one call.
Descriptions supply the action summary; literal inline scripts otherwise show
their language and line count. The native script view highlights that language
and retains the original shell invocation under Call information.

The bounded, display-only scanner respects quoted words and heredoc bodies and
unwraps literal sh/bash/zsh -c/-lc payloads. Compound commands retain one call,
status and output, with a combined label such as Python + Status. Unsupported
shell constructs keep a generic identity. Only standalone literal interpreter
input is extracted as source; redirects, expansions and compound commands keep
their command context. Raw arguments, invocation IDs and results are untouched.
The shared command display starts a new line after top-level `&&`, `;`, `|` and `|&`, with
the operator retained on the preceding line. Quoted patterns, inline scripts,
heredoc bodies and existing line breaks keep their formatting. Commands sharing
a heredoc opener line stay together so its input remains intact.
The web parser also supplies zero-based `commandBreakLines`. Native command
blocks place system dividers at those boundaries while keeping one full-command
Copy button and one highlighting pass. The optional `commandPipeLines` subset
marks pipe-input boundaries: these dividers contain a downward arrow and
"Piped input", distinguishing them from the plain sequential dividers. Browser
disclosures use the same boundaries and labels. Quoted pipes, heredoc bodies
and `||` are not pipeline dividers. Script lines and terminal output are not
divided into commands. Progressive reveal keeps copying the complete command.

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
| Host/device console logs | Searchable captured logs, severity filters/counts, newest/oldest ordering, repeat groups, expandable messages and stack traces, filtered Copy |
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
Source blocks use HighlightSwift (bundled highlight.js via JavaScriptCore), with
GitHub light/dark themes and native attributed text. File extensions select the
language; evaluation calls use JavaScript and terminal commands use Bash.
Terminal output uses automatic language detection, including string results and
nested stdout/stderr/output fields. Guesses scoring at most 5 on highlight.js's
relevance scale remain plain text; the score is a heuristic, not a probability.
Detection runs on the revealed text as one block, so mixed-language command
output receives a best guess rather than guaranteed per-file grammar selection.
Diffs highlight the before/after source separately, retaining addition/removal
backgrounds. Call information uses the same engine in JSON mode.
Highlighting preserves the original source;
selection and Copy retain its exact text, including escapes and large numbers.
Commands, scripts, file contents, text output and JSON default to no wrapping
and scroll horizontally. Each panel's local **Wrap** switch enables wrapping
within that panel, independently of the other input/output panels. Toolbars and
command dividers stay within the panel width. Copy retains the complete text
in either mode, and live text updates retain the selected wrapping mode.

The shared engine runs asynchronously, with cancellation checks and a bounded
cache (16 results / 500 KB of source). Only revealed lines are highlighted,
together so multiline syntax keeps its context. Read-tool line-number prefixes
are excluded from tokenization and restored unchanged. Unknown file types,
highlighting failures, and visible blocks over 100 KB remain plain text.
The adapter transfers colours onto the original source to protect whitespace,
escaping and numeric precision from the library's HTML conversion. Scripts being
displayed are never evaluated and no native execution bridge is exposed.

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

Console browsing only filters the recorded result; it never fetches more logs or
changes the host's logging settings. Count summaries distinguish captured entries
from the total buffer. Level chips count entries, including folded repeats. Search
matches messages and stack traces; consecutive groups are formed before filtering
so separate occurrences stay separate. Rows retain their original identities when
filtering or reversing order. Copy includes every matching entry and its timestamp
and stack, including folded repeats and rows beyond the progressive reveal limit.
Host/device tool names with single- or double-underscore MCP prefixes select the
same native renderer, including when canonical renderer metadata is absent.

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
swift test --filter 'NativeSourceHighlightingTests|NativeToolRendererTests|ToolCallDetailsTests'
bash scripts/test-host-screen-preview.sh <simulator-UDID> -only-testing:HostPreviewUITests/ToolCallDetailsUITests
```

Also build the native app's `RipulApp` (iOS) and `RipulMac` schemes against the
local SDK package. UI attachments cover commands, source, edits, Codex patches,
searches, logs, tasks, evaluation, and viewing repeated calls together.
