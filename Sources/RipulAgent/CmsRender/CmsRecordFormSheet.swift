import SwiftUI

/// A record's form opened from a list row or a card (`openRowForm`, a card's
/// `open: { form }`): the mutation, the values it opens with (filled from
/// the row), the delete mutation, and an optional query loading the record.
struct CmsRecordFormRequest: Identifiable {
    var id = UUID()
    var spec: CmsRowFormSpec
    /// The row the form was opened from: what `{column}` templates fill from.
    var row: [String: CmsJSON]
    /// An action button's own form: its inputs and its save, in place of the spec's run.
    var custom: Custom?
    /// What was typed, carried when the form flips between a sheet and a page.
    var draft: [String: CmsActionForm.Draft]?

    struct Custom {
        var inputs: [CmsActionInputDef]
        var onSave: ([String: CmsJSON]) async -> String?
    }

    /// An action button's form: the mutation, the inputs it asks, its save.
    init(mutationSlug: String, inputs: [CmsActionInputDef], onSave: @escaping ([String: CmsJSON]) async -> String?) {
        self.spec = CmsRowFormSpec(mutationSlug: mutationSlug)
        self.row = [:]
        self.custom = Custom(inputs: inputs, onSave: onSave)
    }

    /// The form the row opens: the spec's first variant whose `when` holds, else the spec.
    init(spec: CmsRowFormSpec, row: [String: CmsJSON]) {
        self.spec = spec.form(for: row)
        self.row = row
    }

    /// `values`' templates filled from a row.
    static func values(_ spec: CmsRowFormSpec, row: [String: CmsJSON]) -> [String: CmsJSON] {
        spec.values.mapValues { template in
            // A template that is one slot keeps the column's own value (a
            // list's array, a number), else the filled text.
            let trimmed = template.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), trimmed.dropFirst().dropLast().allSatisfy({ $0 != "{" && $0 != "}" && $0 != "|" }) {
                return row[String(trimmed.dropFirst().dropLast())] ?? .null
            }
            return .string(CmsFormText.fill(template) { name, _ in row[name].map { CmsCards.text($0) } ?? "" })
        }
    }
}

/// The record form: the mutation's `action.form` laid out natively (sections,
/// rows of tiles, a summary with a total, a list input's items), a title
/// from its computed values, Save in the bar, Delete at the foot. Closing
/// with changes asks first. Without a `form`, the inputs in one section.
struct CmsRecordFormSheet: View {
    @ObservedObject var runtime: CmsRuntime
    let mutation: CmsMutationDef
    /// The inputs the form asks for (the button's supplied ones left out).
    let inputs: [CmsActionInputDef]
    let deleteMutation: CmsMutationDef?
    /// The delete button's word (`deleteLabel`, "Archive"), else "Delete".
    let deleteLabel: String
    /// `load`: the query that reads the whole record, its params, and the
    /// values it fills (the request's templates over its first row).
    let load: (slug: String, params: [String: CmsJSON], fill: ([String: CmsJSON]) -> [String: CmsJSON])?
    let onSave: ([String: CmsJSON]) async -> String?
    /// Delete, given the record's values: the row's, with the loaded record's over them.
    let onDelete: (([String: CmsJSON]) async -> String?)?
    /// `actions`: more buttons, each running another mutation with the record.
    let actions: [(label: String, run: ([String: CmsJSON]) async -> String?)]
    /// `sheet` (in its own stack) or `page` (pushed on the tab's stack, under the site's masthead).
    var presentation: CmsMasthead.Presentation = .sheet
    /// The quick flip to the other presentation, with what was typed; nil when the site doesn't offer it.
    var onFlip: (([String: CmsActionForm.Draft]) -> Void)?
    /// Closes a page-form (it and its steps); a sheet dismisses itself.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String: CmsActionForm.Draft]
    @State private var baseline: [String: CmsActionForm.Draft]
    @State private var running = false
    @State private var failure: String?
    @State private var confirmDiscard = false
    @State private var confirmDelete = false
    @State private var confirmSave: [String: CmsJSON]?
    @State private var collapsed: Set<Int>
    @State private var pickingDate: String?
    /// A tile's `floating` popover, and the tile whose `inline` picker is open under its row.
    @State private var floatingDate: String?
    @State private var inlineDate: String?
    @State private var editingItem: ItemEdit?
    @State private var editingInput: String?
    @State private var loading = false
    @State private var loadFailure: String?
    /// The record's values: `values` from the row, then the loaded record's over them (Delete's key).
    @State private var recordValues: [String: CmsJSON]
    /// `form.steps`: the steps pushed after the first, by their place among the shown steps.
    @State private var stepPath: [Int] = []
    /// Inputs a step's Next found wanting: each says why beside it until put right.
    @State private var flagged: Set<String> = []
    @State private var functionCache = CmsFunctionResultCache()
    @State private var functionRevision = 0
    /// The inputs `values` bound (the row's key): sent, shown only when laid out.
    private let bound: Set<String>

    /// A list item being added or changed.
    struct ItemEdit: Identifiable {
        let id = UUID()
        var list: String
        var index: Int?
        var item: [String: CmsJSON]
    }

    init(runtime: CmsRuntime, mutation: CmsMutationDef, inputs: [CmsActionInputDef], values: [String: CmsJSON],
         deleteMutation: CmsMutationDef? = nil,
         deleteLabel: String? = nil,
         load: (slug: String, params: [String: CmsJSON], fill: ([String: CmsJSON]) -> [String: CmsJSON])? = nil,
         onSave: @escaping ([String: CmsJSON]) async -> String?,
         onDelete: (([String: CmsJSON]) async -> String?)? = nil,
         actions: [(label: String, run: ([String: CmsJSON]) async -> String?)] = [],
         presentation: CmsMasthead.Presentation = .sheet,
         initialDraft: [String: CmsActionForm.Draft]? = nil,
         onFlip: (([String: CmsActionForm.Draft]) -> Void)? = nil,
         onClose: (() -> Void)? = nil) {
        self.presentation = presentation
        self.onFlip = onFlip
        self.onClose = onClose
        self.runtime = runtime
        self.mutation = mutation
        self.inputs = inputs
        self.deleteMutation = deleteMutation
        self.deleteLabel = deleteLabel ?? "Delete"
        self.load = load
        self.onSave = onSave
        self.onDelete = onDelete
        self.actions = actions
        bound = Set(values.keys)
        _recordValues = State(initialValue: values)
        let start = CmsActionForm.draft(inputs, values: values)
        _draft = State(initialValue: initialDraft ?? start)
        _baseline = State(initialValue: start)
        let form = mutation.action?.form
        _collapsed = State(initialValue: Set((form?.sections ?? []).enumerated().compactMap { $0.element.collapsed ? $0.offset : nil }))
    }

    private var form: CmsFormDef? { mutation.action?.form }
    private var mastheadStyle: CmsMasthead.Style { CmsMasthead.style(runtime.themeConfig, named: form?.masthead) }
    private var computed: [CmsComputedDef] { (form?.computed ?? []) + (mutation.action?.computed ?? []) }
    private var validation: CmsActionForm.Validation {
        _ = functionRevision
        return CmsActionForm.validate(inputs, draft: draft, computedStates: values.computedStates)
    }
    private var dirty: Bool { draft != baseline }
    private func input(_ name: String) -> CmsActionInputDef? { inputs.first { $0.name == name } }

    /// The draft as `showWhen` and a choice list's `params` read it.
    private var showValues: [String: CmsJSON] { CmsActionForm.showValues(inputs, draft: draft) }
    /// Inputs a `showWhen` keeps out now: not drawn, not required, not sent.
    private var hiddenNow: Set<String> {
        CmsFormSteps.hidden(inputs, values: showValues).union(whenOneNow.filter { $0.value.hide }.map(\.key))
    }

    /// `optionsQuery.whenOne: 'pick'` for each input that has it, from its
    /// choices as they stand (`CmsFormSteps.whenOne`).
    private var whenOneNow: [String: CmsFormSteps.WhenOne] {
        var out: [String: CmsFormSteps.WhenOne] = [:]
        for input in inputs {
            guard let query = input.optionsQuery, query.whenOne != nil || query.whenNone != nil else { continue }
            let rows: CmsFormSteps.ChoiceRows
            if (query.params ?? [:]).isEmpty {
                rows = CmsFormSteps.choiceRows(runtime.state(for: query.querySlug))
            } else if case .ready(let params) = CmsFormSteps.optionsParams(query.params, values: showValues) {
                rows = CmsFormSteps.choiceRows(runtime.optionList(query.querySlug, params: params))
            } else {
                rows = .loading
            }
            out[input.name] = CmsFormSteps.whenOne(query, rows)
        }
        return out
    }

    /// Loads a `whenOne` input's list though it isn't drawn, and sets the
    /// value it decides.
    private func applyWhenOne() {
        for input in inputs {
            guard let query = input.optionsQuery, query.whenOne != nil || query.whenNone != nil else { continue }
            if (query.params ?? [:]).isEmpty { runtime.ensureLoaded(query.querySlug) }
            else if case .ready(let params) = CmsFormSteps.optionsParams(query.params, values: showValues) {
                runtime.ensureOptionList(query.querySlug, params: params)
            }
        }
        for (name, outcome) in whenOneNow {
            guard let value = outcome.value else { continue }
            let next = CmsActionForm.Draft.text(value ?? "")
            if draft[name] != next { set(name, next) }
        }
    }

