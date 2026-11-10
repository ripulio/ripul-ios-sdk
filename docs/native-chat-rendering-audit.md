# Native chat rendering audit — 27 October 2026

## A seventh gap: context attachments sent from the composer

Found by Peter after the six fixes below shipped, on another participant's
message with an Inspector element attached. The SDK sends picked context (an Inspector element, the
current screen, saved instructions) as a text envelope after the typed words:
`User-selected context attachments (…):` and a JSON array
(`RipulContextAttachment.message`). Web chat splits it off before parsing XML
context tags (`parseComposerContextAttachments`) and draws each record as an
expandable card (`ComposerContextAttachments.tsx`). The forwarder sent the
whole text as `content`, so native chat drew the JSON inside the bubble.

The forwarder now splits the envelope in the same order as the web and sends
`contextAttachments`. Each item is labelled by `composerContextAttachmentDisplay`,
the function the web card also uses, with title, source line, icon kind and
scope. Native draws them under the words as `NativeContextAttachmentCard`:
closed to title and source, open to scope, capture time and the attached text.
Lettered elements (`Element A — …`, since 30 September) were labelled "Screen
context" on the web, because its check expected the unlettered `Element — `
title. Both now say "Screen element". Copy, Reply and Select use the words
without the envelope, as on the web.

Fixtures `context-attachment` (the message from the report, byte for byte) and
`context-attachment-only` in `shared/native-chat-rendering.json` go through the
real forwarder and the Swift store. Composer prompt history still records the
envelope: `obs_mvqji6n9_b5c26cb3`.

## Fixes following the audit

The six findings below now have implementations and regression coverage. The
native bridge normalizes the tool's row-array table contract, including row
links, and forwards video attachments. Native chat displays table actions,
picture choices and recordings with playback controls, posters and unavailable
states. Players start on demand and stop when their row disappears.

Native Markdown renders file citations as readable links, groups adjacent
sources into a native source sheet, and shows partial references as `Source…`.
File links and source-sheet selections use the existing host-aware file viewer
through `openFileReference`, including line ranges and source chat identity.
Participant slugs become readable names with separate device labels. Code,
escaped examples, link destinations and raw Copy retain their original text.

`shared/native-chat-rendering.json` is exercised by both the actual TypeScript
forwarder and the Swift message store/parser. Additional checks cover streaming,
malformed syntax, file URL routing, unavailable playback and narrow media layout.
Validation: 98 web checks and TypeScript checking pass; 37 native Markdown,
layout and state checks pass, including the eight new rendering tests. After
integrating the current performance work, 41 focused native/state checks pass.
The native theme-token gate reports no violations.

Web support is live as **mvqep5cq** from train `4486`. The downloaded
`js/chunk-static-6NYJA6FO.js` matches the build byte-for-byte and contains the
new file action and video projection (SHA-256
`63847a64e16ba7e44011501d0d57867c4b73bad2d37f22ba83a8fc76f9eb993a`). The combined
train reported failure because the separate worker D1 migration received
Cloudflare 7403. These fixes require no worker change. Evidence:
`/tmp/ripul-rendering-fixes-web-live.json`.

Train `4489` shipped **202610270815** from `065801df9`. Both Ripul
(`io.ripul.app`) and Alice (`io.ripul.app.alice`) were signed, installed on
Peter's iPhone 17 Pro Max, read back as installed and launched. Both OTA
manifests and downloaded IPAs were also verified; the builds are available in
Settings > Advanced > Builds. The release receipt reports `complete`, with
`installed-verified` for both direct installations and `published-verified`
for both OTA publications:
`/Volumes/WD Black 4TB/Xcode/RipulBuildCaches/tmp/ripul-ship-ios-_a3r5eli/result.json`.
The initial archive's theme checks were corrected before delivery.

No screenshot or simulator visual verification was performed. Phone playback,
source navigation and picture-choice appearance remain for Peter's hands-on
check, tracked in `obs_mvq1fj6k_1ffa4107`.

## Original audit

Six additional gaps were found after fixing sent-message `@chat` references.
This audit compares the full `NativeChatView` scroller with web chat at
`3c0fc461d`. It does not compare the separate native interaction embed used
inside the web console. `AgentView.swift` mounts the full native scroller over
the web view; `nativeChatMessageForwarder.ts` supplies its messages.

