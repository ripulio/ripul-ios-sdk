import SwiftUI
import RipulAgent

struct SettingsView: View {
    @AppStorage("agentBaseURL") private var baseURLString = AgentConfiguration.defaultBaseURL.absoluteString
    @AppStorage("agentSiteKey") private var siteKey = "pk_live_2pakky4z3s9674wu9zvvgzze"
    @State private var showDeleteConfirmation = false
    @State private var deleteResultMessage: String?

    var body: some View {
        Form {
            Section("Agent Configuration") {
                TextField("Base URL", text: $baseURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField("Site Key", text: $siteKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Local Model") {
                NavigationLink {
                    LocalModelTestView()
                } label: {
                    Label("Test Apple Foundation Models", systemImage: "apple.intelligence")
                }
            }

            Section("Data") {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete All Calendar Events", systemImage: "trash")
                }
            }

            Section {
                Link(destination: URL(string: "https://ripul.io")!) {
                    HStack {
                        Label("Get a site key", systemImage: "key")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Link(destination: URL(string: "https://ripul.io")!) {
                    HStack {
                        Label("ripul.io", systemImage: "globe")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("About")
            } footer: {
                Text("Ripul Agent Demo")
            }
        }
        .confirmationDialog(
            "Delete All Events",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                do {
                    let count = try CalendarService.shared.deleteAllEvents()
                    deleteResultMessage = "Deleted \(count) event\(count == 1 ? "" : "s")."
                } catch {
                    deleteResultMessage = "Failed to delete events: \(error.localizedDescription)"
                }
            }
        } message: {
            Text("This will permanently remove all events from your default calendar. This cannot be undone.")
        }
        .alert("Done", isPresented: .init(
            get: { deleteResultMessage != nil },
            set: { if !$0 { deleteResultMessage = nil } }
        )) {
            Button("OK") { deleteResultMessage = nil }
        } message: {
            if let msg = deleteResultMessage {
                Text(msg)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .navigationTitle("Settings")
    }
}
