# Inspector

Inspector uses one floating native panel and one selection across UIKit, SwiftUI
and HTML inside a WKWebView on iOS and Catalyst. The Tools menu, Settings,
solution management and the chat title double-tap launch the same window.
Browser and native macOS clients use the web Inspector.

Single-tap the chat title to expand or collapse it. Double-tap opens Inspector
and preserves the title's expanded state. The single tap waits for the system's
double-tap recognition window; the expanded title's navigation buttons retain
their own actions.

Drag to aim on a touchscreen, or move a mouse/trackpad pointer. Tap to pin the
selection. **Activate** explicitly presses the selected control; selecting it
does not press it. **Back**, **Parent element** and the Tree tab navigate the same
selection. Folding the panel or choosing **Interact with app** returns touches
to the app while retaining the selection. Unfolding/resuming refreshes it.

Identity, Layout, Appearance and Tree share the panel. Native selections retain
theme token editing, audit and macro recording. Web selections expose CSS layout
and appearance edits and an Eval tab, where `$0` is the selected DOM element.
Web CSS edits change the current page; they are not source-code changes.

**Add to chat** freezes a selection snapshot and opens the existing context
preview. The user chooses description, screenshot and optional recognized text,
then attaches it to the chat that opened the Inspector. Nothing is sent until
the message is sent. The composer's **Selected element** option uses the same
selection. Removed elements fail explicitly rather than resolving a replacement
with the same identifier. Editable web elements are excluded from context;
editable descendants are masked in screenshots and suppress aggregate text.

## Implementation

`InspectorSession` owns selection, history, pinning and DOM operations. Native
hit testing hands a WKWebView and local point to its DOM provider. The provider
converts points to CSS viewport coordinates, retains weak references to selected
nodes, and draws outlines in the DOM so scrolling follows the actual element.
Generation checks discard late web responses after a native selection. Pointer
requests coalesce while WebKit is busy; there is no background polling.

`AgentBridge` advertises native inspection at document start. The web app then
routes Inspector launch requests to native and suppresses its HTML overlay.
Standalone browser use retains the web presentation. Public host launch APIs
remain `RipulViewExplorer.present(in:recording:bridge:)` and `toggle`.

DOM inspection traverses open shadow roots. Frame elements can be selected;
their nested documents are not traversed by this provider. Native macOS view
inspection remains unavailable. Native macro recording applies to native
selections; web selections provide DOM activation and evaluation.

## Verification

- SDK `UnifiedInspectorTests`, `ExplorerSelectionTests`, `ComposerElementContextTests`.
- App `MacroRecordingToggleUITests` covers recording, the separate-window
  Inspector's explicit activation and touch pass-through, and single/double taps
  on the production chat title overlay and session-list title.
- `node --test tests/unified-inspector.browser.test.mjs` in `chrome-extension`
  exercises the actual React overlay and DOM provider in WebKit and Chromium.
