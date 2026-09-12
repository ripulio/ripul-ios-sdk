#if os(iOS)
import SwiftUI
import CryptoKit

@MainActor
final class ThemeManagementModel: ObservableObject {
    @Published var text = ""
    @Published var sourceDirty = false
    @Published var busy = false
    @Published var error: String?
    @Published var published = false
    @Published var version = 0
    @Published private(set) var undoTitle: String?
    private var undoDraft: (before: Data, after: Data)?
    private(set) var baseline = Data()
    private(set) var etag: String?
    let remote: RipulRemoteThemeClient?
    let publisher: RipulThemePublisher
    let themeID: String?
    private var lease: UUID?
    private var saveTask: Task<Void, Never>?
    private let draftURL: URL
    private var started = false
    private let capture: @MainActor (Data?) throws -> Data
    private struct Draft: Codable { let text: String; let baseline: Data; let etag: String? }

    convenience init(baseURL: URL, tokenProvider: @escaping () -> String?) {
        self.init(baseURL: baseURL, tokenProvider: tokenProvider, remote: RipulThemeEngine.remoteTheme,
                  capture: { try RipulThemeEngine.themeDocumentForPublishing(over: $0) })
    }
    init(baseURL: URL, tokenProvider: @escaping () -> String?,
         remote: RipulRemoteThemeClient?,
         publisher: RipulThemePublisher? = nil, draftURL: URL? = nil,
         capture: @escaping @MainActor (Data?) throws -> Data) {
        self.remote = remote
        self.capture = capture
        self.publisher = publisher ?? RipulThemePublisher(baseURL: baseURL, tokenProvider: tokenProvider)
        let url = remote?.url
        themeID = url?.deletingLastPathComponent().path == "/v1/app-themes" ? url?.lastPathComponent : nil
        self.draftURL = draftURL ?? Self.draftLocation(for: url)
    }