    /// Changes whenever a `whenOne` list or the values it reads change.
    private var whenOneKey: String {
        whenOneNow.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.hide)/\(String(describing: $0.value.value))" }.joined(separator: ";")
            + "|" + String(describing: showValues.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
    }
    private var hasSteps: Bool { !(form?.steps.isEmpty ?? true) }
    private var shownSteps: [CmsFormSteps.VisibleStep] {
        CmsFormSteps.visible(inputs, form: form, values: showValues, fixed: bound)
    }

    private var unlisted: [CmsActionInputDef] {
        let laidOut = Set(form?.namesUsed ?? [])
        let hiddenNow = hiddenNow
        return inputs.filter { input in
            guard input.hidden != true, input.fromComputed == nil, !laidOut.contains(input.name),
                  !hiddenNow.contains(input.name) else { return false }
            return form == nil ? input.name != "id" : !bound.contains(input.name)
        }
    }

    private var values: CmsFormValues {
        _ = functionRevision
        return CmsFormValues(
            inputs: inputs,
            computed: computed,
            draft: draft,
            chosenRow: chosenRow,
            functions: runtime.functionDefs,
            siteRevision: runtime.cmsId,
            functionCache: functionCache
        )
    }

    private var usesSiteFunctions: Bool {
        computed.contains { CmsFormExpr.parse($0.expr)?.usesFunctions == true || $0.expr.contains("fn.") }
    }

    private var functionEvalKey: String {
        guard usesSiteFunctions else { return "" }
        let draftSig = draft.keys.sorted().map { "\($0)=\(String(describing: draft[$0]))" }.joined(separator: ";")
        return "\(runtime.cmsId)|\(draftSig)|\(fillsKey)"
    }

    /// The chosen option's row of a choice from a query (`job.rate`).
    private func chosenRow(_ name: String) -> [String: CmsJSON]? {
        guard let input = input(name), let query = input.optionsQuery,
              case .text(let chosen)? = draft[name], !chosen.isEmpty else { return nil }
        // A list with `params` (a job's roles) was run for these params, not as the plain query.
        let state: CmsRuntime.QueryState
        if (query.params ?? [:]).isEmpty {
            state = runtime.state(for: query.querySlug)
        } else if case .ready(let params) = CmsFormSteps.optionsParams(query.params, values: showValues) {
            state = runtime.optionList(query.querySlug, params: params)
        } else {
            return nil
        }
        guard case .ok(let result) = state else { return nil }
        return result.rows.first { $0[query.valueColumn].map { CmsCards.text($0) } == chosen }
    }

    private var title: String {
        // While the record loads, the title waits with the fields (the
        // defaults would read a length that isn't the record's).
        if loading { return "" }
        if let template = form?.title, !template.isEmpty {
            let text = values.fill(template)
            if !text.isEmpty { return text }
        }
        return mutation.name ?? "Details"
    }

    /// A sheet holds its own stack; a page-form is already on the tab's, and
    /// its steps push there in turn (each step presents the next).
    @ViewBuilder
    private var root: some View {
        if presentation == .page {
            page(0)
        } else {
            NavigationStack(path: $stepPath) {
                page(0)
                    .navigationDestination(for: Int.self) { page($0) }
            }
        }
    }

