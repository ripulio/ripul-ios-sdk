import MarkdownUI
import SwiftUI

/// Native sheet for presenting multichoice user interaction questions.
@available(iOS 16.0, macOS 14.0, *)
struct UserInteractionSheet: View {
    let question: UserInteractionQuestion
    let onRespond: (Any) -> Void
    var onOpenLink: ((URL) -> Void)?

    @State private var selectedValues: Set<Int> = []
    @State private var alternativeText = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                // Close button — glass circle with X icon
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .modifier(InteractiveGlassCircleModifier())
                }

                Spacer()

                Text("Choose an option")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .modifier(GlassCardModifier())

                Spacer()

                if question.multiSelect {
                    Button("Done") {
                        let values = selectedValues.sorted().map { question.options[$0].value }
                        onRespond(values)
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .disabled(selectedValues.isEmpty)
                } else {
                    // Invisible spacer to balance layout
                    Color.clear.frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 8) {
                    // Question (with table-to-card rendering)
                    MarkdownContentView(
                        markdown: question.question,
                        onOpenLink: onOpenLink
                    )
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    // Options — each is an interactive glass button
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        let isSelected = selectedValues.contains(index)
                        Button {
                            if question.multiSelect {
                                toggleSelection(index)
                            } else {
                                if let link = option.link, let url = URL(string: link) {
                                    if let handler = onOpenLink {
                                        handler(url)
                                    } else {
                                        openURL(url)
                                    }
                                }
                                onRespond(option.value)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .foregroundStyle(.primary)
                                    if let desc = option.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if question.multiSelect {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(isSelected ? .blue : .secondary)
                                } else if option.link != nil {
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.blue)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .modifier(InteractiveGlassCardModifier(isSelected: question.multiSelect && isSelected))
                    }

                    // Alternative text input
                    HStack {
                        TextField("Type an alternative...", text: $alternativeText)
                            .focused($isTextFieldFocused)
                            .onSubmit { submitAlternative() }
                        if !alternativeText.isEmpty {
                            Button {
                                submitAlternative()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .modifier(GlassCardModifier())
                }
                .padding(12)
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .modifier(SheetBackgroundModifier())
        #else
        .frame(minWidth: 360, minHeight: 300)
        #endif
    }

    private func toggleSelection(_ index: Int) {
        if selectedValues.contains(index) {
            selectedValues.remove(index)
        } else {
            selectedValues.insert(index)
        }
    }

    private func submitAlternative() {
        let text = alternativeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onRespond(text)
        dismiss()
    }
}

// MARK: - Text Input Sheet

/// Native sheet for presenting a free-text input question with markdown support.
@available(iOS 16.0, macOS 14.0, *)
struct UserTextInputSheet: View {
    let question: UserTextQuestion
    let onRespond: (String) -> Void
    var onOpenLink: ((URL) -> Void)?

    @State private var text = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .modifier(InteractiveGlassCircleModifier())
                }

                Spacer()

                Text("Provide input")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .modifier(GlassCardModifier())

                Spacer()

                // Submit button
                Button {
                    submitText()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.blue)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 12) {
                    // Question (with table-to-card rendering)
                    MarkdownContentView(
                        markdown: question.question,
                        onOpenLink: onOpenLink
                    )
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                    // Text input
                    TextField("Type your response...", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($isTextFieldFocused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .modifier(GlassCardModifier())
                        .onSubmit { submitText() }
                }
                .padding(12)
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .modifier(SheetBackgroundModifier())
        #else
        .frame(minWidth: 360, minHeight: 250)
        #endif
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private func submitText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRespond(trimmed)
        dismiss()
    }
}

// MARK: - Date Picker Sheet

/// Native sheet for presenting a date picker question.
@available(iOS 16.0, macOS 14.0, *)
struct UserDatePickerSheet: View {
    let question: UserDateQuestion
    let onRespond: (String) -> Void
    var onOpenLink: ((URL) -> Void)?

    @State private var selectedDate = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .modifier(InteractiveGlassCircleModifier())
                }

                Spacer()

                Text("Select a date")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .modifier(GlassCardModifier())

                Spacer()

                Button("Done") {
                    submitDate()
                }
                .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 12) {
                    // Question (with table-to-card rendering)
                    MarkdownContentView(
                        markdown: question.question,
                        onOpenLink: onOpenLink
                    )
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                    // Date picker
                    DatePicker(
                        "Date",
                        selection: $selectedDate,
                        in: dateRange,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                    .modifier(GlassCardModifier())
                }
                .padding(12)
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .modifier(SheetBackgroundModifier())
        #else
        .frame(minWidth: 360, minHeight: 400)
        #endif
        .onAppear {
            if let defaultDate = question.defaultDate {
                selectedDate = defaultDate
            }
        }
    }

    private var dateRange: ClosedRange<Date> {
        let min = question.minDate ?? Date.distantPast
        let max = question.maxDate ?? Date.distantFuture
        return min...max
    }

    private func submitDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        onRespond(formatter.string(from: selectedDate))
        dismiss()
    }
}

