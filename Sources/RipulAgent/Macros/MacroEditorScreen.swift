#if os(iOS)
import SwiftUI

/// In-place macro editing (docs/plans/automation-macros/): opened from a
/// library row, edits a copy of the macro's steps — delete, drag-reorder,
/// per-step field edits (selector, payload, wait timing), insert manual
/// waits after any step — then PATCHes the whole thing back. Parameters are
/// re-derived from `{{token}}` usage on save, preserving descriptions for
/// names that survived.
@available(iOS 16.0, *)
struct MacroEditScreen: View {
    let macro: RipulMacro
    let client: RipulMacroClient
    let onSaved: () -> Void

    @State private var name: String
    @State private var descriptionText: String
    @State private var steps: [MacroStep]
    @State private var editingStep: StepIndex?
    @State private var insertChoice: InsertChoice?
    @State private var isSaving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(macro: RipulMacro, client: RipulMacroClient, onSaved: @escaping () -> Void) {
        self.macro = macro
        self.client = client
        self.onSaved = onSaved
        _name = State(initialValue: macro.name)
        _descriptionText = State(initialValue: macro.description)
        _steps = State(initialValue: macro.steps)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !descriptionText.trimmingCharacters(in: .whitespaces).isEmpty
            && !steps.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Details") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .uiKitIdentifier("MacroEditScreen.nameField")
                    TextField("Description (what the agent reads)", text: $descriptionText, axis: .vertical)
                        .uiKitIdentifier("MacroEditScreen.descriptionField")
                }

