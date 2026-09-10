# Screen audit and share-sheet tools

The developer console automatically registers `screen_audit` and `share_sheet`.
They are gated from end-user channels by `RipulDeveloperOnlyTool`, including
when another registration path is used (`Sources/RipulAgent/Sessions/RipulAgentConsole.swift:147`,
`Sources/RipulAgent/RipulDeveloperOnlyTool.swift:31`).

`screen_audit` is read-only and returns the View Explorer Audit tab's exact
classifier and screen root, counts, item identities and text report. It does
not open the overlay. `zero_anonymous` requires a nonempty audit with no anonymous
items. Coverage is the loaded host view tree and materialized SwiftUI accessibility
elements; scroll or expand and repeat for other states. It does not certify
remote system views (`Sources/RipulAgent/ScreenAuditTool.swift:11`,
`Sources/RipulAgent/ViewInspectorOverlay.swift:2425`).

For file exports, present `RipulShareSheet(fileURLs: [url])` in a SwiftUI `.sheet`,
or use `RipulShareSheet.makeController(fileURLs:)` from UIKit. This offers the same
URLs to native `UIActivityViewController` and to the diagnostic contract; it does
not maintain a separate mock export. The share tool can detect other activity
controllers too, but explicitly reports their items unreadable because UIKit
has no public getter (`Sources/RipulAgent/ShareSheetTool.swift:10`, `:97`).

Call `share_sheet` with `action: "inspect"`, optionally `include_text: true`.
It returns the presentation ID, offered filenames, types, sizes and SHA-256.
Only offered local regular files are readable; contents/hashes are bounded to
1 MiB per file, with explicit unavailable/truncated errors. No arbitrary file
path argument is accepted (`Sources/RipulAgent/ShareSheetTool.swift:54`).

To close it, call `action: "dismiss"` with the returned `presentation_id`.
Missing/stale IDs, detached controllers and a dialog above the share sheet
are rejected. Dismissal is observed for up to three seconds, then the actual
visibility is returned (`Sources/RipulAgent/ShareSheetTool.swift:116`). The tool
does not read or select iOS destination activities, which render remotely, or
send a file. Validate those external destination flows separately when required.

Seven simulator regression tests passed on 10 September 2026. They exercise
classification, custom UIHostingController subclasses, modal root selection, actual offered-file bytes and bounds,
untracked-item errors, stale dismissal rejection, and channel gating
(`Tests/RipulAgentTests/UXInspectionToolsTests.swift:7`). Live host presentation
and dismissal require an embedding app's device check.

SDK 0.7.97 fixes the shared Audit classifier to recognize custom subclasses of
UIHostingController by walking the superclass chain. Previously these could
fall through to UIKit internals and omit the hosted SwiftUI accessibility rows
(`Sources/RipulAgent/ViewInspectorOverlay.swift:2479`).
