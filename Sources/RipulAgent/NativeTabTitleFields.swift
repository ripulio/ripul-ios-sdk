#if os(iOS)
import SwiftUI

enum NativeTextDraftError: LocalizedError {
    case noRemoteTheme
    var errorDescription: String? { "This app needs an app-wide remote theme connection before saving text drafts." }
}

/// Shared text control for View Explorer and Solution Management. The explorer's
/// trial edits are separate from saved overrides and disappear when it closes.
@MainActor
struct NativeTabTitleFields: View {
    let identifier: String
    let savesExplicitly: Bool
    @State private var text: String
    @State private var message: String?
    @State private var error: String?
    @State private var lease: UUID?

    init(identifier: String, savesExplicitly: Bool) {
        self.identifier = identifier; self.savesExplicitly = savesExplicitly
        _text = State(initialValue: NativeTabTitleTheme.title(for: identifier) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tab title").font(.headline)
            Text(identifier).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("Title", text: Binding(get: { text }, set: { value in
                    text = value
                    message = nil; error = nil
                    if savesExplicitly { NativeTabTitleTheme.preview(value, identifier: identifier) }
                    else { NativeTabTitleTheme.setOverride(value, identifier: identifier) }
                }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("NativeTextTheme.title")
            if savesExplicitly {
                Button("Save to theme draft") { save(text) }
                    .accessibilityIdentifier("NativeTextTheme.save")
                Text("Then open Solution management → Theme → Review & Publish.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Changes preview here and are saved in your unpublished theme draft.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Use app title") {
                if savesExplicitly { save(nil) }
                else { NativeTabTitleTheme.setOverride(nil, identifier: identifier) }
                if error == nil { text = NativeTabTitleTheme.title(for: identifier) ?? "" }
            }
            .accessibilityIdentifier("NativeTextTheme.reset")
            if let message { Text(message).font(.caption) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .onAppear {
            if savesExplicitly { lease = RipulThemeEngine.remoteTheme?.beginEditing() }
        }
        .onDisappear {
            if savesExplicitly {
                NativeTabTitleTheme.preview(nil, identifier: identifier)
                if let lease { RipulThemeEngine.remoteTheme?.endEditing(lease) }; lease = nil
            }
        }
    }

    private func save(_ title: String?) {
        do {
            try ThemeManagementModel.saveTabTitleDraft(identifier: identifier, title: title)
            error = nil; message = "Saved to theme draft."
        } catch { self.error = "Could not save the draft: " + error.localizedDescription }
    }
}
#endif
