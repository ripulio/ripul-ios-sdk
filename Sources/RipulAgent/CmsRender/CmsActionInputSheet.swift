import SwiftUI

/// The form an action button shows before it runs a mutation whose action
/// contract names inputs nothing on the page supplies: the native twin of the
/// web's `ActionInputDialog`. A system `Form` with Cancel and Save in the
/// toolbar, one native control per input type (text and number fields, a
/// toggle, date pickers, a picker for choices). Save is enabled once the
/// required inputs are filled and the shared rules pass (`CmsActionForm`).
///
/// Save confirms (when the mutation asks to) and runs through `onSave`, which
/// returns the server's refusal or nil. A refusal stays in the form with the
/// values; success closes it.
struct CmsActionInputSheet: View {
    @ObservedObject var runtime: CmsRuntime
    let title: String
    let inputs: [CmsActionInputDef]
    let confirmMessage: String?
    let confirmLabel: String
    let onSave: ([String: CmsJSON]) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String: CmsActionForm.Draft]
    @State private var running = false
    @State private var failure: String?
    @State private var pending: [String: CmsJSON]?

    init(runtime: CmsRuntime, title: String, inputs: [CmsActionInputDef], confirmMessage: String?,
         confirmLabel: String, onSave: @escaping ([String: CmsJSON]) async -> String?) {
        self.runtime = runtime
        self.title = title
        self.inputs = inputs
        self.confirmMessage = confirmMessage
        self.confirmLabel = confirmLabel
        self.onSave = onSave
        _draft = State(initialValue: CmsActionForm.initialDraft(inputs))
    }

    private var validation: CmsActionForm.Validation { CmsActionForm.validate(inputs, draft: draft) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Hidden and computed inputs are the record form's; never drawn here.
                    ForEach(inputs.filter { $0.hidden != true && $0.fromComputed == nil }) { input in
                        field(input)
                        if let message = validation.errors.first(where: { $0.field == input.name })?.message {
                            Text(message)
                                .font(.ripul(.footnote))
                                .foregroundStyle(.ripul(.danger))
                                .cmsInspectorID("Cms.actionInputSheet.fieldError")
                        } else if let note = input.description, !note.isEmpty {
                            Text(note)
                                .font(.ripul(.footnote))
                                .foregroundStyle(.ripul(.textSecondary))
                        }
                    }
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.ripul(.danger))
                            .cmsInspectorID("Cms.actionInputSheet.failure")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(running)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(running)
                        .cmsInspectorID("Cms.actionInputSheet.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if running {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(!validation.ready)
                            .cmsInspectorID("Cms.actionInputSheet.save")
                    }
                }
            }
            .alert("Confirm", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                Button("Cancel", role: .cancel) {}
                Button(confirmLabel) { if let params = pending { run(params) } }
            } message: {
                Text(confirmMessage ?? "")
            }
        }
        .interactiveDismissDisabled(running)
        .tint(runtime.theme.primary)
    }

    private func save() {
        let check = validation
        guard check.ready else { return }
        let params = CmsActionForm.typedParams(inputs, values: check.values)
        if let confirmMessage, !confirmMessage.isEmpty { pending = params } else { run(params) }
    }

    private func run(_ params: [String: CmsJSON]) {
        pending = nil
        failure = nil
        running = true
        Task {
            let refusal = await onSave(params)
            running = false
            if let refusal { failure = refusal } else { dismiss() }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func field(_ input: CmsActionInputDef) -> some View {
        let label = input.displayLabel
        switch CmsActionForm.control(for: input) {
        case .toggle:
            Toggle(label, isOn: boolBinding(input.name))
                .cmsInspectorID("Cms.actionInputSheet.toggle")
        case .date, .dateTime, .time:
            dateField(input, label: label)
        case .choice:
            if let query = input.optionsQuery {
                CmsActionQueryPicker(runtime: runtime, input: input, query: query, label: label, selection: textBinding(input.name))
            } else {
                choicePicker(input, label: label,
                             choices: (input.options?.choices ?? []).map { ($0.value, ($0.label?.isEmpty == false ? $0.label : nil) ?? $0.value) },
                             selection: textBinding(input.name))
            }
        case .multiline:
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
                TextField(input.isRequired ? "Required" : "Optional", text: textBinding(input.name), axis: .vertical)
                    .lineLimit(3...8)
                    .autocorrectionDisabled()
                    .cmsInspectorID("Cms.actionInputSheet.multiline")
            }
        case .unsupported, .list, .dates:
            // A list or a set of days is entered in the record form (CmsRecordFormSheet).
            LabeledContent(label) { Text("Can't be entered here") }
        case .number, .text, .duration:
            LabeledContent {
                TextField(label, text: textBinding(input.name), prompt: Text(input.isRequired ? "Required" : "Optional"))
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(keyboard(for: input))
                    #endif
                    .cmsInspectorID("Cms.actionInputSheet.textField")
            } label: {
                Text(label)
            }
        }
    }

    #if os(iOS)
    private func keyboard(for input: CmsActionInputDef) -> UIKeyboardType {
        switch input.type {
        case "integer": return .numberPad
        case "float": return .decimalPad
        default:
            switch input.validation?.format {
            case "email": return .emailAddress
            case "url": return .URL
            case "phone": return .phonePad
            default: return .default
            }
        }
    }
    #endif

    /// A required date shows a picker straight away; an optional one has a
    /// toggle that adds it, as Reminders does for a due date. A date that must
    /// come after another (`after`) offers nothing earlier than it, as an
    /// event's end does in Calendar.
    @ViewBuilder
    private func dateField(_ input: CmsActionInputDef, label: String) -> some View {
        let control = CmsActionForm.control(for: input)
        let components: DatePickerComponents = control == .date ? [.date] : control == .time ? [.hourAndMinute] : [.date, .hourAndMinute]
        let binding = dateBinding(input.name)
        let lower = lowerBound(for: input)
        let style = CmsDatePickerStyle.resolve(input, form: nil)
        if style != .sheet {
            // `floating` or `inline` (`picker` on the input): a row showing the value.
            if !input.isRequired {
                Toggle(label, isOn: Binding(
                    get: { binding.wrappedValue != nil },
                    set: { binding.wrappedValue = $0 ? (binding.wrappedValue ?? max(defaultDate(components), lower ?? .distantPast)) : nil }
                ))
                .cmsInspectorID("Cms.actionInputSheet.dateToggle")
            }
            if input.isRequired || binding.wrappedValue != nil {
                CmsDatePickerRow(label: input.isRequired ? label : "", selection: binding.unwrapped, lower: lower,
                                 dateOnly: components == [.date], style: style, tint: runtime.theme.primary,
                                 timeOnly: components == [.hourAndMinute])
            }
        } else if input.isRequired {
            datePicker(label, selection: binding.unwrapped, from: lower, components: components)
                .cmsInspectorID("Cms.actionInputSheet.datePicker")
        } else {
            Toggle(label, isOn: Binding(
                get: { binding.wrappedValue != nil },
                set: { binding.wrappedValue = $0 ? (binding.wrappedValue ?? max(defaultDate(components), lower ?? .distantPast)) : nil }
            ))
            .cmsInspectorID("Cms.actionInputSheet.dateToggle")
            if binding.wrappedValue != nil {
                datePicker(label, selection: binding.unwrapped, from: lower, components: components)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .cmsInspectorID("Cms.actionInputSheet.datePicker")
            }
        }
    }

    @ViewBuilder
    private func datePicker(_ label: String, selection: Binding<Date>, from lower: Date?,
                            components: DatePickerComponents) -> some View {
        if let lower {
            DatePicker(label, selection: selection, in: lower..., displayedComponents: components)
        } else {
            DatePicker(label, selection: selection, displayedComponents: components)
        }
    }

    /// The earliest value an input that must come after another may take.
    private func lowerBound(for input: CmsActionInputDef) -> Date? {
        guard let rule = input.after,
              case .date(let start?)? = draft[rule.input] else { return nil }
        return CmsActionForm.earliest(after: start, control: CmsActionForm.control(for: input))
    }

    /// Sets a date. Moving one that others must come after moves them with it
    /// and keeps the length between, as moving an event's start does.
    private func setDate(_ name: String, _ value: Date?) {
        let previous: Date? = { if case .date(let d)? = draft[name] { return d } else { return nil } }()
        draft[name] = .date(value)
        failure = nil
        guard let previous, let value else { return }
        let shift = value.timeIntervalSince(previous)
        for input in inputs where input.after?.input == name {
            if case .date(let later?)? = draft[input.name] { draft[input.name] = .date(later.addingTimeInterval(shift)) }
        }
    }

    private func defaultDate(_ components: DatePickerComponents) -> Date {
        let draft = CmsActionForm.initialDraft([CmsActionInputDef(name: "d", type: components.contains(.hourAndMinute) ? "timestamp" : "date", required: true)])
        if case .date(let d)? = draft["d"], let d { return d }
        return Date()
    }

    // MARK: - Bindings

    private func textBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { if case .text(let t)? = draft[name] { return t } else { return "" } },
            set: { draft[name] = .text($0); failure = nil }
        )
    }

    private func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { if case .bool(let b)? = draft[name] { return b } else { return false } },
            set: { draft[name] = .bool($0); failure = nil }
        )
    }

    private func dateBinding(_ name: String) -> DateDraftBinding {
        DateDraftBinding(binding: Binding(
            get: { if case .date(let d)? = draft[name] { return d } else { return nil } },
            set: { setDate(name, $0) }
        ))
    }
}

