import SwiftUI
import HighlightSwift

enum NativeToolCodeSyntax: Hashable, Sendable {
    case json, javascript, shell, automatic
    case file(String)
    case language(String)

    var language: String {
        switch self {
        case .json: return "json"
        case .javascript: return "javascript"
        case .shell: return "bash"
        case .automatic: return "auto"
        case .language(let language): return language
        case .file(let path):
            let name = (path as NSString).lastPathComponent.lowercased()
            if name == "dockerfile" || name.hasPrefix("dockerfile.") { return "dockerfile" }
            if name == "makefile" || name == "gnumakefile" { return "makefile" }
            let ext = (name as NSString).pathExtension
            return [
                "swift": "swift", "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
                "ts": "typescript", "tsx": "typescript", "json": "json", "jsonc": "json",
                "sh": "bash", "bash": "bash", "zsh": "bash", "py": "python", "rb": "ruby",
                "rs": "rust", "go": "go", "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "hpp": "cpp",
                "m": "objectivec", "mm": "objectivec", "cs": "csharp", "java": "java", "kt": "kotlin",
                "html": "xml", "htm": "xml", "xml": "xml", "svg": "xml", "plist": "xml",
                "css": "css", "scss": "scss", "less": "less", "sql": "sql", "yaml": "yaml", "yml": "yaml",
                "toml": "toml", "md": "markdown", "markdown": "markdown", "php": "php", "lua": "lua",
                "dart": "dart", "graphql": "graphql", "gql": "graphql", "diff": "diff", "patch": "diff"
            ][ext] ?? "plaintext"
        }
    }
}

struct NativeHighlightRequest: Hashable, Sendable {
    let source: String
    let language: String
    let dark: Bool
    var readLineNumbers = false
}

/// One reusable engine, with bounded caching. Only the bundled highlighter is
/// executed; the displayed source is passed to highlight.js as a string argument.
actor NativeSourceHighlighting {
    static let shared = NativeSourceHighlighting()
    private let highlight = Highlight()
    private var cache: [NativeHighlightRequest: AttributedString] = [:]
    private var order: [NativeHighlightRequest] = []
    private var cachedBytes = 0

    func attributed(_ request: NativeHighlightRequest) async -> AttributedString {
        if let cached = cache[request] { return cached }
        let source = request.source
        // Avoid HTML-import edge cases on empty input, and bound work for minified files.
        guard request.language != "plaintext", source.utf8.count <= 100_000,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !Task.isCancelled else { return AttributedString(source) }
        if request.readLineNumbers {
            let rows = source.components(separatedBy: "\n")
            let prefixes = rows.map { row -> String in
                guard let range = row.range(of: "^[ \\t]*[0-9]+[→\\t]", options: .regularExpression) else { return "" }
                return String(row[range])
            }
            let code = zip(rows, prefixes).map { String($0.dropFirst($1.count)) }.joined(separator: "\n")
            let highlighted = await attributed(.init(source: code, language: request.language, dark: request.dark))
            let coloured = Self.lines(highlighted)
            guard coloured.count == rows.count else { return AttributedString(source) }
            var result = AttributedString()
            for index in rows.indices {
                if index > 0 { result += AttributedString("\n") }
                result += AttributedString(prefixes[index]) + coloured[index]
            }
            return String(result.characters) == source ? result : AttributedString(source)
        }
        let result: AttributedString
        do {
            let automatic = request.language == "auto"
            let highlighted = try await highlight.request(
                source, mode: automatic ? .automatic : .languageAliasIgnoreIllegal(request.language),
                colors: request.dark ? .dark(.github) : .light(.github)
            )
            // Relevance is highlight.js's heuristic score, not a probability.
            // Keep weak guesses uncoloured, including ordinary terminal prose.
            if automatic && (highlighted.isUndefined || highlighted.relevance <= 5 || highlighted.language == "plaintext") {
                result = AttributedString(source)
            } else {
                result = Self.preservingSource(source, highlighted: highlighted.attributedText)
            }
        } catch {
            return AttributedString(source)
        }
        guard !Task.isCancelled else { return AttributedString(source) }
        if cache[request] == nil {
            while order.count >= 16 || cachedBytes + source.utf8.count > 500_000 {
                let oldest = order.removeFirst()
                cachedBytes -= oldest.source.utf8.count
                cache.removeValue(forKey: oldest)
            }
            cache[request] = result
            order.append(request)
            cachedBytes += source.utf8.count
        }
        return result
    }

    /// HighlightSwift's HTML importer can trim whitespace and normalize line
    /// endings. Copy only colours onto the original text; never replace source.
    static func preservingSource(_ source: String, highlighted: AttributedString) -> AttributedString {
        let rendered = String(highlighted.characters)
        let original = source as NSString
        let match = original.range(of: rendered)
        guard !rendered.isEmpty, match.location != NSNotFound else { return AttributedString(source) }
        let native = NSAttributedString(highlighted)
        var result = AttributedString(source)
        native.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: native.length)) { value, range, _ in
            let sourceRange = NSRange(location: match.location + range.location, length: range.length)
            guard let stringRange = Range(sourceRange, in: source),
                  let start = AttributedString.Index(stringRange.lowerBound, within: result),
                  let end = AttributedString.Index(stringRange.upperBound, within: result) else { return }
            #if os(iOS)
            if let color = value as? UIColor { result[start..<end].foregroundColor = Color(uiColor: color) }
            #else
            if let color = value as? NSColor { result[start..<end].foregroundColor = Color(nsColor: color) }
            #endif
        }
        return result
    }

    /// Split after tokenization so multiline strings/comments retain their state.
    static func lines(_ text: AttributedString) -> [AttributedString] {
        var result: [AttributedString] = []
        var start = text.startIndex
        for index in text.characters.indices where text.characters[index] == "\n" || text.characters[index] == "\r\n" {
            result.append(AttributedString(text[start..<index]))
            start = text.characters.index(after: index)
        }
        result.append(AttributedString(text[start..<text.endIndex]))
        return result
    }
}

