#if os(iOS)
import SwiftUI

// The emailed-code sign-in drawn natively (CmsSiteSignIn.swift): the form both
// web forms share (email, then the 6-digit code), the `authForm` block on a
// site that signs in by email, and the sheet the app shows when a page needs a
// signed-in member. System controls only: the email keyboard and autofill, the
// one-time-code field the system fills from Mail, prominent buttons in the
// site's colour.

/// Email, then code. Signing in is the `CmsSiteSignIn`'s; `onSignedIn` is told after.
struct CmsSiteSignInForm: View {
    @ObservedObject var signIn: CmsSiteSignIn
    let wording: CmsSiteSignInWording
    var onSignedIn: () -> Void = {}
    @EnvironmentObject private var runtime: CmsRuntime

    @State private var email = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var tried = false
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    private var emailOk: Bool { CmsSiteSignInRules.isEmail(email) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let pending = signIn.pendingEmail {
                codeStep(pending)
            } else {
                emailStep
            }
        }
        .tint(runtime.theme.primary)
        .disabled(busy)
    }

    @ViewBuilder
    private var emailStep: some View {
        if let heading = wording.heading {
            Text(heading).font(.ripul(.title2, weight: .bold))
        }
        Text(wording.emailIntro)
            .font(.ripul(.subheadline))
            .foregroundStyle(.ripul(.textSecondary))
        problem
        VStack(alignment: .leading, spacing: 6) {
            TextField(wording.emailLabel, text: $email)
                .modifier(CmsSiteFieldStyle(theme: runtime.theme))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($focus, equals: .email)
                .onSubmit(sendCode)
                .accessibilityIdentifier("Cms.siteSignIn.email")
            if tried && !emailOk {
                Text(wording.emailProblem(email.trimmingCharacters(in: .whitespaces)))
                    .font(.ripul(.footnote))
                    .foregroundStyle(.ripul(.danger))
            }
        }
        Button(action: sendCode) {
            HStack(spacing: 8) {
                if busy { ProgressView() }
                Text(busy ? wording.sendingButton : wording.sendButton)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(runtime.theme.buttonShape)
        .controlSize(.large)
        .accessibilityIdentifier("Cms.siteSignIn.send")
        if let footnote = wording.footnote {
            Text(footnote).font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
        }
    }

    @ViewBuilder
    private func codeStep(_ pending: String) -> some View {
        if let heading = wording.codeHeading {
            Text(heading).font(.ripul(.title2, weight: .bold))
        }
        Text(wording.codeIntro(pending))
            .font(.ripul(.subheadline))
            .foregroundStyle(.ripul(.textSecondary))
        problem
        TextField("Code", text: Binding(get: { code }, set: { code = CmsSiteSignInRules.codeField($0) }))
            .modifier(CmsSiteFieldStyle(theme: runtime.theme))
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(.ripul(.title3, family: .code))
            .focused($focus, equals: .code)
            .accessibilityIdentifier("Cms.siteSignIn.code")
            .onAppear { focus = .code }
            .onChange(of: code) { value in
                // The system's code from Mail fills all six at once: sign straight in.
                if CmsSiteSignInRules.isCompleteCode(value), !busy, error == nil { verify() }
            }
        Button(action: verify) {
            HStack(spacing: 8) {
                if busy { ProgressView() }
                Text(busy ? wording.checkingButton : wording.codeButton)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(runtime.theme.buttonShape)
        .controlSize(.large)
        .disabled(!CmsSiteSignInRules.isCompleteCode(code))
        .accessibilityIdentifier("Cms.siteSignIn.verify")
        HStack {
            Button(wording.resend) { resend(pending) }
                .accessibilityIdentifier("Cms.siteSignIn.resend")
            Spacer()
            Button(wording.otherEmail) {
                error = nil
                code = ""
                signIn.startAgain()
                focus = .email
            }
            .accessibilityIdentifier("Cms.siteSignIn.otherEmail")
        }
        .font(.ripul(.subheadline))
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var problem: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.danger))
                .accessibilityIdentifier("Cms.siteSignIn.error")
        }
    }

    private func sendCode() {
        tried = true
        guard emailOk, !busy else { return }
        run(fallback: wording.sendFallback) {
            try await signIn.sendCode(to: email)
            code = ""
        }
    }

    private func resend(_ pending: String) {
        run(fallback: wording.sendFallback) {
            try await signIn.sendCode(to: pending)
            code = ""
        }
    }

    private func verify() {
        guard CmsSiteSignInRules.isCompleteCode(code), !busy else { return }
        run(fallback: wording.verifyFallback) {
            try await signIn.verify(code: code)
            code = ""
            onSignedIn()
        }
    }

    private func run(fallback: String, _ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await work()
            } catch let failure as CmsSiteSignInError {
                error = failure.errorDescription ?? fallback
            } catch {
                // Offline, or the request never reached the server.
                self.error = fallback
            }
            busy = false
        }
    }
}

