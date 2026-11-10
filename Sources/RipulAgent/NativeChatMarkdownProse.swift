import Foundation
import cmark_gfm

/// Source positions keep display extensions out of code, links, images and
/// escaped examples. Offsets are UTF-8 in cmark and UTF-16 in NSRegularExpression.
struct NativeChatMarkdownProse {
    let source: String
    private let bytes: [UInt8]
    private var ranges: [Range<Int>] = []

    init(_ source: String) {
        self.source = source
        bytes = Array(source.utf8)
        guard let document = cmark_parse_document(source, bytes.count, CMARK_OPT_DEFAULT) else { return }
        defer { cmark_node_free(document) }
        var lineStarts = [0]
        for (index, byte) in bytes.enumerated() where byte == 10 { lineStarts.append(index + 1) }
        func offset(_ line: Int32, _ column: Int32) -> Int? {
            guard line > 0, Int(line) <= lineStarts.count, column > 0 else { return nil }
            return min(bytes.count, lineStarts[Int(line) - 1] + Int(column) - 1)
        }
        var rawTags: [String] = []
        func visit(_ node: UnsafeMutablePointer<cmark_node>) {
            switch cmark_node_get_type(node) {
            case CMARK_NODE_LINK, CMARK_NODE_IMAGE, CMARK_NODE_CODE, CMARK_NODE_CODE_BLOCK, CMARK_NODE_HTML_BLOCK:
                return
            case CMARK_NODE_HTML_INLINE:
                if let literal = cmark_node_get_literal(node) {
                    let tag = String(cString: literal).lowercased()
                    for name in ["code", "pre", "script", "style", "a"] {
                        if tag.range(of: "^<\(name)(?:\\s|>)", options: .regularExpression) != nil { rawTags.append(name) }
                        if tag.hasPrefix("</\(name)"), rawTags.last == name { rawTags.removeLast() }
                    }
                }
                return
            case CMARK_NODE_TEXT:
                if rawTags.isEmpty,
                   let start = offset(cmark_node_get_start_line(node), cmark_node_get_start_column(node)),
                   let end = offset(cmark_node_get_end_line(node), cmark_node_get_end_column(node)), end >= start {
                    ranges.append(start..<min(bytes.count, end + 1))
                }
            default: break
            }
            var child = cmark_node_first_child(node)
            while let current = child { visit(current); child = cmark_node_next(current) }
        }
        visit(document)
    }

    func containsStart(of range: NSRange) -> Bool {
        guard let range = Range(range, in: source) else { return false }
        let start = source[..<range.lowerBound].utf8.count
        guard ranges.contains(where: { $0.contains(start) }) else { return false }
        var slash = start
        while slash > 0, bytes[slash - 1] == 92 { slash -= 1 }
        return (start - slash).isMultiple(of: 2)
    }

    func startsText(at range: NSRange) -> Bool {
        guard let range = Range(range, in: source) else { return false }
        let start = source[..<range.lowerBound].utf8.count
        return ranges.contains { $0.lowerBound == start }
    }

    static func literal(_ text: String) -> String {
        text.unicodeScalars.map { "&#\($0.value);" }.joined()
    }
}
