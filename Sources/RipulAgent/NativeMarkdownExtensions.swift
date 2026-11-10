import SwiftUI
import RipulThemeKit

/// Dispatch after MarkdownUI has parsed the complete document. The caller scopes
/// every fence by its full block path, including identical fences in lists/quotes.
struct NativeMarkdownFencedBlock: View {
    let source: String
    let language: String?

    @ViewBuilder var body: some View {
        switch language?.lowercased() {
        case "mermaid": NativeMarkdownMermaid(source: source)
        case "steps": NativeMarkdownSteps(source: source)
        case "report": NativeMarkdownReportBlock(source: source)
        default:
            if let custom = NativeMarkdownBlocks.view(for: language, source: source) {
                custom
            } else {
                NativeMarkdownSourceBlock(source: source, language: language)
            }
        }
    }
}

/// Fenced blocks a host app draws itself, by language: the chat knows nothing of
/// the app's own views. Ripul's live Mac window card is ```mac-window
/// (ripul-native-app's MacWindowCard). A language nobody registered is code.
@MainActor
public enum NativeMarkdownBlocks {
    private static var views: [String: (String) -> AnyView] = [:]

    public static func register(_ language: String, view: @escaping (String) -> AnyView) {
        views[language.lowercased()] = view
    }

    static func view(for language: String?, source: String) -> AnyView? {
        guard let language, let make = views[language.lowercased()] else { return nil }
        return make(source)
    }
}

struct NativeMarkdownSourceBlock: View {
    let source: String
    var language: String? = nil
    var body: some View {
        NativeToolCodeBlock(text: source, title: language,
                            titleFont: .ripul(.caption, weight: .semibold),
                            syntax: language.map { .language($0.lowercased()) } ?? .automatic,
                            compact: true, preservesSource: true)
    }
}

struct NativeMarkdownSteps: View {
    let source: String
    @NativeRowState("steps.expanded") private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // The web steps contract is literal text, not a second Markdown
            // document: keep code, HTML and dollar signs exactly as authored.
            Text(source.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.ripul(.callout))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("NativeMarkdown.steps.body")
                .padding(.top, 6)
        } label: {
            Text("How this is worked out")
                .font(.ripul(.callout))
                .foregroundStyle(.ripul(.textSecondary))
        }
        .accessibilityIdentifier("NativeMarkdown.steps")
    }
}

enum NativeMarkdownClipboard {
    @MainActor static func copy(_ source: String) {
        #if os(iOS)
        UIPasteboard.general.string = source
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        #endif
    }
}
