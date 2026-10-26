import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct NativeToolSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.ripul(.headline))
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared source/output surface, just as ToolOutputBlock is shared on the web.
/// Large output is progressively revealed; the full text remains copyable.
struct NativeToolCodeBlock: View {
    let text: String
    var title: String?
    var titleFont: Font = .ripul(.headline)
    var numbered = false
    var firstLine = 1
    var syntax: NativeToolCodeSyntax?
    var compact = false
    var preservesSource = false
    var readLineNumbers = false
    var commandBreakLines: [Int] = []
    var commandPipeLines: [Int] = []
    var identifier = "NativeTool.code"
    @NativeRowState("code.visibleLines") private var visibleLines = 80
    @NativeRowState("code.wraps") private var wraps = false
    @State private var textWidth: CGFloat = 0
    @State private var panelWidth: CGFloat = 0
    @State private var highlighted: AttributedString?
    @State private var highlightedRequest: NativeHighlightRequest?
    @Environment(\.colorScheme) private var colorScheme

    var codeScopeKey: String { title ?? identifier }
    var wrapsScopeKey: String { title ?? identifier }

    var body: some View {
        let currentVisibleLines = _visibleLines.value(subscope: codeScopeKey)
        let currentWraps = _wraps.value(subscope: wrapsScopeKey)
        let clean = !preservesSource && (syntax == nil || syntax == .automatic) ? ToolValue.cleanTerminal(text) : text
        let lines = clean.components(separatedBy: "\n")
        let visible = lines.prefix(currentVisibleLines).joined(separator: "\n")
        let request = NativeHighlightRequest(source: visible, language: syntax?.language ?? "plaintext", dark: colorScheme == .dark, readLineNumbers: readLineNumbers)
        let attributed = highlightedRequest == request ? (highlighted ?? AttributedString(visible)) : AttributedString(visible)
        let colouredLines = NativeSourceHighlighting.lines(attributed)
        let sectionStarts = [0] + Set(commandBreakLines.filter { $0 > 0 && $0 < colouredLines.count }).sorted()
        let lineCount = "\(lines.count) \(lines.count == 1 ? "line" : "lines")"
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            if let title { toolbar(title: title, font: titleFont, clean: clean) }
            VStack(alignment: .leading, spacing: 8) {
                if title == nil { toolbar(title: lineCount, font: .ripul(.caption), clean: clean) }
                else if !compact { Text(lineCount).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)) }
                if numbered {
                    wrapping {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.prefix(currentVisibleLines).enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(firstLine + index)").foregroundStyle(.ripul(.textSecondary)).frame(minWidth: 28, alignment: .trailing)
                                    Text(line.isEmpty ? AttributedString(" ") : index < colouredLines.count ? colouredLines[index] : AttributedString(line))
                                        .textSelection(.enabled).fixedSize(horizontal: !currentWraps, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.ripul(.caption, family: .code))
                            }
                        }
                        .accessibilityIdentifier(identifier)
                    }
                } else if sectionStarts.count > 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sectionStarts.indices, id: \.self) { index in
                            let start = sectionStarts[index]
                            if index > 0 {
                                Group {
                                    if commandPipeLines.contains(start) {
                                        HStack(spacing: 8) {
                                            VStack { Divider() }
                                            Label("Piped input", systemImage: "arrow.down")
                                                .font(.ripul(.caption2, weight: .medium))
                                                .foregroundStyle(.ripul(.textSecondary))
                                                .fixedSize()
                                                .accessibilityElement(children: .combine)
                                                .accessibilityLabel("Piped input from previous command")
                                                .accessibilityIdentifier("\(identifier).pipe.\(index)")
                                            VStack { Divider() }
                                        }
                                    } else {
                                        Divider()
                                    }
                                }
                                .padding(.vertical, 10)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("\(identifier).divider.\(index)")
                            }
                            let end = index + 1 < sectionStarts.count ? sectionStarts[index + 1] : colouredLines.count
                            wrapping {
                                Text(colouredLines[(start + 1)..<end].reduce(colouredLines[start]) { $0 + AttributedString("\n") + $1 })
                                    .font(.ripul(.callout, family: .code)).textSelection(.enabled)
                                    .fixedSize(horizontal: !currentWraps, vertical: true)
                                    .accessibilityIdentifier("\(identifier).part.\(index)")
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(identifier)
                } else {
                    wrapping {
                        Text(attributed)
                            .font(.ripul(.callout, family: .code)).textSelection(.enabled)
                            .fixedSize(horizontal: !currentWraps, vertical: true)
                            .accessibilityIdentifier(identifier)
                    }
                }
                if lines.count > currentVisibleLines {
                    Button("Show more (\(lines.count - currentVisibleLines) lines remaining)") {
                        _visibleLines.setValue(currentVisibleLines + 200, subscope: codeScopeKey)
                    }.font(.ripul(.callout))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
            .overlay(alignment: .topLeading) {
                // Measure the unwrapped text independently of the toggle, so Wrap
                // remains available while wrapping and responds to resizing/text updates.
                HStack(alignment: .top, spacing: numbered ? 10 : 0) {
                    if numbered {
                        Text("\(firstLine + min(lines.count, currentVisibleLines) - 1)").frame(minWidth: 28)
                    }
                    Text(visible)
                }
                .font(.ripul(numbered ? .caption : .callout, family: .code))
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                .hidden().accessibilityHidden(true).allowsHitTesting(false)
            }
            .padding(compact ? 10 : 12).background(.ripul(.textQuaternary).opacity(0.5), in: RoundedRectangle(cornerRadius: compact ? 6 : 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: request) {
            let result = await NativeSourceHighlighting.shared.attributed(request)
            guard !Task.isCancelled else { return }
            highlighted = result
            highlightedRequest = request
        }
    }

    private func toolbar(title: String, font: Font, clean: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(font).accessibilityIdentifier("\(identifier).title")
            Spacer(minLength: 8)
            if panelWidth > 0 && textWidth > panelWidth + 0.5 {
                Toggle("Wrap", isOn: _wraps.binding(subscope: wrapsScopeKey))
                    .toggleStyle(.switch).fixedSize().font(.ripul(.caption))
                    .accessibilityIdentifier("\(identifier).wrap")
            }
            Button {
                #if os(iOS)
                UIPasteboard.general.string = clean
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clean, forType: .string)
                #endif
            } label: { Label("Copy", systemImage: "doc.on.doc") }
                .font(.ripul(.caption)).fixedSize().accessibilityIdentifier("\(identifier).copy")
        }
        .frame(minHeight: 32)
    }

    /// Scroll the text only, keeping its toolbar and command dividers in view.
    @ViewBuilder private func wrapping<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if _wraps.value(subscope: wrapsScopeKey) {
            content().frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal) {
                content().fixedSize(horizontal: true, vertical: true)
            }
        }
    }
}

