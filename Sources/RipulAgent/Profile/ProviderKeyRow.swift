import SwiftUI

/// One provider's bring-your-own-key row: paste, verify, replace, remove.
///
/// The row has two faces and never both at once. With no key stored it is a
/// field and a Save button. With a key stored it is a statement of which key
/// is installed — last four characters and the account it authenticated as —
/// because that is the only question someone returning to this screen has,
/// and the key itself is unreadable by construction.
///
/// Saving verifies against the provider before storing, so the error appears
/// under the field that caused it rather than as a dead mic somewhere else.
struct ProviderKeyRow: View {
    struct Provider {
        let id: String
        let name: String
        let icon: String
        /// Shown as the field's placeholder — the shape of a valid key is the
        /// fastest way to tell someone they have pasted the wrong thing.
        let placeholder: String
        /// Where to go and get one.
        let consoleURL: URL
    }

    static let elevenLabs = Provider(
        id: "elevenlabs",
        name: "ElevenLabs",
        icon: "waveform",
        placeholder: "sk_…",
        consoleURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")!
    )

    let provider: Provider
    let status: UserSecretStatus?
    let storageEnabled: Bool
    var baseURL: URL = AgentConfiguration.defaultBaseURL
    let tokenProvider: () -> String?
    let onChange: (UserSecretStatus) -> Void

    @State private var keyInput = ""
    @State private var entering = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var confirmingRemove = false

    private var isConfigured: Bool { status?.configured == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isConfigured && !entering {
                storedDetail
            } else {
                entryField
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Remove your \(provider.name) key?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove Key", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
    }

    private var header: some View {
        HStack {
            Label(provider.name, systemImage: provider.icon)
            Spacer()
            if busy {
                ProgressView()
            } else if isConfigured {
                Menu {
                    Button("Replace Key…") {
                        keyInput = ""
                        errorMessage = nil
                        entering = true
                    }
                    Button("Remove Key", role: .destructive) { confirmingRemove = true }
                } label: {
                    Text("••••\(status?.hint ?? "")")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                .uiKitIdentifier("ProviderKeyRow.storedMenu")
            }
        }
    }

    private var storedDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label = status?.accountLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let added = addedDescription {
                Text(added)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var entryField: some View {
        SecureField(provider.placeholder, text: $keyInput)
            .textContentType(.password)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .disabled(!storageEnabled || busy)
            .uiKitIdentifier("ProviderKeyRow.keyField")

        HStack {
            Link("Get a key", destination: provider.consoleURL)
                .font(.caption)

            Spacer()

            if entering {
                Button("Cancel") {
                    entering = false
                    keyInput = ""
                    errorMessage = nil
                }
                .font(.caption)
            }

            Button("Save") { Task { await save() } }
                .disabled(!storageEnabled || busy || keyInput.trimmed.isEmpty)
                .uiKitIdentifier("ProviderKeyRow.saveButton")
        }
    }

    private var addedDescription: String? {
        guard let updatedAt = status?.updatedAt,
              let date = ISO8601DateFormatter.userSecrets.date(from: updatedAt) else { return nil }
        return "Added \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Naming the consequence, not just the action — removing a key silently
    /// downgrades speech, and which downgrade depends on whether the shared
    /// key exists.
    private var removeMessage: String {
        status?.platformFallbackAvailable == true
            ? "Speech will go back to running on Ripul's shared key."
            : "Cloud speech will turn off, and dictation and read-aloud will fall back to the on-device Apple voice."
    }

    private func save() async {
        busy = true
        errorMessage = nil
        do {
            let updated = try await UserSecretsClient(baseURL: baseURL, tokenProvider: tokenProvider)
                .save(provider: provider.id, key: keyInput.trimmed)
            onChange(updated)
            keyInput = ""
            entering = false
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }

    private func remove() async {
        busy = true
        errorMessage = nil
        do {
            let updated = try await UserSecretsClient(baseURL: baseURL, tokenProvider: tokenProvider)
                .remove(provider: provider.id)
            onChange(updated)
            entering = false
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension ISO8601DateFormatter {
    /// The worker stamps with `new Date().toISOString()`, which always carries
    /// fractional seconds — the default formatter rejects those.
    static let userSecrets: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
