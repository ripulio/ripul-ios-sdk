import SwiftUI
import UniformTypeIdentifiers

/// The Intent Lab: try a sentence, see exactly what the model was sent and what
/// came back, and edit the command map that produced it — on the device.
///
/// Drop it into any navigation stack:
///
/// ```swift
/// NavigationLink("Intent Lab") { CommandLabView(lab: myLab) }
/// ```
///
/// Every control carries an accessibility identifier (`CommandLab.*`), so the
/// screen can be driven by UI automation as well as by `CommandLab.handle(_:)`.
public struct CommandLabView: View {
    @Bindable var lab: CommandLab
    @State private var confirmingPerform: CommandLabRun.Outcome?

    public init(lab: CommandLab) {
        self.lab = lab
    }

    public var body: some View {
        Form {
            trySection
            if let run = lab.run {
                resultSection(run)
                sentSection(run)
            }
            liveSection
            modelSection
            mapSection
        }
        .navigationTitle("Intent Lab")
        .onChange(of: lab.map) { _, _ in lab.saveMap() }
        .navigationDestination(item: $lab.route) { route in
            switch route {
            case .maps: CommandMapsView(lab: lab)
            case .commands: CommandListView(lab: lab)
            case .command(let name): CommandEditor(lab: lab, commandId: name)
            case .templates: TemplateEditor(lab: lab)
            case .appWords: AddressWordsEditor(lab: lab)
            }
        }
        .confirmationDialog("Run this for real?", isPresented: Binding(
            get: { confirmingPerform != nil }, set: { if !$0 { confirmingPerform = nil } }
        ), presenting: confirmingPerform) { outcome in
            Button("Run \(outcome.commandId ?? "nothing")") { Task { await lab.perform(outcome) } }
                .accessibilityIdentifier("CommandLab.result.confirmPerform")
        } message: { outcome in
            Text("This performs the action in the app, exactly as if the sentence had been spoken: \(outcome.actionId ?? "nothing").")
        }
    }

    // MARK: Try