/// Unknown/extra fields use native labelled values and disclosure groups. A
/// result containing structured data is never dumped back as a JSON document.
struct NativeToolValueView: View {
    let value: CmsJSON
    var title: String?
    var titleFont: Font = .ripul(.headline)
    var identifier = "NativeTool.value"
    var textSyntax: NativeToolCodeSyntax?
    var narrative = true
    @NativeRowState("value.visibleItems") private var visibleItems = 40
    @NativeRowState("value.disclosure") private var fieldDisclosure = false

    private var valueScopeKey: String { title ?? identifier }

    var body: some View {
        let display = narrative && textSyntax == nil ? NativeToolNarrative.expanded(value) : value
        if let title, case .string(let text) = display, !NativeToolNarrative.isProse(text, enabled: narrative, hasSyntax: textSyntax != nil), text.contains("\n") || (textSyntax != nil && !text.isEmpty) {
            NativeToolCodeBlock(text: text, title: title, titleFont: titleFont, syntax: textSyntax, identifier: identifier)
        } else if let title {
            NativeToolSection(title: title) { content(display) }
        } else { content(display) }
    }

    private func content(_ value: CmsJSON) -> AnyView {
        switch value {
        case .string(let text):
            if NativeToolNarrative.isProse(text, enabled: narrative, hasSyntax: textSyntax != nil) {
                return AnyView(NativeToolProse(text: text, identifier: identifier))
            }
            if text.contains("\n") || (textSyntax != nil && !text.isEmpty) {
                return AnyView(NativeToolCodeBlock(text: text, syntax: textSyntax, identifier: identifier))
            }
            return AnyView(Text(ToolValue.cleanTerminal(text.isEmpty ? "Empty text" : text)).textSelection(.enabled).accessibilityIdentifier(identifier))
        case .number(let number): return AnyView(Text(CmsJSON.number(number).displayString).monospacedDigit().textSelection(.enabled))
        case .bool(let yes): return AnyView(Label(yes ? "Yes" : "No", systemImage: yes ? "checkmark.circle" : "minus.circle"))
        case .null: return AnyView(Text("No value").foregroundStyle(.ripul(.textSecondary)))
        case .array(let items):
            if items.isEmpty { return AnyView(Text("None").foregroundStyle(.ripul(.textSecondary))) }
            let currentVisibleItems = _visibleItems.value(subscope: valueScopeKey)
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.prefix(currentVisibleItems).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                        NativeToolValueView(value: item, textSyntax: textSyntax, narrative: narrative)
                            .nativeChatRowStateScope("item:\(index)")
                    }
                    if index < items.count - 1 { Divider() }
                }
                if items.count > currentVisibleItems {
                    Button("Show more (\(items.count - currentVisibleItems) remaining)") {
                        _visibleItems.setValue(currentVisibleItems + 100, subscope: valueScopeKey)
                    }
                }
            })
        case .object(let object):
            if let source = NativeToolImage.source(object) { return AnyView(NativeToolImage(source: source)) }
            if object.isEmpty { return AnyView(Text("None").foregroundStyle(.ripul(.textSecondary))) }
            let sortedKeys = object.keys.sorted()
            let scalarKeys = sortedKeys.filter { key in
                guard let item = object[key] else { return false }
                return Self.isCompactFieldControl(key: key, item: item, textSyntax: textSyntax, narrative: narrative)
            }
            let blockKeys = sortedKeys.filter { key in
                guard let item = object[key] else { return false }
                return !Self.isCompactFieldControl(key: key, item: item, textSyntax: textSyntax, narrative: narrative)
            }
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                if !scalarKeys.isEmpty {
                    NativeToolFieldFlowLayout(spacing: 8) {
                        ForEach(scalarKeys, id: \.self) { key in
                            if let item = object[key] {
                                let syntax = ["stdout", "stderr", "output", "text", "content"].contains(key) ? textSyntax : nil
                                NativeToolFieldControl(label: ToolValue.title(key), isLiteral: NativeToolNarrative.isLiteralField(key)) {
                                    if let raw = item.stringValue, let url = URL(string: raw), ["https", "http"].contains(url.scheme) {
                                        Link(raw, destination: url).textSelection(.enabled)
                                    } else {
                                        NativeToolValueView(value: item, textSyntax: syntax, narrative: false)
                                            .nativeChatRowStateScope("field:\(key)")
                                    }
                                }
                            }
                        }
                    }
                }
                ForEach(blockKeys, id: \.self) { key in
                    if let item = object[key] {
                        if item.objectValue != nil || item.toolArray != nil {
                            DisclosureGroup(
                                ToolValue.title(key),
                                isExpanded: _fieldDisclosure.binding(subscope: "\(valueScopeKey):\(key)")
                            ) {
                                NativeToolValueView(value: item, textSyntax: textSyntax, narrative: narrative && !NativeToolNarrative.isLiteralField(key))
                                    .nativeChatRowStateScope("field:\(key)")
                                    .padding(.top, 8)
                            }
                        } else {
                            let syntax = ["stdout", "stderr", "output", "text", "content"].contains(key) ? textSyntax : nil
                            if let text = item.stringValue, NativeToolNarrative.isProse(text, field: key, enabled: narrative, hasSyntax: textSyntax != nil) {
                                NativeToolSection(title: ToolValue.title(key)) {
                                    NativeToolProse(text: text).nativeChatRowStateScope("field:\(key)")
                                }
                            } else if let text = item.stringValue, text.contains("\n") || (syntax != nil && !text.isEmpty) {
                                NativeToolCodeBlock(text: text, title: ToolValue.title(key), titleFont: .ripul(.caption), syntax: syntax, identifier: "NativeTool.value")
                                    .nativeChatRowStateScope("field:\(key)")
                            }
                        }
                    }
                }
            })
        }
    }

    static func isCompactFieldControl(key: String, item: CmsJSON, textSyntax: NativeToolCodeSyntax? = nil, narrative: Bool = true) -> Bool {
        if item.objectValue != nil || item.toolArray != nil { return false }
        let syntax = ["stdout", "stderr", "output", "text", "content"].contains(key) ? textSyntax : nil
        if let text = item.stringValue {
            if NativeToolNarrative.isProse(text, field: key, enabled: narrative, hasSyntax: textSyntax != nil) { return false }
            if text.contains("\n") || (syntax != nil && !text.isEmpty) { return false }
        }
        return true
    }
}

