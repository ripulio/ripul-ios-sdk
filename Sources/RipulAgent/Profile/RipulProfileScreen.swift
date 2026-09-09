import SwiftUI

/// Personal Ripul settings shared by the app and signed-in SDK consoles.
/// Identity and service keys use the account; speech choices remain app-local.
@available(iOS 26.0, macOS 26.0, *)
public struct RipulProfileScreen<PlanContent: View>: View {
    @ObservedObject var bridge: AgentBridge
    let userName: String?
    let userEmail: String?
    let tokenProvider: () -> String?
    let baseURL: URL
    let onSignOut: () async -> Void
    let planContent: PlanContent
    #if os(iOS)
    @State private var webTheme: String = "darkGradient"
    #endif

    public init(
        bridge: AgentBridge,
        userName: String?,
        userEmail: String?,
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?,
        onSignOut: @escaping () async -> Void,
        @ViewBuilder planContent: () -> PlanContent
    ) {
        self.bridge = bridge
        self.userName = userName
        self.userEmail = userEmail
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.onSignOut = onSignOut
        self.planContent = planContent()
    }

    @State private var secrets: UserSecretsSnapshot = .empty
    @State private var loadingSecrets = true
    @State private var secretsError: String?

    public var body: some View {
        Form {
            identitySection
            planContent
            serviceKeysSection
            preferencesSection
            signOutSection
        }
        .navigationTitle("Profile")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .task { await loadSecrets() }
    }

    // MARK: Identity

    private var identitySection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    if let name = userName {
                        Text(name)
                            .font(.headline)
                    }
                    if let email = userEmail {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if userName == nil && userEmail == nil {
                        Text("Signed in")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Service keys

    private var serviceKeysSection: some View {
        Section {
            if loadingSecrets {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProviderKeyRow(
                    provider: ProviderKeyRow.elevenLabs,
                    status: secrets.status(for: ProviderKeyRow.elevenLabs.id),
                    storageEnabled: secrets.storageEnabled,
                    baseURL: baseURL,
                    tokenProvider: tokenProvider,
                    onChange: { updated in
                        secrets = UserSecretsSnapshot(
                            secrets: secrets.secrets.map {
                                $0.provider == updated.provider ? updated : $0
                            },
                            storageEnabled: secrets.storageEnabled
                        )
                    }
                )
            }

            if let secretsError {
                Text(secretsError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Service Keys")
        } footer: {
            Text(serviceKeysFooter)
        }
    }

    /// The footer answers the only question this section really raises: what
    /// happens if I leave it empty. Three different answers, and guessing
    /// wrong is the difference between "my mic is broken" and "it's fine".
    private var serviceKeysFooter: String {
        if !secrets.storageEnabled {
            return "This deployment can't store personal keys yet, so speech runs on Ripul's shared key."
        }
        let elevenLabs = secrets.status(for: ProviderKeyRow.elevenLabs.id)
        if elevenLabs?.configured == true {
            return "Speech runs on your own ElevenLabs account — your voices, your quota, billed to you."
        }
        if elevenLabs?.platformFallbackAvailable == true {
            return "Speech is running on Ripul's shared key. Add your own to use your own voices and quota instead."
        }
        return "Add an ElevenLabs key to turn on cloud speech. Without one, dictation and read-aloud fall back to the on-device Apple voice."
    }

    // MARK: Preferences

    private var preferencesSection: some View {
        Section("Preferences") {
            NavigationLink {
                VoiceSettingsScreen(tokenProvider: tokenProvider)
            } label: {
                Label("Voice", systemImage: "waveform")
            }
            .uiKitIdentifier("ProfileScreen.preferences.voice")

            #if os(iOS)
            Picker(selection: $webTheme) {
                Text("Auto (System)").tag("auto")
                Text("Dark Gradient").tag("darkGradient")
                Text("Dark Flat").tag("darkFlat")
                Text("Dark Minimal").tag("darkMinimal")
                Text("Dark Glass").tag("darkGlass")
                Text("Dark Neon").tag("darkNeon")
                Text("Dark Aurora").tag("darkAurora")
                Text("Light").tag("light")
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }
            .uiKitIdentifier("ProfileScreen.preferences.theme")
            .task {
                if let theme = try? await bridge.callAsyncJavaScript(
                    "return window.__ripulGetTheme?.()"
                ) as? String {
                    webTheme = theme
                }
            }
            .onChange(of: webTheme) { newValue in
                bridge.evaluateJavaScript("window.__ripulSetTheme?.('\(newValue)')")
            }
            #endif
        }
    }

    // MARK: Sign out

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await onSignOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .uiKitIdentifier("ProfileScreen.account.signOutButton")
        }
    }

    private func loadSecrets() async {
        loadingSecrets = true
        secretsError = nil
        do {
            secrets = try await UserSecretsClient(baseURL: baseURL, tokenProvider: tokenProvider).list()
        } catch {
            secretsError = error.localizedDescription
        }
        loadingSecrets = false
    }
}
