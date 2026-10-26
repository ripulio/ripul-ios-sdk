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

    static func parse(_ source: String) -> MarkdownContent {
        let key = source as NSString
        if let hit = cache.object(forKey: key) { return hit.content }
        let content = MarkdownContent(source)
        // Account approximately for the source key and the parsed text/tree.
        cache.setObject(Box(content), forKey: key, cost: source.utf8.count * 4)
        return content
    }
}

@available(iOS 16.0, macOS 14.0, *)
struct NativeChatMarkdownBody: View, Equatable {
    let content: String
    private let document: MarkdownContent

    init(content: String) {
        self.content = content
        self.document = NativeChatMarkdownDocument.parse(content)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.content == rhs.content }

    var body: some View {
        Markdown(document)
            .markdownTheme(NativeChatMarkdownTheme.theme)
            // The web chat uses marked's breaks:true. Keep authored newlines.
            .markdownSoftBreakMode(.lineBreak)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// The web chat's compact reading rhythm, expressed using native controls and
/// semantic theme colours. MarkdownUI scales its base font with Dynamic Type.
@available(iOS 16.0, macOS 14.0, *)
enum NativeChatMarkdownTheme {
    static var theme: Theme {
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
                    .markdownMargin(top: 0, bottom: 8)
            }
            .list { configuration in
                configuration.label.markdownMargin(top: 4, bottom: 8)
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
                    .markdownMargin(top: 4, bottom: 8)
            }
            .codeBlock { configuration in
                NativeToolCodeBlock(
                    text: configuration.content,
                    title: configuration.language,
                    titleFont: .ripul(.caption, weight: .semibold),
                    syntax: configuration.language.map { .language($0.lowercased()) } ?? .automatic,
                    compact: true,
                    preservesSource: true
                )
                .nativeChatRowStateScope("code:" + configuration.blockPath.map(String.init).joined(separator: "."))
                .markdownMargin(top: 8, bottom: 8)
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
                    .markdownMargin(top: 12, bottom: 12)
            }
    }

    private static func heading(_ configuration: BlockConfiguration) -> some View {
        configuration.label
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(1.1))
            }
            .relativeLineSpacing(.em(0.15))
            .markdownMargin(top: 8, bottom: 4)
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
        .markdownMargin(top: 8, bottom: 8)
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
