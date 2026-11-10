import SwiftUI
import MarkdownUI

/// Parse the whole document together: reference links and code inside a list or
/// quote depend on surrounding blocks. Cache the parsed tree, not fragments.
enum NativeChatMarkdownDocument {
    private final class Box: NSObject {
        let content: MarkdownContent
        init(_ content: MarkdownContent) { self.content = content }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func parse(_ source: String, contextMentions: Bool = false) -> MarkdownContent {
        let key = "\(contextMentions)\u{0}\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit.content }
        let display = displaySource(source, contextMentions: contextMentions)
        let content = MarkdownContent(NativeMarkdownMath.prepare(display))
        // Account approximately for the source key and the parsed text/tree.
        cache.setObject(Box(content), forKey: key, cost: source.utf8.count * 4)
        return content
    }

    static func displaySource(_ source: String, contextMentions: Bool) -> String {
        if contextMentions {
            return NativeChatParticipantMentions.prepare(NativeChatContextMentions.prepare(source))
        }
        return NativeChatFileReferences.prepare(source)
    }
}

/// A message cut into its top-level blocks, so a streamed message lays out
/// again only the block that grew (`-perfOn mdBlocks`, off by default).
///
/// The cut is made only at a blank line where it cannot change what the whole
/// message would show: outside a fence, display maths and an HTML block whose
/// end has not come; before a line at the left margin (an indented one may
/// continue a list item or indented code); and not between two items of one
/// list (a list with blank lines between its items is one loose list).
/// Anything uncertain stays in one block, which is always safe: a block is
/// parsed as a document of its own. Reference definitions apply to the whole
/// message, so each block that could use one is parsed with all of them.
/// Every block's text ends at its last non-blank line, so a block is the same
/// string before and after the text after it arrives: the parse cache returns
/// the same tree and its view, being equatable, is not drawn again.
enum NativeChatMarkdownBlocks {
    enum Kind: Equatable { case paragraph, heading, list, quote, code, table, rule }

    struct Block: Identifiable, Equatable {
        /// Its position in the message: a block keeps it as text is appended.
        let id: Int
        /// The block's own Markdown.
        let text: String
        /// What is parsed: the text, and the reference definitions it may use.
        let source: String
        /// Space above it: the larger of its own top margin and the bottom
        /// margin of the block before, as MarkdownUI spaces blocks. None above the first.
        let spacingAbove: CGFloat
    }

    /// The theme's margins (top, bottom) for each kind of top-level block.
    static func margins(_ kind: Kind) -> (top: CGFloat, bottom: CGFloat) {
        switch kind {
        case .paragraph: return (0, 8)
        case .heading: return (8, 4)
        case .list, .quote: return (4, 8)
        case .code, .table: return (8, 8)
        case .rule: return (12, 12)
        }
    }

    static func split(_ content: String) -> [Block] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var chunks: [[Substring]] = []
        var current: [Substring] = []
        var definitions: [Substring] = []
        var fence: (char: Character, count: Int)?
        var displayMathOpen = false
        var bracketMathDepth = 0
        var htmlEnd: String?
        var chunkHasListItem = false
        var blankSinceContent = false

        func close() {
            while let last = current.last, isBlank(last) { current.removeLast() }
            if !current.isEmpty { chunks.append(current) }
            current = []
            chunkHasListItem = false
        }

        for line in lines {
            let blank = isBlank(line)
            if !blank, blankSinceContent, !current.isEmpty, fence == nil, !displayMathOpen,
               bracketMathDepth <= 0, htmlEnd == nil, let first = line.first, first != " ", first != "\t",
               !(chunkHasListItem && isListItem(line)) {
                close()
            }
            current.append(line)
            if blank {
                if fence == nil { blankSinceContent = true }
                continue
            }
            blankSinceContent = false
            let body = blockBody(line)
            if let open = fence {
                let run = body.prefix { $0 == open.char }.count
                if run >= open.count, body.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                    fence = nil
                }
                continue
            }
            if let char = body.first, char == "`" || char == "~" {
                let run = body.prefix { $0 == char }.count
                if run >= 3 { fence = (char, run); continue }
            }
            if line.first != " ", line.first != "\t", isListItem(line) { chunkHasListItem = true }
            if isDefinition(line) { definitions.append(line) }
            if line.contains("$$"), occurrences(of: "$$", in: line) % 2 == 1 { displayMathOpen.toggle() }
            if line.contains("\\[") || line.contains("\\]") {
                bracketMathDepth += occurrences(of: "\\[", in: line) - occurrences(of: "\\]", in: line)
            }
            if let end = htmlEnd {
                if line.lowercased().contains(end) { htmlEnd = nil }
            } else if line.contains("<") {
                let lower = line.lowercased()
                for (open, end) in htmlBlocks {
                    if let start = lower.range(of: open), !lower[start.upperBound...].contains(end) {
                        htmlEnd = end
                        break
                    }
                }
            }
        }
        close()

