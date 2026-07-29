#if os(iOS)
import SwiftUI

/// Create or edit one collection, with membership previewed live against the
/// tools this build registered.
///
/// The preview is the reason this screen exists on-device: the web dashboard
/// cannot show it, because its collection form has no access to a tool list.
@available(iOS 16.0, *)
struct RipulToolCollectionEditorView: View {
    @ObservedObject var model: RipulToolCollectionsModel
    let tools: [RipulRegisteredTool]
    /// Nil when creating.
    let existing: RipulToolCollection?
    /// Names of solution contexts referencing this collection via `group://`
    /// (native-tool-registry phase 4). Deleting a referenced collection is
    /// allowed — the server degrades the context rather than bricking it —
    /// but the developer should see the blast radius first.
    var referencedByContexts: [String] = []

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var label = ""
    @State private var descriptionText = ""
    @State private var mode = "expand"
    @State private var prompt = ""
    @State private var patterns: [String] = []
    @State private var explicitTools: [String] = []
    @State private var patternEntry = ""
    @State private var pickingTools = false
    @State private var saving = false
    @State private var confirmingDelete = false
    /// `onAppear` fires again when a pushed picker returns; without this the
    /// form would reload from the server copy and discard unsaved edits.
    @State private var didLoad = false

    private var isEditing: Bool { existing != nil }

    private var toolNames: [String] { tools.map(\.name) }

    private var matcher: RipulToolCollectionMatcher {
        RipulToolCollectionMatcher(
            explicitTools: explicitTools,
            toolPatterns: patterns,
            toolNames: toolNames
        )
    }

    /// Inline validation so a bad regex never round-trips to a 400.
    private var patternError: String? {
        let trimmed = patternEntry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if patterns.contains(trimmed) { return "Already added" }
        return RipulToolPatternValidator.reasonInvalid(trimmed)
    }

