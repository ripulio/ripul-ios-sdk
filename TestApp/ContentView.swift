import SwiftUI

struct ContentView: View {
    @State private var showAgent = false
    @AppStorage("agentBaseURL") private var baseURLString = AgentConfiguration.defaultBaseURL.absoluteString
    @AppStorage("agentSiteKey") private var siteKey = ""

    private var agentConfiguration: AgentConfiguration {
        AgentConfiguration(
            baseURL: URL(string: baseURLString) ?? AgentConfiguration.defaultBaseURL,
            siteKey: siteKey.isEmpty ? nil : siteKey
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent Configuration") {
                    TextField("Base URL", text: $baseURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    TextField("Site Key (optional)", text: $siteKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button {
                        showAgent = true
                    } label: {
                        Label("Launch Agent", systemImage: "message.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("TestApp")
            .sheet(isPresented: $showAgent) {
                AgentView(configuration: agentConfiguration)
            }
        }
    }
}

#Preview {
    ContentView()
}
