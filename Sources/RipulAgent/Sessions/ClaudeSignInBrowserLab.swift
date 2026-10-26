#if DEBUG
import CryptoKit
import SwiftUI
import WebKit

/// The Claude sign-in browser on its own, with no Mac waiting: launch with
/// `-ripul.claudeSignInLab render|callback|mismatch`.
///
/// It opens the sheet's browser on a real claude.ai authorize address, of the
/// shape `claude auth login` makes. `render` stops there, to see the page draw.
/// `callback` and `mismatch` then have the page itself navigate to Anthropic's
/// code page, with this sign-in's `state` and with another one, and log what
/// the browser made of it. The outcome goes to this lab, never to a machine, and
/// the lab's code is made up, so nobody is signed in or out.
public struct ClaudeSignInBrowserLab: View {
    public static var mode: String? { UserDefaults.standard.string(forKey: "ripul.claudeSignInLab") }

    let mode: String
    private let state: String
    private let authUrl: URL
    @StateObject private var model: ClaudeSignInBrowserModel
    @State private var page: ClaudeSignInPage?
    @State private var result = "Waiting for the page…"

    /// `configuration` stands in for the app's, which is set only once the app
    /// has signed in to Ripul: the lab runs on a simulator that need not be.
    public init(mode: String, configuration: (() -> WKWebViewConfiguration)? = nil) {
        self.mode = mode
        if ClaudeSignInBrowser.makeConfiguration == nil, let configuration {
            ClaudeSignInBrowser.makeConfiguration = configuration
        }
        let state = Self.randomToken()
        let verifier = Self.randomToken() + Self.randomToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var parts = URLComponents(string: "https://claude.ai/oauth/authorize")!
        parts.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: ClaudeSignInBrowser.defaultCallback.absoluteString),
            .init(name: "scope", value: "org:create_api_key user:profile user:inference"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        let url = parts.url!
        self.state = state
        self.authUrl = url
        let box = ResultBox()
        _model = StateObject(wrappedValue: ClaudeSignInBrowserModel(authUrl: url) { box.report?($0) })
        self.box = box
    }

    private final class ResultBox { var report: ((ClaudeSignInBrowser.Outcome) -> Void)? }
    private let box: ResultBox

    public var body: some View {
        VStack(spacing: 12) {
            Text("Claude sign-in lab: \(mode)").ripulText()
                .font(.ripul(.headline))
            Text(result).ripulText()
                .font(.ripul(.subheadline))
                .uiKitIdentifier("ClaudeSignInBrowserLab.result")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ripul(.canvas))
        .ripulSheet(item: $page) { page in
            ClaudeSignInBrowserSheet(authUrl: page.url, machineName: "Lab", onOpenElsewhere: {},
                                     onFinish: { _ in self.page = nil; report("cancelled") }, model: model)
        }
        .task { await run() }
    }

    private func run() async {
        let expected = "LABCODE#\(state)"
        box.report = { outcome in
            page = nil
            switch outcome {
            case .code(let found):
                report("code caught; equals code#state of this sign-in: \(found == expected)")
            case .refused(let message): report("refused: \(message)")
            case .denied(let message): report("denied: \(message)")
            }
        }
        page = ClaudeSignInPage(url: authUrl)
        // The page has drawn once claude.ai's own document has finished loading.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let top = model.pages.first, !top.isLoading, top.url?.host?.hasSuffix("claude.ai") == true { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard let top = model.pages.first, !top.isLoading else { return report("the page did not finish loading in 60 s") }
        // claude.ai is an app: its document finishes before it draws anything.
        var text = ""
        let drawBy = Date().addingTimeInterval(30)
        while text.isEmpty, Date() < drawBy {
            text = ((try? await top.evaluateJavaScript("document.body ? document.body.innerText.trim().slice(0, 200) : ''")) as? String ?? "")
                .replacingOccurrences(of: "\n", with: " | ")
            if text.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        let title = (try? await top.evaluateJavaScript("document.title")) as? String ?? ""
        NSLog("[ClaudeSignInLab] rendered %@%@ title=\"%@\" text=\"%@\"", top.url?.host ?? "", top.url?.path ?? "", title, text)
        result = "Rendered: \(top.url?.host ?? "")\(top.url?.path ?? "") — \(title)"
        guard mode == "callback" || mode == "mismatch" else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let sentState = mode == "callback" ? state : "ANOTHER-SIGN-IN"
        var callback = URLComponents(url: ClaudeSignInBrowser.defaultCallback, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "code", value: "LABCODE"), .init(name: "state", value: sentState)]
        NSLog("[ClaudeSignInLab] page navigates to the callback with %@ state", mode == "callback" ? "this sign-in's" : "another sign-in's")
        _ = try? await top.evaluateJavaScript("location.href = \(Self.jsString(callback.url!.absoluteString))")
    }

    private func report(_ line: String) {
        result = line
        NSLog("[ClaudeSignInLab] outcome: %@", line)
    }

    private static func randomToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "''"
    }
}
#endif
