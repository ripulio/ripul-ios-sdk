#if os(iOS)
import SwiftUI

enum NativeTextDraftError: LocalizedError {
    case noRemoteTheme
    var errorDescription: String? { "This app needs an app-wide remote theme connection before saving text drafts." }
}

/// Shared text control for View Explorer and Solution Management. The explorer's
/// trial edits are separate from saved overrides and disappear when it closes.
@MainActor
struct NativeTextFields: View {
    let target: NativeTextTarget
    let savesExplicitly: Bool
    @State private var text: String
    @State private var message: String?
    @State private var error: String?
    @State private var lease: UUID?

    init(target: NativeTextTarget, savesExplicitly: Bool) {
        self.target = target; self.savesExplicitly = savesExplicitly
        _text = State(initialValue: target.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.heading).font(.headline)
            Text(target.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(target.strategy).font(.caption).foregroundStyle(.secondary)
            TextField("Text", text: Binding(get: { text }, set: { value in
                    text = value
                    message = nil; error = nil
                    if savesExplicitly { target.preview(value) }
                    else { target.apply(value) }
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
            Button("Use app text") {
                if savesExplicitly { save(nil) }
                else { target.apply(nil) }
                if error == nil { text = target.appText ?? "" }
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
                target.preview(nil)
                if let lease { RipulThemeEngine.remoteTheme?.endEditing(lease) }; lease = nil
            }
        }
    }

    private func save(_ title: String?) {
        do {
            try ThemeManagementModel.saveNativeTextDraft(target: target, text: title)
            error = nil; message = "Saved to theme draft."
        } catch { self.error = "Could not save the draft: " + error.localizedDescription }
    }
}
#endif