struct NativeDiffHighlightRequest: Hashable, Sendable {
    let lines: [NativeToolDiffLine]
    let path: String
    let includesPrefix: Bool
    let dark: Bool
}

extension NativeSourceHighlighting {
    /// Highlight the before/after source independently: a removed quote or
    /// comment delimiter must not change the syntax state of added lines.
    func diff(_ request: NativeDiffHighlightRequest) async -> [AttributedString] {
        var result = request.lines.map { AttributedString($0.text) }
        var language = NativeToolCodeSyntax.file(request.path).language
        var rows: [(index: Int, line: NativeToolDiffLine, prefix: String)] = []

        func flush() async {
            for before in [true, false] {
                let side = rows.filter { before ? $0.line.kind != .added : $0.line.kind != .removed }
                guard !side.isEmpty else { continue }
                let source = side.map { $0.line.text }.joined(separator: "\n")
                let text = await attributed(.init(source: source, language: language, dark: request.dark))
                let coloured = Self.lines(text)
                for (offset, row) in side.enumerated() where offset < coloured.count {
                    result[row.index] = AttributedString(row.prefix) + coloured[offset]
                }
            }
            rows.removeAll()
        }

        for (index, line) in request.lines.enumerated() {
            guard !Task.isCancelled else { return result }
            let raw = line.text
            if request.includesPrefix {
                let pathMarkers = ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "+++ b/", "--- a/"]
                if let marker = pathMarkers.first(where: { raw.hasPrefix($0) }) {
                    await flush()
                    language = NativeToolCodeSyntax.file(String(raw.dropFirst(marker.count))).language
                    continue
                }
                if raw.hasPrefix("@@") || raw.hasPrefix("***") || raw.hasPrefix("diff ") || raw.hasPrefix("index ")
                    || raw.hasPrefix("---") || raw.hasPrefix("+++") || raw.hasPrefix("\\ No newline") {
                    await flush()
                    continue
                }
            }
            let prefix = request.includesPrefix && ["+", "-", " "].contains(String(raw.prefix(1))) ? String(raw.prefix(1)) : ""
            rows.append((index, .init(kind: line.kind, text: String(raw.dropFirst(prefix.count))), prefix))
        }
        await flush()
        return result
    }
}
