# User-selected composer context

The native composer has an **Add context** menu beside the microphone, on iOS,
Catalyst and macOS, in both single-row and two-row layouts. Choosing an item resolves
it locally and opens a preview. **Attach** adds a removable chip; cancel does not
attach anything. No option is selected automatically and no screen is captured until
its option is chosen.

## Choose what gets attached

Current screen captures a frozen, local draft, then presents independent toggles:

- **App description:** live component instrumentation or a developer-supplied resolver.
- **Screenshot:** a preview of the actual JPEG that will be attached to the message.
- **Recognized screen text:** optional, short OCR text without coordinates or diagnostic
  labels. Recognition runs only when this option is selected. It uses the same frozen
  pixels as the screenshot, not a recapture of the preview sheet.

Defaults select app description when available, otherwise screenshot. Recognized text
is off by default. Developers control which options are offered and can instead
preselect description plus screenshot, screenshot alone, or any permitted combination.
The user can change the selection in the preview; Attach is disabled when nothing is
selected or selected text recognition is still running.

```swift
configuration.composerContexts = [
    .currentScreen(configuration: .init(
        available: [.instrumentedText, .screenshot],
        defaults: [.instrumentedText, .screenshot]
    )),
    .planningOnly,
    .whileAway
]
```

The same list can be assigned to `AgentConfiguration.composerContexts` or
`RipulSessionsConfiguration.composerContexts`. Omit `defaults` for adaptive selection;
an explicit empty set starts with all toggles off. Options not in `available` are
never offered or sent, even if included in `defaults`.

Developers may supply their own screen description instead of component discovery:

```swift
.currentScreen(configuration: .init(defaults: [.instrumentedText, .screenshot])) {
    screenModel.descriptionForAI()
}
```

The provider runs only on explicit Current screen selection, before the preview.
Returning an empty description makes that option unavailable. Component annotations
remain useful for masking excluded regions even when a custom description is supplied.

The screenshot is sent through the normal multimodal image-attachment route alongside
any photos already selected, including on voice submissions. It is resized to at most
1600 pixels on its longest edge and encoded as JPEG; base64 never enters the text
context. Unselected descriptions, screenshots and recognized text stay local. Screen
drafts are not saved to preferences. Reopening a chip reviews the original capture;
selecting Current screen again captures fresh. Nothing is captured or attached to
ordinary messages automatically.

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
not captured. Native macOS captures the app's main window. Very large view trees omit the screenshot when the bounded traversal cannot check
all privacy regions; accessible text may still be offered.
Custom icons and plots are not interpreted by OCR; selecting Screenshot sends their
visual representation to the model instead. For richer app semantics, label the
component or provide a description resolver. Recognition failure is shown in the
preview; deselect recognized text to attach the other selected components.

The WAC integration labels its shift editor, shared job header, time/break controls
and role/rate control. Users can additionally select Screenshot to include earnings
and other uninstrumented content visually.

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