/// The app's sign-in sheet: a page that needs a signed-in member was opened
/// (`CmsRuntime.signInRequest`). It closes once signed in; the app then opens
/// the page asked for, if the person may see it.
struct CmsSiteSignInSheet: View {
    @ObservedObject var signIn: CmsSiteSignIn
    /// The site's own sign-in form's props (its heading and words).
    let formProps: [String: CmsJSON]
    /// Other words for this sign-in (the returning guest's); unset, the authForm's.
    var wording: CmsSiteSignInWording? = nil
    let onDone: (_ signedIn: Bool) -> Void
    @EnvironmentObject private var runtime: CmsRuntime

    var body: some View {
        NavigationStack {
            ScrollView {
                CmsSiteSignInForm(signIn: signIn, wording: wording ?? .authForm(formProps)) { onDone(true) }
                    .padding(20)
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(false) }
                }
            }
        }
    }
}

/// Native twin of `authForm` (AuthFormBlock.tsx) on a site that signs people in
/// by an emailed code (`codeOnly` on the web): the heading, the email, then the
/// code; signed in, who they are, Continue (the after-sign-in page) and "Not
/// you?". Passwords, sign-up and provider buttons are not on such a site.
///
/// Degraded: on a site that signs in another way (its own Clerk, the site's
/// own accounts) the app signs in through its host, so the block says so.
struct CmsAuthFormBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime

    var body: some View {
        Group {
            if let signIn = runtime.siteSignIn {
                CmsAuthFormEmail(block: block, signIn: signIn)
            } else {
                Text("Sign in with the app’s own sign-in.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cmsInspectorID("Cms.authForm")
    }
}

private struct CmsAuthFormEmail: View {
    let block: CmsBlock
    @ObservedObject var signIn: CmsSiteSignIn
    @EnvironmentObject private var runtime: CmsRuntime

    private var props: [String: CmsJSON] { block.props }
    private var afterSignIn: String? { props.string("afterSignInPageSlug").flatMap { $0.isEmpty ? nil : $0 } }
    private var maxWidth: CGFloat? { props.double("maxWidth").flatMap { $0 > 0 ? CGFloat($0) : nil } }

    var body: some View {
        content
            .padding(props.bool("bare") == true ? 0 : 20)
            .background {
                if props.bool("bare") != true {
                    RoundedRectangle(cornerRadius: runtime.theme.cardCorner(16), style: .continuous).fill(Color.ripul(.surface))
                }
            }
            .frame(maxWidth: maxWidth ?? .infinity)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let email = signIn.email {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(props.string("signedInText").flatMap { $0.isEmpty ? nil : $0 } ?? "You are signed in.") (\(email))")
                    .font(.ripul(.body))
                    .foregroundStyle(.ripul(.textSecondary))
                if let afterSignIn {
                    Button("Continue") { runtime.navigate(toPage: afterSignIn) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(runtime.theme.buttonShape)
                        .tint(runtime.theme.primary)
                        .accessibilityIdentifier("Cms.authForm.continue")
                }
                Button("Not you? Use a different account") { Task { await signIn.signOut() } }
                    .buttonStyle(.borderless)
                    .font(.ripul(.subheadline))
                    .accessibilityIdentifier("Cms.authForm.switchAccount")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CmsSiteSignInForm(signIn: signIn, wording: .authForm(props)) {
                if let afterSignIn { runtime.navigate(toPage: afterSignIn) }
            }
        }
    }
}
#endif
