import Foundation
import SwiftUI

struct NativeChatFileReference: Codable, Equatable, Identifiable {
    let filePath: String
    var purpose: String = "source"
    var line: Int?
    var endLine: Int?
    var id: String { "\(filePath):\(line ?? 0):\(endLine ?? 0)" }
    var label: String {
        let filename = filePath.split(separator: "/").last.map(String.init) ?? filePath
        return filename + (line.map { ":\($0)" + (endLine.map { "–\($0)" } ?? "") } ?? "")
    }
    var href: String {
        // A literal colon/hash in a filename must not become line/URL syntax.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#:%"))
        let path = filePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "file://\(path)" + (line.map { "#L\($0)" + (endLine.map { "-L\($0)" } ?? "") } ?? "")
    }
}

/// Display counterpart of markdownFileCitations.ts. The bridge's fileLocation
/// parser remains the authority for opening a host file and selecting its lines.
enum NativeChatFileReferences {
    static let prefix = ":codex-file-citation{"
    private static let maximum = 8192
    private static let attribute = try! NSRegularExpression(pattern: #"^([a-zA-Z_][\w-]*)\s*=\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')"#)
    private static let pendingAttribute = try! NSRegularExpression(pattern: #"^(?:[a-zA-Z_][\w-]*(?:\s*=\s*(?:"(?:\\.|[^"\\])*|'(?:\\.|[^'\\])*|)?)?)?$"#)
    private static let suffix = try! NSRegularExpression(pattern: #":(\d+)(?::\d+)?(?:-(\d+)(?::\d+)?)?$"#)

    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("//") && !path.unicodeScalars.contains { $0.value < 32 }
    }

    static func fromPath(_ path: String, purpose: String = "source") -> NativeChatFileReference? {
        guard validPath(path) else { return nil }
        let ns = path as NSString
        var result = NativeChatFileReference(filePath: path, purpose: purpose)
        if let match = suffix.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)),
           let line = positive(ns.substring(with: match.range(at: 1))) {
            let end = match.range(at: 2)
            let last = end.location == NSNotFound ? nil : positive(ns.substring(with: end))
            result = NativeChatFileReference(filePath: ns.substring(to: match.range.location), purpose: purpose,
                                            line: line, endLine: last.flatMap { $0 >= line ? $0 : nil })
        }
        return result
    }

    private static func positive(_ text: String) -> Int? {
        guard let n = Int(text), n > 0, n <= 9_007_199_254_740_991 else { return nil }
        return n
    }

    private struct Read { let length: Int; let citation: NativeChatFileReference?; let pending: Bool }
    private static func read(_ source: String) -> Read? {
        guard source.hasPrefix(prefix) else { return nil }
        let ns = source as NSString
        var offset = (prefix as NSString).length
        var attributes: [String: String] = [:]
        while offset < ns.length && offset < maximum {
            let rest = ns.substring(from: offset)
            let whitespace = rest.range(of: #"^\s*"#, options: .regularExpression)!
            offset += (String(rest[whitespace]) as NSString).length
            if offset < ns.length, ns.character(at: offset) == 125 {
                guard let citation = fromPath(attributes["path"] ?? "", purpose: attributes["purpose"].flatMap { $0.isEmpty ? nil : $0 } ?? "source") else { return nil }
                return Read(length: offset + 1, citation: citation, pending: false)
            }
            let tail = ns.substring(from: offset)
            let tailNS = tail as NSString
            guard let match = attribute.firstMatch(in: tail, range: NSRange(location: 0, length: tailNS.length)) else {
                if ns.length < maximum, tail.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r}")) == nil,
                   pendingAttribute.firstMatch(in: tail, range: NSRange(location: 0, length: tailNS.length)) != nil {
                    return Read(length: ns.length, citation: nil, pending: true)
                }
                return nil
            }
            let key = tailNS.substring(with: match.range(at: 1))
            guard attributes[key] == nil else { return nil }
            let quoted = tailNS.substring(with: match.range(at: 2))
            if quoted.hasPrefix("\"") {
                guard let data = quoted.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { return nil }
                attributes[key] = value
            } else {
                attributes[key] = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: #"\\(['\\])"#, with: "$1", options: .regularExpression)
            }
            offset += match.range.length
        }
        return offset == ns.length && offset < maximum ? Read(length: offset, citation: nil, pending: true) : nil
    }

