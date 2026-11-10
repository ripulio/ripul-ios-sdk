import SwiftUI

/// Runs a card-shaped action for one row, outside a cards block: a swipe
/// action on a grid list row or a link list row (CmsSwipe). The cards' rules:
/// a run's inputs filled from the row's slots, inputs left out asked for in
/// the mutation's form, a confirm before it runs (the action's own text, else
/// the mutation's), its success message, and a failure said.
@MainActor
final class CmsRowActionRunner: ObservableObject {
    struct Confirm { var slug: String; var params: [String: CmsJSON]; var message: String; var label: String; var destructive: Bool }
    struct Ask { var slug: String; var params: [String: CmsJSON]; var inputs: [CmsActionInputDef]; var label: String }

    @Published var confirm: Confirm?
    @Published var asking: Ask?
    @Published var failure: String?
    @Published var note: String?
    @Published var recordForm: CmsRecordFormRequest?

    /// A swipe action on a row: asks first when it says to.
    func perform(_ swipe: CmsSwipe.Action, row: [String: CmsJSON]?, query: String?, runtime: CmsRuntime, openURL: (URL) -> Void) {
        perform(swipe.action, label: swipe.label, confirm: swipe.confirm, destructive: swipe.destructive,
                row: row, query: query, runtime: runtime, openURL: openURL)
    }

    /// Any card-shaped action for a row (a swipe's, or a primitives node's tap).
    func perform(_ action: CmsCardAction, label: String, confirm ownConfirm: String? = nil, destructive: Bool = false,
                 row: [String: CmsJSON]?, query: String?, runtime: CmsRuntime, openURL: (URL) -> Void) {
        switch action {
        case .openPage(let page, let params):
            // As a card's open: the row (with the params filled) becomes its query's selection.
            if let query, var selected = row {
                for (name, value) in CmsCards.inputs(params, row: row) { selected[name] = value.objectValue?["value"] ?? value }
                runtime.setSelectedRows(query, rows: [selected])
            }
            runtime.navigate(toPage: page)
        case .openTab(let page):
            runtime.navigate(toPage: page)
        case .openURL(let address):
            let filled = row.flatMap { CmsListRowLayout.fill(address, row: $0) { CmsColumnPresentation(key: $0, json: [:]) } } ?? address
            if let url = URL(string: filled) { openURL(url) }
        case .openSidebar(let edge):
            runtime.openSidebar(edge: edge)
        case .openForm(let spec):
            recordForm = CmsRecordFormRequest(spec: spec, row: row ?? [:])
        case .openHost(let name):
            runtime.hostActions[name]?()
        case .openWeb(let address, let title):
            CmsWebPage.open(address, title: title, row: row, runtime: runtime)
        case .run(let slug, let inputs, _):
            let params = CmsCards.inputs(inputs, row: row)
            let def = runtime.mutationDefs[slug]
            let asked = CmsActionForm.askedInputs(def, paramMap: inputs)
            if !asked.isEmpty {
                asking = Ask(slug: slug, params: params, inputs: asked, label: label)
            } else if let message = ownConfirm ?? def?.confirmMessage.flatMap({ $0.isEmpty ? nil : $0 }) {
                confirm = Confirm(slug: slug, params: params, message: message, label: label, destructive: destructive)
            } else {
                Task { await execute(slug, params: params, runtime: runtime) }
            }
        case .show, .close:
            break
        }
    }

    /// Returns a failure's message (for the input sheet, which shows it).
    @discardableResult
    func execute(_ slug: String, params: [String: CmsJSON], runtime: CmsRuntime, reportFailure: Bool = true) async -> String? {
        let outcome = await runtime.runMutation(slug, params: params)
        if case .failed(let message) = outcome {
            if reportFailure { failure = message }
            return message
        }
        if let message = runtime.mutationDefs[slug]?.successMessage, !message.isEmpty { showNote(message) }
        return nil
    }

    func showNote(_ message: String) {
        withAnimation { note = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { if note == message { note = nil } }
        }
    }
}

/// The runner's confirm, its asked inputs, its failure, its note and its record form.
struct CmsRowActionRunnerPresenter: ViewModifier {
    @ObservedObject var runner: CmsRowActionRunner
    let runtime: CmsRuntime

    func body(content: Content) -> some View {
        content
            .alert(runner.confirm?.label ?? "", isPresented: Binding(get: { runner.confirm != nil }, set: { if !$0 { runner.confirm = nil } })) {
                Button("Cancel", role: .cancel) {}
                Button(runner.confirm?.label ?? "OK", role: runner.confirm?.destructive == true ? .destructive : nil) {
                    if let c = runner.confirm { Task { await runner.execute(c.slug, params: c.params, runtime: runtime) } }
                }
            } message: {
                Text(runner.confirm?.message ?? "")
            }
            .ripulSheet(isPresented: Binding(get: { runner.asking != nil }, set: { if !$0 { runner.asking = nil } })) {
                if let ask = runner.asking {
                    let def = runtime.mutationDefs[ask.slug]
                    let save: ([String: CmsJSON]) async -> String? = { form in
                        var merged = ask.params
                        merged.merge(form) { _, new in new }
                        return await runner.execute(ask.slug, params: merged, runtime: runtime, reportFailure: false)
                    }
                    if let def, def.opensRecordForm {
                        CmsRecordFormSheet(runtime: runtime, mutation: def, inputs: ask.inputs, values: ask.params, onSave: save)
                    } else {
                        CmsActionInputSheet(
                            runtime: runtime,
                            title: def?.name.flatMap { $0.isEmpty ? nil : $0 } ?? ask.label,
                            inputs: ask.inputs,
                            confirmMessage: def?.confirmMessage,
                            confirmLabel: ask.label,
                            onSave: save
                        )
                    }
                }
            }
            .alert("Couldn't run that", isPresented: Binding(get: { runner.failure != nil }, set: { if !$0 { runner.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(runner.failure ?? "")
            }
            .overlay(alignment: .bottom) {
                if let note = runner.note {
                    Text(note)
                        .font(.ripul(.subheadline))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .modifier(CmsRecordFormPresenter(runtime: runtime, request: $runner.recordForm))
    }
}