/// An optional date with a non-optional view for a picker.
private struct DateDraftBinding {
    let binding: Binding<Date?>
    var wrappedValue: Date? {
        get { binding.wrappedValue }
        nonmutating set { binding.wrappedValue = newValue }
    }
    var unwrapped: Binding<Date> {
        Binding(get: { binding.wrappedValue ?? Date() }, set: { binding.wrappedValue = $0 })
    }
}

/// A picker of an input's choices: a menu for a few, a pushed list for many.
@ViewBuilder
private func choicePicker(_ input: CmsActionInputDef, label: String, choices: [(value: String, label: String)],
                          selection: Binding<String>) -> some View {
    let picker = Picker(label, selection: selection) {
        Text(input.isRequired ? "Choose" : "None").tag("")
        ForEach(choices, id: \.value) { choice in
            Text(choice.label).tag(choice.value)
        }
    }
    #if os(iOS)
    if choices.count > 7 {
        picker.pickerStyle(.navigationLink).cmsInspectorID("Cms.actionInputSheet.picker")
    } else {
        picker.pickerStyle(.menu).cmsInspectorID("Cms.actionInputSheet.picker")
    }
    #else
    picker.pickerStyle(.menu).cmsInspectorID("Cms.actionInputSheet.picker")
    #endif
}

