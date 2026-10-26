# Native chat Markdown

`NativeChatMarkdown.swift` is the shared renderer for user and assistant messages,
thinking, questions and Markdown tabs. It parses one complete `MarkdownContent`
per source string, with a bounded cache, then applies a chat theme. Never split
fences before parsing: that loses list/quote nesting and reference definitions.

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

Code blocks use `NativeToolCodeBlock` with compact chrome and unmodified source
for Copy. Language, content and nested position come from the Markdown parser.
The complete position scopes Wrap/Show more independently in the chat row's state
registry. Existing tool-result code panels keep their current presentation and
terminal cleaning. Highlighting still uses the bounded HighlightSwift engine.

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
- The full iPhone build checks the production SwiftUI integration. On the phone,
  compare a native message with its web version in light/dark appearance: headings,
  single newlines, nested lists/quotes, tables, code Copy/Wrap and streamed replies.

This does not reproduce web-only custom fenced widgets (for example report/steps)
or arbitrary HTML layouts; those require their own native component integration.
