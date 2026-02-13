import SwiftUI
import RipulAgent

struct SettingsView: View {
    @AppStorage("agentBaseURL") private var baseURLString = AgentConfiguration.defaultBaseURL.absoluteString
    @AppStorage("agentSiteKey") private var siteKey = "pk_live_2pakky4z3s9674wu9zvvgzze"

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
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .navigationTitle("Settings")
    }
}