/// MUI-inspired read-only field box that tightly integrates its micro-label and
/// value inside a differentiated surface container.
struct NativeToolFieldControl<Content: View>: View {
    let label: String
    var isLiteral = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.ripul(.caption2, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .lineLimit(1)
            content
                .font(isLiteral ? .ripul(.caption, family: .code) : .ripul(.subheadline, weight: .medium))
                .foregroundStyle(.ripul(.text))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ripul(.textQuaternary).opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.ripul(.separator).opacity(0.75), lineWidth: 1)
        )
    }
}

/// Packs narrow field controls into shared horizontal rows (up to `maxPerRow`
/// per row) while giving wider values their own full-width row and stretching
/// fields within each row so leading and trailing edges align.
struct NativeToolFieldFlowLayout: Layout {
    var spacing: CGFloat = 8
    var maxPerRow: Int = 3

    struct RowItem: Equatable {
        let index: Int
        let width: CGFloat
    }

    static func packRows(idealWidths: [CGFloat], availableWidth: CGFloat, spacing: CGFloat = 8, maxPerRow: Int = 3) -> [[RowItem]] {
        guard !idealWidths.isEmpty else { return [] }
        let safeWidth = max(availableWidth, 120)
        let shareThreshold = safeWidth * 0.62
        var rawRows: [[(index: Int, ideal: CGFloat, raw: CGFloat)]] = []
        var current: [(index: Int, ideal: CGFloat, raw: CGFloat)] = []
        var currentSum: CGFloat = 0

        for (index, raw) in idealWidths.enumerated() {
            let clamped = max(min(raw, safeWidth), 64)
            let canShare = raw <= shareThreshold && current.allSatisfy { $0.raw <= shareThreshold }
            let nextWidth = currentSum + CGFloat(current.count) * spacing + clamped
            if !current.isEmpty && canShare && current.count < maxPerRow && nextWidth <= safeWidth {
                current.append((index, clamped, raw))
                currentSum += clamped
            } else {
                if !current.isEmpty { rawRows.append(current) }
                current = [(index, clamped, raw)]
                currentSum = clamped
            }
        }
        if !current.isEmpty { rawRows.append(current) }

        return rawRows.map { row in
            let totalSpacing = CGFloat(max(0, row.count - 1)) * spacing
            let sumIdeal = row.reduce(CGFloat(0)) { $0 + $1.ideal }
            let extra = max(0, safeWidth - totalSpacing - sumIdeal)
            return row.map { item in
                let share = sumIdeal > 0 ? extra * (item.ideal / sumIdeal) : extra / CGFloat(row.count)
                return RowItem(index: item.index, width: item.ideal + share)
            }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let availableWidth = proposal.width ?? 320
        let idealWidths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rows = Self.packRows(idealWidths: idealWidths, availableWidth: availableWidth, spacing: spacing, maxPerRow: maxPerRow)
        var totalHeight: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 { totalHeight += spacing }
            let rowHeight = row.map { subviews[$0.index].sizeThatFits(ProposedViewSize(width: $0.width, height: nil)).height }.max() ?? 0
            totalHeight += rowHeight
        }
        return CGSize(width: availableWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let availableWidth = bounds.width > 0 ? bounds.width : (proposal.width ?? 320)
        let idealWidths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rows = Self.packRows(idealWidths: idealWidths, availableWidth: availableWidth, spacing: spacing, maxPerRow: maxPerRow)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { subviews[$0.index].sizeThatFits(ProposedViewSize(width: $0.width, height: nil)).height }.max() ?? 0
            var x = bounds.minX
            for item in row {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.width, height: rowHeight)
                )
                x += item.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

struct NativeToolParameters: View {
    let args: [String: CmsJSON]
    var excluding: Set<String> = []
    var title = "Parameters"
    @NativeRowState("params.expanded") private var isExpanded = false

    var body: some View {
        let fields = args.filter { !excluding.contains($0.key) && $0.value != .null }
        if !fields.isEmpty {
            DisclosureGroup(title, isExpanded: _isExpanded.binding(subscope: title)) {
                NativeToolValueView(value: .object(fields))
                    .nativeChatRowStateScope("params:\(title)")
                    .padding(.top, 8)
            }
        }
    }
}

struct NativeToolResultView: View {
    let content: NativeToolContent
    var title = "Result"
    var textSyntax: NativeToolCodeSyntax?
    var body: some View {
        if let output = content.output {
            NativeToolValueView(value: output, title: title, identifier: "ToolCallDetails.result", textSyntax: textSyntax)
        } else {
            NativeToolSection(title: title) {
                if content.running { ProgressView("Waiting for result…") }
                else { Text("No output was recorded.").foregroundStyle(.ripul(.textSecondary)) }
            }
        }
    }
}

struct NativeToolPath: View {
    let path: String
    var body: some View {
        if !path.isEmpty {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text((path as NSString).lastPathComponent).font(.ripul(.headline))
                    Text(path).font(.ripul(.caption, family: .code)).foregroundStyle(.ripul(.textSecondary)).textSelection(.enabled)
                }
            } icon: { Image(systemName: "doc.text").foregroundStyle(.ripul(.textSecondary)) }
        }
    }
}

