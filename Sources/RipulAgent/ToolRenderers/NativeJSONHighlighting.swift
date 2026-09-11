import SwiftUI

enum NativeToolCodeSyntax {
    case json
}

/// Colour the original source without parsing/reserializing it: diagnostics
/// must retain exact whitespace, escapes, numeric precision and copied bytes.
enum NativeJSONHighlighting {
    private static let tokens = try! NSRegularExpression(pattern:
        #"("(?:\\.|[^"\\])*")(?=\s*:)|("(?:\\.|[^"\\])*")|(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)|\b(true|false|null)\b|[{}\[\],:]"#)

    static func attributed(_ source: String, colorScheme: ColorScheme) -> AttributedString {
        let text = source as NSString
        var result = AttributedString()
        var offset = 0
        let dark = colorScheme == .dark
        let key = dark ? Color(red: 0.45, green: 0.73, blue: 1) : Color(red: 0.15, green: 0.32, blue: 0.70)
        let string = dark ? Color(red: 0.55, green: 0.82, blue: 0.57) : Color(red: 0.10, green: 0.43, blue: 0.24)
        let number = dark ? Color(red: 0.96, green: 0.73, blue: 0.43) : Color(red: 0.55, green: 0.27, blue: 0.08)
        let literal = dark ? Color(red: 0.82, green: 0.62, blue: 0.95) : Color(red: 0.58, green: 0.20, blue: 0.62)

        tokens.enumerateMatches(in: source, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            if match.range.location > offset {
                result += AttributedString(text.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            }
            var token = AttributedString(text.substring(with: match.range))
            token.foregroundColor = match.range(at: 1).location != NSNotFound ? key
                : match.range(at: 2).location != NSNotFound ? string
                : match.range(at: 3).location != NSNotFound ? number
                : match.range(at: 4).location != NSNotFound ? literal : .secondary
            result += token
            offset = NSMaxRange(match.range)
        }
        if offset < text.length { result += AttributedString(text.substring(from: offset)) }
        return result
    }
}