The audit used the real TypeScript forwarder, web renderers/click handler and
Swift Markdown parser. Seven web probes and three Swift probes passed while
asserting the **observed gaps**, not the desired behaviour. View and URL-handler
source traces complete the evidence below. No phone UI or tap verification was
performed for this audit. These findings are not a claim of exhaustive visual
parity, and no production fixes are included in the audit commit.

Rechecked after the concurrent native performance changes through `6e2012b0f`
landed: the same ten probes passed on `c19efc87e`, and all six gaps remain.
Line references below refer to the original audit baseline.

| Finding | Web | Full native chat | Priority |
| --- | --- | --- | --- |
| Structured interaction tables | Rows, columns and row actions | Table omitted by the bridge | High |
| Video attachments | Playable recording | Attachment omitted; media-only message becomes a generic placeholder | High |
| Picture choices | Image cards | Labels and descriptions without pictures | High |
| File citations | Filename link or grouped Sources pill | Raw `:codex-file-citation{…}` text | High |
| Local file links | Opens the host file viewer at the requested line | Falls through to the system URL action | High |
| Participant mentions | Readable name/device pill | Underscore wire name remains visible | Medium |

## 1. Structured interaction tables are dropped

The interaction tool handlers and web `AgentQuestionRequest` use an array of
row objects. For example, an `askUserMultiChoice` action carries:

```json
{
  "question": "Current status",
  "options": [{ "label": "Alice", "value": "alice" }],
  "table": [{ "Name": "Alice", "Status": "Ready", "_link": "https://example.com/item" }]
}
```

The actual native forwarder returns `askUser.table: null`, no top-level `table`,
and no `Ready` cell or row link. Its extractor only accepts the incompatible
`{columns: [...], rows: [...]}` shape. A control probe with that shape preserved
the rows. The web table derives headers from the first row and handles `_link`
and matching choice options.

Start in `chrome-extension/src/hosted-app/nativeChatMessageForwarder.ts`,
`extractInteraction` (line 547), and compare
`chrome-extension/src/LLM/Tools/DecomposedUserInteractionHandlers.ts` (line 61)
with `chrome-extension/src/logging/panels/UnifiedAgentQuestionPanelProviderReact.tsx`,
`AgentQuestionRequest.table` (line 218) and `TableRows` (line 2141).
Markdown pipe tables are a separate path and are already supported.

Observation: `obs_mvq2qcif_d073316f`.

## 2. Video attachments never reach the native view

Reproduction: a `respondToUser` action with `data.question: ""` and:

```json
{
  "videoAttachments": [{
    "id": "recording-1",
    "url": "https://example.com/recording.mp4",
    "posterUrl": "https://example.com/poster.jpg",
    "name": "Demo", "width": 640, "height": 360
  }]
}
```

Put that object in the action's `payload`. The actual web `AssistantVideos`
component renders a `<video>` with the URL and controls. The native forwarder
emits empty content and `label: "respondToUser"`, without the video URL or
attachment. Native message types and the row have only image attachments, so
the row reaches its generic label fallback. This is missing content, not a
different player design.

Start in `chrome-extension/src/logging/components/chat/AssistantVideos.tsx`
(line 18), the forwarder's assistant enrichment (line 1779), and
`ripul-ios-sdk/Sources/RipulAgent/NativeChatView.swift` (line 1801).

Observation: `obs_mvq2qdkr_e450bdab`.

## 3. Picture choices lose their pictures

Reproduction: an `askUserMultiChoice` question with this option:

```json
{ "label": "Blue design", "value": "blue", "image": "https://example.com/blue.jpg" }
```

The web `ChoiceCard` renders an image. The forwarder preserves the exact image
field (probe verified), and `NativeAskUser.Option` stores it. However,
`NativeChatView.questionOptionRow` never reads `opt.image`; it draws only the
selection control, label, description and value. A visual design/product choice
therefore loses the information needed to choose.