struct NativeToolImage: View {
    let source: String
    @State private var zoomed = false
    static func source(_ object: [String: CmsJSON]) -> String? {
        if let source = object.string("imageData") { return source }
        if object.string("type") == "image", let data = object.string("data") {
            return data.hasPrefix("data:") ? data : "data:\(object.string("mimeType") ?? object.string("mediaType") ?? "image/png");base64,\(data)"
        }
        if let blob = object["blobs"]?.toolArray?.first?.objectValue { return source(blob) }
        return nil
    }
    @ViewBuilder private var picture: some View {
        if source.hasPrefix("data:"), let encoded = source.components(separatedBy: ",").last, let data = Data(base64Encoded: encoded) {
            #if os(iOS)
            if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
            else { Text("Image preview unavailable") }
            #else
            if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
            else { Text("Image preview unavailable") }
            #endif
        } else if let url = URL(string: source), ["https", "http"].contains(url.scheme) {
            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
        } else { Text("Image preview unavailable") }
    }
    var body: some View {
        Button { zoomed = true } label: { picture }.buttonStyle(.plain).accessibilityLabel("Enlarge image")
            .ripulSheet(isPresented: $zoomed) {
                NavigationStack { ScrollView([.horizontal, .vertical]) { picture.padding() }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { zoomed = false } } }
                }
            }
    }
}
