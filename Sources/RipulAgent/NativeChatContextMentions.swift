import Foundation

/// Sent-message display only. Keep the serialized token in the stored message
/// and Copy action; use the same link destination as UserMessageMarkdown on web.
enum NativeChatContextMentions {
    static func prepare(_ source: String) -> String {
        guard source.contains("[context:"), let pattern = ContextMentionAliasing.tokenPattern else { return source }
        let ns = source as NSString
        let matches = pattern.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return source }

        let prose = NativeChatMarkdownProse(source)

        let result = NSMutableString(string: source)
        for match in matches.reversed() {
            guard prose.containsStart(of: match.range) else { continue }

            let provider = ns.substring(with: match.range(at: 1))
            let item = ns.substring(with: match.range(at: 2))
            let labelRange = match.range(at: 3)
            let label = labelRange.location == NSNotFound ? "" : ns.substring(with: labelRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = label.isEmpty ? (provider == "ripul.chats" ? "Chat" : "mention") : label
            // Labels are data, not Markdown: punctuation, TeX and HTML stay
            // literal, even when a title contains backticks or an asterisk.
            let literal = NativeChatMarkdownProse.literal(title)
            let display = provider == "ripul.chats"
                ? "[@\(literal)](ripul://chat-reference?ref=\(item))"
                : "@\(literal)"
            result.replaceCharacters(in: match.range, with: display)
        }
        return result as String
    }

    static func reference(in url: URL) -> String? {
        guard url.scheme == "ripul", url.host == "chat-reference" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "ref" })?.value
    }
}
