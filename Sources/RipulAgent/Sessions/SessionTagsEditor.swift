import SwiftUI

/// Add / remove tags for a session. Presented as a sheet from the session-row
/// context menu. Hands the final, normalized tag list back via `onSave`, which
/// persists it through `AgentBridge.setSessionTags`.
@available(iOS 26.0, macOS 26.0, *)
public struct SessionTagsEditor: View {
    let session: UnifiedSession
    /// Tags the user has used before, most-recent first — offered as a picker.
    let suggestions: [String]
    let onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tags: [String]
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    /// Mirror the server-side limits so we never send over-cap data.
    private let maxTags = 20
    private let maxTagLength = 40
    /// Cap the picker so it never floods the sheet.
    private let maxSuggestions = 12

    public init(session: UnifiedSession, suggestions: [String] = [], onSave: @escaping ([String]) -> Void) {
        self.session = session
        self.suggestions = suggestions
        self.onSave = onSave
        _tags = State(initialValue: session.tags)
    }

    private var atLimit: Bool { tags.count >= maxTags }

    private var canAdd: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !atLimit
    }

    /// Recent tags not already on this session, filtered by the current draft.
    private var filteredSuggestions: [String] {
        let existing = Set(tags.map { $0.lowercased() })
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return suggestions
            .filter { tag in
                !existing.contains(tag.lowercased())
                    && (query.isEmpty || tag.lowercased().contains(query))
            }
            .prefix(maxSuggestions)
            .map { $0 }
    }

    /// Append a tag chosen from the picker (deduped, respecting the cap).
    private func addSuggested(_ tag: String) {
        guard !atLimit else { return }
        if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        draft = ""
    }

    /// Trim, cap length, dedupe case-insensitively, then append.
    private func commitDraft() {
        let trimmed = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTagLength))
        draft = ""
        guard !trimmed.isEmpty, !atLimit else { return }
        if !tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            tags.append(trimmed)
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Tags") {
                    if tags.isEmpty {
                        Text("No tags yet.")
                            .foregroundStyle(.secondary)
                            .uiKitIdentifier("SessionTagsEditor.empty")
                    } else {
                        ForEach(tags, id: \.self) { tag in
                            HStack {
                                TagLozenge(text: tag)
                                Spacer()
                            }
                            .uiKitIdentifier("SessionTagsEditor.tagRow")
                        }
                        .onDelete { offsets in tags.remove(atOffsets: offsets) }
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("Add a tag", text: $draft)
                            .focused($inputFocused)
                            .submitLabel(.done)
                            .onSubmit { commitDraft() }
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .uiKitIdentifier("SessionTagsEditor.input")
                        Button {
                            commitDraft()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(canAdd ? Color.accentColor : Color.secondary)
                        .disabled(!canAdd)
                        .uiKitIdentifier("SessionTagsEditor.addButton")
                    }
                } footer: {
                    if atLimit {
                        Text("Tag limit reached (\(maxTags)).")
                    } else {
                        Text(session.title)
                            .lineLimit(1)
                    }
                }

                if !filteredSuggestions.isEmpty {
                    Section("Recent Tags") {
                        ForEach(filteredSuggestions, id: \.self) { tag in
                            Button {
                                addSuggested(tag)
                            } label: {
                                HStack {
                                    TagLozenge(text: tag)
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .uiKitIdentifier("SessionTagsEditor.suggestionRow")
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .uiKitIdentifier("SessionTagsEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        commitDraft()
                        onSave(tags)
                    }
                    .uiKitIdentifier("SessionTagsEditor.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { inputFocused = true }
    }
}
