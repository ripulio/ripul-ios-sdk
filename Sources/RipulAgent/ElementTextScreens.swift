#if os(iOS)
import SwiftUI

@MainActor
enum TextEditingTarget {
    case element(RipulTextAssignment), native(NativeTextTarget)
    private var liveElement: RipulTextAssignment? {
        guard case .element(let value) = self else { return nil }
        return RipulElementText.assignments.first { $0.id == value.id } ?? value
    }
    var label: String { switch self { case .element(let value): return value.label; case .native(let value): return value.heading } }
    var address: String { switch self { case .element(let value): return value.id; case .native(let value): return value.summary } }
    var text: String { switch self { case .element: return liveElement?.text ?? ""; case .native(let value): return value.text } }
    var source: String? { liveElement?.dataSource }
    var defaultToken: String? { liveElement?.defaultToken }
    var reference: RipulTextReference? {
        switch self {
        case .element(let value): return value.override ?? RipulElementText.legacyTargets[value.id]?.reference
        case .native(let value): return value.reference
        }
    }
    var token: String? {
        if case .token(let name) = reference { return name }
        return reference == nil ? defaultToken : nil
    }
    func set(_ reference: RipulTextReference?) throws {
        switch self {
        case .element(let value): try (liveElement ?? value).setReference(reference)
        case .native(let value):
            try RipulElementText.change { document in
                if let reference { _ = try RipulElementText.resolve(reference, document: document) }
                value.update(&document, reference: reference)
            }
        }
    }
}

@MainActor
struct TextPropertyRow: View {
    let target: TextEditingTarget
    @State private var version = 0
    var body: some View {
        let _ = version
        Button { TextEditorPresenter.present(target) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.label).font(.headline)
                    Text(target.text.isEmpty ? "Empty text" : target.text).lineLimit(2)
                    Text(target.source.map { "App data · " + $0 } ?? target.token.map { "Token · " + $0 }
                         ?? (target.reference == nil ? "App default" : "Individual override"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uiKitIdentifier("theme.text.property." + target.address)
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in version += 1 }
    }
}

@MainActor
private enum TextEditorPresenter {
    static func present(_ target: TextEditingTarget) {
        guard let root = RipulChrome.presentationRoot() else { return }
        let host = UIHostingController(rootView: TextEditorSheet(target: target))
        host.sheetPresentationController?.detents = [.large()]
        root.present(host, animated: true)
    }
}

@MainActor
private struct TextEditorSheet: View {
    let target: TextEditingTarget
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ElementTextEditor(target: target)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.uiKitIdentifier("theme.text.done") } }
        }
    }
}

@MainActor
struct ElementTextEditor: View {
    let target: TextEditingTarget
    @State private var version = 0
    @State private var wording = ""
    @State private var naming = false
    @State private var name = ""
    @State private var error: String?
    @State private var lease: UUID?