    private static func draftLocation(for url: URL?) -> URL {
        let key = SHA256.hash(data: Data((url?.absoluteString ?? "local-theme").utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ripul/ThemeDrafts/" + key + ".json")
    }

    /// The explorer saves into the SAME durable draft as Solution Management, even
    /// when that screen has never been opened. Keep its reviewed baseline and extras.
    static func saveNativeTextDraft(target: NativeTextTarget, text: String?,
                                  remote: RipulRemoteThemeClient? = nil,
                                  draftURL: URL? = nil) throws {
        try saveTextMutation({ target.update(&$0, text: text) }, remote: remote, draftURL: draftURL)
    }

    static func saveTextMutation(_ edit: (inout NativeTextTheme) throws -> Void,
                                remote: RipulRemoteThemeClient? = nil, draftURL: URL? = nil) throws {
        guard let remote = remote ?? RipulThemeEngine.remoteTheme else { throw NativeTextDraftError.noRemoteTheme }
        let destination = draftURL ?? draftLocation(for: remote.url)
        let existing: Draft?
        if FileManager.default.fileExists(atPath: destination.path) {
            existing = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: destination))
        } else { existing = nil }
        let document = try existing.map { Data($0.text.utf8) } ?? RipulThemeEngine.themeDocumentForPublishing()
        var native = try NativeTextTheme.decode(document: document)
        try edit(&native)
        try RipulElementText.validate(native)
        let changed = try native.merging(into: document, baseline: existing?.baseline ?? remote.authoritativeDocument)
        _ = try RipulThemeManifest(data: changed, etag: nil)
        let draft = Draft(text: String(decoding: changed, as: UTF8.self),
                          baseline: existing?.baseline ?? remote.authoritativeDocument,
                          etag: existing.map { $0.etag } ?? remote.authoritativeETag)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: destination, options: .atomic)
        NativeTextRuntime.adopt(native)
        NotificationCenter.default.post(name: .ripulThemeDidChange, object: nil)
    }

    var data: Data { Data(text.utf8) }
    static func canonical(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    var hasChanges: Bool { Self.canonical(data) != Self.canonical(baseline) }
    var canPublish: Bool { themeID != nil && !busy && !sourceDirty && hasChanges && Self.canonical(data) != nil }

    func start() {
        guard !started else { return }; started = true
        lease = remote?.beginEditing()
        do {
            baseline = try remote?.authoritativeDocument ?? capture(nil)
            etag = remote?.authoritativeETag
            if let bytes = try? Data(contentsOf: draftURL), let draft = try? JSONDecoder().decode(Draft.self, from: bytes) {
                text = draft.text; baseline = draft.baseline; etag = draft.etag
                sourceDirty = true
                applySource()
            } else {
                text = try RipulThemeManifest(data: capture(nil), etag: etag).formatted
            }
        } catch { self.error = error.localizedDescription }
    }
    func close() {
        saveTask?.cancel(); saveNow()
        if let lease { remote?.endEditing(lease) }; lease = nil; started = false
    }
    func sourceChanged(_ value: String) {
        guard !busy else { return }
        text = value; sourceDirty = true; published = false; saveSoon()
    }
    func applySource() {
        guard !busy else { return }
        do {
            _ = try RipulThemeManifest(data: data, etag: etag)
            guard let remote else { throw RipulThemePublishError.invalidResponse }
            // Keep the complete draft, including fields outside the engine's vocabulary.
            sourceDirty = true
            try remote.preview(data)
            sourceDirty = false; error = nil; published = false; version &+= 1; saveSoon()
        } catch { self.error = error.localizedDescription }
    }
    func captureChanges() {
        guard started, !busy, !sourceDirty else { return }
        do {
            let updated = try RipulThemeManifest(data: capture(data), etag: etag).formatted
            guard Self.canonical(Data(updated.utf8)) != Self.canonical(data) else { return }
            text = updated
            published = false; version &+= 1; saveSoon()
        } catch { self.error = error.localizedDescription }
    }
    func reloadServer() async {
        guard let themeID else { return }; busy = true; defer { busy = false }
        do {
            guard let fresh = try await publisher.load(id: themeID) else { throw RipulThemePublishError.http(404) }
            try remote?.acceptPublication(fresh)
            baseline = fresh.data; etag = fresh.etag; text = fresh.formatted
            sourceDirty = false; published = false; error = nil; version &+= 1; saveNow()
        } catch { self.error = error.localizedDescription }
    }
    var canUndoDiscard: Bool {
        !busy && !sourceDirty && undoDraft.map { Self.canonical(data) == Self.canonical($0.after) } == true
    }
    @discardableResult func discard(_ change: ThemeDocumentChanges.Change, title: String) -> Bool {
        guard !busy, !sourceDirty else { return false }
        do {
            let previous = data
            let updated = try ThemeDocumentChanges.reverting(change, baseline: baseline, draft: previous)
            try replaceReviewedDraft(updated)
            undoDraft = (previous, updated); undoTitle = title
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func undoDiscard() {
        guard canUndoDiscard, let undoDraft else { return }
        do {
            try replaceReviewedDraft(undoDraft.before)
            self.undoDraft = nil; undoTitle = nil
        } catch { self.error = error.localizedDescription }
    }
    private func replaceReviewedDraft(_ document: Data) throws {
        let manifest = try RipulThemeManifest(data: document, etag: etag)
        guard let remote else { throw RipulThemePublishError.invalidResponse }
        // Block synchronous theme notifications until validation and adoption finish.
        sourceDirty = true; defer { sourceDirty = false }
        try remote.preview(document)
        text = manifest.formatted; error = nil; published = false; version &+= 1
        saveNow()
    }
    func publish(reviewed: Data? = nil) async {
        guard canPublish, let themeID else { return }
        let sent = reviewed ?? data
        guard Self.canonical(sent) == Self.canonical(data) else {
            error = ThemeDocumentChanges.ReviewError.changed.localizedDescription; return
        }
        busy = true; defer { busy = false }
        do {
            // A first-launch fallback may predate the first public fetch. Only adopt its
            // version if that exact baseline is still published; otherwise require review.
            if etag == nil, let server = try await publisher.load(id: themeID) {
                guard Self.canonical(server.data) == Self.canonical(baseline) else { throw RipulThemePublishError.conflict }
                etag = server.etag
            }
            guard Self.canonical(sent) == Self.canonical(data) else { throw ThemeDocumentChanges.ReviewError.changed }
            try remote?.preview(sent) // host schema validation BEFORE any server write
            let result = try await publisher.publish(id: themeID, data: sent, replacing: etag)
            try remote?.acceptPublication(result)
            baseline = result.data; etag = result.etag; text = result.formatted
            sourceDirty = false; published = true; error = nil; version &+= 1; saveNow()
        } catch { self.error = error.localizedDescription; saveNow() }
    }
    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }; self?.saveNow()
        }
    }
    private func saveNow() {
        guard !baseline.isEmpty else { return }
        do {
            if !hasChanges { try? FileManager.default.removeItem(at: draftURL); return }
            try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Draft(text: text, baseline: baseline, etag: etag)).write(to: draftURL, options: .atomic)
        } catch { self.error = "Could not save this draft on the phone: " + error.localizedDescription }
    }
}

