#if os(iOS)
import SwiftUI

/// In-place macro editing AND replay (docs/plans/automation-macros/): one
/// screen instead of two. Edits a working copy of the macro — delete,
/// drag-reorder, per-step field edits, insert waits — and replays THAT COPY
/// directly (unsaved edits included, so you can test before saving):
/// HUD-mode when the overlay exists (sheets unwind, the strip runs on the
/// host screen; the working copy is stashed and restored on the way back so
/// the round-trip never silently reverts to the stored macro), inline with
/// live per-step statuses otherwise. Also carries the former replay screen's
/// remaining duties: parameter fields, outcome banner, and Copy log.
@available(iOS 16.0, *)
struct MacroEditScreen: View {
    let macro: RipulMacro
    let client: RipulMacroClient
    let onSaved: () -> Void

    @State private var name: String
    @State private var descriptionText: String
    @State private var steps: [MacroStep]
    @State private var paramValues: [String: String]
    @State private var statuses: [MacroReplayHUDController.StepStatus]?
    @State private var outcome: MacroReplayResult?
    @State private var lastRunMacro: RipulMacro?
    @State private var isRunningInline = false
    @State private var didCopy = false
    @State private var editingStep: StepIndex?
    @State private var insertChoice: InsertChoice?
    @State private var isSaving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hud = MacroReplayHUDController.shared

    init(macro: RipulMacro, client: RipulMacroClient, onSaved: @escaping () -> Void) {
        self.macro = macro
        self.client = client
        self.onSaved = onSaved
        _name = State(initialValue: macro.name)
        _descriptionText = State(initialValue: macro.description)
        _steps = State(initialValue: macro.steps)
        _paramValues = State(initialValue: [:])
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !descriptionText.trimmingCharacters(in: .whitespaces).isEmpty
            && !steps.isEmpty
    }

    private var derivedParameters: [MacroParameter] {
        MacroParameterSubstitution.detectParameters(in: steps).map { n in
            MacroParameter(name: n, description: macro.parameters.first { $0.name == n }?.description ?? "")
        }
    }

    private var isReplayBusy: Bool { isRunningInline || hud.phase == .running }

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

                if !derivedParameters.isEmpty {
                    Section("Parameters (used when replaying)") {
                        ForEach(derivedParameters, id: \.name) { parameter in
                            TextField(
                                parameter.description.isEmpty ? parameter.name : "\(parameter.name) — \(parameter.description)",
                                text: Binding(
                                    get: { paramValues[parameter.name] ?? "" },
                                    set: { paramValues[parameter.name] = $0 }
                                )
                            )
                            .autocorrectionDisabled()
                            .uiKitIdentifier("MacroEditScreen.param.\(parameter.name)")
                        }
                    }
                }

                Section {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        Button {
                            clearRunState()
                            editingStep = StepIndex(value: index)
                        } label: {
                            HStack(spacing: 10) {
                                leadingIcon(for: index, kind: step.kind)
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
                                clearRunState()
                                insertChoice = InsertChoice(index: index, kind: nil)
                            } label: {
                                Label("Insert wait", systemImage: "plus")
                            }
                            .tint(.blue)
                            .uiKitIdentifier("MacroEditScreen.step.\(index).insertAfter")
                        }
                    }
                    .onDelete { clearRunState(); steps.remove(atOffsets: $0) }
                    .onMove { clearRunState(); steps.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Drag to reorder. Swipe right to insert a wait after a step. Tap a step to edit it.")
                }

                Section {
                    Button {
                        clearRunState()
                        insertChoice = InsertChoice(index: steps.count - 1, kind: nil)
                    } label: {
                        Label("Add a wait at the end", systemImage: "plus.circle")
                    }
                    .uiKitIdentifier("MacroEditScreen.addWaitAtEnd")

                    Button {
                        Task { await runReplay() }
                    } label: {
                        HStack {
                            Spacer()
                            if isReplayBusy {
                                ProgressView()
                            } else {
                                Label("Replay", systemImage: "play.fill")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(steps.isEmpty || isReplayBusy || isSaving)
                    .uiKitIdentifier("MacroEditScreen.replayButton")
                }

                if let outcome {
                    Section {
                        Label(
                            outcome.success
                                ? "All \(outcome.totalSteps) steps completed."
                                : "Stopped at step \((outcome.failedStepIndex ?? 0) + 1) of \(outcome.totalSteps) — \(outcome.error ?? "unknown error")",
                            systemImage: outcome.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(outcome.success ? .green : .red)
                        .font(.subheadline.weight(.medium))
                    }
                }
            }
            .navigationTitle("Edit \(macro.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .uiKitIdentifier("MacroEditScreen.cancelButton")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { copyLog() } label: {
                        Label(didCopy ? "Copied" : "Copy log", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.subheadline)
                    }
                    .disabled(outcome == nil || lastRunMacro == nil)
                    .uiKitIdentifier("MacroEditScreen.copyLogButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 12) {
                        EditButton()
                            .uiKitIdentifier("MacroEditScreen.reorderButton")
                        Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                            .disabled(!isValid || isSaving || isReplayBusy)
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
                    clearRunState()
                    steps[stepIndex.value] = edited
                }
            }
            .sheet(item: $insertChoice) { choice in
                MacroInsertWaitSheet(afterIndex: choice.index) { step in
                    clearRunState()
                    let at = min(choice.index + 1, steps.count)
                    steps.insert(step, at: at)
                }
            }
            .onAppear { adoptRoundTripState() }
        }
    }

