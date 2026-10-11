#if os(iOS)
import SwiftUI

// ---------------------------------------------------------------------------
// Gateway operations — the web tab's "Discover" and "Verify costs" panels as
// native sheets. Both run the server-side discovery against the CF AI Gateway;
// discover imports selected new models (they arrive DISABLED for review),
// verify compares stored prices and applies gateway values to the selection.
// ---------------------------------------------------------------------------

@available(iOS 16.0, *)
struct RipulModelDiscoverySheet: View {
    let client: RipulModelCatalogClient
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var result: RipulDiscoverResult?
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                if loading {
                    ProgressView("Asking the gateway…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, result == nil {
                    failure(errorMessage) {
                        Task { await run() }
                    }
                } else if let result {
                    list(result)
                }
            }
            .navigationTitle("Discover models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Import (\(selected.count))") {
                            Task { await runImport() }
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
            .task { await run() }
        }
    }

    private func list(_ result: RipulDiscoverResult) -> some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.ripul(.danger)).font(.ripul(.callout))
                }.ripulThemedListRows()
            }
            if result.newModels.isEmpty {
                Section {
                    Text("Nothing new — every gateway model is already in the catalog.")
                        .foregroundStyle(.ripul(.textSecondary))
                }.ripulThemedListRows()
            } else {
                Section {
                    ForEach(result.newModels) { m in
                        Button {
                            if selected.contains(m.gatewayId) {
                                selected.remove(m.gatewayId)
                            } else {
                                selected.insert(m.gatewayId)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(m.gatewayId)
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(m.gatewayId)
                                        ? Color.accentColor : Color.ripul(.textSecondary))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name)
                                        .font(.ripul(.subheadline, weight: .medium))
                                        .foregroundStyle(.ripul(.text))
                                    Text(m.gatewayId)
                                        .font(.ripul(.caption))
                                        .foregroundStyle(.ripul(.textSecondary))
                                        .lineLimit(1)
                                    if m.perMInput > 0 || m.perMOutput > 0 {
                                        Text("$\(fmt(m.perMInput)) in · $\(fmt(m.perMOutput)) out · per M tokens")
                                            .font(.ripul(.caption2))
                                            .foregroundStyle(.ripul(.textTertiary))
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: { RipulSectionHeader {
                    Text("New on the gateway")
                } } footer: { RipulSectionFooter {
                    Text("Imported models arrive disabled, for review before anyone can pick them.")
                } }.ripulThemedListRows()
            }
            Section {
                Text("\(result.totalGatewayModels) on the gateway · \(result.existingMatches.count) already in the catalog")
                    .font(.ripul(.footnote))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }.ripulThemedListRows()
        }.ripulThemedList()
    }

    private func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.ripulIcon(.largeTitle))
                .foregroundStyle(.ripul(.textSecondary))
            Text(message)
                .font(.ripul(.callout))
                .foregroundStyle(.ripul(.textSecondary))
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
        }
        .padding()
    }

    private func run() async {
        loading = true
        errorMessage = nil
        do {
            result = try await client.discover()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func runImport() async {
        working = true
        errorMessage = nil
        do {
            _ = try await client.importDiscovered(gatewayIds: Array(selected))
            onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        working = false
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

@available(iOS 16.0, *)
struct RipulModelCostVerifySheet: View {
    let client: RipulModelCatalogClient
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var result: RipulVerifyCostsResult?
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                if loading {
                    ProgressView("Comparing prices…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, result == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "dollarsign.circle")
                            .font(.ripulIcon(.largeTitle))
                            .foregroundStyle(.ripul(.textSecondary))
                        Text(errorMessage)
                            .font(.ripul(.callout))
                            .foregroundStyle(.ripul(.textSecondary))
                            .multilineTextAlignment(.center)
                        Button("Retry") { Task { await run() } }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                } else if let result {
                    list(result)
                }
            }
            .navigationTitle("Verify costs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Apply (\(selected.count))") {
                            Task { await apply() }
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
            .task { await run() }
        }
    }

    private func list(_ result: RipulVerifyCostsResult) -> some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.ripul(.danger)).font(.ripul(.callout))
                }.ripulThemedListRows()
            }
            if result.discrepancies.isEmpty {
                Section {
                    Label(
                        "All \(result.totalChecked) matched prices agree with the gateway.",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.ripul(.textSecondary))
                }.ripulThemedListRows()
            } else {
                Section {
                    ForEach(result.discrepancies) { d in
                        Button {
                            if selected.contains(d.catalogId) {
                                selected.remove(d.catalogId)
                            } else {
                                selected.insert(d.catalogId)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(d.catalogId)
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(d.catalogId)
                                        ? Color.accentColor : Color.ripul(.textSecondary))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.modelName)
                                        .font(.ripul(.subheadline, weight: .medium))
                                        .foregroundStyle(.ripul(.text))
                                    Text("In: $\(fmt(d.catalog.perMInput)) → $\(fmt(d.gateway.perMInput)) · Out: $\(fmt(d.catalog.perMOutput)) → $\(fmt(d.gateway.perMOutput))")
                                        .font(.ripul(.caption))
                                        .foregroundStyle(.ripul(.textSecondary))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: { RipulSectionHeader {
                    Text("Prices that differ")
                } } footer: { RipulSectionFooter {
                    Text("Applying sets the catalog price to the gateway's current value.")
                } }.ripulThemedListRows()
            }
        }.ripulThemedList()
    }

    private func run() async {
        loading = true
        errorMessage = nil
        do {
            let verified = try await client.verifyCosts()
            result = verified
            // Discrepancies exist to be fixed — preselect them all.
            selected = Set(verified.discrepancies.map(\.catalogId))
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func apply() async {
        working = true
        errorMessage = nil
        do {
            _ = try await client.applyCostUpdates(catalogIds: Array(selected))
            onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        working = false
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
#endif