    private var trySection: some View {
        Section {
            TextField("Type a sentence", text: $lab.sentence, axis: .vertical)
                .accessibilityIdentifier("CommandLab.sentence")
                .onSubmit { Task { await lab.runSentence() } }
            Picker("Resolver", selection: $lab.mode) {
                Text("Model").tag(CommandResolver.Mode.model)
                Text("Rules").tag(CommandResolver.Mode.rules)
                Text("Rules, then model").tag(CommandResolver.Mode.rulesThenModel)
            }
            .accessibilityIdentifier("CommandLab.mode")
            Stepper("Tries: \(lab.tries)", value: $lab.tries, in: 1...10)
                .accessibilityIdentifier("CommandLab.tries")
            Toggle("Use demo chats", isOn: $lab.useDemoEntities)
                .accessibilityIdentifier("CommandLab.demoToggle")
            Button {
                Task { await lab.runSentence() }
            } label: {
                if lab.isRunning {
                    HStack { ProgressView(); Text("Running…") }
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .disabled(lab.isRunning || lab.sentence.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("CommandLab.run")
            if let status = lab.status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("CommandLab.status")
            }
        } header: {
            Text("Try a sentence")
        } footer: {
            Text("Each try is a separate call to the model. More than one shows whether it gives the same answer every time.")
        }
    }

    // MARK: Result

    private func resultSection(_ run: CommandLabRun) -> some View {
        Section {
            ForEach(Array(run.outcomes.enumerated()), id: \.element.id) { index, outcome in
                outcomeRow(outcome, tries: run.tries)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("CommandLab.result.outcome.\(index)")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Rules would").foregroundStyle(.secondary)
                    Spacer()
                    Text(run.rules.commandId ?? "nothing runs")
                }
                ForEach(run.rules.inputs.sorted { $0.key < $1.key }, id: \.key) { name, value in
                    Text("\(name): \(value)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("CommandLab.result.rules")
            if let top = run.outcomes.first, top.actionId != nil {
                Button("Run it for real") { confirmingPerform = top }
                    .accessibilityIdentifier("CommandLab.result.perform")
            }
            if let performed = run.performed {
                Text(performed).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("CommandLab.result.performed")
            }
        } header: {
            Text("“\(run.sentence)”")
        } footer: {
            Text(run.isStable
                 ? "Same answer every time."
                 : "Different answers across tries — not safe to act on without a check.")
                .accessibilityIdentifier("CommandLab.result.stability")
        }
    }

    private func outcomeRow(_ outcome: CommandLabRun.Outcome, tries: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(outcome.commandId ?? "nothing runs").font(.headline)
                Spacer()
                Text("\(outcome.count)/\(tries)").monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(outcome.inputs.sorted { $0.key < $1.key }, id: \.key) { name, value in
                Text("\(name): \(value)").font(.subheadline)
            }
            HStack(spacing: 8) {
                if outcome.fellBack { Text("fell back").font(.caption).foregroundStyle(.orange) }
                Text("\(Int(outcome.averageMilliseconds.rounded())) ms").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(outcome.notes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: What was sent

    private func sentSection(_ run: CommandLabRun) -> some View {
        Section("What the model was sent") {
            if let instructions = run.instructions {
                DisclosureGroup("Instructions") { monospaced(instructions) }
                    .accessibilityIdentifier("CommandLab.sent.instructions")
            }
            if let prompt = run.prompt {
                DisclosureGroup("Prompt") { monospaced(prompt) }
                    .accessibilityIdentifier("CommandLab.sent.prompt")
            }
            DisclosureGroup("Raw answers (\(run.rawDecisions.count))") {
                ForEach(Array(run.rawDecisions.enumerated()), id: \.offset) { _, raw in monospaced(raw) }
            }
            .accessibilityIdentifier("CommandLab.sent.raw")
            if run.instructions == nil {
                Text("The rules answered; nothing was sent to the model.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func monospaced(_ text: String) -> some View {
        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }

    // MARK: Live

    private var liveSection: some View {
        Section {
            Toggle("Route live requests", isOn: $lab.live.isEnabled)
                .accessibilityIdentifier("CommandLab.live.enabled")
            Picker("Resolver", selection: $lab.live.mode) {
                Text("Model").tag(CommandResolver.Mode.model)
                Text("Rules").tag(CommandResolver.Mode.rules)
                Text("Rules, then model").tag(CommandResolver.Mode.rulesThenModel)
            }
            .disabled(!lab.live.isEnabled)
            .accessibilityIdentifier("CommandLab.live.mode")
            if let last = lab.lastLive, let outcome = last.outcomes.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last: “\(last.sentence)”").font(.subheadline)
                    Text(outcome.commandId ?? "nothing runs").font(.headline)
                    ForEach(outcome.inputs.sorted { $0.key < $1.key }, id: \.key) { name, value in
                        Text("\(name): \(value)").font(.caption)
                    }
                    Text([last.performed, "\(Int(outcome.averageMilliseconds.rounded())) ms",
                          last.date.formatted(date: .omitted, time: .shortened)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("CommandLab.live.last")
            }
        } header: {
            Text("Live requests")
        } footer: {
            Text((lab.liveDescription.map { $0 + " " } ?? "")
                 + "Uses the active map. A request that lands on the fallback is passed on untouched.")
        }
        .onChange(of: lab.live) { _, _ in lab.saveLive() }
    }

    // MARK: Model

    private var modelSection: some View {
        Section("On-device model") {
            LabeledContent("Available") {
                Text(CommandResolver.isModelAvailable ? "Yes" : (CommandResolver.modelUnavailableReason ?? "No"))
            }
            .accessibilityIdentifier("CommandLab.model.available")
            if let size = CommandResolver.modelContextSize {
                LabeledContent("Context window") { Text("\(size) tokens") }
                    .accessibilityIdentifier("CommandLab.model.context")
            }
            Button("Prewarm") { CommandResolver.prewarm() }
                .accessibilityIdentifier("CommandLab.model.prewarm")
        }
    }

    // MARK: Map

    private var mapSection: some View {
        Section {
            RouteRow(lab: lab, route: .maps, title: "Map", detail: lab.map.name)
                .accessibilityIdentifier("CommandLab.map.maps")
            LabeledContent("Name") {
                TextField("Name", text: $lab.map.name).multilineTextAlignment(.trailing)
            }
            .accessibilityIdentifier("CommandLab.map.name")
            ForEach(lab.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("CommandLab.map.problem")
            }
            RouteRow(lab: lab, route: .commands, title: "Commands",
                     detail: "\(lab.map.enabledCommands.count) of \(lab.map.commands.count) on")
                .accessibilityIdentifier("CommandLab.map.commands")
            RouteRow(lab: lab, route: .templates, title: "Instructions and prompt")
                .accessibilityIdentifier("CommandLab.map.templates")
            RouteRow(lab: lab, route: .appWords, title: "App words")
                .accessibilityIdentifier("CommandLab.map.addressWords")
            if let json = lab.exportMap().flatMap({ String(data: $0, encoding: .utf8) }) {
                ShareLink("Export map", item: json)
                    .accessibilityIdentifier("CommandLab.map.export")
            }
            Button("Reset commands to default", role: .destructive) { lab.resetMap() }
                .accessibilityIdentifier("CommandLab.map.reset")
        } header: {
            Text("Command map")
        } footer: {
            Text("The map being edited and run. Saved on this device as you edit; Export shares it as JSON.")
        }
    }
}

/// A row that pushes a Lab screen by setting `lab.route` — looks and behaves
/// like a navigation link, but the destination is state, so it can be driven
/// (and backed out of) by URL as well as by a tap.
struct RouteRow: View {
    let lab: CommandLab
    let route: CommandLab.Route
    let title: String
    var detail: String?

    var body: some View {
        Button {
            lab.route = route
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let detail { Text(detail).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Maps

struct CommandMapsView: View {
    @Bindable var lab: CommandLab
    @State private var importing = false

    var body: some View {
        List {
            Section {
                ForEach(lab.maps) { map in
                    Button {
                        lab.activate(map.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(map.name).foregroundStyle(.primary)
                                Text("\(map.enabledCommands.count) commands on")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if map.id == lab.map.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                                    .accessibilityLabel("Active")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    // Plain, so a map name reads as a name and not as a link.
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("CommandMaps.map.\(map.name)")
                    .swipeActions(edge: .trailing) {
                        if lab.maps.count > 1 {
                            Button("Delete", role: .destructive) { lab.deleteMap(map.id) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Duplicate") { lab.createMap(named: "\(map.name) copy", from: map) }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button("Duplicate") { lab.createMap(named: "\(map.name) copy", from: map) }
                        if lab.maps.count > 1 {
                            Button("Delete", role: .destructive) { lab.deleteMap(map.id) }
                        }
                    }
                }
            } footer: {
                Text("Tap a map to use it. The ticked one is edited and run by the Lab. Swipe to duplicate or delete.")
            }

            Section {
                Button {
                    lab.createMap(named: "New map")
                } label: {
                    Label("New map from default", systemImage: "plus")
                }
                .accessibilityIdentifier("CommandMaps.new")
                Button {
                    lab.duplicateActiveMap()
                } label: {
                    Label("Duplicate \(lab.map.name)", systemImage: "plus.square.on.square")
                }
                .accessibilityIdentifier("CommandMaps.duplicate")
                Button {
                    importing = true
                } label: {
                    Label("Import JSON", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("CommandMaps.import")
            }

            if let status = lab.status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    .accessibilityIdentifier("CommandMaps.status")
            }
        }
        .navigationTitle("Maps")
        .sheet(isPresented: $importing) {
            ImportMapSheet(lab: lab, isPresented: $importing)
        }
    }
}

/// Paste a map, or pick a .json file. An import always becomes a new map.
struct ImportMapSheet: View {
    @Bindable var lab: CommandLab
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var choosingFile = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 240)
                        .accessibilityIdentifier("ImportMap.json")
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { text = first }
                    }
                    .accessibilityIdentifier("ImportMap.paste")
                } header: {
                    Text("Map JSON")
                } footer: {
                    Text("An exported map. It is added as a new map and never replaces one already here.")
                }
                Section {
                    Button {
                        choosingFile = true
                    } label: {
                        Label("Choose a file…", systemImage: "folder")
                    }
                    .accessibilityIdentifier("ImportMap.file")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                        .accessibilityIdentifier("ImportMap.error")
                }
            }
            .navigationTitle("Import map")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .accessibilityIdentifier("ImportMap.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { finish(Data(text.utf8)) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ImportMap.import")
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) { finish(data) } else { error = "Couldn't read that file." }
                case .failure(let failure):
                    error = failure.localizedDescription
                }
            }
        }
    }

    private func finish(_ data: Data) {
        if lab.importMap(data) {
            isPresented = false
        } else {
            error = lab.status
        }
    }
}

// MARK: - Commands

struct CommandListView: View {
    @Bindable var lab: CommandLab

    var body: some View {
        List {
            Section {
                ForEach($lab.map.commands) { $command in
                    NavigationLink {
                        CommandEditor(lab: lab, commandId: command.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(command.id).font(.headline)
                                if lab.map.fallbackCommandId == command.id {
                                    Text("fallback").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Text(lab.registry.action(command.actionId)?.title ?? "No action: \(command.actionId)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .opacity(command.isEnabled ? 1 : 0.45)
                    }
                    .accessibilityIdentifier("CommandList.command.\(command.id)")
                }
                .onDelete { lab.map.commands.remove(atOffsets: $0) }
                .onMove { lab.map.commands.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("The model can only answer with an enabled command. Order is the order it reads them in.")
            }
            Button {
                let number = lab.map.commands.count + 1
                lab.map.commands.append(SoftCommand(
                    id: "command_\(number)", description: "", actionId: lab.registry.actions.first?.id ?? "",
                    isEnabled: false))
            } label: {
                Label("Add command", systemImage: "plus")
            }
            .accessibilityIdentifier("CommandList.add")
        }
        .navigationTitle("Commands")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
        .onChange(of: lab.map) { _, _ in lab.saveMap() }
    }
}

struct CommandEditor: View {
    @Bindable var lab: CommandLab
    let commandId: String

    private var index: Int? { lab.map.commands.firstIndex { $0.id == commandId } }

    var body: some View {
        if let index {
            form(index)
                .navigationTitle(lab.map.commands[index].id)
                .onChange(of: lab.map) { _, _ in lab.saveMap() }
        } else {
            Text("This command no longer exists.")
        }
    }

    private func form(_ index: Int) -> some View {
        Form {
            Section {
                TextField("open_chat", text: Binding(
                    get: { lab.map.commands[index].id },
                    set: { newValue in
                        let clean = Self.commandName(newValue)
                        guard !clean.isEmpty, !lab.map.commands.contains(where: { $0.id == clean }) else { return }
                        if lab.map.fallbackCommandId == lab.map.commands[index].id { lab.map.fallbackCommandId = clean }
                        lab.map.commands[index].id = clean
                    }))
                    .accessibilityIdentifier("CommandEditor.name")
                Toggle("Enabled", isOn: $lab.map.commands[index].isEnabled)
                    .accessibilityIdentifier("CommandEditor.enabled")
                Toggle("Fallback for anything unclear", isOn: Binding(
                    get: { lab.map.fallbackCommandId == lab.map.commands[index].id },
                    set: { lab.map.fallbackCommandId = $0 ? lab.map.commands[index].id : nil }))
                    .accessibilityIdentifier("CommandEditor.fallback")
            } header: {
                Text("Name")
            } footer: {
                Text("What the model answers with. Short, lowercase, meaningful.")
            }

            Section {
                TextField("What this command is for", text: $lab.map.commands[index].description, axis: .vertical)
                    .accessibilityIdentifier("CommandEditor.description")
            } header: {
                Text("What the model is told")
            }

            Section {
                TextField("One per line", text: Binding(
                    get: { lab.map.commands[index].examples.joined(separator: "\n") },
                    set: { lab.map.commands[index].examples = $0.components(separatedBy: "\n") }),
                    axis: .vertical)
                    .accessibilityIdentifier("CommandEditor.examples")
            } header: {
                Text("What people say")
            } footer: {
                Text("Phrases a person says for this command — also the rules' trigger phrases. Never examples of what to write: the model copies those into its answers.")
            }

            Section("Runs") {
                Picker("Action", selection: $lab.map.commands[index].actionId) {
                    ForEach(lab.registry.actions) { action in Text(action.title).tag(action.id) }
                }
                .accessibilityIdentifier("CommandEditor.action")
            }

            if let action = lab.registry.action(lab.map.commands[index].actionId), !action.parameters.isEmpty {
                Section {
                    ForEach(action.parameters, id: \.name) { parameter in
                        Picker(parameter.name + (parameter.isRequired ? "" : " (optional)"),
                               selection: binding(index, parameter)) {
                            ForEach(BindingChoice.choices(for: parameter.kind), id: \.self) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .accessibilityIdentifier("CommandEditor.input.\(parameter.name)")
                    }
                } header: {
                    Text("Inputs")
                } footer: {
                    Text("“Matched by name” never asks the model. Model-written text is measured as the least reliable thing it produces.")
                }
            }
        }
    }

    private func binding(_ index: Int, _ parameter: ActionParameter) -> Binding<BindingChoice> {
        Binding(
            get: { BindingChoice(lab.map.commands[index].bindings[parameter.name]) },
            set: { lab.map.commands[index].bindings[parameter.name] = $0.binding })
    }

    static func commandName(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

enum BindingChoice: String, CaseIterable, Hashable {
    case none, modelPicks, rulesMatch, utterance, modelWrites

    init(_ binding: ParameterBinding?) {
        switch binding {
        case .modelPicks: self = .modelPicks
        case .rulesMatch: self = .rulesMatch
        case .utterance: self = .utterance
        case .modelWrites: self = .modelWrites
        case .constant, nil: self = .none
        }
    }

    var binding: ParameterBinding? {
        switch self {
        case .none: return nil
        case .modelPicks: return .modelPicks
        case .rulesMatch: return .rulesMatch
        case .utterance: return .utterance
        case .modelWrites: return .modelWrites
        }
    }

    var title: String {
        switch self {
        case .none: return "Leave empty"
        case .modelPicks: return "Model picks by number"
        case .rulesMatch: return "Matched by name"
        case .utterance: return "What was said"
        case .modelWrites: return "Model writes it"
        }
    }

    static func choices(for kind: ActionParameter.Kind) -> [BindingChoice] {
        switch kind {
        case .entity: return [.modelPicks, .rulesMatch, .none]
        case .text: return [.utterance, .modelWrites, .none]
        }
    }
}

// MARK: - Templates and app words

struct TemplateEditor: View {
    @Bindable var lab: CommandLab

    var body: some View {
        Form {
            Section {
                TextEditor(text: $lab.map.instructionsTemplate)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 220)
                    .accessibilityIdentifier("TemplateEditor.instructions")
            } header: {
                Text("Instructions")
            } footer: {
                Text("{{commands}} becomes the command list; {{fallback}} the fallback command's name.")
            }
            Section {
                TextEditor(text: $lab.map.promptTemplate)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 100)
                    .accessibilityIdentifier("TemplateEditor.prompt")
            } header: {
                Text("Prompt, per sentence")
            } footer: {
                Text("{{entities}} becomes the numbered lists; {{sentence}} what was said.")
            }
            Section {
                Button("Restore default templates") {
                    lab.map.instructionsTemplate = CommandMap.defaultInstructionsTemplate
                    lab.map.promptTemplate = CommandMap.defaultPromptTemplate
                }
                .accessibilityIdentifier("TemplateEditor.restore")
            }
        }
        .navigationTitle("Instructions")
        .onChange(of: lab.map) { _, _ in lab.saveMap() }
    }
}

struct AddressWordsEditor: View {
    @Bindable var lab: CommandLab

    var body: some View {
        Form {
            Section {
                TextField("One per line", text: Binding(
                    get: { lab.map.addressWords.joined(separator: "\n") },
                    set: { lab.map.addressWords = $0.components(separatedBy: "\n") }),
                    axis: .vertical)
                    .accessibilityIdentifier("AddressWordsEditor.words")
            } footer: {
                Text("The app's name and how speech recognition mishears it. Removed from any text handed on, so \"tell Ripul to run the tests\" passes on \"run the tests\".")
            }
        }
        .navigationTitle("App words")
        .onChange(of: lab.map) { _, _ in lab.saveMap() }
    }
}
