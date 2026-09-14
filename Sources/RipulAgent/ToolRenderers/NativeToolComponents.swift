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
            Text(title).font(.headline)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared source/output surface, just as ToolOutputBlock is shared on the web.
/// Large output is progressively revealed; the full text remains copyable.
struct NativeToolCodeBlock: View {
    let text: String
    var numbered = false
    var firstLine = 1
    var syntax: NativeToolCodeSyntax?
    var readLineNumbers = false
    var commandBreakLines: [Int] = []
    var commandPipeLines: [Int] = []
    var identifier = "NativeTool.code"
    @State private var visibleLines = 80
    @State private var wraps = false
    @State private var highlighted: AttributedString?
    @State private var highlightedRequest: NativeHighlightRequest?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let clean = syntax == nil || syntax == .automatic ? ToolValue.cleanTerminal(text) : text
        let lines = clean.components(separatedBy: "\n")
        let visible = lines.prefix(visibleLines).joined(separator: "\n")
        let request = NativeHighlightRequest(source: visible, language: syntax?.language ?? "plaintext", dark: colorScheme == .dark, readLineNumbers: readLineNumbers)
        let attributed = highlightedRequest == request ? (highlighted ?? AttributedString(visible)) : AttributedString(visible)
        let colouredLines = NativeSourceHighlighting.lines(attributed)
        let sectionStarts = [0] + Set(commandBreakLines.filter { $0 > 0 && $0 < colouredLines.count }).sorted()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(lines.count) \(lines.count == 1 ? "line" : "lines")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Wrap", isOn: $wraps)
                    .toggleStyle(.switch).fixedSize().font(.caption)
                    .accessibilityIdentifier("\(identifier).wrap")
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = clean
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(clean, forType: .string)
                    #endif
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .font(.caption).accessibilityIdentifier("\(identifier).copy")
            }
            if numbered {
                wrapping {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.prefix(visibleLines).enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(firstLine + index)").foregroundStyle(.secondary).frame(minWidth: 28, alignment: .trailing)
                                Text(line.isEmpty ? AttributedString(" ") : index < colouredLines.count ? colouredLines[index] : AttributedString(line))
                                    .textSelection(.enabled).fixedSize(horizontal: !wraps, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(.caption, design: .monospaced))
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
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
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
                                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: !wraps, vertical: true)
                                .accessibilityIdentifier("\(identifier).part.\(index)")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
            } else {
                wrapping {
                    Text(attributed)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: !wraps, vertical: true)
                        .accessibilityIdentifier(identifier)
                }
            }
            if lines.count > visibleLines {
                Button("Show more (\(lines.count - visibleLines) lines remaining)") { visibleLines += 200 }.font(.callout)
            }
        }
        .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .task(id: request) {
            let result = await NativeSourceHighlighting.shared.attributed(request)
            guard !Task.isCancelled else { return }
            highlighted = result
            highlightedRequest = request
        }
    }

    /// Scroll the text only, keeping its toolbar and command dividers in view.
    @ViewBuilder private func wrapping<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if wraps {
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
    var identifier = "NativeTool.value"
    var textSyntax: NativeToolCodeSyntax?
    @State private var visibleItems = 40

    var body: some View { content(value) }

    private func content(_ value: CmsJSON) -> AnyView {
        switch value {
        case .string(let text):
            if text.contains("\n") || (textSyntax != nil && !text.isEmpty) {
                return AnyView(NativeToolCodeBlock(text: text, syntax: textSyntax, identifier: identifier))
            }
            return AnyView(Text(ToolValue.cleanTerminal(text.isEmpty ? "Empty text" : text)).textSelection(.enabled).accessibilityIdentifier(identifier))
        case .number(let number): return AnyView(Text(CmsJSON.number(number).displayString).monospacedDigit().textSelection(.enabled))
        case .bool(let yes): return AnyView(Label(yes ? "Yes" : "No", systemImage: yes ? "checkmark.circle" : "minus.circle"))
        case .null: return AnyView(Text("No value").foregroundStyle(.secondary))
        case .array(let items):
            if items.isEmpty { return AnyView(Text("None").foregroundStyle(.secondary)) }
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.prefix(visibleItems).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                        NativeToolValueView(value: item, textSyntax: textSyntax)
                    }
                    if index < items.count - 1 { Divider() }
                }
                if items.count > visibleItems { Button("Show more (\(items.count - visibleItems) remaining)") { visibleItems += 100 } }
            })
        case .object(let object):
            if let source = NativeToolImage.source(object) { return AnyView(NativeToolImage(source: source)) }
            if object.isEmpty { return AnyView(Text("None").foregroundStyle(.secondary)) }
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                ForEach(object.keys.sorted(), id: \.self) { key in
                    if let item = object[key] {
                        if item.objectValue != nil || item.toolArray != nil {
                            DisclosureGroup(ToolValue.title(key)) { NativeToolValueView(value: item, textSyntax: textSyntax).padding(.top, 8) }
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ToolValue.title(key)).font(.caption).foregroundStyle(.secondary)
                                if let raw = item.stringValue, let url = URL(string: raw), ["https", "http"].contains(url.scheme) {
                                    Link(raw, destination: url).textSelection(.enabled)
                                } else {
                                    NativeToolValueView(value: item, textSyntax: ["stdout", "stderr", "output", "text", "content"].contains(key) ? textSyntax : nil)
                                }
                            }
                        }
                    }
                }
            })
        }
    }
}

struct NativeToolParameters: View {
    let args: [String: CmsJSON]
    var excluding: Set<String> = []
    var title = "Parameters"
    var body: some View {
        let fields = args.filter { !excluding.contains($0.key) && $0.value != .null }
        if !fields.isEmpty {
            DisclosureGroup(title) { NativeToolValueView(value: .object(fields)).padding(.top, 8) }
        }
    }
}

struct NativeToolResultView: View {
    let content: NativeToolContent
    var title = "Result"
    var textSyntax: NativeToolCodeSyntax?
    var body: some View {
        NativeToolSection(title: title) {
            if let output = content.output { NativeToolValueView(value: output, identifier: "ToolCallDetails.result", textSyntax: textSyntax) }
            else if content.running { ProgressView("Waiting for result…") }
            else { Text("No output was recorded.").foregroundStyle(.secondary) }
        }
    }
}

struct NativeToolPath: View {
    let path: String
    var body: some View {
        if !path.isEmpty {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text((path as NSString).lastPathComponent).font(.headline)
                    Text(path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } icon: { Image(systemName: "doc.text").foregroundStyle(.secondary) }
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
            .sheet(isPresented: $zoomed) {
                NavigationStack { ScrollView([.horizontal, .vertical]) { picture.padding() }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { zoomed = false } } }
                }
            }
    }
}