    /// Status icon when a run has happened for these steps, else the kind icon.
    @ViewBuilder
    private func leadingIcon(for index: Int, kind: MacroStepKind) -> some View {
        if let statuses, statuses.indices.contains(index) {
            switch statuses[index] {
            case .running:
                ProgressView().frame(width: 20, height: 20)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 20)
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).frame(width: 20)
            case .pending:
                Image(systemName: "circle").foregroundStyle(.tertiary).frame(width: 20)
            }
        } else {
            Image(systemName: icon(for: kind))
                .foregroundStyle(.tint)
                .frame(width: 20)
        }
    }

    private func icon(for kind: MacroStepKind) -> String {
        switch kind {
        case .tap: return "hand.tap"
        case .setValue: return "slider.horizontal.3"
        case .type: return "keyboard"
        case .scroll: return "arrow.up.arrow.down"
        case .wait: return "hourglass"
        case .pause: return "timer"
        }
    }

    private func summary(for step: MacroStep) -> String {
        switch step.kind {
        case .setValue:
            return "= \(step.text ?? "?")"
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

    /// The macro as it stands RIGHT NOW in this editor (unsaved edits
    /// included) — replay always runs this, so test-before-save is free.
    private func workingMacro() -> RipulMacro {
        RipulMacro(id: macro.id, name: MacroSlug.slug(from: name), description: descriptionText,
                   steps: steps, parameters: derivedParameters, published: macro.published,
                   siteKeyId: macro.siteKeyId, createdAt: macro.createdAt, updatedAt: Date())
    }

    /// Any structural edit invalidates the displayed run results (status
    /// icons index into the step list).
    private func clearRunState() {
        statuses = nil
        outcome = nil
        lastRunMacro = nil
    }

    /// Restore the working copy stashed when a HUD replay began (the sheet
    /// stack unwinds for the run; the return trip must not revert to the
    /// stored macro), and adopt the run's statuses/outcome for display.
    private func adoptRoundTripState() {
        if let stash = MacroDeepLink.pendingEditorState, stash.macroId == macro.id {
            MacroDeepLink.pendingEditorState = nil
            name = stash.name
            descriptionText = stash.description
            steps = stash.steps
            paramValues = stash.paramValues
        }
        if hud.currentMacro?.id == macro.id, hud.statuses.count == steps.count {
            statuses = hud.statuses
            outcome = hud.outcome
            lastRunMacro = hud.currentMacro
        }
    }

    private func runReplay() async {
        let working = workingMacro()
        // HUD mode (overlay exists): the strip takes over the host screen;
        // stash the working copy so the return trip restores it.
        if #available(iOS 26.0, *),
           MacroReplayHUDController.shared.begin(
               working, parameters: paramValues,
               resolver: LiveScreenResolver(), presenter: DevOverlayReplayPresenter()
           ) {
            MacroDeepLink.pendingEditorState = MacroEditorState(
                macroId: macro.id, name: name, description: descriptionText,
                steps: steps, paramValues: paramValues)
            dismiss()
            return
        }
        // Fallback (no overlay): inline run with live statuses in this list.
        await runInline(working)
    }

    private func runInline(_ working: RipulMacro) async {
        isRunningInline = true
        statuses = Array(repeating: .pending, count: working.steps.count)
        lastRunMacro = working
        guard let result = try? await (MacroReplayEngine.replay(
            working, parameters: paramValues, resolver: LiveScreenResolver()
        ) { event in
            guard let current = statuses, current.indices.contains(event.index) else { return }
            var updated = current
            switch event.phase {
            case .started:
                updated[event.index] = .running
            case .succeeded(let via, _, _):
                updated[event.index] = .succeeded(via: via)
            case .failed(let error, _, _):
                updated[event.index] = .failed(error: error)
            }
            statuses = updated
        }) else {
            isRunningInline = false
            return
        }
        outcome = result
        isRunningInline = false
    }

    private func copyLog() {
        guard let outcome, let lastRunMacro else { return }
        UIPasteboard.general.string = MacroReplayLog.text(macro: lastRunMacro, paramValues: paramValues, outcome: outcome)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await client.update(id: macro.id, edit: RipulMacroEdit(
                name: MacroSlug.slug(from: name),
                description: descriptionText,
                steps: steps,
                parameters: derivedParameters
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
                case .setValue:
                    Section("Value ({{name}} = filled at call time)") {
                        TextField("e.g. 09:00, 2026-08-02 09:00, on, 2", text: $payloadText)
                    }
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