    /// Closes the form: a sheet dismisses; a page-form pops itself and its steps.
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        root
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { close() }
            Button("Keep editing", role: .cancel) {}
        }
        .alert("Confirm", isPresented: Binding(get: { confirmSave != nil }, set: { if !$0 { confirmSave = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let p = confirmSave { run(p) } }
        } message: {
            Text(mutation.confirmMessage ?? "")
        }
        .alert(deleteMutation?.confirmMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "\(deleteLabel) this?",
               isPresented: $confirmDelete) {
            Button(deleteLabel, role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        }
        .ripulSheet(item: $editingItem, size: .form) { edit in itemEditor(edit) }
        .ripulSheet(isPresented: Binding(get: { pickingDate != nil }, set: { if !$0 { pickingDate = nil } }), size: .form) {
            if let name = pickingDate { datePickerSheet(name) }
        }
        .ripulSheet(isPresented: Binding(get: { editingInput != nil }, set: { if !$0 { editingInput = nil } }), size: .form) {
            if let name = editingInput { inputEditor(name) }
        }
        .interactiveDismissDisabled(running || dirty)
        .tint(runtime.theme.primary)
        .environmentObject(runtime)
        .task {
            for input in inputs {
                if let q = input.optionsQuery, (q.params ?? [:]).isEmpty { runtime.ensureLoaded(q.querySlug) }
            }
            await runLoad()
        }
        .task(id: whenOneKey) { applyWhenOne() }
        .task(id: fillsKey) { applyLoadedChoice() }
        .task(id: functionEvalKey) {
            guard usesSiteFunctions else { return }
            await values.resolveAllFunctions()
            if !Task.isCancelled {
                functionRevision &+= 1
            }
        }
    }

    /// One screen of the form: the whole form, or with `form.steps` the
    /// shown step at `position` (each pushed in this sheet's own stack, so
    /// the system's back button and swipe go back with what was entered).
    @ViewBuilder
    private func page(_ position: Int) -> some View {
        let steps = hasSteps ? shownSteps : []
        let step = steps.indices.contains(position) ? steps[position] : nil
        Form {
            if position == 0, let loadFailure {
                Section {
                    Label(loadFailure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.ripul(.danger))
                    Button("Try again") { Task { await runLoad() } }
                }
            }
            if hasSteps {
                if let step {
                    // On a page-form the step's question and progress are in the band.
                    if bandText == nil { stepHeader(step, position: position, count: steps.count) }
                    stepSections(step)
                }
            } else {
                if let form {
                    ForEach(Array(form.sections.enumerated()), id: \.offset) { index, section in
                        sectionView(section, index: index)
                    }
                }
                // Inputs no section names follow in a last section: not
                // hidden, and not bound by `values` (without a layout, only
                // `id` is kept back).
                let rest = unlisted
                if !rest.isEmpty {
                    Section { ForEach(rest) { item(.input($0.name)) } }
                }
            }
            if let failure, !hasSteps || position == steps.count - 1 {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.ripul(.danger))
                }
            }
            if !actions.isEmpty, !hasSteps || position == 0 {
                Section {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button { runAction(action.run) } label: {
                            Text(action.label).frame(maxWidth: .infinity)
                        }
                        .cmsInspectorID("Cms.recordForm.action")
                    }
                }
            }
            if onDelete != nil, !hasSteps || position == 0 {
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(deleteLabel, systemImage: "trash")
                            .foregroundStyle(.ripul(.danger))
                            .frame(maxWidth: .infinity)
                    }
                    .cmsInspectorID("Cms.recordForm.delete")
                }
            }
        }
        .redacted(reason: loading ? .placeholder : [])
        .scrollDismissesKeyboard(.interactively)
        .disabled(running || loading)
        .modifier(CmsFormPageChrome(enabled: presentation == .page, style: mastheadStyle, showsBand: form?.mastheadOff != true,
                                    title: bandTitle(step), subtitle: bandSubtitle(step, position: position, count: steps.count),
                                    scroll: form?.mastheadScroll, cut: form?.mastheadCut))
        .navigationTitle(presentation == .page && form?.mastheadOff != true ? "" : title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // A page-form with changes asks before going back, as a sheet does
        // before it is swiped away: the system's back returns once it's saved or untouched.
        .navigationBarBackButtonHidden(presentation == .page && position == 0 && (dirty || running))
        #endif
        .navigationDestination(isPresented: Binding(
            get: { presentation == .page && hasSteps && stepPath.count > position },
            set: { shown in if !shown, stepPath.count > position { stepPath = Array(stepPath.prefix(position)) } }
        )) {
            // SwiftUI builds a destination as the page draws: only a step that exists
            // builds the next, so a form without steps (or its last step) stops here.
            if presentation == .page, hasSteps, position + 1 < shownSteps.count {
                AnyView(page(position + 1).environmentObject(runtime))
            } else {
                AnyView(EmptyView())
            }
        }
        .toolbar {
            if position == 0 && presentation == .sheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if dirty { confirmDiscard = true } else { close() } }
                        .disabled(running)
                        .cmsInspectorID("Cms.recordForm.cancel")
                }
            }
            if position == 0 && presentation == .page && (dirty || running) {
                ToolbarItem(placement: .cancellationAction) {
                    Button { confirmDiscard = true } label: { Label("Back", systemImage: "chevron.backward") }
                        .disabled(running)
                        .cmsInspectorID("Cms.recordForm.back")
                }
            }
            if let onFlip, position == 0 {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        let carried = draft
                        close()
                        onFlip(carried)
                    } label: {
                        Label(CmsMasthead.flipLabel(presentation),
                              systemImage: presentation == .page ? "rectangle.bottomthird.inset.filled" : "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(running)
                    .cmsInspectorID("Cms.recordForm.flip")
                }
            }
            if !hasSteps {
                ToolbarItem(placement: .confirmationAction) {
                    if running {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .fontWeight(.semibold)
                            .disabled(!validation.ready || loading)
                            .cmsInspectorID("Cms.recordForm.save")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasSteps, let step {
                stepButton(step, position: position, count: steps.count)
            }
        }
    }

    // MARK: Steps

    /// The step's progress (a bar, "Step 2 of 4" or nothing), its title, its
    /// question big and its description.
    private func stepHeader(_ step: CmsFormSteps.VisibleStep, position: Int, count: Int) -> some View {
        let progress = CmsFormSteps.progress(position + 1, of: count)
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                switch form?.progress ?? "bar" {
                case "none":
                    EmptyView()
                case "count":
                    Text(progress.text).font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
                        .cmsInspectorID("Cms.recordForm.stepCount")
                default:
                    ProgressView(value: progress.fraction)
                        .accessibilityLabel(progress.text)
                        .cmsInspectorID("Cms.recordForm.stepProgress")
                }
                if let title = step.step.title, !title.isEmpty {
                    Text(values.fill(title)).font(.ripul(.footnote, weight: .semibold)).foregroundStyle(.ripul(.textSecondary))
                        .modifier(CmsOnBandText(color: bandText))
                }
                if let question = step.step.question, !question.isEmpty {
                    Text(values.fill(question)).font(.ripul(.title2, weight: .bold)).foregroundStyle(.ripul(.text))
                        .modifier(CmsOnBandText(color: bandText))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .cmsInspectorID("Cms.recordForm.stepQuestion")
                }
                if let description = step.step.description, !description.isEmpty {
                    Text(values.fill(description)).font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
    }

    /// The step's sections, each holding only the inputs the step asks for
    /// now; inputs no step names follow on the last step.
    @ViewBuilder
    private func stepSections(_ step: CmsFormSteps.VisibleStep) -> some View {
        let asked = Set(step.inputs)
        let laidOut = CmsFormSteps.inputNames(step.step)
        ForEach(Array(step.step.sections.enumerated()), id: \.offset) { offset, section in
            let items = section.items.compactMap { item -> CmsFormDef.Item? in
                switch item {
                case .input(let name): return asked.contains(name) ? item : nil
                case .row(let names):
                    let kept = names.filter(asked.contains)
                    return kept.isEmpty ? nil : .row(kept)
                case .summary: return item
                }
            }
            if !items.isEmpty {
                sectionView(CmsFormDef.Section(heading: section.heading, collapsible: section.collapsible,
                                               collapsed: section.collapsed, items: items),
                            index: 10_000 + step.index * 100 + offset)
            }
        }
        let rest = step.inputs.filter { !laidOut.contains($0) }
        if !rest.isEmpty {
            Section { ForEach(rest, id: \.self) { item(.input($0)) } }
        }
    }

    /// The button at the step's foot: its `nextLabel` ("Continue"), and on
    /// the last step `form.submitLabel` ("Save"), which runs the mutation.
    private func stepButton(_ step: CmsFormSteps.VisibleStep, position: Int, count: Int) -> some View {
        let last = position >= count - 1
        let label = last ? (form?.submitLabel.flatMap { $0.isEmpty ? nil : $0 } ?? "Save")
                         : (step.step.nextLabel.flatMap { $0.isEmpty ? nil : $0 } ?? "Continue")
        return Button { next(step, position: position, count: count) } label: {
            Group {
                if running && last { ProgressView() } else { Text(label).fontWeight(.semibold) }
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(running || loading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .cmsInspectorID(last ? "Cms.recordForm.submit" : "Cms.recordForm.next")
    }

    /// Next: only this step's inputs are checked, by the shared rules; what's
    /// wanting says why beside it. The last step saves.
    private func next(_ step: CmsFormSteps.VisibleStep, position: Int, count: Int) {
        let check = validation
        let wanting = Set(step.inputs).intersection(Set(check.missing).union(check.errors.map(\.field)))
        guard wanting.isEmpty else { flagged.formUnion(wanting); return }
        if position >= count - 1 { save() } else { stepPath.append(position + 1) }
    }

    /// Why an input flagged by Next is wanting, while it still is.
    private func issue(_ name: String) -> String? {
        guard flagged.contains(name) else { return nil }
        let check = validation
        if let error = check.errors.first(where: { $0.field == name }) { return error.message }
        return check.missing.contains(name) ? "\(input(name)?.displayLabel ?? name) is required." : nil
    }

    // MARK: Saving, deleting, loading

    private func save() {
        // `fromComputed`: the computed value goes in its input at save when ready.
        for input in inputs {
            guard let name = input.fromComputed else { continue }
            if case .value(let v) = values.state(name) {
                draft[input.name] = .text(v.text ?? "")
            }
        }
        let check = validation
        guard check.ready else {
            flagged.formUnion(check.missing + check.errors.map(\.field))
            if let computedErr = check.errors.first(where: { err in inputs.contains { $0.name == err.field && $0.fromComputed != nil } }) {
                failure = computedErr.message
            } else if hasSteps {
                failure = "Some answers in earlier steps need a look."
            }
            return
        }
        let params = CmsActionForm.typedParams(inputs, values: check.values)
        if let confirm = mutation.confirmMessage, !confirm.isEmpty { confirmSave = params } else { run(params) }
    }

    private func run(_ params: [String: CmsJSON]) {
        confirmSave = nil
        failure = nil
        running = true
        Task {
            let refusal = await onSave(params)
            running = false
            if let refusal { failure = refusal } else { close() }
        }
    }

    private func runAction(_ run: @escaping ([String: CmsJSON]) async -> String?) {
        failure = nil
        running = true
        Task {
            let refusal = await run(recordValues)
            running = false
            if let refusal { failure = refusal } else { close() }
        }
    }

    private func delete() {
        guard let onDelete else { return }
        failure = nil
        running = true
        Task {
            let refusal = await onDelete(recordValues)
            running = false
            if let refusal { failure = refusal } else { close() }
        }
    }

    /// `load`: the whole record (its nested items) read for the form; the
    /// row's values show meanwhile, the rest as placeholders.
    private func runLoad() async {
        guard let load else { return }
        loading = true
        loadFailure = nil
        do {
            let result = try await runtime.client.runSavedQuery(cmsId: runtime.cmsId, querySlug: load.slug, params: load.params)
            loading = false
            guard let row = result.rows.first else {
                loadFailure = "This entry couldn't be found."
                return
            }
            let loadedValues = load.fill(row)
            // A value the loaded record lacks keeps the row's.
            recordValues = recordValues.merging(loadedValues.filter { $0.value != .null }) { _, loaded in loaded }
            let filled = CmsActionForm.draft(inputs, values: loadedValues)
            draft = filled
            baseline = filled
        } catch {
            loading = false
            loadFailure = "Couldn't load this entry. \(error.localizedDescription)"
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ section: CmsFormDef.Section, index: Int) -> some View {
        let open = !collapsed.contains(index)
        Section {
            if open {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, entry in
                    item(entry)
                }
            }
        } header: {
            if let heading = section.heading {
                if section.collapsible {
                    Button {
                        withAnimation(.snappy) {
                            if open { collapsed.insert(index) } else { collapsed.remove(index) }
                        }
                    } label: {
                        HStack {
                            Text(heading)
                            Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 0 : -90))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(CmsOnBandText(color: index == 0 ? bandText : nil))
                } else {
                    Text(heading)
                        .modifier(CmsOnBandText(color: index == 0 ? bandText : nil))
                }
            }
        }
    }

    /// A page-form's band: a step's question, else the form's title.
    private func bandTitle(_ step: CmsFormSteps.VisibleStep?) -> String {
        if let q = step?.step.question, !q.isEmpty { return values.fill(q) }
        return title
    }

    /// Under it: a step's progress and title ("Step 1 of 3 · Room"), else the form's `subtitle`.
    private func bandSubtitle(_ step: CmsFormSteps.VisibleStep?, position: Int, count: Int) -> String? {
        guard let step else { return form?.subtitle.map { values.fill($0) } }
        var parts: [String] = []
        if form?.progress != "none" { parts.append(CmsFormSteps.progress(position + 1, of: count).text) }
        if let t = step.step.title, !t.isEmpty { parts.append(values.fill(t)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A page-form's band text colour: what sits above its first card is on the band.
    private var bandText: Color? {
        presentation == .page && form?.mastheadOff != true ? runtime.theme.color(role: mastheadStyle.text) : nil
    }

    @ViewBuilder
    private func item(_ entry: CmsFormDef.Item) -> some View {
        switch entry {
        case .input(let name):
            if let input = input(name), input.hidden != true, !hiddenNow.contains(name) {
                field(input)
                if let issue = issue(name) { issueLine(issue) }
            }
        case .row(let names):
            let row = names.compactMap(input).filter { $0.hidden != true && !hiddenNow.contains($0.name) }
            HStack(spacing: 10) {
                ForEach(row) { tile($0) }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            // A tile's `inline` picker opens straight under its row.
            if let open = row.first(where: { $0.name == inlineDate }) {
                CmsInlineDatePicker(label: open.displayLabel, selection: dateBinding(open.name), lower: lowerBound(open),
                                    dateOnly: CmsActionForm.control(for: open) == .date,
                                    timeOnly: CmsActionForm.control(for: open) == .time)
            }
            // A list input in the row lists its items under the tiles.
            ForEach(row.filter { $0.type == "list" }) { listItems($0) }
            ForEach(row.compactMap { issue($0.name) }, id: \.self) { issueLine($0) }
        case .summary(let lines, let total):
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in summaryLine(line, bold: false) }
            if let total { summaryLine(total, bold: true) }
        }
    }

    // MARK: Tiles

    @ViewBuilder
    private func tile(_ input: CmsActionInputDef) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            switch CmsActionForm.control(for: input) {
            case .date, .dateTime, .time:
                let style = CmsDatePickerStyle.resolve(input, form: form)
                let empty = !hasDate(input.name)
                Button {
                    switch style {
                    case .sheet: pickingDate = input.name
                    case .floating: floatingDate = input.name
                    case .inline: withAnimation(.snappy) { inlineDate = inlineDate == input.name ? nil : input.name }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(input.displayLabel)
                            .font(.ripul(.caption2)).foregroundStyle(.ripul(.textSecondary)).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(empty ? "Add" : values.text(input.name, format: CmsActionForm.control(for: input) == .date ? "d MMM" : "HH:mm"))
                                .font(.title3.weight(.semibold).monospacedDigit())
                                .foregroundStyle(inlineDate == input.name ? Color.accentColor : Color.ripul(.text))
                            if style == .floating {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                            }
                        }
                        if CmsActionForm.control(for: input) == .dateTime, !empty {
                            Text(values.text(input.name, format: input.detail ?? "d MMM"))
                                .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .contentShape(shape)
                }
                .accessibilityLabel("\(input.displayLabel), \(empty ? "Add" : values.text(input.name, format: CmsActionForm.control(for: input) == .time ? "HH:mm" : "d MMM, HH:mm"))")
                .cmsAnchoredPopover(isPresented: Binding(get: { floatingDate == input.name }, set: { if !$0 { floatingDate = nil } }),
                                    tint: runtime.theme.primary) {
                    CmsFloatingDatePicker(label: input.displayLabel, selection: dateBinding(input.name), lower: lowerBound(input),
                                          dateOnly: CmsActionForm.control(for: input) == .date,
                                          timeOnly: CmsActionForm.control(for: input) == .time) { floatingDate = nil }
                }
            case .list:
                Button { addItem(to: input) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill").font(.title3)
                        Text(input.addLabel ?? "Add").font(.ripul(.subheadline).weight(.semibold))
                            .multilineTextAlignment(.center)
                        let count = CmsActionForm.listItems(draft[input.name]).count
                        if count > 0 {
                            Text("\(count) added").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                        }
                    }
                    .foregroundStyle(runtime.theme.primary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .contentShape(shape)
                }
            default:
                VStack(spacing: 2) {
                    Text(input.displayLabel).font(.ripul(.caption2)).foregroundStyle(.ripul(.textSecondary))
                    field(input).labelsHidden()
                }
                .frame(maxWidth: .infinity, minHeight: 72)
            }
        }
        .buttonStyle(.plain)
        .background(shape.fill(Color.ripul(system: .secondarySystemGroupedBackground)))
        .overlay(shape.stroke(Color.ripul(system: .separator), lineWidth: 0.5))
        .cmsInspectorID("Cms.recordForm.tile")
    }

    // MARK: Lists

    @ViewBuilder
    private func listItems(_ input: CmsActionInputDef) -> some View {
        let items = CmsActionForm.listItems(draft[input.name])
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            Button { editingItem = ItemEdit(list: input.name, index: index, item: item) } label: {
                HStack {
                    Image(systemName: "cup.and.saucer").foregroundStyle(runtime.theme.primary)
                    Text(CmsFormValues.itemText(input.itemLabel, item: item, fields: input.fields ?? []))
                        .foregroundStyle(.ripul(.text))
                    Spacer()
                    Image(systemName: "chevron.right").font(.ripul(.footnote)).foregroundStyle(.ripul(.textTertiary))
                }
            }
            .swipeActions { Button("Remove", role: .destructive) { removeItem(input.name, at: index) } }
            .cmsInspectorID("Cms.recordForm.listItem")
        }
    }

    private func addItem(to input: CmsActionInputDef) {
        var item: [String: CmsJSON] = [:]
        for field in input.fields ?? [] {
            if let value = field.defaultValue { item[field.name] = value }
            else if field.type == "boolean" { item[field.name] = .bool(false) }
        }
        editingItem = ItemEdit(list: input.name, index: nil, item: item)
    }

    private func removeItem(_ list: String, at index: Int) {
        guard case .list(var items, var removed)? = draft[list], items.indices.contains(index) else { return }
        let gone = items.remove(at: index)
        if gone["id"] != nil { removed.append(gone) }
        draft[list] = .list(items, removed: removed)
    }

    private func itemEditor(_ edit: ItemEdit) -> some View {
        CmsListItemEditor(runtime: runtime, list: input(edit.list), edit: edit,
                          onDone: { item in
                              guard case .list(var items, let removed)? = draft[edit.list] else { return }
                              if let index = edit.index, items.indices.contains(index) { items[index] = item } else { items.append(item) }
                              draft[edit.list] = .list(items, removed: removed)
                          },
                          onRemove: edit.index.map { index in { removeItem(edit.list, at: index) } })
    }

    // MARK: Summary

    private func summaryLine(_ line: CmsFormDef.Line, bold: Bool) -> some View {
        let content = HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(values.fill(line.label)).fontWeight(bold ? .bold : .regular)
                if let detail = line.detail.flatMap(values.fillComplete) {
                    Text(detail).font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
                }
            }
            Spacer()
            Text(values.fill(line.amount)).fontWeight(bold ? .bold : .medium).monospacedDigit()
            if line.input != nil {
                Image(systemName: "chevron.right").font(.ripul(.footnote)).foregroundStyle(.ripul(.textTertiary))
            }
        }
        .foregroundStyle(.ripul(.text))
        return Group {
            if let name = line.input {
                Button { editingInput = name } label: { content.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else {
                content
            }
        }
        .cmsInspectorID(bold ? "Cms.recordForm.total" : "Cms.recordForm.summaryLine")
    }

    private func inputEditor(_ name: String) -> some View {
        NavigationStack {
            Form { if let input = input(name) { field(input) } }
                .navigationTitle(input(name)?.displayLabel ?? "")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editingInput = nil } } }
        }
    }

    private func datePickerSheet(_ name: String) -> some View {
        let control = input(name).map { CmsActionForm.control(for: $0) }
        let components: DatePickerComponents = control == .date ? [.date] : control == .time ? [.hourAndMinute] : [.date, .hourAndMinute]
        return NavigationStack {
            Form {
                DatePicker(input(name)?.displayLabel ?? "", selection: dateBinding(name), displayedComponents: components)
                    .datePickerStyle(.graphical)
            }
            .navigationTitle(input(name)?.displayLabel ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { pickingDate = nil } } }
        }
    }

    // MARK: Fields

    @ViewBuilder
    private func field(_ input: CmsActionInputDef) -> some View {
        let label = input.displayLabel
        switch CmsActionForm.control(for: input) {
        case .toggle:
            Toggle(label, isOn: boolBinding(input.name))
        case .date, .dateTime, .time:
            let control = CmsActionForm.control(for: input)
            let style = CmsDatePickerStyle.resolve(input, form: form)
            if style == .sheet {
                DatePicker(label, selection: dateBinding(input.name),
                           displayedComponents: control == .date ? [.date] : control == .time ? [.hourAndMinute] : [.date, .hourAndMinute])
            } else {
                CmsDatePickerRow(label: label, selection: dateBinding(input.name), lower: lowerBound(input),
                                 dateOnly: control == .date, style: style,
                                 tint: runtime.theme.primary, timeOnly: control == .time)
            }
        case .choice:
            CmsRecordChoicePicker(runtime: runtime, input: input, label: label, selection: textBinding(input.name),
                                  formValues: showValues, labelFor: { self.input($0)?.displayLabel ?? $0 },
                                  fill: { values.fill($0) })
        case .multiline:
            TextField(label, text: textBinding(input.name), axis: .vertical)
                .lineLimit(3...8)
                .cmsInspectorID("Cms.recordForm.multiline")
        case .duration:
            CmsDurationField(label: label, unit: input.unit ?? "minutes", value: textBinding(input.name))
        case .list:
            listItems(input)
            Button { addItem(to: input) } label: { Label(input.addLabel ?? "Add", systemImage: "plus.circle.fill") }
        case .dates:
            CmsDateSetField(input: input,
                            days: input.range.map { CmsDateSets.daysBetween(showValues[$0.from], showValues[$0.to]) } ?? [],
                            selection: textBinding(input.name))
        case .unsupported:
            LabeledContent(label) { Text("Can't be entered here") }
        case .number, .text:
            LabeledContent {
                HStack(spacing: 8) {
                TextField(label, text: textBinding(input.name), prompt: Text(input.isRequired ? "Required" : "Optional"))
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(input.type == "integer" ? .numberPad : input.type == "float" ? .decimalPad : .default)
                    #endif
                // `image` on a text input: a live picture of what's typed.
                if let chain = input.image?.objectValue?["chain"], CmsActionForm.control(for: input) == .text {
                    CmsTypedPicture(chain: chain, shape: input.image?.objectValue?.string("shape"),
                                    name: input.name, text: textBinding(input.name).wrappedValue)
                }
                }
            } label: { Text(label) }
        }
    }

    private func textBinding(_ name: String) -> Binding<String> {
        Binding(get: { if case .text(let t)? = draft[name] { return t } else { return "" } },
                set: { set(name, .text($0)) })
    }

    private func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { if case .bool(let b)? = draft[name] { return b } else { return false } },
                set: { set(name, .bool($0)) })
    }

    /// A choice input's rows as they stand (its list with `params` runs for these values).
    private func choiceRows(_ input: CmsActionInputDef) -> [[String: CmsJSON]]? {
        guard let query = input.optionsQuery else { return nil }
        let state: CmsRuntime.QueryState
        if (query.params ?? [:]).isEmpty {
            state = runtime.state(for: query.querySlug)
        } else if case .ready(let params) = CmsFormSteps.optionsParams(query.params, values: showValues) {
            state = runtime.optionList(query.querySlug, params: params)
        } else {
            return nil
        }
        if case .ok(let result) = state { return result.rows }
        return nil
    }

    /// A record loaded into the form: a choice that fills other inputs takes the
    /// row those inputs describe (`CmsActionOptionsQuery.choice(forValues:)`).
    private func applyLoadedChoice() {
        for input in inputs {
            guard let query = input.optionsQuery, query.fills != nil, let rows = choiceRows(input) else { continue }
            if case .text(let t)? = draft[input.name], !t.isEmpty { continue }
            var values: [String: String] = [:]
            for name in (query.fills ?? [:]).keys { if case .text(let t)? = draft[name] { values[name] = t } }
            if let v = query.choice(forValues: values, rows: rows) { draft[input.name] = .text(v) }
        }
    }

    /// Changes when a filling choice's rows or value do.
    private var fillsKey: String {
        inputs.filter { $0.optionsQuery?.fills != nil }.map { input in
            let rows = choiceRows(input)?.count ?? -1
            let value: String = { if case .text(let t)? = draft[input.name] { return t } else { return "" } }()
            return "\(input.name)=\(rows)/\(value)"
        }.joined(separator: ";")
    }

    /// Sets an input; a choice list whose `params` name it loses its choice.
    private func set(_ name: String, _ value: CmsActionForm.Draft) {
        let changed = draft[name] != value
        draft[name] = value
        // A choice that fills other inputs (`optionsQuery.fills`: a role sets its job and rate) sets them too.
        if changed, let input = input(name), let query = input.optionsQuery, query.fills != nil, case .text(let chosen) = value {
            let row = chosen.isEmpty ? nil : choiceRows(input)?.first { $0[query.valueColumn].map { CmsCards.text($0) } == chosen }
            for (k, v) in query.fillValues(row) { draft[k] = .text(v ?? "") }
        }
        failure = nil
        guard changed else { return }
        resetDateSets(reading: name)
        for dependent in inputs where CmsFormSteps.dependsOn(dependent.optionsQuery?.params).contains(name) {
            if case .text(let t)? = draft[dependent.name], !t.isEmpty { set(dependent.name, .text("")) }
        }
    }

    private func issueLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.ripul(.footnote))
            .foregroundStyle(.ripul(.danger))
            .cmsInspectorID("Cms.recordForm.issue")
    }

    /// The earliest a date that must come after another (`after`) may take, as the input sheet's.
    private func lowerBound(_ input: CmsActionInputDef) -> Date? {
        guard let rule = input.after, case .date(let start?)? = draft[rule.input] else { return nil }
        return CmsActionForm.earliest(after: start, control: CmsActionForm.control(for: input))
    }

    private func hasDate(_ name: String) -> Bool {
        if case .date(_?)? = draft[name] { return true } else { return false }
    }

    /// A set of days whose range reads `name` starts again for the new range
    /// (all its days, or none), as the web's form does (CmsDateSets).
    private func resetDateSets(reading name: String) {
        for set in CmsDateSets.readingRange(inputs, changed: name) {
            guard let range = set.range else { continue }
            let values = showValues
            draft[set.name] = .text(CmsDateSets.forRange(defaultSelection: set.defaultSelection,
                                                         values[range.from], values[range.to]).joined(separator: ","))
        }
    }

    /// A date; moving one that another must come after moves that one too,
    /// keeping the length between (as moving an event's start does).
    private func dateBinding(_ name: String) -> Binding<Date> {
        Binding(
            get: { if case .date(let d?)? = draft[name] { return d } else { return Date() } },
            set: { value in
                let previous: Date? = { if case .date(let d)? = draft[name] { return d } else { return nil } }()
                draft[name] = .date(value)
                failure = nil
                if previous.map({ CmsActionForm.dateString($0) }) != CmsActionForm.dateString(value) { resetDateSets(reading: name) }
                if let previous {
                    let shift = value.timeIntervalSince(previous)
                    for later in inputs where later.after?.input == name {
                        if case .date(let d?)? = draft[later.name] { draft[later.name] = .date(d.addingTimeInterval(shift)) }
                    }
                }
            })
    }
}