                Section {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        Button { editingStep = StepIndex(value: index) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: step.kind))
                                    .foregroundStyle(.tint)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(step.recordedLabel)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(summary(for: step))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button {
                                insertChoice = InsertChoice(index: index, kind: nil)
                            } label: {
                                Label("Insert wait", systemImage: "plus")
                            }
                            .tint(.blue)
                            .uiKitIdentifier("MacroEditScreen.step.\(index).insertAfter")
                        }
                    }
                    .onDelete { steps.remove(atOffsets: $0) }
                    .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Drag to reorder. Swipe right to insert a wait after a step. Tap a step to edit it.")
                }

                Section {
                    Button {
                        insertChoice = InsertChoice(index: steps.count - 1, kind: nil)
                    } label: {
                        Label("Add a wait at the end", systemImage: "plus.circle")
                    }
                    .uiKitIdentifier("MacroEditScreen.addWaitAtEnd")
                }
            }
            .navigationTitle("Edit \(macro.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .uiKitIdentifier("MacroEditScreen.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 12) {
                        EditButton()
                            .uiKitIdentifier("MacroEditScreen.reorderButton")
                        Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                            .disabled(!isValid || isSaving)
                            .fontWeight(.semibold)
                            .uiKitIdentifier("MacroEditScreen.saveButton")
                    }
                }
            }
            .alert("Couldn't save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .sheet(item: $editingStep) { stepIndex in
                MacroStepEditSheet(step: steps[stepIndex.value]) { edited in
                    steps[stepIndex.value] = edited
                }
            }
            .sheet(item: $insertChoice) { choice in
                MacroInsertWaitSheet(afterIndex: choice.index) { step in
                    let at = min(choice.index + 1, steps.count)
                    steps.insert(step, at: at)
                }
            }
        }
    }

    private func icon(for kind: MacroStepKind) -> String {
        switch kind {
        case .tap: return "hand.tap"
        case .type: return "keyboard"
        case .scroll: return "arrow.up.arrow.down"
        case .wait: return "hourglass"
        case .pause: return "timer"
        }
    }

    private func summary(for step: MacroStep) -> String {
        switch step.kind {
        case .type:
            return step.text ?? step.selector.compactSummary
        case .scroll:
            return "\(step.direction ?? "down") × \(step.amount ?? 0.8)"
        case .wait:
            return "\(step.state ?? "visible") · \(Int(step.timeout ?? 5))s"
        case .pause:
            return "\(step.seconds ?? 1)s"
        case .tap:
            return step.selector.compactSummary
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // Params follow {{token}} usage, keeping descriptions for names that
        // survived the edit.
        let parameters = MacroParameterSubstitution.detectParameters(in: steps).map { name in
            MacroParameter(name: name, description: macro.parameters.first { $0.name == name }?.description ?? "")
        }
        do {
            _ = try await client.update(id: macro.id, edit: RipulMacroEdit(
                name: MacroSlug.slug(from: name),
                description: descriptionText,
                steps: steps,
                parameters: parameters
            ))
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Identifiable wrapper for `.sheet(item:)` — `Int` doesn't conform.
private struct StepIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

/// Which gap an inserted wait lands in (`index` = the step it goes AFTER).
private struct InsertChoice: Identifiable {
    let index: Int
    /// nil → the chooser (appear / disappear / pause) is still being asked.
    var kind: MacroInsertWaitSheet.Mode?
    var id: Int { index }
}

/// Per-step field editor: label + selector (all kinds except pause) + the
/// kind's own payload. Selector edits keep every predicate optional —
/// clearing a field just drops it from the selector.
@available(iOS 16.0, *)
private struct MacroStepEditSheet: View {
    let step: MacroStep
    let onSave: (MacroStep) -> Void

    @State private var label: String
    @State private var idText: String
    @State private var text: String
    @State private var role: String
    @State private var className: String
    @State private var nthText: String
    @State private var withinText: String
    @State private var payloadText: String
    @State private var append: Bool
    @State private var direction: String
    @State private var amountText: String
    @State private var state: String
    @State private var timeoutText: String
    @State private var secondsText: String
    @Environment(\.dismiss) private var dismiss

    init(step: MacroStep, onSave: @escaping (MacroStep) -> Void) {
        self.step = step
        self.onSave = onSave
        _label = State(initialValue: step.recordedLabel)
        _idText = State(initialValue: step.selector.id ?? "")
        _text = State(initialValue: step.selector.text ?? "")
        _role = State(initialValue: step.selector.role ?? "")
        _className = State(initialValue: step.selector.className ?? "")
        _nthText = State(initialValue: step.selector.nth.map(String.init) ?? "")
        _withinText = State(initialValue: step.selector.within?.text ?? "")
        _payloadText = State(initialValue: step.text ?? "")
        _append = State(initialValue: step.append ?? false)
        _direction = State(initialValue: step.direction ?? "down")
        _amountText = State(initialValue: step.amount.map { String($0) } ?? "0.8")
        _state = State(initialValue: step.state ?? "visible")
        _timeoutText = State(initialValue: step.timeout.map { String(Int($0)) } ?? "5")
        _secondsText = State(initialValue: step.seconds.map { String($0) } ?? "1")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("Shown in the step list and logs", text: $label)
                }

                if step.kind != .pause {
                    Section("Selector (all optional — every given predicate must match)") {
                        TextField("id", text: $idText).autocorrectionDisabled()
                        TextField("text", text: $text).autocorrectionDisabled()
                        Picker("role", selection: $role) {
                            Text("any").tag("")
                            ForEach(ScreenElementFinder.roleVocabulary, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("class", text: $className).autocorrectionDisabled()
                        TextField("nth (0-based, when several match)", text: $nthText)
                            .keyboardType(.numberPad)
                        TextField("within — anchor text", text: $withinText).autocorrectionDisabled()
                    }
                }

                switch step.kind {
                case .type:
                    Section("Text to type ({{name}} = filled at call time)") {
                        TextField("Text", text: $payloadText, axis: .vertical)
                        Toggle("Append instead of replace", isOn: $append)
                    }
                case .scroll:
                    Section("Scroll") {
                        Picker("Direction", selection: $direction) {
                            ForEach(["up", "down", "left", "right"], id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Amount (0.1–2.0)", text: $amountText).keyboardType(.decimalPad)
                    }
                case .wait:
                    Section("Wait") {
                        Picker("Until it is", selection: $state) {
                            Text("visible").tag("visible")
                            Text("gone").tag("gone")
                        }
                        TextField("Timeout (seconds)", text: $timeoutText).keyboardType(.numberPad)
                    }
                case .pause:
                    Section("Pause") {
                        TextField("Seconds", text: $secondsText).keyboardType(.decimalPad)
                    }
                case .tap:
                    EmptyView()
                }
            }
            .navigationTitle("Edit step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        var selector = MacroSelector(
            id: idText.isEmpty ? nil : idText,
            text: text.isEmpty ? nil : text,
            role: role.isEmpty ? nil : role,
            className: className.isEmpty ? nil : className,
            nth: Int(nthText),
            within: withinText.isEmpty ? nil : MacroAnchorSelector(text: withinText)
        )
        if step.kind == .pause { selector = MacroSelector() }

        let edited = MacroStep(
            id: step.id, kind: step.kind, selector: selector,
            text: step.kind == .type ? payloadText : nil,
            append: step.kind == .type ? append : nil,
            direction: step.kind == .scroll ? direction : nil,
            amount: step.kind == .scroll ? Double(amountText) : nil,
            state: step.kind == .wait ? state : nil,
            timeout: step.kind == .wait ? Double(timeoutText) : nil,
            seconds: step.kind == .pause ? Double(secondsText) : nil,
            recordedLabel: label.isEmpty ? step.recordedLabel : label
        )
        onSave(edited)
        dismiss()
    }
}

/// The insert-wait form: which kind (appear / disappear / pause), the match
/// text for element waits, or the duration for a pause.
@available(iOS 16.0, *)
private struct MacroInsertWaitSheet: View {
    enum Mode: String, CaseIterable {
        case appear = "Wait for element to appear"
        case disappear = "Wait for element to disappear"
        case pause = "Fixed pause"
    }

    let afterIndex: Int
    let onInsert: (MacroStep) -> Void

    @State private var mode: Mode = .appear
    @State private var matchText = ""
    @State private var timeoutText = "5"
    @State private var secondsText = "1"
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        switch mode {
        case .appear, .disappear: return !matchText.trimmingCharacters(in: .whitespaces).isEmpty
        case .pause: return (Double(secondsText) ?? 0) > 0
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)

                switch mode {
                case .appear, .disappear:
                    Section {
                        TextField("Text to match", text: $matchText)
                            .autocorrectionDisabled()
                        TextField("Timeout (seconds)", text: $timeoutText)
                            .keyboardType(.numberPad)
                    } footer: {
                        Text("The step resolves as soon as an element containing this text is \(mode == .appear ? "visible" : "gone"); it fails after the timeout.")
                    }
                case .pause:
                    Section {
                        TextField("Seconds", text: $secondsText)
                            .keyboardType(.decimalPad)
                    } footer: {
                        Text("Always succeeds after this long — settle time for animations and transitions.")
                    }
                }
            }
            .navigationTitle("Insert wait")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") { insert() }
                        .disabled(!isValid)
                        .fontWeight(.semibold)
                        .uiKitIdentifier("MacroInsertWaitSheet.insertButton")
                }
            }
        }
    }

    private func insert() {
        let step: MacroStep
        switch mode {
        case .appear:
            step = MacroStep(kind: .wait, selector: MacroSelector(text: matchText),
                            state: "visible", timeout: Double(timeoutText) ?? 5,
                            recordedLabel: "Wait for '\(matchText)' to appear")
        case .disappear:
            step = MacroStep(kind: .wait, selector: MacroSelector(text: matchText),
                            state: "gone", timeout: Double(timeoutText) ?? 5,
                            recordedLabel: "Wait for '\(matchText)' to disappear")
        case .pause:
            let seconds = Double(secondsText) ?? 1
            step = MacroStep(kind: .pause, selector: MacroSelector(), seconds: seconds,
                            recordedLabel: "Pause \(secondsText)s")
        }
        onInsert(step)
        dismiss()
    }
}
#endif
