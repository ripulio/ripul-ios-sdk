import SwiftUI
import RipulThemeKit
import MermaidLayout
import MermaidRender

/// A serialized, bounded worker: no parsing/layout on the scrolling thread and
/// no web process per diagram. The engine also bounds text, edges and canvas size.
actor NativeMermaidRenderer {
    static let shared = NativeMermaidRenderer()
    struct Result: @unchecked Sendable {
        let image: PlatformImage?
        let description: String
        let problem: String?
    }
    private final class Box: NSObject {
        let value: Result
        init(_ value: Result) { self.value = value }
    }
    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 24
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func render(source: String, theme: DiagramTheme, textScale: Double) -> Result {
        let key = "\(theme.fingerprint)|\(textScale)|\(source)" as NSString
        if let value = cache.object(forKey: key) { return value.value }
        guard !Task.isCancelled else { return Result(image: nil, description: "", problem: nil) }
        guard source.utf8.count <= 32_000 else {
            return Result(image: nil, description: "", problem: "This diagram is too large to preview. Its source is below.")
        }
        // A partial flowchart must not look like a complete, authoritative one.
        // The parser reports statements it dropped, including incomplete arrows.
        let diagnostics = MermaidParser.diagnose(source)
        let value: Result
        if let diagnostic = diagnostics.first {
            value = Result(image: nil, description: "", problem:
                (diagnostic.line.map { "Line \($0): " } ?? "") + diagnostic.message)
        } else if !Self.fitsPreview(source: source, theme: theme, textScale: textScale) {
            value = Result(image: nil, description: "", problem: "This diagram is too large to preview. Its source is below.")
        } else if let image = MermaidRenderer.image(source: source, theme: theme,
                                                    spacing: DiagramSpacing(textScale: textScale)) {
            value = Result(image: image, description: MermaidRenderer.altText(source: source) ?? "Mermaid diagram", problem: nil)
        } else {
            value = Result(image: nil, description: "", problem: "This diagram cannot be previewed. Its source is below.")
        }
        let cost = source.utf8.count + Int((value.image?.size.width ?? 0) * (value.image?.size.height ?? 0) * 36)
        cache.setObject(Box(value), forKey: key, cost: cost)
        return value
    }

    private static func fitsPreview(source: String, theme: DiagramTheme, textScale: Double) -> Bool {
        // Inspect vector geometry before the engine allocates a Retina bitmap.
        // Keep generous headroom for font/caption differences between backends.
        guard let scene = MermaidRenderer.renderScene(source: source, theme: theme,
                                                       spacing: DiagramSpacing(textScale: textScale)) else { return false }
        let size = scene.size
        return size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width < 2800 && size.height < 2800 && size.width * size.height < 1_000_000
    }
}

struct NativeMarkdownMermaid: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0
    @NativeRowState("mermaid.source") private var showsSource = false
    @NativeRowState("mermaid.layout") private var layoutSignature = ""
    @State private var result: NativeMermaidRenderer.Result?
    @State private var resultKey = ""
    @State private var expanded: NativeMermaidSnapshot?
    @State private var copied = false

    var body: some View {
        let theme = Self.theme(dark: colorScheme == .dark)
        let key = "\(theme.fingerprint)|\(textScale)|\(source)"
        let current = resultKey == key ? result : nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text("Diagram").font(.ripul(.caption, weight: .semibold))
                    .foregroundStyle(.ripul(.textSecondary))
                Spacer(minLength: 4)
                Button { showsSource.toggle() } label: {
                    Image(systemName: showsSource ? "diagram" : "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityLabel(showsSource ? "Show diagram" : "Show diagram source")
                .accessibilityIdentifier("NativeMarkdown.mermaid.source")
                Button {
                    NativeMarkdownClipboard.copy(source)
                    copied = true
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .accessibilityLabel(copied ? "Copied diagram source" : "Copy diagram source")
                .accessibilityIdentifier("NativeMarkdown.mermaid.copy")
                if let current, current.image != nil {
                    Button { expanded = NativeMermaidSnapshot(source: source, result: current) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Expand diagram")
                    .accessibilityIdentifier("NativeMarkdown.mermaid.expand")
                }
            }
            .font(.ripulIcon(.callout))
            .buttonStyle(.borderless)
            if showsSource {
                NativeMarkdownSourceBlock(source: source, language: "mermaid")
            } else if let current, let image = current.image {
                Button { expanded = NativeMermaidSnapshot(source: source, result: current) } label: {
                    Self.image(image).resizable().scaledToFit()
                        .frame(maxWidth: image.size.width, maxHeight: min(320, image.size.height))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(current.description)
                .accessibilityHint("Opens a larger diagram you can zoom and pan")
                .accessibilityIdentifier("NativeMarkdown.mermaid.preview")
            } else if let current {
                Text(current.problem ?? "Diagram source")
                    .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    .accessibilityIdentifier("NativeMarkdown.mermaid.problem")
                NativeMarkdownSourceBlock(source: source, language: "mermaid")
            } else {
                Text("Drawing diagram…")
                    .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .padding(10)
        .background(Color.ripul(.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.ripul(.separator)))
        .ripulSheet(item: $expanded) { NativeMermaidSheet(snapshot: $0) }
        .task(id: key) {
            // Coalesce streamed edits. Task cancellation prevents an older result
            // overwriting a newer source or a different appearance.
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let rendered = await NativeMermaidRenderer.shared.render(source: source, theme: theme, textScale: textScale)
            guard !Task.isCancelled else { return }
            result = rendered
            resultKey = key
            copied = false
            layoutSignature = String(key.hashValue)
        }
    }

    @MainActor static func theme(dark: Bool) -> DiagramTheme {
        #if os(iOS)
        let family = UIFont.ripul(.body).familyName
        #else
        let family: String? = nil
        #endif
        return DiagramTheme(ink: .ripul(.text), secondaryTextColor: .ripul(.textSecondary),
                            tertiaryTextColor: .ripul(.textSecondary), canvas: .ripul(.surface),
                            accent: .ripul(.info), hairline: .ripul(.separator), prefersDark: dark,
                            palette: [.ripul(.info), .ripul(.success), .ripul(.warning), .ripul(.danger)],
                            fontFamily: family)
    }

    static func image(_ image: PlatformImage) -> Image {
        #if os(iOS)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}

private struct NativeMermaidSnapshot: Identifiable {
    let id = UUID()
    let source: String
    let result: NativeMermaidRenderer.Result
}

private struct NativeMermaidSheet: View {
    let snapshot: NativeMermaidSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var showsSource = false
    @State private var copied = false
    #if os(macOS)
    @State private var scale = 1.0
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if showsSource {
                    ScrollView { NativeMarkdownSourceBlock(source: snapshot.source, language: "mermaid").padding() }
                } else if let image = snapshot.result.image {
                    #if os(iOS)
                    NativeChatZoomableImage(image: image, label: snapshot.result.description)
                        .accessibilityIdentifier("NativeMarkdown.mermaid.zoom")
                    #else
                    ScrollView([.horizontal, .vertical]) {
                        NativeMarkdownMermaid.image(image).resizable()
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                    }
                    .safeAreaInset(edge: .bottom) { Slider(value: $scale, in: 0.25...4).padding().accessibilityLabel("Diagram zoom") }
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Diagram")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(showsSource ? "Diagram" : "Source") { showsSource.toggle() }
                    Button(copied ? "Copied" : "Copy source") {
                        NativeMarkdownClipboard.copy(snapshot.source)
                        copied = true
                    }
                }
            }
        }
        .frame(minWidth: 280, minHeight: 320)
    }
}
