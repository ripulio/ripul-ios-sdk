# Native chat Markdown

`NativeChatMarkdown.swift` is the shared renderer for user and assistant messages,
thinking, questions and Markdown tabs. It parses one complete `MarkdownContent`
per source string, with a bounded cache, then applies a chat theme. Never split
fences before parsing: that loses list/quote nesting and reference definitions.

Sent user messages enable `NativeChatContextMentions`: serialized `[context: ...]`
tokens display as literal `@Title` text, and chat mentions become inline links.
CommonMark source positions restrict the transformation to prose; code, existing
links/images and escaped tokens remain examples. The message and its Copy action
retain the original token. Select text uses the readable display. Cache entries
include the mention mode so assistant examples cannot inherit user formatting.
Chat links send `openChatReference` through the existing native chat action bridge
to the web's shared navigator, including same-Mac, remote and direct-host routing.
This keeps navigation inside the active app when both Ripul and Alice are installed.

The theme follows the web chat's compact spacing in
`chrome-extension/src/logging/components/markdownThemeStyles.ts`: 8-point paragraph
gaps, modest headings, quote rules, table borders and row shading. Colours use
Ripul's semantic roles. MarkdownUI scales the base text with Dynamic Type.
`markdownSoftBreakMode(.lineBreak)` matches the web renderer's `breaks: true`.
Tables use the fork's opt-in adaptive column layout. The actual scroll viewport
width is measured, so tables also adapt inside quotes/lists and after rotation
or window resizing. A subtle width icon at the table's top-right corner offers
**Fit**, **Balanced** (default) and **Wide**, targeting 1, 1.5 and 2.5 times that
viewport. Short columns retain
their natural width; prose columns wrap to fit the selected budget. If readable
minimums cannot fit, columns wrap at those minimums and scroll only as far as
needed. Fit uses 44/320-point minimum/maximum column widths, Balanced 80/400,
and Wide 96/640. These limits include padding and scale with Dynamic Type.
The icon overlaps the top border within the existing table margin, without adding
a control row. On iPhone, its 44-point touch area covers the existing margin and
header; the visible capsule is only 28 by 18 points. It stays pinned while the
content scrolls and follows the actual table edge when a short table does not
fill the viewport. VoiceOver names the control "Table width" and announces the
current choice. Its `NativeRowState` value uses the fork's document-local
`markdownBlockPath`, preserving independent choices
across streaming and chat-row recycling, with height-cache invalidation.
Alignment follows
the Markdown column delimiters, text starts at the top of each row, and header
and alternate-row shading covers full cells.

On iOS 18 and later (including Catalyst), `NativeReplySwipeGesture` rejects
touches originating inside an enabled horizontal scroller before the message
can move or arm a reply. It checks the touched UIKit ancestry up to the gesture's
own view, including horizontal bounce and content insets. Both scroll limits
remain owned by the table; an edge drag never becomes a reply. This also covers
horizontally scrolling code. Normal message text and vertical scrolling keep
their existing gesture behavior. Cancelled or failed reply gestures reset the
message without triggering a reply.

Code blocks use `NativeToolCodeBlock` with compact chrome and unmodified source
for Copy. Language, content and nested position come from the Markdown parser.
The complete position scopes Wrap/Show more independently in the chat row's state
registry. Existing tool-result code panels keep their current presentation and
terminal cleaning. Highlighting still uses the bounded HighlightSwift engine.

## Streaming a block at a time (`-perfOn mdBlocks`, off by default)

An assistant message (its prose and its markdown tabs) can be drawn a top-level block at a time, so a streamed change lays out only the block that grew instead of the whole message. Launch a DEBUG build with `-perfOn mdBlocks` to switch it on; release builds and launches without it draw the whole message as one document, as before.

`NativeChatMarkdownBlocks.split` (in `NativeChatMarkdown.swift`) cuts the source only at a blank line where a cut cannot change what the whole message shows: outside a fence, display maths (`$$`, `\[`) and an unfinished HTML block, before a line at the left margin, and never between two items of one list. Anything uncertain stays in one block. Reference definitions apply to the whole message, so a block that may use one is parsed with all of them, and a block of definitions alone is not drawn. A block's text ends at its last non-blank line, so it is the same string once the text after it arrives: the parse cache returns the same tree and the block's equatable view is not drawn again. Spacing between blocks comes from the same margin table the theme uses (`NativeChatMarkdownBlocks.margins`). Code blocks and tables keep their state under a `block:<n>` scope, since each block's own block paths start from zero.

`NativeChatMarkdownBlocksTests` checks that the blocks render the same HTML as the whole message across fences, loose lists, indented continuations, maths, HTML comments, reference links, tables and setext headings, and that every block before the growing one is already final at each character of a streamed message.

## Maintained dependency

The SDK pins `ripulio/swift-markdown-ui` to a release. The fork starts at upstream
2.4.1 and keeps its MIT licence. `RIPUL.md` in that repository describes the patch:
stable block-view positions during streaming, a nested `blockPath` on code-block
configuration, correct language extraction from a fence's info string, and
adaptive table layout with cell alignment exposed to the theme, a minimum-width
overflow policy, and read-only access to the current block path.
App-specific styling lives here rather than in the fork.

## Checks

- `NativeChatMarkdownTests`: nested and longer fences, continued list numbering,
  reference links across code, an incomplete streaming fence, the parsed table
  tree, and real macOS scroller widths in a 320-point message.
- `NativeChatTableLayoutTests`: the real app theme in hosted macOS views, covering
  a compact numeric column alongside wrapping prose, resizing, a long code path,
  wide-table scrolling and larger rendered text. macOS hosted tests increase
  the font directly; check iOS Dynamic Type categories on the phone.
  The native macOS menu is exercised directly to verify the three layouts,
  row-height invalidation and independent nested-table choices after streaming
  and unmount/remount.