// MARK: - Rich Markdown Content View

/// A parsed markdown link: `[text](url)`.
private struct ParsedLink {
    let text: String
    let url: String
}

/// A single row extracted from a markdown table, rendered as a card.
private struct TableCardRow: Identifiable {
    let id = UUID()
    let title: String
    let link: ParsedLink?
    let subtitle: String  // remaining columns joined with " · "
}

/// Segments of a markdown document: either freeform text or a table.
private enum MarkdownSegment: Identifiable {
    case text(String)
    case table([TableCardRow])

    var id: String {
        switch self {
        case .text(let s): return "text_\(s.hashValue)"
        case .table(let rows): return "table_\(rows.first?.id.uuidString ?? "empty")"
        }
    }
}

/// Renders markdown with tables extracted as native glass cards.
/// Non-table content renders via MarkdownUI; tables render as tappable cards.
@available(iOS 16.0, macOS 14.0, *)
private struct MarkdownContentView: View {
    let markdown: String
    var onOpenLink: ((URL) -> Void)?

    var body: some View {
        let segments = Self.parse(markdown)
        ForEach(segments) { segment in
            switch segment {
            case .text(let text):
                Markdown(text)
                    .markdownTextStyle {
                        FontSize(.em(0.95))
                        ForegroundColor(.secondary)
                    }
                    .markdownTextStyle(\.link) {
                        ForegroundColor(.blue)
                        UnderlineStyle(.single)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        if let handler = onOpenLink {
                            handler(url)
                        }
                        return .handled
                    })

            case .table(let rows):
                ForEach(rows) { row in
                    if let link = row.link, let url = URL(string: link.url) {
                        Button {
                            onOpenLink?(url)
                        } label: {
                            tableCardLabel(row: row, hasLink: true)
                        }
                        .buttonStyle(.plain)
                        .modifier(InteractiveGlassCardModifier())
                    } else {
                        tableCardLabel(row: row, hasLink: false)
                            .modifier(GlassCardModifier())
                    }
                }
            }
        }
    }

    private func tableCardLabel(row: TableCardRow, hasLink: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .foregroundStyle(hasLink ? .blue : .primary)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hasLink {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Markdown Table Parser

    /// Parse markdown into segments of text and tables.
    static func parse(_ markdown: String) -> [MarkdownSegment] {
        let normalized = normalizeInlineTables(markdown)
        let lines = normalized.components(separatedBy: "\n")
        var segments: [MarkdownSegment] = []
        var currentText: [String] = []
        var tableLines: [String] = []

        func flushText() {
            let text = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(.text(text))
            }
            currentText = []
        }

        func flushTable() {
            if let rows = parseTable(tableLines) {
                segments.append(.table(rows))
            } else {
                // Failed to parse as table — treat as text
                currentText.append(contentsOf: tableLines)
            }
            tableLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                if tableLines.isEmpty {
                    flushText()
                }
                tableLines.append(trimmed)
            } else {
                if !tableLines.isEmpty {
                    flushTable()
                }
                currentText.append(line)
            }
        }

        if !tableLines.isEmpty { flushTable() }
        flushText()

        return segments
    }

    /// Parse table lines into card rows. Returns nil if not a valid table.
    private static func parseTable(_ lines: [String]) -> [TableCardRow]? {
        // Need at least header + separator + 1 data row
        guard lines.count >= 3 else { return nil }

        let headers = parseCells(lines[0])
        guard !headers.isEmpty else { return nil }

        // Line 1 should be the separator (|---|---|)
        let sep = lines[1]
        guard sep.contains("-") else { return nil }

        var rows: [TableCardRow] = []
        for i in 2..<lines.count {
            let cells = parseCells(lines[i])
            guard !cells.isEmpty else { continue }

            // Two-pass: first find the best title (prefer a cell with a link)
            var titleIndex: Int?
            var titleLink: ParsedLink?

            // Pass 1: find first cell with a link
            for (index, cell) in cells.enumerated() {
                if let link = extractLink(cell) {
                    titleIndex = index
                    titleLink = link
                    break
                }
            }

            // If no linked cell, use first column as title
            if titleIndex == nil {
                titleIndex = 0
            }

            guard let ti = titleIndex else { continue }
            let titleText = stripMarkdown(titleLink?.text ?? cells[ti])

            // Pass 2: collect remaining cells as subtitle
            var otherCells: [String] = []
            for (index, cell) in cells.enumerated() {
                if index == ti { continue }
                // Skip cells that are duplicates of the title link
                if let tl = titleLink, let link = extractLink(cell), link.url == tl.url {
                    continue
                }
                let cleaned = stripMarkdown(cell.trimmingCharacters(in: .whitespacesAndNewlines))
                if !cleaned.isEmpty {
                    otherCells.append(cleaned)
                }
            }

            let title = titleText

            rows.append(TableCardRow(
                title: title,
                link: titleLink,
                subtitle: otherCells.joined(separator: " · ")
            ))
        }

        return rows.isEmpty ? nil : rows
    }

    /// Split a table row line into cell strings.
    private static func parseCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Remove leading and trailing |
        let inner = trimmed.dropFirst().dropLast()
        return inner.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Strip inline markdown formatting (bold, italic, strikethrough, code) from a string.
    private static func stripMarkdown(_ text: String) -> String {
        var result = text
        // Bold+italic: ***text*** or ___text___
        result = result.replacingOccurrences(of: #"\*{3}(.+?)\*{3}"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"_{3}(.+?)_{3}"#, with: "$1", options: .regularExpression)
        // Bold: **text** or __text__
        result = result.replacingOccurrences(of: #"\*{2}(.+?)\*{2}"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"_{2}(.+?)_{2}"#, with: "$1", options: .regularExpression)
        // Italic: *text* or _text_
        result = result.replacingOccurrences(of: #"\*(.+?)\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\b_(.+?)_\b"#, with: "$1", options: .regularExpression)
        // Strikethrough: ~~text~~
        result = result.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)
        // Inline code: `text`
        result = result.replacingOccurrences(of: #"`(.+?)`"#, with: "$1", options: .regularExpression)
        return result
    }

    /// Normalize inline markdown tables where all rows appear on a single line
    /// (space-separated instead of newline-separated). Detects the separator
    /// pattern to determine column count, then splits into proper rows.
    private static func normalizeInlineTables(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Quick check: does this line contain a separator-like pattern?
            guard trimmed.contains("---|") else {
                result.append(line)
                continue
            }

            // Is the whole line just a separator row already?
            let isSeparatorOnly = trimmed.allSatisfy { "|: -".contains($0) }
            if isSeparatorOnly && trimmed.hasPrefix("|") {
                result.append(line)
                continue
            }

            // Find the separator to determine column count
            let sepPattern = #"\|(?:\s*:?-{2,}:?\s*\|)+"#
            guard let sepRegex = try? NSRegularExpression(pattern: sepPattern),
                  let sepMatch = sepRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let sepRange = Range(sepMatch.range, in: trimmed) else {
                result.append(line)
                continue
            }

            let separator = String(trimmed[sepRange])
            let columnCount = separator.components(separatedBy: "|")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .count

            guard columnCount > 0 else {
                result.append(line)
                continue
            }

            // Use regex to find all rows with exactly columnCount columns
            let rowPattern = "\\|(?:[^|]*\\|){\(columnCount)}"
            guard let rowRegex = try? NSRegularExpression(pattern: rowPattern) else {
                result.append(line)
                continue
            }

            let matches = rowRegex.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
            if matches.count >= 3 {
                // Collect non-table text before the first match
                if let firstRange = Range(matches[0].range, in: trimmed) {
                    let before = String(trimmed[trimmed.startIndex..<firstRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !before.isEmpty { result.append(before) }
                }
                // Add each row on its own line
                for match in matches {
                    if let range = Range(match.range, in: trimmed) {
                        result.append(String(trimmed[range]).trimmingCharacters(in: .whitespaces))
                    }
                }
                // Collect non-table text after the last match
                if let lastRange = Range(matches.last!.range, in: trimmed) {
                    let after = String(trimmed[lastRange.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !after.isEmpty { result.append(after) }
                }
            } else {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    /// Extract a markdown link `[text](url)` from a cell string.
    private static func extractLink(_ cell: String) -> ParsedLink? {
        let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)),
              let textRange = Range(match.range(at: 1), in: cell),
              let urlRange = Range(match.range(at: 2), in: cell) else {
            return nil
        }
        return ParsedLink(text: String(cell[textRange]), url: String(cell[urlRange]))
    }
}

/// Sheet background: on iOS 26+ let the system apply its default glass chrome;
/// on older iOS use ultraThinMaterial.
@available(iOS 16.0, *)
private struct SheetBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Don't override — iOS 26 sheets get liquid glass automatically.
            content
        } else if #available(iOS 16.4, *) {
            content
                .presentationBackground(.ultraThinMaterial)
        } else {
            content
        }
    }
}

/// Static glass card (for title pill and text input).
@available(iOS 15.0, macOS 13.0, *)
private struct GlassCardModifier: ViewModifier {
    var isSelected: Bool = false

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear, in: .rect(cornerRadius: 14))
                .tint(isSelected ? Color.blue.opacity(0.3) : nil)
        } else {
            content
                .background(
                    isSelected ? AnyShapeStyle(.blue.opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear, in: .rect(cornerRadius: 14))
                .tint(isSelected ? Color.blue.opacity(0.3) : nil)
        } else {
            content
                .background(
                    isSelected ? AnyShapeStyle(.blue.opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        #endif
    }
}

/// Interactive glass card for option buttons — has press feedback.
@available(iOS 15.0, macOS 13.0, *)
private struct InteractiveGlassCardModifier: ViewModifier {
    var isSelected: Bool = false

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 14))
                .tint(isSelected ? Color.blue.opacity(0.3) : nil)
        } else {
            content
                .background(
                    isSelected ? AnyShapeStyle(.blue.opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 14))
                .tint(isSelected ? Color.blue.opacity(0.3) : nil)
        } else {
            content
                .background(
                    isSelected ? AnyShapeStyle(.blue.opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        #endif
    }
}

/// Interactive glass circle for the close button.
@available(iOS 15.0, macOS 13.0, *)
private struct InteractiveGlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
        }
        #endif
    }
}
