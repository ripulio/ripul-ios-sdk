# User-selected composer context

The native composer has an **Add context** menu beside the microphone, on iOS,
Catalyst and macOS, in both single-row and two-row layouts. Choosing an item resolves
it locally and opens a preview. **Attach** adds a removable chip; cancel does not
attach anything. No option is selected automatically and no screen is captured until
its option is chosen.

The SDK generates Current screen from the host app's identity, screen title when
available, and visible native labels. On iOS it excludes Ripul overlay windows,
editable fields, secure fields and webview contents. Native text extraction is best
effort: custom-drawn and web content may not have readable labels. Applications can
replace the default resolver with a richer description of their own screen or add
selected-record context. The reviewed snapshot is frozen, timestamped and sent as
reference data. It is not recaptured silently at send time.

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
