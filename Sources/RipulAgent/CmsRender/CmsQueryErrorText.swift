import SwiftUI

/// Twin of `queryErrorText.ts`: what a visitor reads when a query fails. The
/// server's error carries the provider's message and a `[diag]` section for
/// the designer; neither means anything to the person using the page. Same
/// rules, and the tests read the web's fixture file.
enum CmsQueryErrorText {
    enum Kind: String { case unavailable, denied, failed }

    struct Text {
        var kind: Kind
        var message: String
        var retry: Bool
    }

    private static let unavailable: [String] = [
        #"retrying the job may solve"#,
        #"encountered an error during execution"#,
        #"\bbackend ?error\b"#,
        #"\brate ?limit"#,
        #"\bquota\b"#,
        #"\btimed? ?out\b|\btimeout\b|did not complete within"#,
        #"\bunavailable\b"#,
        #"\binternal error\b"#,
        #"failed to fetch|network ?error|load failed|connection (was )?(lost|reset|refused)"#,
        #"\bHTTP 5\d\d\b|\b50[234]\b"#,
        #"the network connection was lost|offline"#,
    ]
    private static let denied: [String] = [
        #"\baccess denied\b"#, #"\bpermission\b"#, #"\bnot authori[sz]ed\b"#, #"\bforbidden\b"#, #"\bHTTP 40[13]\b"#,
    ]

    /// The provider's own message, without the designer's `[diag]` section.
    static func main(_ message: String) -> String {
        let main = message.components(separatedBy: "\n\n[diag]").first ?? message
        return main.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func describe(_ message: String?) -> Text {
        let main = main(message ?? "")
        func matches(_ patterns: [String]) -> Bool {
            patterns.contains { main.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        if matches(unavailable) {
            return Text(kind: .unavailable,
                        message: "This data can't be loaded right now. The service it comes from is having trouble; try again in a few minutes.",
                        retry: true)
        }
        if matches(denied) {
            return Text(kind: .denied, message: "You don't have access to this data.", retry: false)
        }
        return Text(kind: .failed, message: "This data couldn't be loaded.", retry: true)
    }
}

/// A failed query on the page: the system unavailable view with Try again for
/// visitors; in design mode the server's full error too.
struct CmsQueryErrorView: View {
    let message: String
    let querySlug: String
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let text = CmsQueryErrorText.describe(message)
        let icon = text.kind == .denied ? "lock" : (text.kind == .unavailable ? "icloud.slash" : "exclamationmark.triangle")
        VStack(spacing: 8) {
            if #available(iOS 17.0, macOS 14.0, *) {
                ContentUnavailableView {
                    Label(text.kind == .denied ? "No access" : "Couldn't load", systemImage: icon)
                } description: {
                    Text(text.message)
                } actions: {
                    if text.retry { retryButton }
                }
            } else {
                Label(text.message, systemImage: icon)
                    .font(.system(size: 13))
                    .foregroundColor(runtime.theme.textSecondary)
                if text.retry { retryButton }
            }
            if runtime.isDesignMode {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(runtime.theme.error)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .cmsInspectorID("Cms.queryError")
    }

    private var retryButton: some View {
        Button("Try again") { runtime.invalidate(querySlug) }
            .buttonStyle(.bordered)
            .tint(runtime.theme.primary)
    }
}