    private var canSave: Bool {
        !saving && (isEditing || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        Form {
            identitySection
            modeSection
            patternsSection
            explicitToolsSection
            previewSection
            if isEditing { deleteSection }
        }
        .navigationTitle(isEditing ? (existing?.displayLabel ?? "Collection") : "New Collection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
                    .accessibilityIdentifier("ripul.toolCollections.save")
            }
        }
        .sheet(isPresented: $pickingTools) {
            NavigationStack {
                RipulToolPickerView(tools: tools, selected: $explicitTools)
            }
        }
        .onAppear(perform: loadExisting)
        .alert(
            referencedByContexts.isEmpty
                ? "Delete collection?"
                : "Delete collection used by \(referencedByContexts.joined(separator: ", "))?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if referencedByContexts.isEmpty {
                Text("Its \(matcher.memberCount) members return to the agent's flat list. The tools themselves are not deleted.")
            } else {
                Text("Its \(matcher.memberCount) members return to the agent's flat list. The tools themselves are not deleted.\n\nContexts referencing it via group:// keep working but lose these tools on their next request.")
            }
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            if !isEditing {
                TextField("data_tools", text: $name)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ripul.toolCollections.name")
            }
            TextField("Label shown to the agent", text: $label)
            TextField("What these tools do together", text: $descriptionText, axis: .vertical)
                .lineLimit(2...4)
        } header: {
            Text(isEditing ? "Identity" : "Name")
        } footer: {
            Text(isEditing
                 ? "The name cannot be changed after creation."
                 : "A unique identifier. The label and description are what the agent reads when deciding whether to expand this collection.")
        }
    }

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $mode) {
                Text("Expand").tag("expand")
                Text("Isolate").tag("isolate")
            }
            .pickerStyle(.segmented)

            if mode == "isolate" {
                TextField("Sub-agent system prompt (optional)", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.system(.footnote, design: .monospaced))
            }
        } header: {
            Text("Mode")
        } footer: {
            Text(mode == "isolate"
                 ? "A focused sub-agent runs with only these tools, then reports back. Best when the area is self-contained."
                 : "Tools join the agent's current scope alongside everything else. Best when tasks mix this area with others.")
        }
    }

    private var patternsSection: some View {
        Section {
            ForEach(patterns, id: \.self) { pattern in
                HStack {
                    Text(pattern).font(.system(.footnote, design: .monospaced))
                    Spacer()
                    Text("\(matchCount(for: pattern))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { patterns.remove(atOffsets: $0) }

            HStack {
                TextField("^calendar_", text: $patternEntry)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(addPattern)
                    .accessibilityIdentifier("ripul.toolCollections.patternInput")
                Button("Add", action: addPattern)
                    .disabled(patternEntry.trimmingCharacters(in: .whitespaces).isEmpty || patternError != nil)
            }
            if let patternError {
                Text(patternError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Name Patterns")
        } footer: {
            Text("Regexes matched against tool names. Any tool matching joins this collection, so future tools following the convention are absorbed automatically — no regrouping. Match the name your app registers (get_events), not the prefixed one (host_get_events).")
        }
    }

    private var explicitToolsSection: some View {
        Section {
            ForEach(explicitTools, id: \.self) { tool in
                Text(tool)
                    .font(.system(.footnote, design: .monospaced))
                    // A group:// entry is a server-resolved reference, not a
                    // local tool — surface it rather than silently listing it
                    // as something that will never match here.
                    .foregroundStyle(tool.hasPrefix("group://") ? .secondary : .primary)
            }
            .onDelete { explicitTools.remove(atOffsets: $0) }

            Button {
                pickingTools = true
            } label: {
                Label("Pick Tools", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("ripul.toolCollections.pickTools")
        } header: {
            Text("Picked Tools")
        } footer: {
            Text("Hand-picked members, in addition to anything the patterns capture.")
        }
    }

    private var previewSection: some View {
        Section {
            if matcher.memberCount == 0 {
                Text("No members yet — this collection would not be shown to the agent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(matcher.presentMatches, id: \.self) { toolName in
                HStack {
                    Text(toolName).font(.system(.footnote, design: .monospaced))
                    Spacer()
                    if matcher.patternMatches.contains(toolName) {
                        Text("pattern").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            // Members this build doesn't register — a web app tool, or one from
            // another device. Shown greyed rather than hidden, so a collection
            // curated elsewhere doesn't look empty here.
            ForEach(matcher.absentMembers, id: \.self) { member in
                HStack {
                    Text(member)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("not in this app").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(matcher.invalidPatterns, id: \.pattern) { invalid in
                Label("\(invalid.pattern) — \(invalid.reason)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("\(matcher.memberCount) members · \(matcher.presentCount) in this app")
        } footer: {
            Text("Collections are account-wide. Members this build doesn't register are still part of the collection — they belong to the web app or another device.")
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Delete Collection", role: .destructive) { confirmingDelete = true }
        }
    }

    // MARK: - Actions

    private func matchCount(for pattern: String) -> Int {
        RipulToolCollectionMatcher(
            explicitTools: [],
            toolPatterns: [pattern],
            toolNames: toolNames
        ).presentCount
    }

    private func addPattern() {
        let trimmed = patternEntry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, patternError == nil else { return }
        patterns.append(trimmed)
        patternEntry = ""
    }

    private func loadExisting() {
        guard !didLoad else { return }
        didLoad = true
        guard let existing else { return }
        name = existing.name
        label = existing.label
        descriptionText = existing.description
        mode = existing.mode
        prompt = existing.prompt ?? ""
        patterns = existing.toolPatterns
        explicitTools = existing.explicitTools
    }

    private func save() async {
        saving = true
        defer { saving = false }

        let edit = RipulToolCollectionEdit(
            label: label.trimmingCharacters(in: .whitespaces),
            description: descriptionText.trimmingCharacters(in: .whitespaces),
            mode: mode,
            // Only meaningful in isolate mode; send empty otherwise so a mode
            // flip doesn't leave a stale prompt behind on the record.
            prompt: mode == "isolate" ? prompt.trimmingCharacters(in: .whitespaces) : "",
            toolPatterns: patterns,
            explicitTools: explicitTools
        )

        let ok: Bool
        if let existing {
            ok = await model.update(id: existing.id, edit: edit)
        } else {
            ok = await model.create(name: name.trimmingCharacters(in: .whitespaces), edit: edit)
        }
        if ok { dismiss() }
    }

    private func performDelete() async {
        guard let existing else { return }
        if await model.delete(id: existing.id) { dismiss() }
    }
}

// MARK: - Tool picker

/// Multi-select over the live registered tool set.
@available(iOS 16.0, *)
struct RipulToolPickerView: View {
    let tools: [RipulRegisteredTool]
    @Binding var selected: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [RipulRegisteredTool] {
        guard !search.isEmpty else { return tools }
        return tools.filter {
            $0.name.localizedCaseInsensitiveContains(search)
            || $0.description.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            section(title: "App Tools", items: filtered.filter { !$0.isBuiltIn })
            section(title: "SDK Built-ins", items: filtered.filter(\.isBuiltIn))
        }
        .searchable(text: $search)
        .navigationTitle("Pick Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func section(title: String, items: [RipulRegisteredTool]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { tool in
                    Button {
                        toggle(tool.name)
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.primary)
                                if !tool.description.isEmpty {
                                    Text(tool.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if selected.contains(tool.name) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ name: String) {
        if let index = selected.firstIndex(of: name) {
            selected.remove(at: index)
        } else {
            selected.append(name)
        }
    }
}
#endif