/// A duration (an integer in `seconds` or `minutes`), edited as hours and minutes.
struct CmsDurationField: View {
    let label: String
    let unit: String
    @Binding var value: String

    private var perMinute: Int { unit == "seconds" ? 60 : 1 }
    private var minutes: Int { (Int(Double(value) ?? 0)) / perMinute }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                Picker("Hours", selection: Binding(get: { minutes / 60 }, set: { set($0 * 60 + minutes % 60) })) {
                    ForEach(0..<24) { Text("\($0) h").tag($0) }
                }
                Picker("Minutes", selection: Binding(get: { minutes % 60 }, set: { set(minutes / 60 * 60 + $0) })) {
                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text("\($0) min").tag($0) }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .accessibilityValue(CmsFormText.duration(Double(minutes)))
    }

    private func set(_ minutes: Int) { value = String(minutes * perMinute) }
}

/// A choice from a query, with a picture beside each choice when the input
/// names an `imageColumn` (a pushed list); a menu otherwise.
private struct CmsRecordChoicePicker: View {
    @ObservedObject var runtime: CmsRuntime
    let input: CmsActionInputDef
    let label: String
    @Binding var selection: String
    /// The form's values, for `optionsQuery.params`.
    let formValues: [String: CmsJSON]
    /// Another input's label ("Choose Industry first").
    let labelFor: (String) -> String
    /// The form's template filler (`optionsQuery.emptyChoice`'s line).
    var fill: (String) -> String = { _ in "" }