        let definitionText = definitions.joined(separator: "\n")
        var blocks: [Block] = []
        var previousBottom: CGFloat?
        for chunk in chunks {
            // A block of definitions alone draws nothing; the others carry them.
            if chunk.allSatisfy({ isBlank($0) || isDefinition($0) }) { continue }
            let text = chunk.joined(separator: "\n")
            let source = definitionText.isEmpty || !text.contains("[") ? text : text + "\n\n" + definitionText
            let first = firstKind(chunk)
            let spacing = previousBottom.map { max($0, margins(first).top) } ?? 0
            blocks.append(Block(id: blocks.count, text: text, source: source, spacingAbove: spacing))
            previousBottom = margins(lastKind(chunk)).bottom
        }
        return blocks
    }

    private static let htmlBlocks: [(String, String)] = [
        ("<!--", "-->"), ("<pre", "</pre>"), ("<script", "</script>"),
        ("<style", "</style>"), ("<textarea", "</textarea>"),
    ]

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func occurrences(of needle: String, in line: Substring) -> Int {
        line.components(separatedBy: needle).count - 1
    }

    /// The line past its indent, quote markers and a list marker: where a fence would begin.
    private static func blockBody(_ line: Substring) -> Substring {
        var rest = line.drop { $0 == " " || $0 == "\t" || $0 == ">" }
        if let marker = listMarkerLength(rest) { rest = rest.dropFirst(marker).drop { $0 == " " } }
        return rest
    }

    /// The length of a list marker and the space after it, at the line's start.
    private static func listMarkerLength(_ line: Substring) -> Int? {
        guard let first = line.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            return line.dropFirst().first == " " ? 2 : nil
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }.count
        guard (1...9).contains(digits) else { return nil }
        let rest = line.dropFirst(digits)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return digits + 2
    }

    private static func isListItem(_ line: Substring) -> Bool {
        let body = line.drop { $0 == " " }
        return listMarkerLength(body) != nil && !isRule(line)
    }

    private static func isRule(_ line: Substring) -> Bool {
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let mark = marks.first, mark == "-" || mark == "*" || mark == "_" else { return false }
        return marks.allSatisfy { $0 == mark } && line.prefix { $0 == " " }.count <= 3
    }

    private static func isDefinition(_ line: Substring) -> Bool {
        let body = line.drop { $0 == " " }
        guard body.first == "[", body.contains("]:"), line.prefix(while: { $0 == " " }).count <= 3 else { return false }
        return body.range(of: #"^\[[^\]]+\]:\s*\S"#, options: .regularExpression) != nil
    }

    private static func isSetextUnderline(_ line: Substring) -> Bool {
        let marks = line.trimmingCharacters(in: .whitespaces)
        guard let mark = marks.first, mark == "=" || mark == "-" else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    private static func firstKind(_ chunk: [Substring]) -> Kind {
        guard let line = chunk.first(where: { !isBlank($0) }) else { return .paragraph }
        let body = line.drop { $0 == " " }
        if body.hasPrefix("#") {
            let hashes = body.prefix { $0 == "#" }.count
            if hashes <= 6, body.dropFirst(hashes).first.map({ $0 == " " }) ?? true { return .heading }
        }
        if body.hasPrefix("```") || body.hasPrefix("~~~") { return .code }
        if body.hasPrefix(">") { return .quote }
        if isRule(line) { return .rule }
        if isListItem(line) { return .list }
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return .code }
        if body.hasPrefix("|") { return .table }
        if chunk.count > 1 {
            let next = chunk[1]
            if isSetextUnderline(next) { return .heading }
            if next.contains("|"), next.contains("-"),
               next.allSatisfy({ "|-: \t".contains($0) }) { return .table }
        }
        return .paragraph
    }

    /// Only a heading or a rule ends with a bottom margin other than a paragraph's.
    private static func lastKind(_ chunk: [Substring]) -> Kind {
        guard let index = chunk.lastIndex(where: { !isBlank($0) }) else { return .paragraph }
        let line = chunk[index]
        let previous = index > 0 ? chunk[index - 1] : nil
        let afterText = previous.map { !isBlank($0) } ?? false
        if isSetextUnderline(line), afterText, !isListItem(previous ?? "") {
            return .heading
        }
        if isRule(line) { return .rule }
        let body = line.drop { $0 == " " }
        if body.hasPrefix("#") {
            let hashes = body.prefix { $0 == "#" }.count
            if hashes <= 6, body.dropFirst(hashes).first.map({ $0 == " " }) ?? true { return .heading }
        }
        return .paragraph
    }
}

