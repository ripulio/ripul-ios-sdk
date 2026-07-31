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
    /// The macro currently open in the deterministic-replay sheet (no agent
    /// round-trip — live per-step pass/fail, `MacroReplaySheet`).
    @State private var replayMacro: RipulMacro?
    /// The macro open in the in-place editor (`MacroEditScreen`).
    @State private var editingMacro: RipulMacro?
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
            .sheet(item: $replayMacro) { macro in
                MacroReplaySheet(macro: macro)
            }
            .sheet(item: $editingMacro) { macro in
                MacroEditScreen(macro: macro, client: client, onSaved: {
                    Task { await load(); onChange() }
                })
            }
            .onReceive(MacroReplayHUDController.shared.$phase) { phase in
                // A HUD-mode replay takes over the bottom strip — the modal
                // sheet stack (library + replay sheet) must unwind
                // SwiftUI-side or it floats over the host screen. Hiding the
                // console panel never dismisses modal presentations (they're
                // siblings of the panel in the window, not children of it),
                // and dismissing them UIKit-side would desync the
                // .sheet(isPresented:) bindings and re-present them.
                if phase == .running { dismiss() }
            }
        }
        .task { await load() }
    }

    private func row(_ macro: RipulMacro) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(macro.name)
                    .font(.headline)
                Spacer()
                Button {
                    replayMacro = macro
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
        .contentShape(Rectangle())
        .onTapGesture { editingMacro = macro }
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
#endif