/// Native solution-management surface; uses the same registered scopes and mutators as
/// View Explorer and the host's in-app theme editor. No visible-view scan is needed.
@available(iOS 16.0, *)
@MainActor
public struct RipulThemeManagementScreen: View {
    @StateObject private var model: ThemeManagementModel
    @State private var search = ""
    @State private var textOnly = false
    @State private var showSource = false
    @State private var reviewPublish = false
    @State private var confirmReload = false
    @Environment(\.dismiss) private var dismiss

    public init(baseURL: URL, tokenProvider: @escaping () -> String?) {
        _model = StateObject(wrappedValue: ThemeManagementModel(baseURL: baseURL, tokenProvider: tokenProvider))
    }
    private struct Element: Identifiable {
        let kind: RipulStyleKind; let scope: RipulThemeScope
        var id: String { kind.name + "/" + scope.id }
        var subtitle: String { (kind.path + [kind.label] + scope.path).joined(separator: " › ") }
        var text: String {
            let resolved = RipulThemeEngine.resolvedStyle(kind: kind.name, element: scope.id)
            return kind.knobs.compactMap { knob -> String? in
                guard case .text(let fallback, _) = knob.kind else { return nil }
                let value = resolved[knob.key]?.string ?? fallback
                return value.isEmpty ? nil : value
            }.joined(separator: " · ")
        }
    }
    private var elements: [Element] {
        var items: [Element] = []
        for kind in RipulThemeEngine.styleKinds {
            if textOnly && !kind.knobs.contains(where: { if case .text = $0.kind { return true }; return false }) { continue }
            for scope in kind.scopes {
                let item = Element(kind: kind, scope: scope)
                let searchable = [scope.label, scope.id, item.subtitle, item.text]
                if search.isEmpty || searchable.contains(where: { $0.localizedCaseInsensitiveContains(search) }) { items.append(item) }
            }
        }
        return items.sorted { ($0.subtitle + $0.scope.label).localizedStandardCompare($1.subtitle + $1.scope.label) == .orderedAscending }
    }
    private var nativeElements: [NativeTabTitleTheme.Element] {
        NativeTabTitleTheme.elements.filter { item in
            search.isEmpty || [item.id, item.title, "Tab bar title"].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    private var labelElements: [NativeLabelTheme.Element] {
        NativeLabelTheme.elements.filter { item in
            search.isEmpty || [item.selector.summary, item.text].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    public var body: some View {
        NavigationStack { content }
            .onAppear { NativeLabelTheme.discoverEditableLabels(); model.start() }
            .onDisappear { model.close() }
            .interactiveDismissDisabled(model.busy)
    }
    @ViewBuilder private var content: some View {
        let _ = model.version
        let labels = labelElements
        List {
            Section {
                Text(model.published ? "Published to server" : model.hasChanges ? "Unpublished draft" : "No unpublished changes")
                    .font(.headline)
                Text("Edits preview in this app. Publish makes them available to apps using this theme on their next refresh.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.themeID == nil { Text("Publishing is not configured for this app.").font(.footnote).foregroundStyle(.secondary) }
                if let error = model.error { Text(error).foregroundStyle(.red).font(.footnote).textSelection(.enabled) }
                Button { reviewPublish = true } label: { Label("Review & Publish", systemImage: "icloud.and.arrow.up") }
                    .disabled(!model.canPublish).accessibilityIdentifier("ThemeManagement.reviewPublish")
                if model.remote != nil {
                    Button { showSource = true } label: { Label("Theme document", systemImage: "doc.text") }
                        .disabled(model.busy).accessibilityIdentifier("ThemeManagement.document")
                }
                if model.sourceDirty { Text("Apply the edits in Theme document before editing elements or publishing.").font(.footnote) }
            }
            Section {
                NavigationLink("Text tokens and individual overrides") { RipulTextLibraryScreen() }
                    .disabled(model.busy || model.sourceDirty)
                Toggle("Text elements only", isOn: $textOnly).accessibilityIdentifier("ThemeManagement.textOnly")
                ForEach(elements) { item in
                    NavigationLink {
                        ThemeManagedElementScreen(kind: item.kind, scope: item.scope, textOnly: textOnly)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.scope.label)
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                            if !item.text.isEmpty { Text(item.text).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    .disabled(model.busy || model.sourceDirty)
                    .accessibilityIdentifier("ThemeManagement.element." + item.id)
                }
                ForEach(nativeElements) { item in
                    NavigationLink {
                        Form { NativeTextFields(target: .tabTitle(item.id), savesExplicitly: false) }
                            .navigationTitle("Tab title").navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title.isEmpty ? "Untitled tab" : item.title)
                            Text("Tab bar · " + item.id).font(.caption).foregroundStyle(.secondary)
                            if item.ambiguous { Text("Identifier is used by more than one tab item.").font(.caption).foregroundStyle(.secondary) }
                            else if !item.mounted { Text("This tab is not currently loaded.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(model.busy || model.sourceDirty || item.ambiguous)
                    .accessibilityIdentifier("ThemeManagement.nativeText." + item.id)
                }
                ForEach(labels) { item in
                    NavigationLink {
                        Form { NativeTextFields(target: .label(item.selector), savesExplicitly: false) }
                            .navigationTitle("Label text").navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text.isEmpty ? "Empty label" : item.text).lineLimit(2)
                            Text(item.selector.summary).font(.caption).foregroundStyle(.secondary)
                            if item.ambiguous { Text("More than one label matches this target.").font(.caption).foregroundStyle(.secondary) }
                            else if !item.mounted { Text("This label is not currently loaded.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(model.busy || model.sourceDirty || item.ambiguous)
                    .accessibilityIdentifier("ThemeManagement.nativeLabel." + item.id)
                }
                if elements.isEmpty && nativeElements.isEmpty && labels.isEmpty { Text(search.isEmpty ? "No theme elements match this filter." : "No matching elements.").foregroundStyle(.secondary) }
            } header: { Text("Elements (\(elements.count + nativeElements.count + labels.count))") }
        }
        .searchable(text: $search, prompt: "Find an element or its text")
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Reload server version", role: .destructive) { confirmReload = true }
                        .disabled(model.themeID == nil || model.busy)
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.close(); dismiss() }.disabled(model.busy) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in model.captureChanges() }
        .sheet(isPresented: $showSource) { sourceEditor }
        .sheet(isPresented: $reviewPublish) { ThemePublishReviewScreen(model: model) }
        .confirmationDialog("Replace this draft with the server version?", isPresented: $confirmReload, titleVisibility: .visible) {
            Button("Reload and replace draft", role: .destructive) { Task { await model.reloadServer() } }
        }
    }
    private var sourceEditor: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Complete theme document").font(.headline)
                TextEditor(text: Binding(get: { model.text }, set: { model.sourceChanged($0) }))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ThemeManagement.source")
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }.padding()
            .navigationTitle("Theme document").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { showSource = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply to app") { model.applySource(); if !model.sourceDirty { showSource = false } }
                        .accessibilityIdentifier("ThemeManagement.applySource")
                }
            }
        }
    }
}

@available(iOS 16.0, *)
private struct ThemeManagedElementScreen: View {
    let kind: RipulStyleKind
    let scope: RipulThemeScope
    let textOnly: Bool
    @State private var version = 0
    var body: some View {
        let _ = version
        if !textOnly {
            RipulScopeOverridesScreen(kind: kind.name, element: scope.id, title: scope.label)
        } else {
            Form {
                Section {
                    RipulStyleKnobRows(knobs: kind.knobs.filter { if case .text = $0.kind { return true }; return false },
                        working: RipulThemeEngine.current.styleOverrides[kind.name]?[scope.id] ?? [:],
                        inherited: RipulThemeEngine.resolvedStyle(kind: kind.name, element: scope.id),
                        onChange: { RipulThemeEngine.setOverrides(kind: kind.name, element: scope.id, knobs: $0) })
                } footer: { Text("These are the same values used by the in-app editor and View Explorer.") }
            }
            .navigationTitle(scope.label).navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in version &+= 1 }
        }
    }
}
#endif