/// Choices from a saved query, run through the runtime as the page's queries
/// are: as the signed-in member, with the query's own parameter sources.
private struct CmsActionQueryPicker: View {
    @ObservedObject var runtime: CmsRuntime
    let input: CmsActionInputDef
    let query: CmsActionOptionsQuery
    let label: String
    let selection: Binding<String>

    var body: some View {
        Group {
            switch runtime.state(for: query.querySlug) {
            case .ok(let result):
                let choices = CmsActionForm.options(from: result.rows, query: query)
                if choices.isEmpty {
                    LabeledContent(label) { Text("No choices") }
                } else if CmsActionForm.choiceStyle(input, themeInputs: runtime.themeConfig?.inputs) == "dropdown" {
                    // As in a record form: each option's picture, its descriptionColumn as a subtitle.
                    CmsDropdownChoice(runtime: runtime, label: label,
                                      options: CmsDropdownChoice.options(rows: result.rows, query: query),
                                      picture: CmsDropdownChoice.picture(input: input, query: query),
                                      allowsNone: !input.isRequired, selection: selection)
                } else {
                    choicePicker(input, label: label, choices: choices, selection: selection)
                }
            case .error(let message):
                LabeledContent(label) {
                    Text(message).font(.ripul(.footnote)).foregroundStyle(.ripul(.danger)).lineLimit(3)
                }
            case .waiting(let reason):
                LabeledContent(label) { Text(reason).font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary)) }
            case .idle, .loading:
                LabeledContent(label) { ProgressView() }
            }
        }
        .onAppear { runtime.ensureLoaded(query.querySlug) }
    }
}
