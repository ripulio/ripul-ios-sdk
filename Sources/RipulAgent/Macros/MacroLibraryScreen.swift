#if os(iOS)
import SwiftUI

public extension Notification.Name {
    /// Post this notification to open the macro library sheet
    /// (`RipulAgentConsole` listens) — same pattern as `.ripulShowDevTools`.
    /// Any view in the host's hierarchy can trigger it (a menu item, a
    /// button next to the console's own dev-tools entry point, etc.).
    static let ripulShowMacroLibrary = Notification.Name("ripulShowMacroLibrary")
}

/// Lists every macro in scope, with a publish/unpublish toggle and delete —
/// the developer-facing peer of the View Explorer's recording flow. A macro
/// recorded via the Macro tab shows up here as a draft; publishing it here is
/// what makes `RipulAgentConsole.refreshMacroTools()` register it under
/// `.endUser` instead of `.developer` on the next refresh.
@available(iOS 16.0, *)
struct MacroLibraryScreen: View {
    let client: RipulMacroClient
    /// Called after any create/publish/delete so the caller can re-run
    /// `refreshMacroTools()` — the screen doesn't own the registry itself.
    let onChange: () -> Void

    @State private var macros: [RipulMacro] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Deterministic replay (no agent round-trip): the row tapped, the
    /// confirmation dialog, the param-entry sheet for `{{token}}` macros,
    /// and the outcome readout.
    @State private var replayCandidate: RipulMacro?
    @State private var replayParamMacro: RipulMacro?
    @State private var paramValues: [String: String] = [:]
    @State private var replayOutcome: (name: String, result: MacroReplayResult)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if macros.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No macros yet",
                        message: "Record one from the View Explorer's Macro tab."
                    )
                } else {
                    List {
                        ForEach(macros) { macro in
                            row(macro)
                        }
                    }
                }
            }
            .navigationTitle("Macros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .uiKitIdentifier("MacroLibraryScreen.refreshButton")
                }
            }
            .alert("Couldn't load macros", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                replayCandidate.map { "Replay '\($0.name)'?" } ?? "",
                isPresented: Binding(get: { replayCandidate != nil }, set: { if !$0 { replayCandidate = nil } }),
                titleVisibility: .visible
            ) {
                if let macro = replayCandidate {
                    Button("Replay (\(macro.steps.count) step\(macro.steps.count == 1 ? "" : "s"))") {
                        confirmReplay(macro)
                    }
                }
                Button("Cancel", role: .cancel) { replayCandidate = nil }
            } message: {
                Text("Performs the recorded steps on the app screen behind this console — minimize the console to watch.")
            }
            .sheet(item: $replayParamMacro) { macro in
                MacroReplayParamsSheet(macro: macro, initialValues: paramValues) { values in
                    paramValues = values
                    Task { await runReplay(macro) }
                }
            }
            .alert(
                replayOutcome.map { $0.result.success ? "Replay finished" : "Replay stopped at step \((($0.result.failedStepIndex ?? 0) + 1))" } ?? "",
                isPresented: Binding(get: { replayOutcome != nil }, set: { if !$0 { replayOutcome = nil } })
            ) {
                Button("OK", role: .cancel) { replayOutcome = nil }
            } message: {
                if let outcome = replayOutcome {
                    Text(outcome.result.success
                        ? "'\(outcome.name)': all \(outcome.result.totalSteps) steps completed."
                        : "'\(outcome.name)': \(outcome.result.completedSteps) of \(outcome.result.totalSteps) steps done. \(outcome.result.error ?? "Unknown error")")
                }
            }
        }
        .task { await load() }
    }

    private func confirmReplay(_ macro: RipulMacro) {
        replayCandidate = nil
        if macro.parameters.isEmpty {
            paramValues = [:]
            Task { await runReplay(macro) }
        } else {
            paramValues = [:]
            replayParamMacro = macro
        }
    }

    private func runReplay(_ macro: RipulMacro) async {
        let result = await MacroReplayEngine.replay(macro, parameters: paramValues, resolver: LiveScreenResolver())
        replayOutcome = (macro.name, result)
    }

    private func row(_ macro: RipulMacro) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(macro.name)
                    .font(.headline)
                Spacer()
                Button {
                    replayCandidate = macro
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Replay \(macro.name)")
                .uiKitIdentifier("MacroLibraryScreen.row.\(macro.name).replayButton")
                Text(macro.published ? "Published" : "Draft")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(macro.published ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                    .foregroundStyle(macro.published ? .green : .gray)
                    .clipShape(Capsule())
            }
            Text(macro.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(macro.steps.count) step\(macro.steps.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .uiKitIdentifier("MacroLibraryScreen.row.\(macro.name)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await delete(macro) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .uiKitIdentifier("MacroLibraryScreen.row.\(macro.name).deleteButton")
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await togglePublished(macro) }
            } label: {
                Label(macro.published ? "Unpublish" : "Publish",
                     systemImage: macro.published ? "eye.slash" : "eye")
            }
            .tint(macro.published ? .orange : .green)
            .uiKitIdentifier("MacroLibraryScreen.row.\(macro.name).publishToggle")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            macros = try await client.list()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func togglePublished(_ macro: RipulMacro) async {
        do {
            _ = try await client.update(id: macro.id, edit: RipulMacroEdit(published: !macro.published))
            await load()
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ macro: RipulMacro) async {
        do {
            try await client.delete(id: macro.id)
            await load()
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// `ContentUnavailableView` is iOS 17+; this SDK's iOS floor for these
/// screens is 16 (matching `ViewInspectorOverlay`'s own `@available`), so a
/// minimal stand-in covers 16–16.x rather than raising the floor for one screen.
@available(iOS 16.0, *)
private struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}

/// Parameter entry for a deterministic replay of a `{{token}}` macro — one
/// field per declared `MacroParameter`, handed back to the caller as
/// `[name: value]` for `MacroReplayEngine.replay`.
@available(iOS 16.0, *)
private struct MacroReplayParamsSheet: View {
    let macro: RipulMacro
    let onReplay: ([String: String]) -> Void

    @State private var values: [String: String]
    @Environment(\.dismiss) private var dismiss

    init(macro: RipulMacro, initialValues: [String: String], onReplay: @escaping ([String: String]) -> Void) {
        self.macro = macro
        self.onReplay = onReplay
        _values = State(initialValue: initialValues)
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(macro.parameters, id: \.name) { parameter in
                    TextField(
                        parameter.description.isEmpty ? parameter.name : "\(parameter.name) — \(parameter.description)",
                        text: Binding(
                            get: { values[parameter.name] ?? "" },
                            set: { values[parameter.name] = $0 }
                        )
                    )
                    .autocorrectionDisabled()
                    .uiKitIdentifier("MacroReplayParamsSheet.field.\(parameter.name)")
                }
            }
            .navigationTitle("Replay \(macro.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Replay") {
                        dismiss()
                        onReplay(values)
                    }
                    .uiKitIdentifier("MacroReplayParamsSheet.replayButton")
                }
            }
        }
    }
}
#endif