    /// The empty choice's own label and line, when the list names one.
    private var empty: CmsDropdownChoice.Empty? {
        guard let e = input.optionsQuery?.emptyChoice else { return nil }
        let line = e.description.map(fill).flatMap { $0.isEmpty ? nil : $0 }
        return CmsDropdownChoice.Empty(label: e.label, description: line)
    }

    /// A choice just added, shown until the list has it.
    @State private var added: CmsFormChoice?

    var body: some View {
        Group {
            if let query = input.optionsQuery {
                switch CmsFormSteps.optionsParams(query.params, values: formValues) {
                case .waiting(let on):
                    // Waits on the inputs its params name.
                    LabeledContent(label) {
                        Text("Choose \(on.map(labelFor).joined(separator: ", ")) first")
                            .foregroundStyle(.ripul(.textTertiary))
                    }
                    .cmsInspectorID("Cms.recordForm.choiceWaiting")
                case .ready(let params):
                    if (query.params ?? [:]).isEmpty {
                        switch runtime.state(for: query.querySlug) {
                        case .ok(let result):
                            choices(rows: result.rows, query: query, params: params)
                        case .error(let message):
                            LabeledContent(label) { Text(message).font(.ripul(.footnote)).foregroundStyle(.ripul(.danger)).lineLimit(2) }
                        default:
                            LabeledContent(label) { ProgressView() }
                        }
                    } else {
                        // A list with `params` runs its query for these params,
                        // once, in the runtime (`ensureOptionList`).
                        Group {
                            switch runtime.optionList(query.querySlug, params: params) {
                            case .ok(let result):
                                choices(rows: result.rows, query: query, params: params)
                            case .error(let message):
                                LabeledContent(label) { Text(message).font(.ripul(.footnote)).foregroundStyle(.ripul(.danger)).lineLimit(2) }
                            default:
                                LabeledContent(label) { ProgressView() }
                            }
                        }
                        .task(id: CmsRuntime.optionListKey(query.querySlug, params: params)) {
                            runtime.ensureOptionList(query.querySlug, params: params)
                        }
                    }
                }
            } else {
                choices(options: (input.options?.choices ?? []).map {
                    CmsFormChoice(value: $0.value, label: $0.label ?? $0.value, description: $0.description, row: [:])
                }, picture: nil, query: nil, params: [:])
            }
        }
        .cmsInspectorID("Cms.recordForm.choice")
    }

