import Foundation

/// URLs as they may appear in logs. The app URL carries the session token in
/// its fragment query, and native logs are mirrored into the console buffer
/// that `host_console_logs` / `device_console_logs` serve to other devices —
/// so a raw `absoluteString` published a live credential (and ~35 KB per line).
enum WebViewLogRedaction {
    private static let secretParameter = try! NSRegularExpression(
        pattern: "((?:session|access|id|refresh)?[Tt]oken|code|secret|password)(=|%3[Dd])(?:(?!%26|%23)[^&#])*")

    static func url(_ url: URL?, limit: Int = 300) -> String {
        guard let raw = url?.absoluteString else { return "nil" }
        let redacted = secretParameter.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "$1$2<redacted>")
        return redacted.count > limit ? String(redacted.prefix(limit)) + "…(\(redacted.count) chars)" : redacted
    }
}
