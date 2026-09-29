import SwiftUI

/// Edits what one machine's disclosure panel shows: drag to reorder, switch
/// each entry between a square tile and a compact row, hide what you never use.
///
/// Native-first: a `List` held in edit mode gives the system reorder handles,
/// rather than a hand-rolled drag. Writes go straight to the shared layout
/// store, so the row behind the sheet redraws as you edit.
struct MachinePanelCustomiserSheet: View {
    let machineId: String
    let machineName: String
    /// Snapshot of the row's entries when the sheet opened. Only identity and
    /// presentation are read here; no entry actions run from this sheet.
    let entries: [MachinePanelEntry]

    @ObservedObject private var store = MachinePanelLayoutStore.shared
    @Environment(\.dismiss) private var dismiss

    private var layout: MachinePanelLayout { store.layout(for: machineId) }

    /// Only arrangeable entries move: an offline machine's actions have no
    /// position to argue about, and letting a drag rewrite an order whose
    /// result can't be seen would be a trap.
    private var shown: [MachinePanelEntry] {
        entries.filter { $0.available && !$0.isHidden(in: layout) }.ordered(by: layout)
    }

    private var hidden: [MachinePanelEntry] {
        entries.filter { $0.available && $0.isHidden(in: layout) }.ordered(by: layout)
    }

    private var unavailable: [MachinePanelEntry] {
        entries.filter { !$0.available }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(shown) { entry in
                        entryRow(entry, isHidden: false)
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Shown")
                } footer: {
                    Text("Drag to reorder. Tiles fill the grid at the top of the panel; rows sit in the list below it.")
                }

                if !hidden.isEmpty {
                    Section("Hidden") {
                        ForEach(hidden) { entry in
                            entryRow(entry, isHidden: true)
                        }
                    }
                }

                if !unavailable.isEmpty {
                    Section("Unavailable While Offline") {
                        ForEach(unavailable) { entry in
                            Label(entry.label, systemImage: entry.icon)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("Reset to Default", role: .destructive) {
                        store.reset(machineId: machineId)
                    }
                    .disabled(layout.isEmpty)
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("Customise Panel")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Customise Panel").font(.headline)
                        Text(machineName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("MachinePanelCustomiserSheet")
    }

    private func entryRow(_ entry: MachinePanelEntry, isHidden: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.icon)
                .foregroundStyle(entry.tint)
                .frame(width: 22)
            Text(entry.label)
                .lineLimit(1)
                .foregroundStyle(isHidden ? .secondary : .primary)
            Spacer(minLength: 8)

            Picker("Placement", selection: placementBinding(for: entry)) {
                Image(systemName: "square.grid.2x2")
                    .accessibilityLabel("Tile")
                    .tag(MachinePanelPlacement.tile)
                Image(systemName: "list.bullet")
                    .accessibilityLabel("Row")
                    .tag(MachinePanelPlacement.row)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(entry.fixedPlacement)

            Button {
                store.set(layout.settingHidden(entry.id, !isHidden), for: machineId)
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(entry.essential ? Color.secondary.opacity(0.4) : (isHidden ? .secondary : .accentColor))
                    .frame(width: 28)
            }
            .buttonStyle(.borderless)
            .disabled(entry.essential)
            .accessibilityLabel(isHidden ? "Show \(entry.label)" : "Hide \(entry.label)")
        }
    }

    private func placementBinding(for entry: MachinePanelEntry) -> Binding<MachinePanelPlacement> {
        Binding(
            get: { entry.placement(in: layout) },
            set: { store.set(layout.settingPlacement($0, for: entry), for: machineId) }
        )
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ids = shown.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        // Hidden entries keep their slots, so un-hiding one puts it back where it was.
        store.set(layout.reordered(ids + hidden.map(\.id)), for: machineId)
    }
}