    private func choices(rows: [[String: CmsJSON]], query: CmsActionOptionsQuery, params: [String: CmsJSON]) -> some View {
        var options = CmsActionForm.options(from: rows, query: query).map { choice in
            let row = rows.first { $0[query.valueColumn].map { CmsCards.text($0) } == choice.value } ?? [:]
            return CmsFormChoice(value: choice.value, label: choice.label, description: query.describe(row), row: row)
        }
        if let added, !options.contains(where: { $0.value == added.value }) { options.append(added) }
        var picture: CmsColumnPresentation?
        if let imageColumn = query.imageColumn ?? input.imageColumn, !imageColumn.isEmpty {
            let chain = (query.image ?? input.image)?.objectValue?["chain"] ?? .array([])
            picture = CmsColumnPresentation(key: imageColumn, json: ["image": .object(["chain": chain])])
        }
        return choices(options: options, picture: picture, query: query, params: params)
    }

    /// `choiceStyle`: `menu` (the default without pictures), a pushed `list`
    /// (with pictures, a search field or an add row), or `inline` rows.
    @ViewBuilder
    private func choices(options: [CmsFormChoice], picture: CmsColumnPresentation?,
                         query: CmsActionOptionsQuery?, params: [String: CmsJSON]) -> some View {
        let needsList = picture != nil || input.searchable == true || query?.create != nil
        let resolved = CmsActionForm.choiceStyle(input, themeInputs: runtime.themeConfig?.inputs)
        // A dropdown can't search or add: those keep the pushed list.
        let style = (resolved == "dropdown" && (input.searchable == true || query?.create != nil) ? nil : resolved)
            ?? (needsList ? "list" : "menu")
        switch style == "menu" && (input.searchable == true || query?.create != nil) ? "list" : style {
        case "dropdown":
            CmsDropdownChoice(runtime: runtime, label: label, options: options, picture: picture,
                              allowsNone: !input.isRequired, empty: empty, selection: $selection)
        case "inline":
            Picker(label, selection: $selection) {
                // An optional input's empty choice is the first row, so a choice made can be taken back.
                if let none = CmsActionForm.emptyChoice(input) {
                    CmsChoiceRow(option: CmsFormChoice(value: "", label: none.label, description: empty?.description, row: [:]),
                                 picture: nil).tag("")
                }
                ForEach(options) { option in
                    CmsChoiceRow(option: option, picture: picture).tag(option.value)
                }
            }
            #if os(iOS)
            .pickerStyle(.inline)
            #endif
        case "list":
            NavigationLink {
                CmsChoiceListScreen(runtime: runtime, title: label, options: options, picture: picture,
                                    searchable: input.searchable == true, create: query?.create,
                                    listParams: params, selection: $selection) { created in
                    added = created
                    if let query {
                        if (query.params ?? [:]).isEmpty { runtime.invalidate(query.querySlug) }
                        else { runtime.ensureOptionList(query.querySlug, params: params, reload: true) }
                    }
                }
                // Pushed on whichever stack holds the form (a page-form's is the tab's), which
                // doesn't carry the form's environment.
                .environmentObject(runtime)
            } label: {
                LabeledContent(label) {
                    Text(options.first { $0.value == selection }?.label ?? (selection.isEmpty ? "Choose" : selection))
                        .foregroundStyle(.ripul(.textSecondary))
                }
            }
        default:
            Picker(label, selection: $selection) {
                Text(input.isRequired ? "Choose" : empty?.label ?? "None").tag("")
                ForEach(options) { Text($0.label).tag($0.value) }
            }
        }
    }
}

/// One choice: its value, label, a line under it and its row (for a picture).
struct CmsFormChoice: Identifiable, Equatable {
    var value: String
    var label: String
    var description: String?
    var row: [String: CmsJSON]
    var id: String { value }
}

/// A choice's label with its description under it, and its picture.
private struct CmsChoiceRow: View {
    let option: CmsFormChoice
    let picture: CmsColumnPresentation?

    var body: some View {
        HStack(spacing: 10) {
            if let candidates = picture?.pictureCandidates(option.row), !candidates.isEmpty {
                CmsColumnPicture(candidates: candidates, size: 28, cornerRadius: 6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label).foregroundStyle(.ripul(.text))
                if let description = option.description {
                    Text(description).font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
                }
            }
        }
    }
}

/// A choice list pushed in the form's stack: the system's rows with a
/// checkmark, a search field with `searchable`, and with `create` a row that
/// adds the searched text as a new choice.
private struct CmsChoiceListScreen: View {
    @ObservedObject var runtime: CmsRuntime
    let title: String
    let options: [CmsFormChoice]
    let picture: CmsColumnPresentation?
    let searchable: Bool
    let create: CmsOptionsCreate?
    let listParams: [String: CmsJSON]
    @Binding var selection: String
    let onCreated: (CmsFormChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var creating = false
    @State private var failure: String?

    private var shown: [CmsFormChoice] {
        let t = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return options }
        return options.filter { $0.label.localizedCaseInsensitiveContains(t) || ($0.description?.localizedCaseInsensitiveContains(t) ?? false) }
    }

    var body: some View {
        List {
            if let failure {
                Section { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.ripul(.danger)) }
            }
            if let create, CmsFormSteps.offersCreate(search, labels: options.map(\.label)) {
                Section {
                    Button { add(create) } label: {
                        HStack {
                            Label(CmsFormSteps.createLabel(create, text: search), systemImage: "plus.circle.fill")
                            Spacer()
                            if creating { ProgressView() }
                        }
                    }
                    .disabled(creating)
                    .cmsInspectorID("Cms.recordForm.choiceAdd")
                }
            }
            Section {
                ForEach(shown) { option in
                    Button {
                        selection = option.value
                        dismiss()
                    } label: {
                        HStack {
                            CmsChoiceRow(option: option, picture: picture)
                            Spacer()
                            if option.value == selection {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .cmsInspectorID("Cms.recordForm.choiceRow")
                }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .modifier(CmsChoiceSearch(enabled: searchable || create != nil, text: $search))
    }

    /// Runs the create mutation with the searched text, chooses what it made,
    /// and closes; a failure keeps the list open and says why.
    private func add(_ create: CmsOptionsCreate) {
        let text = search
        creating = true
        failure = nil
        Task {
            let params = CmsFormSteps.createParams(create, listParams: listParams, text: text)
            let outcome = await runtime.runMutationResult(create.mutationSlug, params: CmsRuntime.textParams(params))
            creating = false
            switch outcome {
            case .failure(let refusal):
                failure = refusal.message
            case .success(let result):
                guard let chosen = CmsFormSteps.createdChoice(create, result: result, text: text) else {
                    failure = "It was added, but its new choice couldn't be read."
                    return
                }
                onCreated(CmsFormChoice(value: chosen.value, label: chosen.label, description: nil, row: [:]))
                selection = chosen.value
                dismiss()
            }
        }
    }
}

private struct CmsChoiceSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    func body(content: Content) -> some View {
        if enabled { content.searchable(text: $text) } else { content }
    }
}

/// `image` on a text input: a live picture of what's typed, through the
/// site's image sources, after a short pause; nothing when none matches.
private struct CmsTypedPicture: View {
    let chain: CmsJSON
    let shape: String?
    let name: String
    let text: String
    @State private var settled = ""

    var body: some View {
        let value = settled.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = value.isEmpty ? [] : CmsCalendarDecorations.imageCandidates(
            ["value": .string(value), name: .string(value)], CmsCalendarDecorations.imageChain(chain))
        // A zero-size anchor: an empty view would never run the task.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if !candidates.isEmpty {
                CmsColumnPicture(candidates: candidates, size: 32, cornerRadius: shape == "circle" ? 16 : 7)
                    .id(value)
            }
        }
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if !Task.isCancelled { settled = text }
        }
        .cmsInspectorID("Cms.recordForm.typedPicture")
    }
}

/// A list input's item, added or changed in a small form of its fields.
private struct CmsListItemEditor: View {
    @ObservedObject var runtime: CmsRuntime
    let list: CmsActionInputDef?
    let edit: CmsRecordFormSheet.ItemEdit
    let onDone: ([String: CmsJSON]) -> Void
    let onRemove: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var item: [String: CmsJSON]