private extension View {
    /// A top-level block's margins, from the one table the block cut spaces by.
    func markdownMargin(_ kind: NativeChatMarkdownBlocks.Kind) -> some View {
        let margins = NativeChatMarkdownBlocks.margins(kind)
        return markdownMargin(top: margins.top, bottom: margins.bottom)
    }
}

@available(iOS 16.0, macOS 14.0, *)
struct NativeChatMarkdownBody: View, Equatable {
    let content: String
    let contextMentions: Bool
    private let document: MarkdownContent?
    private let blocks: [NativeChatMarkdownBlocks.Block]
    private let themeVersion: Int
    @ScaledMetric(relativeTo: .body) private var mathFontSize: CGFloat = 14.5

    /// - Parameter streamsByBlock: lay out a block at a time (`-perfOn mdBlocks`),
    ///   for text that grows while it streams.
    init(content: String, contextMentions: Bool = false, streamsByBlock: Bool = false) {
        self.content = content
        self.contextMentions = contextMentions
        if streamsByBlock && PerfSwitch.isOn("mdBlocks") {
            self.document = nil
            self.blocks = NativeChatMarkdownBlocks.split(content)
        } else {
            self.document = NativeChatMarkdownDocument.parse(content, contextMentions: contextMentions)
            self.blocks = []
        }
        self.themeVersion = RipulTheme.version
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content && lhs.contextMentions == rhs.contextMentions
            && lhs.themeVersion == rhs.themeVersion
            && (lhs.document == nil) == (rhs.document == nil)
    }

    var body: some View {
        rendered
            .markdownTheme(NativeChatMarkdownTheme.theme)
            // The web chat uses marked's breaks:true. Keep authored newlines.
            .markdownSoftBreakMode(.lineBreak)
            .markdownImageProvider(NativeChatMarkdownTheme.mathImageProvider(fontSize: mathFontSize))
            .markdownInlineImageFlow()
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder private var rendered: some View {
        if let document {
            Markdown(document)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    NativeChatMarkdownBlockView(source: block.source, contextMentions: contextMentions,
                                                themeVersion: themeVersion)
                        .equatable()
                        // Code blocks and tables key their state by position
                        // in their own document, which starts again in each block.
                        .nativeChatRowStateScope("block:\(block.id)")
                        .padding(.top, block.spacingAbove)
                }
            }
        }
    }
}

/// One top-level block, drawn again only when its own text changes.
@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatMarkdownBlockView: View, Equatable {
    let source: String
    let contextMentions: Bool
    let themeVersion: Int
    private let document: MarkdownContent

    init(source: String, contextMentions: Bool, themeVersion: Int) {
        self.source = source
        self.contextMentions = contextMentions
        self.themeVersion = themeVersion
        self.document = NativeChatMarkdownDocument.parse(source, contextMentions: contextMentions)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.contextMentions == rhs.contextMentions
            && lhs.themeVersion == rhs.themeVersion
    }

    var body: some View {
        Markdown(document)
    }
}

/// The web chat's compact reading rhythm, expressed using native controls and
/// semantic theme colours. MarkdownUI scales its base font with Dynamic Type.
@available(iOS 16.0, macOS 14.0, *)
enum NativeChatMarkdownTheme {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedTheme: (version: Int, theme: Theme)?
    nonisolated(unsafe) private static var cachedMathProviders: [CGFloat: (version: Int, provider: NativeMarkdownMathImageProvider)] = [:]

    static var theme: Theme {
        let version = RipulTheme.version
        lock.lock()
        if let hit = cachedTheme, hit.version == version {
            lock.unlock()
            return hit.theme
        }
        lock.unlock()
        let built = buildTheme()
        lock.lock()
        cachedTheme = (version, built)
        lock.unlock()
        return built
    }

    static func mathImageProvider(fontSize: CGFloat) -> NativeMarkdownMathImageProvider {
        let version = RipulTheme.version
        lock.lock()
        if let hit = cachedMathProviders[fontSize], hit.version == version {
            lock.unlock()
            return hit.provider
        }
        lock.unlock()
        let built = NativeMarkdownMathImageProvider(fontSize: fontSize, color: .ripul(.text))
        lock.lock()
        if cachedMathProviders.count >= 16 { cachedMathProviders.removeAll() }
        cachedMathProviders[fontSize] = (version, built)
        lock.unlock()
        return built
    }

