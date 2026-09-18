# Inspector

Inspector uses one floating native panel and one selection across UIKit, SwiftUI
and HTML inside a WKWebView on iOS and Catalyst. The Tools menu, Settings,
solution management and the chat title double-tap launch the same window.
Browser and native macOS clients use the web Inspector.

The compact 22-point Web/Native identity lozenge at the top names the current
selection, with smaller type and spacing to show more of long identities. Tap it to
copy the full identity, even when it is visually truncated; a checkmark confirms
the copy. **Copy reference** still copies the detailed inspection report. The
Details tab and other panels omit the repeated identity badges.

With a mouse or trackpad (Catalyst, iPad pointer), **shift-click** collects
elements instead of replacing the selection. Holding shift lets hover preview
through the pin; each shift-click toggles the element under the pointer in a
basket listed under the lozenge, seeded with the already pinned element on the
first shift-click. **Copy all** puts one identity per line on the clipboard;
rows have their own remove buttons and the basket has a clear button. Plain
clicks, tree navigation and Back leave the basket alone. Releasing shift
without clicking restores the pinned selection. Shift-clicks never count as
the double-tap that fires an element. `device_explorer_probe` reports the
basket as `collected`. A folded HUD shows the basket count next to the title
and its own **Copy all** button, so collecting works without unfolding.

On a touchscreen, **double-tap the reticule** to add the highlighted element to
the basket, or to take it out again. On the Appearance tab every tap parks the
reticule under the finger, so a double-tap on an element there selects it and
collects it in one go. Double-taps away from the reticule keep their existing
jobs: confirming a macro step, and the host's element-tap action.

Single-tap the chat title to expand or collapse it. Double-tap opens Inspector
and preserves the title's expanded state. The single tap waits for the system's
double-tap recognition window; the expanded title's navigation buttons retain
their own actions.

Drag to aim on a touchscreen, or move a mouse/trackpad pointer. Tap to pin the
selection. **Activate** explicitly presses the selected control; selecting it
does not press it. **Back**, **Parent element** and the Tree tab navigate the same
selection. Folding the panel or choosing **Interact with app** returns touches
to the app while retaining the selection. Unfolding/resuming refreshes it.

In an SDK host app, the entire embedded assistant is isolated from selection:
its bubble, compact bar and expanded or retained console are always skipped.
Opening the assistant brings it above the explorer, including the explorer's
panel and sheets. Minimizing it reveals the same explorer with the host selection
and pin preserved. Explicitly launching Inspector from the assistant minimizes
the assistant and inspects the host window.
Taps and drags inside minimized agent controls go directly to the agent window,
so tapping the compact session row reopens the console without selecting or
pinning an element. The Inspector's own panel and sheets retain touch priority
where they visibly cover those controls.

Details, Layout, Appearance and Tree share the panel. Native selections retain
theme token editing, audit and macro recording. Web selections expose CSS layout
and appearance edits and an Eval tab, where `$0` is the selected DOM element.
Web CSS edits change the current page; they are not source-code changes.

Native **Appearance** rows lead with the property and show its assigned token or
style plus a colour swatch for colour tokens only. Opening a colour row shows its
shared definition: colour source, resulting colour and **Edit shared token**.
The editor states that changes apply wherever the token is used; it changes the
shared source, preserving the element's assigned token. Style rows instead offer
**Change style** for the selected element. Both the inspector and element-tap
sheet use the same detail/editor views ([implementation](../Sources/RipulAgent/ThemeRemap.swift)).
Hosts mark bindings as colour tokens, style assignments or information and can
supply their existing style/override actions through `remapSections(for:view:)`
([provider contract](../Sources/RipulAgent/RipulTokenInspection.swift)).

Native Appearance editing is theme-based. It also retains saved theme text edits
for supported labels and tab titles. Temporary view overrides (background, tint,
text colour, opacity, corner radius, font size, visibility and unsaved copy) and
their preview reset/handoff controls have been removed. The Details tab continues
to report the view's current properties
([implementation](../Sources/RipulAgent/ViewInspectorOverlay.swift)).

For web elements, **Layout** includes the nested margin (orange), border (yellow),
padding (green), and content (blue) box diagram. Tap any edge to edit its CSS value;
numbers default to pixels, other CSS units are accepted, and clearing a value
removes the inline override. Edits override stylesheet rules and refresh the
diagram immediately. Content dimensions use untransformed CSS layout dimensions
and account for `box-sizing`, rather than the selection's screen bounding box.

**Attach element** uses the composer's **Selected element** attachment flow,
including the host's configured description, screenshot and recognized-text
choices. Both entry points freeze a draft and its destination conversation before
opening the same review sheet. **Attach** adds the reviewed snapshot to the
composer; Cancel adds nothing. Nothing is sent until the message is sent.
The destination uses the composer's source conversation ID, not the containing
chat tab ID. Removed elements fail explicitly rather than resolving a replacement
with the same identifier. Editable web elements are excluded from context;
editable descendants are masked in screenshots and suppress aggregate text.
Host launches such as shake do not need to supply a bridge: attachment capture
finds the existing SDK agent in the inspected window's scene, including its
minimized session row. It reads that agent's current conversation and composer
options without opening another console. A dismissed agent or absent chat cannot
receive a new attachment, and an explicitly supplied bridge takes priority.

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

The floating HUD uses a dark surface and sets the dark colour scheme at its root.
Adaptive text rows therefore remain readable when the host app uses light mode;
the scheme is scoped to inspector content. See `Sources/RipulAgent/ViewInspectorOverlay.swift:2772`.

DOM inspection traverses open shadow roots. Frame elements can be selected;
their nested documents are not traversed by this provider. Native macOS view
inspection remains unavailable. Native macro recording applies to native
selections; web selections provide DOM activation and evaluation.

## Verification

- SDK `UnifiedInspectorTests`, `ExplorerSelectionTests`, `ComposerElementContextTests`.
- App `MacroRecordingToggleUITests` covers recording, the separate-window
  Inspector's explicit activation and touch pass-through, and single/double taps
  on the production chat title overlay and session-list title. It also verifies
  all twelve box-model edges and live edits through the native value editor.
  `testTextAssignmentsSharedSourcesResetAndDataSource` also checks rendered text-row
  contrast and keeps a full inspector screenshot. Run with the simulator in light
  appearance to reproduce the host/inspector scheme mismatch fixed in SDK 0.7.111.
- `node --test tests/unified-inspector.browser.test.mjs` in `chrome-extension`
  exercises the actual React overlay and DOM provider in WebKit and Chromium.
