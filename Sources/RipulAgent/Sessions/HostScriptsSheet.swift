import SwiftUI

/// Write and edit a host's scripts from the phone.
///
/// The Mac app's Scripts tab was the only way to author these, and it isn't
/// offered on iOS, so a script could only be changed from the machine it runs
/// on. This is the same store over the relay: every script here is a tile in
/// that machine's panel.
struct HostScriptsSheet: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    /// Fired after a save or delete lands, so the row can re-read its tiles.
    let onScriptsChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var isSupported = true
    @State private var scripts: [HostScript] = []
    @State private var loadError: String?
    @State private var isCreating = false
    @State private var pendingDelete: HostScript?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scripts")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    if isSupported && !isLoading {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                isCreating = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("New Script")
                        }
                    }
                }
                .navigationDestination(isPresented: $isCreating) {
                    HostScriptEditorView(
                        machine: machine,
                        bridge: bridge,
                        script: HostScript(),
                        onChanged: scriptsChanged
                    )
                }
        }
        .task { await refresh() }
        .accessibilityIdentifier("HostScriptsSheet")
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !isSupported {
            ContentUnavailableView {
                Label("No Scripts Here", systemImage: "terminal")
            } description: {
                Text("\(machine.displayName) has no script store. Scripts are a Mac host feature over the relay. You can hide this row from Customise Panel.")
            }
        } else {
            List {
                if let loadError {
                    Section {
                        Text(loadError).foregroundStyle(.red).font(.callout)
                    }
                }
                if scripts.isEmpty {
                    ContentUnavailableView {
                        Label("No Scripts Yet", systemImage: "terminal")
                    } description: {
                        Text("Tap + to write one. It appears as a tile in \(machine.displayName)’s panel.")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(scripts) { script in
                            NavigationLink {
                                HostScriptEditorView(
                                    machine: machine,
                                    bridge: bridge,
                                    script: script,
                                    onChanged: scriptsChanged
                                )
                            } label: {
                                scriptRow(script)
                            }
                        }
                        .onDelete { offsets in
                            pendingDelete = offsets.first.map { scripts[$0] }
                        }
                    } footer: {
                        Text("Each script is a tile in \(machine.displayName)’s panel.")
                    }
                }
            }
            .refreshable { await refresh() }
            .confirmationDialog(
                "Delete “\(pendingDelete?.name ?? "")”?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Script", role: .destructive) {
                    if let script = pendingDelete { Task { await delete(script) } }
                }
            } message: {
                Text("This removes it from the host and its tile from the panel.")
            }
        }
    }

    private func scriptRow(_ script: HostScript) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.name).lineLimit(1)
                if !script.description.isEmpty {
                    Text(script.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: script.scriptType == "applescript" ? "applescript" : "terminal")
                .foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        let result = await bridge.fetchHostScripts(machineId: machine.machineId)
        isSupported = result.supported
        scripts = result.scripts
        loadError = result.error
        isLoading = false
    }

    private func delete(_ script: HostScript) async {
        guard let id = script.id else { return }
        switch await bridge.deleteHostScript(machineId: machine.machineId, scriptId: id) {
        case .success:
            await scriptsChanged()
        case .failure(let error):
            loadError = error.message
        }
    }

    private func scriptsChanged() async {
        await refresh()
        onScriptsChanged()
    }
}

// MARK: - Editor