    init(runtime: CmsRuntime, list: CmsActionInputDef?, edit: CmsRecordFormSheet.ItemEdit,
         onDone: @escaping ([String: CmsJSON]) -> Void, onRemove: (() -> Void)?) {
        self.runtime = runtime
        self.list = list
        self.edit = edit
        self.onDone = onDone
        self.onRemove = onRemove
        _item = State(initialValue: edit.item)
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach((list?.fields ?? []).filter { $0.hidden != true }) { field in
                    switch CmsActionForm.control(for: field) {
                    case .toggle:
                        Toggle(field.displayLabel, isOn: Binding(get: { CmsFormScope.truth(item[field.name]) },
                                                                 set: { item[field.name] = .bool($0) }))
                    case .duration:
                        CmsDurationField(label: field.displayLabel, unit: field.unit ?? "minutes",
                                         value: Binding(get: { item[field.name].map { CmsCards.text($0) } ?? "0" },
                                                        set: { item[field.name] = .number(Double($0) ?? 0) }))
                    default:
                        LabeledContent(field.displayLabel) {
                            TextField(field.displayLabel, text: Binding(
                                get: { item[field.name].map { CmsCards.text($0) } ?? "" },
                                set: { text in
                                    item[field.name] = ["integer", "float"].contains(field.type)
                                        ? (Double(text).map(CmsJSON.number) ?? .string(text)) : .string(text)
                                }))
                            .multilineTextAlignment(.trailing)
                        }
                    }
                }
                if let onRemove {
                    Section {
                        Button(role: .destructive) { onRemove(); dismiss() } label: {
                            Label("Remove", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(edit.index == nil ? (list?.addLabel ?? "Add") : (list?.displayLabel ?? "Edit"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(edit.index == nil ? "Add" : "Done") { onDone(item); dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(runtime.theme.primary)
    }
}

// MARK: - Presenting a row's form

/// Text that sits on a page-form's masthead band takes the band's text colour.
struct CmsOnBandText: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color { content.foregroundStyle(color) } else { content }
    }
}

/// A record form opened as a page (CmsMasthead.swift): the site's masthead
/// behind, under the status and navigation bars, with the form's title big in
/// it; the form's grouped sections start the style's `overlap` up into it and
/// scroll over it; the bar stays clear so the system's back button sits on the
/// band. With `masthead: false`, a plain page with the title in the bar.
struct CmsFormPageChrome: ViewModifier {
    let enabled: Bool
    let style: CmsMasthead.Style
    let showsBand: Bool
    let title: String
    let subtitle: String?
    /// The form's own `mastheadScroll` and `mastheadCut` (nil = the style's).
    var scroll: String? = nil
    var cut: String? = nil
    @EnvironmentObject var runtime: CmsRuntime

    func body(content: Content) -> some View {
        if enabled && showsBand {
            let how = CmsMasthead.scrolling(style, scroll: scroll, cut: cut)
            content.modifier(CmsMastheadChrome(style: style, theme: runtime.theme, title: title, subtitle: subtitle,
                                               under: how.under, rounded: how.rounded))
        } else if enabled {
            content.navigationTitle(title)
        } else {
            content
        }
    }
}

/// Presents a record's form for a request (a row's, a card's or an action
/// button's) as the site sets: a sheet, or a page pushed on the tab's stack
/// under the site's masthead (CmsMasthead.swift). Runs its mutation or its
/// delete, refreshes and shows the success message. The quick flip closes it
/// and opens it the other way with what was typed.
struct CmsRecordFormPresenter: ViewModifier {
    @ObservedObject var runtime: CmsRuntime
    @Binding var request: CmsRecordFormRequest?
    @State private var sheetRequest: CmsRecordFormRequest?

    func body(content: Content) -> some View {
        content
            .ripulSheet(item: $sheetRequest) { request in
                form(request, presentation: .sheet, close: nil)
            }
            .onChange(of: request?.id) { _ in
                guard let next = request else { return }
                request = nil
                show(next)
            }
    }

    private func show(_ request: CmsRecordFormRequest) {
        let form = runtime.mutationDefs[request.spec.mutationSlug]?.action?.form
        if CmsMasthead.presentation(of: form, runtime: runtime) == .page, let push = runtime.pushFormPage {
            let id = UUID()
            let runtime = runtime
            let pushed = push(id) { [self] in
                AnyView(self.form(request, presentation: .page, close: { runtime.closeFormPage?(id) })
                    .environmentObject(runtime))
            }
            if pushed { return }
        }
        sheetRequest = request
    }

    /// The other presentation, remembered on this device, with what was typed.
    private func flip(_ request: CmsRecordFormRequest, from current: CmsMasthead.Presentation, draft: [String: CmsActionForm.Draft]) {
        CmsMasthead.setChoice(current == .page ? .sheet : .page, cmsId: runtime.cmsId)
        var next = request
        next.id = UUID()
        next.draft = draft
        // After the sheet's dismissal or the page's pop has finished.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { show(next) }
    }

    @ViewBuilder
    private func form(_ request: CmsRecordFormRequest, presentation: CmsMasthead.Presentation, close: (() -> Void)?) -> some View {
        if let mutation = runtime.mutationDefs[request.spec.mutationSlug] {
            let flips = mutation.action?.form != nil && CmsMasthead.viewerChoiceAllowed(runtime.themeConfig)
            let onFlip: (([String: CmsActionForm.Draft]) -> Void)? = flips ? { draft in flip(request, from: presentation, draft: draft) } : nil
            if let custom = request.custom {
                CmsRecordFormSheet(runtime: runtime, mutation: mutation, inputs: custom.inputs, values: [:],
                                   onSave: custom.onSave,
                                   presentation: presentation, initialDraft: request.draft, onFlip: onFlip, onClose: close)
            } else {
                let values = CmsRecordFormRequest.values(request.spec, row: request.row)
                let delete = request.spec.deleteMutationSlug.flatMap { runtime.mutationDefs[$0] }
                CmsRecordFormSheet(
                    runtime: runtime, mutation: mutation, inputs: mutation.action?.inputs ?? [], values: values,
                    deleteMutation: delete,
                    deleteLabel: request.spec.deleteLabel,
                    load: request.spec.load.map { load in
                        let params = load.params.mapValues { template -> CmsJSON in
                            CmsParameterKinds.typedParam(CmsFormText.fill(template) { name, _ in request.row[name].map { CmsCards.text($0) } ?? "" },
                                                         type: "string")
                        }
                        return (slug: load.querySlug, params: params,
                                fill: { loaded in CmsRecordFormRequest.values(request.spec, row: loaded) })
                    },
                    onSave: { params in await run(mutation.slug, params: params) },
                    onDelete: delete.map { def in { values in
                        // The delete runs with the record's values (its key), as the web's does.
                        let inputs = def.action?.inputs ?? []
                        let typed = inputs.isEmpty
                            ? values.mapValues { CmsParameterKinds.typedParam(CmsCards.text($0), type: "string") }
                            : CmsActionForm.typedParams(inputs, values: CmsActionForm.validate(inputs, draft: CmsActionForm.draft(inputs, values: values)).values)
                        return await run(def.slug, params: typed)
                    } },
                    actions: request.spec.actions.compactMap { action in
                        guard let def = runtime.mutationDefs[action.mutationSlug] else { return nil }
                        return (label: action.label, run: { values in
                            let inputs = def.action?.inputs ?? []
                            let picked = CmsRowFormSpec.actionParams(action, inputNames: inputs.map(\.name), record: values)
                            let typed = inputs.isEmpty
                                ? picked.mapValues { CmsParameterKinds.typedParam(CmsCards.text($0), type: "string") }
                                : CmsActionForm.typedParams(inputs, values: CmsActionForm.validate(inputs, draft: CmsActionForm.draft(inputs, values: picked)).values)
                            return await run(def.slug, params: typed)
                        })
                    },
                    presentation: presentation, initialDraft: request.draft, onFlip: onFlip, onClose: close)
            }
        } else {
            ContentUnavailableView("Form unavailable", systemImage: "doc.questionmark",
                                   description: Text("The mutation \(request.spec.mutationSlug) isn't in this site."))
        }
    }

    private func run(_ slug: String, params: [String: CmsJSON]) async -> String? {
        switch await runtime.runMutation(slug, params: params) {
        case .done(_, let text):
            runtime.showNotice(text)
            return nil
        case .failed(let refusal):
            return refusal
        }
    }
}

/// A set of days (`type: "dates"`): the range's days to mark, the system's
/// own multi-date calendar bounded to the range on iPhone (`MultiDatePicker`),
/// a toggle per day elsewhere. The selection is the days joined with commas.
struct CmsDateSetField: View {
    let input: CmsActionInputDef
    /// The range's days (`yyyy-MM-dd`); empty until both ends are set.
    let days: [String]
    @Binding var selection: String

    /// No range: any day, on an unbounded calendar.
    private var free: Bool { input.range == nil }
    private var chosen: [String] {
        let all = CmsDateSets.value(itemField: nil, .string(selection))
        return free ? all : all.filter(days.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(input.displayLabel).font(.ripul(.body, weight: .semibold))
                Spacer()
                if free, !chosen.isEmpty {
                    Text(chosen.count == 1 ? "1 day" : "\(chosen.count) days")
                        .font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary)).monospacedDigit()
                        .cmsInspectorID("Cms.recordForm.dateSet.count")
                } else if !days.isEmpty {
                    Text("\(chosen.count) of \(days.count)")
                        .font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary)).monospacedDigit()
                        .cmsInspectorID("Cms.recordForm.dateSet.count")
                }
            }
            if free {
                freePicker
            } else if days.isEmpty {
                Text("Choose the dates first.")
                    .font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
            } else {
                picker
            }
            if let description = input.description, !description.isEmpty {
                Text(description).font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
            }
        }
        .padding(.vertical, 4)
        .cmsInspectorID("Cms.recordForm.dateSet")
    }

    @ViewBuilder
    private var picker: some View {
        #if os(iOS)
        // The bounds: the first day's start up to just after the last day's
        // start, so the picker offers the last day and not the one after it.
        if let first = days.first.flatMap({ CmsDateSets.date($0) }),
           let lastDay = days.last.flatMap({ CmsDateSets.date($0) }) {
            MultiDatePicker(input.displayLabel, selection: components, in: first..<lastDay.addingTimeInterval(1))
                .labelsHidden()
                // The picker keeps the binding and bounds it was made with, so
                // a new range makes a new picker (else a tap writes the old range).
                .id("\(days.first ?? "")…\(days.last ?? "")")
                .cmsInspectorID("Cms.recordForm.dateSet.picker")
        }
        #else
        ForEach(days, id: \.self) { day in
            Toggle(day, isOn: Binding(get: { chosen.contains(day) }, set: { on in toggle(day, on) }))
        }
        #endif
    }

