import SwiftUI
import AuthenticationServices

/// George's sign-in, as WAC's "Let's get you in": Apple, Google, and on the isolated test server
/// the synthetic test login that stands in for them.
struct SignInView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = SignInModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Track your shifts, know your pay and feel good about money.")
                        .accessibilityIdentifier("signIn.intro")
                }

                Section {
                    SignInWithAppleButton(.continue, onRequest: { _ in }, onCompletion: { _ in })
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 48)
                        .disabled(true)
                        .opacity(0.4)
                        .accessibilityIdentifier("signIn.apple")
                    Button {} label: {
                        Label("Continue with Google", systemImage: "g.circle")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(true)
                    .accessibilityIdentifier("signIn.google")
                } footer: {
                    Text("Apple and Google sign-in arrive once WAC Next has its Sign in with Apple capability and its own Google client.")
                        .accessibilityIdentifier("signIn.providersNote")
                }

                Section {
                    TextField("Test email", text: $model.email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("signIn.test.email")
                    TextField("Test number", text: $model.phone)
                        .keyboardType(.phonePad)
                        .accessibilityIdentifier("signIn.test.phone")
                    Button("Continue with a test login") {
                        Task { if let session = await model.signInWithTestLogin() { app.signedIn(session) } }
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("signIn.test.continue")
                } header: {
                    Text("Test without Apple or Google")
                } footer: {
                    Text("Only on the isolated test server. Use an email ending @example.invalid and a reserved number, +44 7700 900xxx.")
                }

                if model.busy {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Signing you in…")
                        }
                        .accessibilityIdentifier("signIn.busy")
                    }
                }

                if let welcome = model.welcome {
                    Section {
                        Text(welcome.name.isEmpty ? "That number or email is already on an account."
                             : "That number or email is already on \(welcome.name)'s account.")
                        Button("Log in to it") {
                            Task { if let session = await model.decide("confirm") { app.signedIn(session) } }
                        }
                        .accessibilityIdentifier("signIn.welcome.logIn")
                        Button("That's not me", role: .cancel) {
                            Task { _ = await model.decide("not_me") }
                        }
                        .accessibilityIdentifier("signIn.welcome.notMe")
                    } header: {
                        Text("Welcome back")
                    }
                    .disabled(model.busy)
                }

                if let error = model.error {
                    Section {
                        Text(WACAPI.message(for: error))
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("signIn.error")
                    }
                }
            }
            .navigationTitle("WAC Next")
        }
    }
}

/// One sign-in through WAC's provider routes: provider (check 1), number (check 2), then Welcome
/// back's link or the new account. Each answer is either a session or the next step.
@MainActor
final class SignInModel: ObservableObject {
    struct Welcome { let token: String; let name: String }

    @Published var email = Config.testEmail
    @Published var phone = Config.testPhone
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var welcome: Welcome?

    func signInWithTestLogin() async -> WACSession? {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        let slug = String(local.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }.prefix(40))
        guard email.hasSuffix("@example.invalid"), !slug.isEmpty else { error = "invalid_synthetic"; return nil }
        return await run {
            try await WACAPI.signIn("provider", ["provider": "synthetic",
                                                 "id_token": "synthetic-\(slug)|\(email)|\(Config.testName)"])
        }
    }

    /// Welcome back: "confirm" links the test login to the account it matched; "not_me" links nothing.
    func decide(_ decision: String) async -> WACSession? {
        guard let welcome else { return nil }
        return await run { try await WACAPI.signIn("link", ["provider_token": welcome.token, "decision": decision]) }
    }

    private func run(_ first: () async throws -> [String: Any]) async -> WACSession? {
        guard !busy else { return nil }
        busy = true
        error = nil
        welcome = nil
        defer { busy = false }
        do {
            var result = try await first()
            // At most number then account follow the first answer.
            for _ in 0..<3 {
                guard result["success"] as? Bool == true else {
                    error = result["error"] as? String ?? "invalid_response"
                    return nil
                }
                if let secret = result["secret"] as? String, let secretID = result["secret_id"] as? String,
                   !secret.isEmpty, !secretID.isEmpty {
                    return WACSession(secret: secret, secretID: secretID)
                }
                let token = result["provider_token"] as? String ?? ""
                switch result["outcome"] as? String {
                case "number":
                    result = try await WACAPI.signIn("number", ["provider_token": token, "phone": phone.filter { !$0.isWhitespace }])
                case "new_account":
                    result = try await WACAPI.signIn("account", ["provider_token": token, "email": email.lowercased(),
                                                                 "preferred_name": Config.testName])
                case "welcome":
                    // Linking a login to an account is the person's choice, never automatic.
                    welcome = Welcome(token: token, name: result["name"] as? String ?? "")
                    return nil
                case "not_me":
                    error = "phone_unavailable"
                    return nil
                default:
                    error = "invalid_response"
                    return nil
                }
            }
            error = "invalid_response"
        } catch {
            self.error = "network"
        }
        return nil
    }
}
