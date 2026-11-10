import SwiftUI
import AuthenticationServices
import RipulAgent

/// Signed out: the brand, and Sign in, which opens the website's sign-in in the
/// system's sign-in sheet (WAC's business accounts: email and password, a code by
/// email, or Google). Once signed in there, the app has a session of its own.
struct SignInView: View {
    @EnvironmentObject private var session: CmsPortalSession
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var problem: String?

    private var signingIn: Bool { session.state == .signingIn }

    var body: some View {
        BrandBackdrop {
            VStack(spacing: 14) {
                Text("Shifts, rotas and pay for your team.")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Button {
                    signIn()
                } label: {
                    Group {
                        if signingIn {
                            ProgressView().tint(Color.wacPurple)
                        } else {
                            Text("Sign in")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(Color.wacPurple)
                .disabled(signingIn)
                .accessibilityIdentifier("signIn.open")
                Text("With your wac for business account. New here? Sign up from the same page.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .alert("Couldn't sign in", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func signIn() {
        Task {
            do {
                try await session.signIn(using: webAuthenticationSession)
            } catch CmsPortalSignInError.cancelled {
                // The person closed the sheet: nothing to say.
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
