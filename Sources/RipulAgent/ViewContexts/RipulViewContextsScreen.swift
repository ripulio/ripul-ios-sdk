#if os(iOS)
import SwiftUI

@available(iOS 16.0, *)
public struct RipulViewContextsScreen: View {
    private let client: RipulViewContextsClient
    @State private var contexts: [RipulViewContext] = []
    @State private var editing: RipulViewContext?
    @State private var creating = false
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""

    public init(client: RipulViewContextsClient) { self.client = client }

    public var body: some View {
        List {
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                }
            }
            if loading { ProgressView("Loading view contexts…") }
            if !loading && contexts.isEmpty && error == nil {
                Text("No view contexts yet. Add one to configure tabs and chat features.")
                    .foregroundStyle(.secondary)
            }
            ForEach(contexts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { context in
                Button { creating = false; editing = context } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(context.name).font(.headline)
                            if context.isSystem { Label("System", systemImage: "lock").font(.caption) }
                        }
                        if !context.description.isEmpty { Text(context.description).font(.subheadline) }
                        Text(context.id).font(.caption).foregroundStyle(.secondary)
                    }.foregroundStyle(.primary)
                }
                .uiKitIdentifier("RipulViewContexts.row.\(context.id)")
            }
        }
        .navigationTitle("View Contexts")
        .searchable(text: $search)
        .uiKitIdentifier("RipulViewContexts.list")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creating = true
                    editing = try? RipulViewContext(json: ["id": "", "name": "", "tabIds": [String]()])
                } label: { Image(systemName: "plus") }
                .uiKitIdentifier("RipulViewContexts.add")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { context in
            NavigationStack {
                RipulViewContextEditor(context: context, creating: creating, client: client) {
                    await load()
                }
            }
        }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        do { contexts = try await client.list(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

@available(iOS 16.0, *)
private struct RipulViewContextEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var context: RipulViewContext
    let creating: Bool
    let client: RipulViewContextsClient
    let onSaved: () async -> Void
    @State private var busy = false
    @State private var error: String?
    @State private var deleting = false
    @State private var discarding = false
    @State private var initialPayload: Data?
    @State private var invalidNumbers: Set<String> = []

    private var serialized: Data? { try? JSONSerialization.data(withJSONObject: context.payload, options: .sortedKeys) }
    private var changed: Bool { serialized != initialPayload }
    private var valid: Bool {
        !context.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        context.id.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil &&
        context.tabIds.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) && invalidNumbers.isEmpty &&
        (context.defaultTabId.isEmpty || context.tabIds.contains(context.defaultTabId))
    }

    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if context.isSystem { Section { Label("System contexts are read-only.", systemImage: "lock") } }
            Group {
                identitySection
                ForEach(RipulViewContextField.groups, id: \.self) { group in
                    Section {
                        NavigationLink(group) {
                            Form {
                                ForEach(RipulViewContextField.all.filter { $0.group == group }) { field in
                                    RipulViewFeatureControl(field: field, values: $context.features, invalidNumbers: $invalidNumbers)
                                }
                            }
                            .navigationTitle(group)
                            .disabled(context.isSystem || busy)
                        }
                    }
                }
                Section {
                    NavigationLink("Chat action buttons") {
                        RipulViewActionButtons(features: $context.features)
                            .disabled(context.isSystem || busy)
                    }
                }
                if !creating && !context.isSystem {
                    Section { Button("Delete View Context", role: .destructive) { deleting = true } }
                }
            }.disabled(busy)
        }
        .navigationTitle(creating ? "New View Context" : context.name)
        .navigationBarTitleDisplayMode(.inline)
        .uiKitIdentifier("RipulViewContexts.editor")
        .interactiveDismissDisabled(busy || changed)
        .onAppear { if initialPayload == nil { initialPayload = serialized } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { if changed { discarding = true } else { dismiss() } }.disabled(busy)
            }
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView() }
                else if !context.isSystem {
                    Button("Save") { Task { await save() } }
                        .disabled(!valid || (!creating && !changed))
                        .uiKitIdentifier("RipulViewContexts.save")
                }
            }
        }
        .confirmationDialog("Discard changes?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
        }
        .confirmationDialog("Delete \(context.name)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await save(delete: true) } }
        } message: { Text("Site keys using this view context will lose its configuration.") }
    }

    private var identitySection: some View {
        Section {
            TextField("ID", text: $context.id).disabled(!creating)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Name", text: $context.name)
            TextField("Description", text: $context.description, axis: .vertical)
            TextField("Tab IDs (comma separated)", text: Binding(
                get: { context.tabIds.joined(separator: ", ") },
                set: { context.tabIds = $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
            )).textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker("Default tab", selection: $context.defaultTabId) {
                Text("Automatic").tag("")
                ForEach(Array(Set(context.tabIds.filter { !$0.isEmpty } )).sorted(), id: \.self) { Text($0).tag($0) }
                if !context.defaultTabId.isEmpty && !context.tabIds.contains(context.defaultTabId) {
                    Text("\(context.defaultTabId) (not selected)").tag(context.defaultTabId)
                }
            }
        } header: { Text("Details and navigation") } footer: {
            Text("Use tab IDs from your solution, separated by commas. The default tab must be selected. IDs may contain letters, numbers, underscores and hyphens.")
        }.disabled(context.isSystem)
    }

    @MainActor private func save(delete: Bool = false) async {
        busy = true
        defer { busy = false }
        do {
            if delete { try await client.delete(id: context.id) }
            else {
                context.name = context.name.trimmingCharacters(in: .whitespacesAndNewlines)
                context.tabIds = Array(NSOrderedSet(array: context.tabIds.filter { !$0.isEmpty })) as? [String] ?? context.tabIds
                for key in ["slashCommands", "atCommands", "bubbleActions"] {
                    if let entries = context.features[key] as? [String] {
                        context.features[key] = entries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    }
                }
                if let buttons = context.features["chatActionButtons"] as? [[String: Any]] {
                    let ids = buttons.compactMap { $0["id"] as? String }
                    guard Set(ids).count == buttons.count,
                          buttons.allSatisfy({ row in ["id", "label", "eventName"].allSatisfy {
                              !(row[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          } }) else {
                        error = "Each action button needs a unique ID, label and event name."; return
                    }
                }
                guard valid else { error = "Enter a name, valid ID and at least one tab; check the default tab and numeric settings."; return }
                try await client.save(context, creating: creating)
            }
            await onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@available(iOS 16.0, *)
private struct RipulViewFeatureControl: View {
    let field: RipulViewContextField
    @Binding var values: [String: Any]
    @Binding var invalidNumbers: Set<String>
    @State private var numberText = ""

    private var text: Binding<String> {
        Binding(get: { values[field.key] as? String ?? "" }, set: {
            values[field.key] = $0.isEmpty ? nil : $0
        })
    }
    var body: some View {
        Section {
            switch field.kind {
            case .boolean:
                Picker(field.title, selection: Binding(
                    get: { (values[field.key] as? Bool).map { $0 ? "on" : "off" } ?? "default" },
                    set: { values[field.key] = $0 == "default" ? nil : $0 == "on" }
                )) {
                    Text("Default").tag("default"); Text("On").tag("on"); Text("Off").tag("off")
                }
            case .choice(let choices):
                Picker(field.title, selection: text) {
                    Text("Default").tag("")
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
            case .text:
                TextField(field.title, text: text, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            case .number:
                TextField(field.title, text: $numberText)
                    .keyboardType(.decimalPad)
                    .onAppear { numberText = (values[field.key] as? NSNumber)?.stringValue ?? "" }
                    .onChange(of: numberText) { input in
                        if input.isEmpty { values[field.key] = nil; invalidNumbers.remove(field.key) }
                        else if let value = Double(input), value.isFinite, value >= 0 {
                            values[field.key] = value; invalidNumbers.remove(field.key)
                        } else { invalidNumbers.insert(field.key) }
                    }
                if invalidNumbers.contains(field.key) { Text("Enter a non-negative number.").foregroundStyle(.red) }
            case .allowlist:
                Picker(field.title, selection: Binding(
                    get: { values[field.key] is [String] ? "custom" : (values[field.key] as? Bool).map { $0 ? "all" : "none" } ?? "default" },
                    set: {
                        switch $0 {
                        case "custom": values[field.key] = [String]()
                        case "all": values[field.key] = true
                        case "none": values[field.key] = false
                        default: values[field.key] = nil
                        }
                    }
                )) {
                    Text("Default").tag("default"); Text("All").tag("all")
                    Text("None").tag("none"); Text("Custom").tag("custom")
                }
                if values[field.key] is [String] {
                    TextField("Allowed IDs (comma separated)", text: Binding(
                        get: { (values[field.key] as? [String] ?? []).joined(separator: ",") },
                        set: { values[field.key] = $0.components(separatedBy: ",") }
                    )).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
        } header: { Text(field.title) }
        .uiKitIdentifier("RipulViewContexts.\(field.key)")
    }
}

@available(iOS 16.0, *)
private struct RipulViewActionButtons: View {
    @Binding var features: [String: Any]
    @State private var invalidNumbers: Set<String> = []
    private var buttons: [[String: Any]] { features["chatActionButtons"] as? [[String: Any]] ?? [] }
    var body: some View {
        Form {
            Toggle("Custom buttons", isOn: Binding(
                get: { features["chatActionButtons"] != nil },
                set: { features["chatActionButtons"] = $0 ? [[String: Any]]() : nil }
            ))
            if features["chatActionButtons"] != nil {
                ForEach(buttons.indices, id: \.self) { index in
                    Section("Button \(index + 1)") {
                        ForEach(["id", "label", "icon", "tooltip", "eventName"], id: \.self) { key in
                            TextField(key, text: Binding(
                                get: { buttons.indices.contains(index) ? buttons[index][key] as? String ?? "" : "" },
                                set: { value in update(index) { $0[key] = value } }
                            )).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        Picker("Alignment", selection: Binding(
                            get: { buttons.indices.contains(index) ? buttons[index]["alignment"] as? String ?? "left" : "left" },
                            set: { value in update(index) { $0["alignment"] = value } }
                        )) { Text("Left").tag("left"); Text("Right").tag("right") }
                        Toggle("Show label", isOn: Binding(
                            get: { buttons.indices.contains(index) && buttons[index]["showLabel"] as? Bool == true },
                            set: { value in update(index) { $0["showLabel"] = value } }
                        ))
                        NavigationLink("Visibility conditions") {
                            Form {
                                ForEach(["hasMessages", "lastMessageIsAgent", "agentRunning", "isAuthenticated"], id: \.self) { key in
                                    RipulViewFeatureControl(
                                        field: .init(key: key, title: key, group: "", kind: .boolean),
                                        values: Binding(
                                            get: { buttons.indices.contains(index) ? buttons[index]["condition"] as? [String: Any] ?? [:] : [:] },
                                            set: { value in update(index) { $0["condition"] = value } }
                                        ), invalidNumbers: $invalidNumbers)
                                }
                                Stepper("Minimum messages: \(minimumMessages(index))", value: Binding(
                                    get: { minimumMessages(index) },
                                    set: { value in update(index) {
                                        var condition = $0["condition"] as? [String: Any] ?? [:]
                                        condition["minMessageCount"] = value
                                        $0["condition"] = condition
                                    } }
                                ), in: 0...10000)
                            }.navigationTitle("Visibility conditions")
                        }
                        Button("Move Up") { move(index, by: -1) }.disabled(index == 0)
                        Button("Move Down") { move(index, by: 1) }.disabled(index == buttons.count - 1)
                        Button("Remove Button", role: .destructive) {
                            var rows = buttons; rows.remove(at: index); features["chatActionButtons"] = rows
                        }
                    }
                }
                Button("Add Button") {
                    var rows = buttons
                    rows.append(["id": "action-\(UUID().uuidString)", "label": "New Action", "icon": "bolt", "eventName": "chat:custom-action", "order": (rows.compactMap { $0["order"] as? Int }.max() ?? 0) + 10])
                    features["chatActionButtons"] = rows
                }
            }
        }.navigationTitle("Chat action buttons")
    }
    private func minimumMessages(_ index: Int) -> Int {
        guard buttons.indices.contains(index) else { return 0 }
        return (buttons[index]["condition"] as? [String: Any])?["minMessageCount"] as? Int ?? 0
    }
    private func update(_ index: Int, change: (inout [String: Any]) -> Void) {
        var rows = buttons
        guard rows.indices.contains(index) else { return }
        change(&rows[index]); features["chatActionButtons"] = rows
    }
    private func move(_ index: Int, by offset: Int) {
        var rows = buttons
        rows.swapAt(index, index + offset)
        for i in rows.indices { rows[i]["order"] = (i + 1) * 10 }
        features["chatActionButtons"] = rows
    }
}
#endif
