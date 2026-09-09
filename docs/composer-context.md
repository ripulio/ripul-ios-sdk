# User-selected composer context

The native composer has an **Add context** menu beside the microphone, on iOS,
Catalyst and macOS, in both single-row and two-row layouts. Choosing an item resolves
it locally and opens a preview. **Attach** adds a removable chip; cancel does not
attach anything. No option is selected automatically and no screen is captured until
its option is chosen.

## Two capture paths

Current screen captures the host window's pixels and component state together when
selected. It combines two paths:

1. **Developer instrumentation:** live components supply their meaning, value and
   optional hint. These are app data, not agent instructions. Instrumented values and
   controls take precedence over fallback observations within their visible regions.
2. **Fallback:** accessible labels/values plus Apple's on-device Vision text
   recognition of the rendered host screen, including SwiftUI and web content.
   OCR runs off the UI thread. Rows preserve reading order and x/y positions, so
   repeated dates and side-by-side fields retain their context. Uncertain readings
   are marked; the SDK does not invent meanings for ambiguous icons or graphs.

Screen/group annotations can coexist with uninstrumented descendants. No screen
catalogue is needed. Only visible components contribute; an annotation on a reused
component must update along with the component's displayed state. No screenshot is
uploaded, stored in preferences, or included in the message: only the reviewed text
snapshot is attached. The image is transient input to local text recognition.
The image and text are not recaptured at send time.

### Label a component for AI

SwiftUI automatically updates the annotation when its state changes:

```swift
Text(total.formatted(.currency(code: "GBP")))
    .ripulAIContext(.init(id: "shift.total", label: "Total shift earnings",
                          value: total.formatted(.currency(code: "GBP")), role: .value))

ShiftEditor()
    .ripulAIContext(.init(id: "shift.editor", label: "Shift record editor",
                          hint: "Edit job, times, role and earnings", role: .screen))
```

UIKit and AppKit use the same metadata. Assign it whenever displayed state changes:

```swift
payView.ripulAIContext = .init(id: "shift.total", label: "Total shift earnings",
                              value: formattedTotal, role: .value)
```

Use `.control` for an interactive component, `.value` for a displayed fact, `.group`
for a section, and `.screen` for the screen title/purpose. IDs should be stable;
metadata describes the current UI, not a hidden model or unrelated records. Attach
SwiftUI metadata after the component's layout modifiers so it covers that component.
Do not label an entire section as `.value` if its children need fallback capture.

### Exclusions and limitations

Use `.ripulAIContextExcluded()` on a SwiftUI component or
`view.ripulAIContext = .excluded` on a UIKit/AppKit view to exclude its whole visible
region. Exclusions override annotations and accessible text, and are painted out of
the captured pixels before recognition. Secure native fields are always excluded;
other native editable fields are excluded unless explicitly instrumented. Web/custom
editors do not expose the same native field types: hosts must mark sensitive regions
with this API. Screen-level annotations should only describe the screen's purpose.

Capture excludes SDK overlay windows on iOS, so the embedded assistant's own chat is
not read. Native macOS captures the app's main window. Very large view trees skip
visual recognition if the bounded traversal cannot check all privacy regions.
Custom icons, plots and image meaning are not interpreted by OCR. For richer app
semantics, label the component or provide a host-defined resolver below. Recognition
failure is stated in the preview; accessible/developer context remains available.

The WAC integration labels its shift editor, shared job header, time/break controls
and role/rate control; earnings still exercise the visual fallback.

## Host-defined choices

```swift
var configuration = AgentConfiguration(baseURL: URL(string: "https://demo.ripul.io")!)
configuration.composerContexts = RipulComposerContext.standard + [
    .shortcut(id: "myapp.review", title: "Review only",
              instructions: "Review the current work and explain issues. Do not edit files."),
    RipulComposerContext(id: "myapp.record", title: "Selected record",
                         subtitle: "The record currently open in the app") {
        // Main-actor async closure; called only when explicitly selected.
        try await recordStore.describeSelectedRecord()
    }
]
```

`RipulSessionsConfiguration.composerContexts` provides the same extension point for
`RipulAgentConsole` and `RipulDevAssistantOverlay`. Its defaults include Current screen,
Planning only, and Work while I'm away. Ordinary `AgentConfiguration` defaults to
Current screen only. Set an empty array to disable choices, or supply your own list.
Use stable unique IDs: reattaching an option replaces its existing chip.

Screen/data attachments apply to the next message. Instruction shortcuts offer
Next message or Every message in this chat. Persistent instructions are saved in the
host app's preferences under the conversation ID and remain visible as chips when
that chat is reopened. Screen captures are never saved to preferences. Removing a
chip stops future attachment; it does not erase previously sent conversation history.

Selections use the shared `AgentBridge.submitMessage` path, including voice messages.
They are sent as an explicitly labelled JSON attachment section in the user message,
not as system instructions. Human notes do not include or consume them. A successful
send clears only the acknowledged next-message selections; failed sends retain them,
and another chat never inherits them. Preview again by tapping the chip.