    var body: some View {
        let _ = version
        Form {
            Section("Property") {
                LabeledContent("Property", value: target.label)
                Text(target.text.isEmpty ? "Empty text" : target.text).textSelection(.enabled)
                    .uiKitIdentifier("theme.text.result")
                DisclosureGroup("Element details") { Text(target.address).font(.caption).textSelection(.enabled) }
            }
            if let source = target.source {
                Section("Value source") {
                    LabeledContent("Source", value: source)
                    Text("This value updates from app data. Use the app’s controls to change it.")
                }
            } else {
                Section {
                    LabeledContent("Assigned token", value: target.token ?? (target.reference == nil ? "App default" : "Custom text"))
                    Text(target.reference == nil ? "Author default" : "Individual override").foregroundStyle(.secondary)
                    NavigationLink("Choose another text token") {
                        TextTokenPicker { token in perform { try target.set(.token(token)) } }
                    }.uiKitIdentifier("theme.text.chooseToken")
                    TextField("Text for this element", text: $wording, axis: .vertical)
                        .uiKitIdentifier("theme.text.wording")
                    Button("Apply text to this element") { perform { try target.set(.text(wording)) } }
                        .uiKitIdentifier("theme.text.apply")
                    Button(target.defaultToken.map { "Use default: " + $0 } ?? "Use app text") {
                        perform { try target.set(nil); wording = target.text }
                    }.disabled(target.reference == nil).uiKitIdentifier("theme.text.reset")
                } header: { Text("Assignment") } footer: {
                    Text("Changes are saved in the unpublished theme draft and preview immediately.")
                }
                Section {
                    if let token = target.token {
                        NavigationLink("Open " + token) { TextTokenDefinitionScreen(name: token) }
                            .uiKitIdentifier("theme.text.openToken")
                    }
                    Button("Create a shared token from this text") { naming = true }
                        .uiKitIdentifier("theme.text.createToken")
                } header: { Text("Shared definition") } footer: {
                    Text("Editing a shared definition updates every element that uses it.")
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(target.label).navigationBarTitleDisplayMode(.inline)
        .alert("New shared text token", isPresented: $naming) {
            TextField("Token name", text: $name)
            Button("Create") {
                perform {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !RipulElementText.tokenNames.contains(trimmed) else { throw TextReferenceError.name }
                    try RipulElementText.setToken(trimmed, reference: .text(target.text))
                    try target.set(.token(trimmed)); name = ""
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .onAppear { wording = target.text; lease = RipulThemeEngine.remoteTheme?.beginEditing() }
        .onDisappear { if let lease { RipulThemeEngine.remoteTheme?.endEditing(lease) }; lease = nil }
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in version += 1 }
    }
    private func perform(_ action: () throws -> Void) { do { try action(); error = nil; version += 1 } catch { self.error = error.localizedDescription } }
}

@MainActor
struct TextTokenPicker: View {
    let select: (String) -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(RipulElementText.tokenNames.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search)
            || (RipulElementText.tokenText($0) ?? "").localizedCaseInsensitiveContains(search) }, id: \.self) { name in
            Button { select(name); dismiss() } label: {
                VStack(alignment: .leading) {
                    Text(name)
                    Text(RipulElementText.tokenText(name) ?? "Unresolved token").foregroundStyle(.secondary)
                }
            }.uiKitIdentifier("theme.text.pick." + name)
        }.searchable(text: $search).navigationTitle("Text tokens")
    }
}

@MainActor
struct TextTokenDefinitionScreen: View {
    let name: String
    var visited: Set<String> = []
    @State private var text = ""
    @State private var error: String?
    @State private var version = 0
    var body: some View {
        let _ = version
        Form {
            Section("Shared definition") {
                LabeledContent("Token", value: name)
                Text(RipulElementText.tokenText(name) ?? "Unresolved token").textSelection(.enabled)
                if case .token(let source) = RipulElementText.definition(name), !visited.contains(source), source != name {
                    NavigationLink("Open source: " + source) { TextTokenDefinitionScreen(name: source, visited: visited.union([name])) }
                }
                NavigationLink("Choose a source token") {
                    TextTokenPicker { source in perform { try RipulElementText.setToken(name, reference: .token(source)) } }
                }
                TextField("Shared wording", text: $text, axis: .vertical).uiKitIdentifier("theme.text.sharedWording")
                Button("Apply shared wording") { perform { try RipulElementText.setToken(name, reference: .text(text)) } }
                    .uiKitIdentifier("theme.text.sharedApply")
                if RipulElementText.defaults[name] != nil {
                    Button("Use shipped definition") { perform { try RipulElementText.setToken(name, reference: nil); text = RipulElementText.tokenText(name) ?? "" } }
                        .uiKitIdentifier("theme.text.sharedReset")
                }
            }
            Section {
                Text("Every element using this token, directly or through another token, receives this wording.")
                if let value = RipulElementText.tokenText(name), value.contains("{") {
                    Text("Keep named placeholders such as {count} when the wording needs live values.")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .onAppear { text = RipulElementText.tokenText(name) ?? "" }
            .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in version += 1 }
    }
    private func perform(_ action: () throws -> Void) { do { try action(); error = nil; version += 1 } catch { self.error = error.localizedDescription } }
}

@MainActor
public struct RipulTextLibraryScreen: View {
    @State private var version = 0
    @State private var search = ""
    public init() {}
    private var exceptions: [RipulTextAssignment] {
        NativeTextRuntime.current.elements.flatMap { element, properties in
            properties.keys.map { property in
                RipulElementText.assignments.first { $0.element == element && $0.property == property }
                ?? RipulTextAssignment(element: element, property: property, label: ThemeChangePresentation.readable(property), fallback: "")
            }
        }.sorted { $0.id < $1.id }
    }
    public var body: some View {
        let _ = version
        List {
            Section("Shared text tokens") {
                ForEach(RipulElementText.tokenNames.filter { matches($0 + " " + (RipulElementText.tokenText($0) ?? "")) }, id: \.self) { name in
                    NavigationLink { TextTokenDefinitionScreen(name: name) } label: {
                        VStack(alignment: .leading) { Text(name); Text(RipulElementText.tokenText(name) ?? "Unresolved token").foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Individual overrides") {
                ForEach(exceptions.filter { matches($0.id + " " + $0.text) }) { item in
                    NavigationLink { ElementTextEditor(target: .element(item)) } label: {
                        VStack(alignment: .leading) { Text(ThemeChangePresentation.readable(item.element)); Text(item.text).foregroundStyle(.secondary) }
                    }
                }
                ForEach(NativeTextRuntime.current.labels) { item in
                    NavigationLink(item.selector.summary) { ElementTextEditor(target: .native(.label(item.selector))) }
                }
                ForEach(NativeTextRuntime.current.tabBarItemTitles.keys.sorted(), id: \.self) { id in
                    NavigationLink(id) { ElementTextEditor(target: .native(.tabTitle(id))) }
                }
            }
        }.navigationTitle("Text").searchable(text: $search)
            .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in version += 1 }
    }
    private func matches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }
}
#endif