- Fork `ChatDocumentTests` and `StreamingCodeBlockTests`: parser edge cases and
  real macOS SwiftUI view reuse while nested and top-level code changes.
- Fork `AdaptiveTableTests`: measured cell and text bounds, left/center/right
  alignment, row heights, wide tables, empty/header-only tables and RTL order.
- `ripul-native-app/Tests/ReplySwipe`: UIKit touch routing, real SwiftUI scroll
  hit-testing, rightward direction filtering and cancellation handling. These
  checks do not replace a physical table-scroll/reply trial on the phone.
- The full iPhone build checks the production SwiftUI integration. On the phone,
  compare a native message with its web version in light/dark appearance: headings,
  single newlines, nested lists/quotes, tables, code Copy/Wrap and streamed replies.

The custom `mermaid`, `report` and `steps` fences use the native components
described below. Arbitrary HTML layouts are not rendered.

## Feedback regression pass, October 2026

The fork is pinned to `2.4.2-ripul.5` (`70101ea`). It fixes spaces lost after
styled spans at line starts, avoids deeply nested SwiftUI Text concatenation,
and bounds very long paragraphs at existing rendered line breaks. The latter
also addresses a measured accessibility snapshot stall with 1,200 linked lines.
Mixed image paragraphs now flow real image views. The app opts into
`markdownInlineImageFlow()` for headings and cells too, retaining image links,
alt labels and fitting widths even inside nested emphasis.

Tap a message's **Select** action to open one continuous native text view. Its
source is a value snapshot, so a streamed update cannot invalidate the selection.
Selection crosses paragraphs, lists and tables; table cells copy as tabs.
**Copy** publishes plain text and RTF (including bold, italic, code and links).
**Reply** uses the selected text with the existing reply excerpt limit. **Select
all** is explicit because the read-only UIKit context menu does not consistently
offer it. The ordinary message Copy action still copies the original Markdown.

Inline `$…$` / `\(…\)` and display `$$…$$` / `\[…\]` math use native
[SwiftMath](https://github.com/mgriebling/SwiftMath), exactly version 1.7.3, with
its MIT notice bundled. Delimiters are protected before the whole document is
parsed; fenced/indented code, code spans, image alt text, link destinations,
escaped dollars and ordinary prices remain literal. Unclosed streaming math
stays visible; unsupported or excessive expressions show their original notation.
The raster cache is bounded, follows font size and semantic colour, and checks
formula dimensions before allocating a bitmap. Long formulas scroll within the
message instead of reducing the font size. Their accessibility label is the
original notation, not a semantic spoken-maths translation.

Verification uses two standalone apps: the fork's `Examples/RegressionLab`
(6 UI checks, including actual image/link taps and Dynamic Type) and this repo's
`ripul-native-app/Tests/MarkdownFeatures` (6 hosted checks and 2 UI checks for
cross-paragraph selection, RTF round trips, reply, math parsing/rendering and
actual equation bounds). The original 15 SDK Markdown/table/state checks and
68 applicable fork checks pass; the previously reproduced upstream Font equality
failures remain excluded. The seven-level nested-list fixture did not reproduce
the reported freeze. No screenshots or physical VoiceOver approval are claimed.

Textual was evaluated but not adopted: its current minimum platforms exceed
this SDK's iOS 17 / macOS 14 support. Retaining MarkdownUI also keeps the tested
per-table state, native code controls and horizontal gesture ownership.

## Native fenced extensions

`NativeMarkdownFencedBlock` dispatches parsed code blocks by language; it does
not split the Markdown source. All extensions retain the original fence's full
`blockPath` scope, so nested and identical blocks have independent UI state.
Ordinary and unrecognized languages keep the existing Copy/Wrap/Show more panel.

- **Mermaid:** MermaidKit 2.9.0 (MIT notice bundled) parses, lays out and draws
  natively. A serialized worker coalesces streamed changes, renders off the main
  thread and caches by source, semantic colours and Dynamic Type scale. The
  vector size preflight limits bitmap allocations before rendering. A bounded
  inline preview opens the shared UIKit image viewer for pinch, double
  tap and pan; the Mac has a zoom slider. Source and Copy remain available.
  An open sheet holds a snapshot while the original message streams. Unsupported
  input, parser diagnostics for dropped flowchart statements and excessive input
  remain readable as source. The engine covers core Mermaid syntax, not every
  mermaid.js feature: styling/click directives are ignored in favour of the app
  theme, and no diagram-supplied script or network request runs. VoiceOver gets
  the engine's diagram description. This is native-app support; the web chat
  still renders Mermaid as code.
- **Report:** the web report JSON contract becomes native headings, statistics,
  proportional bars, notes and a full data table. Normalization uses the same
  limits and scales amount-only bars against the report's maximum. JSON work
  runs on a serialized worker and streamed edits are coalesced. Streaming
  reports show only completed JSON values, with no export controls until
  complete; invalid payloads fall back to source. Chat previews are bounded;
  the full report uses reusable List cells and the table uses lazy rows.
  Export shares the complete CSV or a printable, escaped HTML document through
  the system share UI. `download: false` hides export controls. The web's
  optional WAC host to-do/auto-add hooks are not part of Ripul's chat and are
  not invoked by viewing a native report.
- **Steps:** a native disclosure labelled “How this is worked out”, initially
  closed, with literal selectable text matching the web contract. Its expanded
  state uses `NativeRowState`, survives streaming/remount and invalidates the
  chat row's cached height.

`ripul-native-app/Tests/MarkdownExtensions` is the standalone simulator app for
these production components. It exercises rendering and actual controls without
screenshot comparisons; see its README for the build and test command.
