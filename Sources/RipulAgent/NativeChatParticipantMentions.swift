import Foundation

/// Mirrors participantMentions.ts. This is presentation only, never identity
/// resolution or routing by a person's name/device label.
enum NativeChatParticipantMentions {
    private static let pattern = try! NSRegularExpression(
        pattern: #"@([A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)*)(_?\(([A-Za-z0-9][A-Za-z0-9 ._-]*)\))?"#)

    static func prepare(_ source: String) -> String {
        guard source.contains("@") else { return source }
        let ns = source as NSString
        let matches = pattern.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return source }
        let prose = NativeChatMarkdownProse(source)
        let result = NSMutableString(string: source)
        for match in matches.reversed() {
            let name = ns.substring(with: match.range(at: 1))
            let deviceRange = match.range(at: 3)
            let device = deviceRange.location == NSNotFound ? nil : ns.substring(with: deviceRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2, name != name.uppercased(),
                  device != nil || name.contains("_") || name.first?.isUppercase == true else { continue }
            let range = match.range
            guard prose.containsStart(of: range) else { continue }
            if range.location > 0, !prose.startsText(at: range) {
                let previous = ns.substring(with: NSRange(location: range.location - 1, length: 1))
                guard previous.allSatisfy(\.isWhitespace) || "([{,;:!?\"'".contains(previous) else { continue }
            }
            let title = "@" + name.replacingOccurrences(of: "_", with: " ")
            // A readable inline name, with its device separately de-emphasised.
            let display = NativeChatMarkdownProse.literal(title) + (device.map { " *\(NativeChatMarkdownProse.literal("(" + $0 + ")"))*" } ?? "")
            result.replaceCharacters(in: range, with: display)
        }
        return result as String
    }
}