    static func prepare(_ source: String) -> String {
        guard source.contains(prefix) else { return source }
        let ns = source as NSString
        let prose = NativeChatMarkdownProse(source)
        var cursor = 0
        var replacements: [(NSRange, String)] = []
        while cursor < ns.length {
            let start = ns.range(of: prefix, range: NSRange(location: cursor, length: ns.length - cursor))
            guard start.location != NSNotFound else { break }
            cursor = start.location + start.length
            guard prose.containsStart(of: start), let first = read(ns.substring(from: start.location)) else { continue }
            var references = first.citation.map { [$0] } ?? []
            var consumed = first.length
            var pending = first.pending
            while !pending {
                let tail = ns.substring(from: start.location + consumed)
                let gapRange = tail.range(of: #"^[ \t]*(?:\r?\n[ \t]*)?"#, options: .regularExpression)!
                let gap = (String(tail[gapRange]) as NSString).length
                let nextStart = start.location + consumed + gap
                guard nextStart < ns.length,
                      prose.containsStart(of: NSRange(location: nextStart, length: 1)),
                      let next = read(ns.substring(from: nextStart)),
                      next.citation == nil || next.citation?.purpose == references.first?.purpose else { break }
                consumed += gap + next.length
                if let citation = next.citation, !references.contains(where: { $0.id == citation.id }) { references.append(citation) }
                pending = next.pending
            }
            let display: String
            if let first = references.first, let url = url(for: references) {
                let label = references.count == 1 ? first.label : "\(first.purpose == "source" ? "Sources" : "Files") · \(references.count)"
                display = "[\(NativeChatMarkdownProse.literal(label))](\(url.absoluteString))"
            } else { display = "Source…" }
            replacements.append((NSRange(location: start.location, length: consumed), display))
            cursor = start.location + consumed
        }
        let result = NSMutableString(string: source)
        for (range, display) in replacements.reversed() { result.replaceCharacters(in: range, with: display) }
        return result as String
    }

    static func url(for references: [NativeChatFileReference]) -> URL? {
        guard let data = try? JSONEncoder().encode(references) else { return nil }
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "ripul://file-references?refs=\(encoded)")
    }

    static func references(in url: URL) -> [NativeChatFileReference]? {
        guard url.scheme == "ripul", url.host == "file-references",
              var value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "refs" })?.value else { return nil }
        value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value), let items = try? JSONDecoder().decode([NativeChatFileReference].self, from: data),
              !items.isEmpty, items.allSatisfy({ validPath($0.filePath) && ($0.line == nil || ($0.line! > 0 && $0.line! <= 9_007_199_254_740_991)) && ($0.endLine == nil || ($0.line != nil && $0.endLine! >= $0.line! && $0.endLine! <= 9_007_199_254_740_991)) }) else { return nil }
        return items
    }

    /// Only decides whether to hand the URL to the bridge. Parsing of encoded
    /// filenames and line ranges is shared with web in fileLocationFromHref.
    static func isFileURL(_ url: URL, pageURL: URL?) -> Bool {
        if url.scheme == "file" { return url.host == nil || url.host == "" || url.host == "localhost" }
        let raw = url.absoluteString
        if let scheme = url.scheme {
            guard ["https", "http"].contains(scheme), let pageURL,
                  url.scheme == pageURL.scheme, url.host == pageURL.host,
                  (url.port ?? (scheme == "https" ? 443 : 80)) == (pageURL.port ?? (scheme == "https" ? 443 : 80)) else { return false }
        } else if !raw.hasPrefix("/") || raw.hasPrefix("//") { return false }
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding else { return false }
        return path.range(of: #"^/(?:Users|home|Volumes|private|tmp|var|mnt|opt|root|workspace|workspaces)/"#, options: .regularExpression) != nil
    }
}

struct NativeChatFileReferencesSheet: View {
    let references: [NativeChatFileReference]
    let open: (NativeChatFileReference) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(references.enumerated()), id: \.offset) { _, reference in
                Button { open(reference) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(reference.label, systemImage: "doc.text")
                        Text(reference.filePath).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    }
                }
                .accessibilityIdentifier("NativeChat.fileReference.\(reference.id)")
            }
            .navigationTitle("Sources")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