    private static func buildTheme() -> Theme {
        Theme.basic
            .text {
                FontSize(14.5)
                ForegroundColor(.ripul(.text))
            }
            .strong { FontWeight(.semibold) }
            .link {
                ForegroundColor(.ripul(.info))
                UnderlineStyle(.single)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                BackgroundColor(Color.ripul(.text).opacity(0.08))
            }
            .heading1 { heading($0) }
            .heading2 { heading($0) }
            .heading3 { heading($0) }
            .heading4 { heading($0) }
            .heading5 { heading($0) }
            .heading6 { heading($0) }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(.paragraph)
            }
            .list { configuration in
                configuration.label.markdownMargin(.list)
            }
            .listItem { configuration in
                configuration.label.markdownMargin(top: 2, bottom: 2)
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle { ForegroundColor(.ripul(.textSecondary)) }
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.ripul(.separator))
                            .frame(width: 3)
                    }
                    .markdownMargin(.quote)
            }
            .codeBlock { configuration in
                NativeMarkdownFencedBlock(source: configuration.content, language: configuration.language)
                .nativeChatRowStateScope("code:" + configuration.blockPath.map(String.init).joined(separator: "."))
                .markdownMargin(.code)
            }
            .table { configuration in
                NativeChatMarkdownTable(configuration: configuration)
            }
            .tableCell { configuration in
                NativeChatMarkdownTableCell(configuration: configuration)
            }
            .thematicBreak {
                Rectangle()
                    .fill(Color.ripul(.separator))
                    .frame(height: 1)
                    .markdownMargin(.rule)
            }
    }

    private static func heading(_ configuration: BlockConfiguration) -> some View {
        configuration.label
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(1.1))
            }
            .relativeLineSpacing(.em(0.15))
            .markdownMargin(.heading)
    }
}

@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatMarkdownTable: View {
    let configuration: BlockConfiguration
    @Environment(\.markdownBlockPath) private var blockPath
    @NativeRowState("table.width") private var widthMode = NativeChatTableWidth.balanced
    @State private var availableWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var columnScale = 1.0

    private var tableKey: String { blockPath.map(String.init).joined(separator: ".") }

    var body: some View {
        let mode = _widthMode.value(subscope: tableKey)
        ScrollView(.horizontal) {
            configuration.label
                .markdownTableLayout(.adaptive(
                    availableWidth: availableWidth * mode.viewportMultiplier,
                    minimumColumnWidth: mode.minimumColumnWidth * columnScale,
                    maximumColumnWidth: mode.maximumColumnWidth * columnScale,
                    overflow: .minimum
                ))
                .markdownTableBorderStyle(.init(color: .ripul(.separator)))
                .markdownTableBackgroundStyle(.alternatingRows(
                    Color.clear, Color.ripul(.text).opacity(0.035),
                    header: Color.ripul(.text).opacity(0.06)
                ))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                Picker("Table width", selection: _widthMode.binding(subscope: tableKey)) {
                    ForEach(NativeChatTableWidth.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.left.and.right")
                    .font(.ripulIcon(size: 11, weight: .medium))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 28, height: 18)
                    .background(Color.ripul(.surface), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.ripul(.separator), lineWidth: 1))
                    // A compact mark with a larger touch target.
                    .frame(width: 44, height: 44, alignment: .top)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Table width")
            .accessibilityValue(mode.title)
            .accessibilityIdentifier("NativeChat.table.width.\(tableKey)")
            .help("Table width: \(mode.title)")
            // Straddle the border within the existing table margin; short
            // tables end before the viewport's trailing edge.
            .offset(x: -max(0, availableWidth - contentWidth), y: -8)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width.isFinite, width > 0, abs(width - availableWidth) > 0.5 {
                availableWidth = width
            }
        }
        .markdownMargin(.table)
    }
}

/// Width budgets for a table; never change the enclosing message's width.
enum NativeChatTableWidth: String, CaseIterable {
    case fit, balanced, wide

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .balanced: return "Balanced"
        case .wide: return "Wide"
        }
    }

    var viewportMultiplier: CGFloat {
        switch self {
        case .fit: return 1
        case .balanced: return 1.5
        case .wide: return 2.5
        }
    }

    var minimumColumnWidth: CGFloat {
        switch self {
        case .fit: return 44
        case .balanced: return 80
        case .wide: return 96
        }
    }

    var maximumColumnWidth: CGFloat {
        switch self {
        case .fit: return 320
        case .balanced: return 400
        case .wide: return 640
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
struct NativeChatMarkdownTableCell: View {
    let configuration: TableCellConfiguration

    var body: some View {
        configuration.label
            .markdownTextStyle {
                if configuration.row == 0 { FontWeight(.semibold) }
            }
            .multilineTextAlignment(configuration.alignment)
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.2))
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private var alignment: Alignment {
        switch configuration.alignment {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }
}