    /// Any day: the system's multi-date calendar, unbounded.
    @ViewBuilder
    private var freePicker: some View {
        #if os(iOS)
        MultiDatePicker(input.displayLabel, selection: components)
            .labelsHidden()
            .cmsInspectorID("Cms.recordForm.dateSet.picker")
        #else
        Text(chosen.joined(separator: ", ")).font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
        #endif
    }

    /// The selection as the picker holds it: each chosen day's calendar components.
    private var components: Binding<Set<DateComponents>> {
        Binding(
            get: { Set(chosen.compactMap { CmsDateSets.components($0) }) },
            set: { picked in
                let next = picked.compactMap { CmsDateSets.day($0) }.filter { free || days.contains($0) }
                selection = Array(Set(next)).sorted().joined(separator: ",")
            })
    }

    private func toggle(_ day: String, _ on: Bool) {
        var set = Set(chosen)
        if on { set.insert(day) } else { set.remove(day) }
        selection = set.sorted().joined(separator: ",")
    }
}

/// `choiceStyle: "dropdown"`: a glass capsule showing the chosen option's
/// picture, label and subtitle, opening the system's own menu (a `Menu`,
/// which morphs from the trigger and is Liquid Glass on iOS 26) with a toggle
/// per option: its picture, label and subtitle, ticked when chosen. Menus can't load images while open, so every option's
/// picture is loaded through the page's image cache and drawn into a tile
/// before the menu opens, in its own colours (`alwaysOriginal`). An option
/// with no picture, or one that fails, gets a tile of its initials instead.
struct CmsDropdownChoice: View {
    @ObservedObject var runtime: CmsRuntime
    let label: String
    let options: [CmsFormChoice]
    let picture: CmsColumnPresentation?
    let allowsNone: Bool
    /// The empty choice's own label and line (`optionsQuery.emptyChoice`); "None" without.
    var empty: Empty? = nil
    @Binding var selection: String

    struct Empty: Equatable {
        var label: String
        var description: String?
    }
    /// Each option's picture as a ready tile, by value.
    @State private var tiles: [String: CmsPlatformImage] = [:]

    static let menuTileSize: CGFloat = 28

    /// A query's rows as choices: label, `descriptionColumn` as the subtitle, and the row (for its picture).
    static func options(rows: [[String: CmsJSON]], query: CmsActionOptionsQuery) -> [CmsFormChoice] {
        CmsActionForm.options(from: rows, query: query).map { choice in
            let row = rows.first { $0[query.valueColumn].map { CmsCards.text($0) } == choice.value } ?? [:]
            return CmsFormChoice(value: choice.value, label: choice.label, description: query.describe(row), row: row)
        }
    }

    /// The options' picture: the query's (or input's) image column and chain.
    static func picture(input: CmsActionInputDef, query: CmsActionOptionsQuery) -> CmsColumnPresentation? {
        guard let imageColumn = query.imageColumn ?? input.imageColumn, !imageColumn.isEmpty else { return nil }
        let chain = (query.image ?? input.image)?.objectValue?["chain"] ?? .array([])
        return CmsColumnPresentation(key: imageColumn, json: ["image": .object(["chain": chain])])
    }
    static let triggerTileSize: CGFloat = 34

    var body: some View {
        let chosen = options.first { $0.value == selection }
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.ripul(.footnote, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .padding(.leading, 4)
            Menu {
                // One toggle per option: in a menu a toggle is an action with a tick, and
                // keeps both its picture and a second line (a Picker's rows drop the second line).
                if allowsNone {
                    Toggle(isOn: Binding(get: { selection.isEmpty }, set: { if $0 { selection = "" } })) {
                        Text(empty?.label ?? "None")
                        if let line = empty?.description { Text(line) }
                    }
                }
                ForEach(options) { option in
                    Toggle(isOn: Binding(get: { selection == option.value }, set: { if $0 { selection = option.value } })) {
                        // A menu row reads its label's parts: the first text as the title, the
                        // second as the subtitle, an image as the icon (a Label's title drops the second).
                        Text(option.label)
                        if let description = option.description { Text(description) }
                        if let tile = tiles[option.value] { Image(cmsPlatformImage: tile) }
                    }
                }
            } label: {
                trigger(chosen)
            }
            .cmsInspectorID("Cms.recordForm.dropdown")
        }
        // In the form's own card, as WAC's capsule sits in its white card.
        .padding(.vertical, 4)
        .task(id: options.map(\.value)) { await loadTiles() }
    }

    private func trigger(_ chosen: CmsFormChoice?) -> some View {
        HStack(spacing: 12) {
            if let chosen, let tile = tiles[chosen.value] {
                Image(cmsPlatformImage: tile)
                    .resizable()
                    .frame(width: Self.triggerTileSize, height: Self.triggerTileSize)
            }
            VStack(alignment: .leading, spacing: 2) {
                let emptyShown = chosen == nil && allowsNone && empty != nil
                Text(chosen?.label ?? (emptyShown ? empty!.label : "Choose"))
                    .font(.ripul(.body, weight: .semibold))
                    .foregroundStyle(chosen == nil && !emptyShown ? .ripul(.textSecondary) : .ripul(.text))
                    .lineLimit(1)
                if let description = chosen?.description ?? (emptyShown ? empty?.description : nil) {
                    Text(description)
                        .font(.ripul(.footnote))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.ripul(.footnote, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .contentShape(Capsule())
        .modifier(CmsGlassCapsule())
        .cmsInspectorID("Cms.recordForm.dropdown.trigger")
    }

    /// Every option's picture, through the page's cache, drawn into a rounded tile.
    private func loadTiles() async {
        guard let picture else { tiles = [:]; return }
        var next: [String: CmsPlatformImage] = [:]
        let cache = CmsMarkerImageCache.forPage(runtime)
        for option in options {
            let candidates = picture.pictureCandidates(option.row)
            if !candidates.isEmpty,
               let image = await cache.resolve(candidates, size: CmsCalendarDecorations.imageRequestSize(Double(Self.triggerTileSize))) {
                next[option.value] = Self.tile(image)
            } else {
                // No picture, or it failed: the option's initials, so every row's text lines up.
                next[option.value] = Self.initialsTile(option)
            }
        }
        tiles = next
    }

    /// The initials an option's fallback tile draws (the web's `choiceInitials`):
    /// the first letter or digit of each of its label's first two words that have
    /// one, upper-cased; with no label, the key's first.
    static func initials(label: String, key: String) -> String {
        let first: (Substring) -> Character? = { $0.first { $0.isLetter || $0.isNumber } }
        let letters = label.split(whereSeparator: \.isWhitespace).compactMap(first).prefix(2)
        if !letters.isEmpty { return String(letters).uppercased() }
        return (first(Substring(key)).map { String($0) } ?? String(key.prefix(1))).uppercased()
    }

    /// An option with no picture as a tile of its initials on the calendar
    /// markers' palette colour hashed from its value: the picture tile's size and shape.
    static func initialsTile(_ option: CmsFormChoice) -> CmsPlatformImage {
        let text = initials(label: option.label, key: option.value)
        let hex = CmsCalendarDecorations.paletteColor(option.value)
        #if canImport(UIKit)
        let size = CGSize(width: triggerTileSize, height: triggerTileSize)
        let fill = CmsCss.color(hex).map { UIColor($0) } ?? .gray // theme-exempt: data palette, the markers'
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: 8).addClip()
            fill.setFill()
            UIRectFill(rect)
            let font = UIFont.systemFont(ofSize: (text.count > 1 ? 0.38 : 0.46) * size.width, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white] // theme-exempt: text on a palette tile
            let drawn = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2),
                                    withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
        #else
        return CmsPlatformImage(size: NSSize(width: triggerTileSize, height: triggerTileSize))
        #endif
    }

    /// A picture drawn into a rounded tile, in its own colours, for a menu's icon slot.
    static func tile(_ image: CmsPlatformImage) -> CmsPlatformImage {
        #if canImport(UIKit)
        let size = CGSize(width: triggerTileSize, height: triggerTileSize)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: 8).addClip()
            UIColor.white.setFill() // theme-exempt: a logo's own backdrop, as WAC's job tiles
            UIRectFill(rect)
            let s = image.size
            let scale = max(size.width / max(s.width, 1), size.height / max(s.height, 1))
            let drawn = CGSize(width: s.width * scale, height: s.height * scale)
            image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }.withRenderingMode(.alwaysOriginal)
        #else
        return image
        #endif
    }
}

/// A capsule of glass: Liquid Glass on iOS 26, else the thin material. Regular,
/// not clear, glass: a clear capsule all but vanishes on a form's light ground
/// (WAC's own job trigger is regular glass too).
struct CmsGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        content.background(.ultraThinMaterial, in: Capsule())
        #endif
    }
}