Start in `NativeChatView.swift` (line 2124),
`NativeChatMessageStore.swift`, `parseAskUser` (line 1321), and the web
`UnifiedAgentQuestionPanelProviderReact.tsx`, `ChoiceCard` (line 2391).

Observation: `obs_mvq2qdt0_30ee8aec`.

## 4. File citations expose their storage syntax

Reproduction in assistant prose:

```text
See :codex-file-citation{path="/Users/me/project/App.swift:12" purpose="source"} for details.
```

The web parser produces the readable `App.swift:12` source link. The forwarder
retains the directive, and the native parser's plain text is exactly the input;
its HTML contains no link. Native preprocessing covers context mentions and
maths, but has no equivalent of `ensureFileCitationRenderer`.

Start in `chrome-extension/src/logging/components/markdownFileCitations.ts`
and `ripul-ios-sdk/Sources/RipulAgent/NativeChatMarkdown.swift` (line 19).
The eventual fix also needs grouped citations and partial streaming tokens;
code examples and escaped directives must stay literal.

Observation: `obs_mvq2s5vc_4835731d`.

## 5. File links bypass Ripul's file viewer

Reproduction:

```markdown
[App.swift](/Users/me/project/App.swift:12)
```

The web click probe emitted `FileViewerOpen` with
`{filePath: "/Users/me/project/App.swift", line: 12, chatId: "chat"}`.
The native Markdown parser retains the destination, which has no URL scheme.
The native `openURL` handler handles chat-reference links and secure-connection
links, then returns `.systemAction`; it has no file-viewer bridge action.
A source-Mac path consequently bypasses the host-aware file navigation.
The exact visible result of tapping on an iPhone was not measured.

Start in `ripul-ios-sdk/Sources/RipulAgent/NativeChatView.swift` (line 71) and
`chrome-extension/src/logging/components/markdownLinks.ts` (line 66).
Reuse the existing web file-location parser and viewer route so line ranges,
paths containing spaces and source-chat/host context remain consistent.

Observation: `obs_mvq2s63i_9d4d9d47`.

## 6. Participant mentions retain wire names

Reproduction in a sent user message:

```markdown
**Hello @Peter_Maude_(Mac)**, please review.
```

Web renders `@Peter Maude` in a participant pill with a separate `Mac` label.
The forwarder keeps the source unchanged; the real native parser with
`contextMentions: true` renders `Hello @Peter_Maude_(Mac), please review.`
The context-token fix does not humanize participant slugs.

Start in `chrome-extension/src/logging/components/chat/UserMessageMarkdown.tsx`,
`chrome-extension/src/LLM/multiParticipant/participantMentions.ts`, and
`ripul-ios-sdk/Sources/RipulAgent/NativeChatContextMentions.swift`.
Preserve code, email addresses, link destinations and raw-message Copy when
adding native participant display.

Observation: `obs_mvq2s6be_e169fc1e`.

## Evidence and exclusions

The temporary web probe suite exercised citation DOM, participant DOM, the
normal table contract and an alternative-shape control, a rendered video,
picture-choice forwarding, and the file click event. The Swift suite exercised
raw citation text, raw participant text and the retained file-link destination.
All ten checks passed. Local logs:
`/tmp/ripul-rendering-audit-web-final.log` and
`/tmp/ripul-rendering-audit-swift.log`. Temporary probes were removed from the
worktree after verification; the fixtures and observed outputs are recorded
above so later fixes can turn them into regression tests.
The second run is recorded in `/tmp/ripul-rendering-audit-recheck-web.log` and
`/tmp/ripul-rendering-audit-recheck-swift.log`; temporary probe sources were
archived in `/tmp/ripul-rendering-audit-probes`.

Existing native support covers ordinary Markdown including pipe tables,
maths, Mermaid, steps/report fences, tab content and image attachments.
User notes are plain text on both surfaces. Arbitrary HTML layouts are a
documented native limitation. WAC report to-do hooks are explicitly excluded
from Ripul chat. Those were not counted as newly discovered defects.

The common cause is separate display pipelines: web-only token extensions,
bridge field/shape drift, and native views that do not consume every field.
The existing native parity UI test does not exercise these web-contract
fixtures. Add shared real message fixtures spanning forwarder, native store,
native rendering and navigation when fixing the gaps.