struct HostScriptEditorView: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    let onChanged: () async -> Void

    /// What the host last stored — nil for a script that doesn't exist yet.
    @State private var baseline: HostScript?
    @State private var draft: HostScript
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var isRunning = false
    @State private var runOutput: String?
    @State private var confirmDiscard = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(machine: RemoteMachine, bridge: AgentBridge, script: HostScript, onChanged: @escaping () async -> Void) {
        self.machine = machine
        self.bridge = bridge
        self.onChanged = onChanged
        _baseline = State(initialValue: script.id == nil ? nil : script)
        _draft = State(initialValue: script)
    }

    private var isDirty: Bool {
        guard let baseline else {
            return !(draft.name.isEmpty && draft.description.isEmpty && draft.source.isEmpty && draft.parameters.isEmpty)
        }
        return !draft.sameContent(as: baseline)
    }

    private var canSave: Bool {
        !isSaving && isDirty && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                TextField("Description", text: $draft.description, axis: .vertical)
                    .lineLimit(1...3)
            } footer: {
                Text("The name is the tile’s label in the machine panel.")
            }

            Section("Type") {
                Picker("Type", selection: $draft.scriptType) {
                    Text("Bash").tag("bash")
                    Text("AppleScript").tag("applescript")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Script") {
                TextEditor(text: $draft.source)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 220)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            Section {
                ForEach($draft.parameters) { $param in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Name", text: $param.name)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            Picker("Type", selection: $param.type) {
                                ForEach(HostScriptParameter.types, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        TextField("Description", text: $param.description)
                            .font(.callout)
                        Toggle("Required", isOn: $param.required)
                            .font(.callout)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { draft.parameters.remove(atOffsets: $0) }

                Button {
                    draft.parameters.append(HostScriptParameter())
                } label: {
                    Label("Add Parameter", systemImage: "plus.circle")
                }
            } header: {
                Text("Parameters")
            } footer: {
                Text("Parameters are asked for when the tile is tapped, and passed to the script.")
            }

            if let saveError {
                Section {
                    Text(saveError).foregroundStyle(.red).font(.callout)
                }
            }

            if baseline != nil {
                Section {
                    Button {
                        Task { await run() }
                    } label: {
                        HStack {
                            Label(isRunning ? "Running…" : "Run", systemImage: "play.fill")
                            if isRunning {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    // Parameters are collected by the tile's own sheet; running
                    // blind here would pass none and misreport the script. And
                    // an unsaved edit would run the stored copy, not this one.
                    .disabled(isRunning || isDirty || !draft.parameters.isEmpty)

                    if let runOutput {
                        Text(runOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } footer: {
                    if !draft.parameters.isEmpty {
                        Text("Run this one from its tile, so you can fill in its parameters.")
                    } else if isDirty {
                        Text("Save first — Run uses the copy stored on the host.")
                    }
                }

                Section {
                    Button("Delete Script", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(baseline == nil ? "New Script" : "Edit Script")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(isDirty)
        .toolbar {
            if isDirty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { confirmDiscard = true }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
        }
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Script", role: .destructive) { Task { await delete() } }
        } message: {
            Text("This removes it from the host and its tile from the panel.")
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        let result = await bridge.saveHostScript(machineId: machine.machineId, script: draft)
        isSaving = false
        switch result {
        case .success(let stored):
            // Adopt the host's copy so a create picks up its id and the next
            // save updates rather than duplicating.
            baseline = stored
            draft = stored
            await onChanged()
        case .failure(let error):
            saveError = error.message
        }
    }

    private func delete() async {
        guard let id = baseline?.id else { return }
        switch await bridge.deleteHostScript(machineId: machine.machineId, scriptId: id) {
        case .success:
            await onChanged()
            dismiss()
        case .failure(let error):
            saveError = error.message
        }
    }

    private func run() async {
        guard let actionId = baseline?.actionId else { return }
        isRunning = true
        runOutput = nil
        let result = await bridge.executeRemoteAction(machineId: machine.machineId, actionId: actionId)
        isRunning = false
        runOutput = Self.describe(result)
    }

    /// Flatten a remote-action result into plain text. The host pre-wraps
    /// output as HTML for the web result view; prefer the raw fields, and
    /// strip the tags only when nothing else is there.
    private static func describe(_ result: [String: Any]) -> String {
        if result["status"] as? String == "error" {
            return "Error: \(result["error"] as? String ?? "Run failed")"
        }
        let text = result
            .filter { $0.key != "status" && $0.key != "html" }
            .sorted { $0.key < $1.key }
            .map { "\($0.value)" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let html = result["html"] as? String ?? ""
        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? "Ran with no output." : stripped
    }
}
