#if os(iOS)
import SwiftUI

// ---------------------------------------------------------------------------
// Native SITE KEY ↔ CONTEXT assignment.
//
// A solution context only reaches real sessions once a site key allows it, so
// this screen is the other half of the contexts editor: pick which contexts a
// key's sessions may enter, which one they boot into, and (optionally) which
// named app surface resolves to which context.
//
// The three fields are ONE unit server-side and are validated together, so the
// pickers here constrain to the allowed set rather than letting the developer
// build a triple the server will refuse — and a refusal is still shown
// verbatim, because the server is the authority, not this form.
// ---------------------------------------------------------------------------

@MainActor
final class RipulSiteKeysModel: ObservableObject {
    @Published private(set) var siteKeys: [RipulSiteKeySummary] = []
    @Published private(set) var contexts: [RipulSolutionContext] = []
    @Published var loading = false
    @Published var errorMessage: String?

    private let siteKeysClient: RipulSiteKeysClient
    private let contextsClient: RipulSolutionContextsClient

    init(siteKeysClient: RipulSiteKeysClient, contextsClient: RipulSolutionContextsClient) {
        self.siteKeysClient = siteKeysClient
        self.contextsClient = contextsClient
    }

    /// Contexts are loaded alongside the keys so the editor can show names
    /// rather than raw ids — an id-only picker is unusable for assignment.
    func load() async {
        loading = true
        errorMessage = nil
        do {
            async let keys = siteKeysClient.list()
            async let ctxs = contextsClient.list()
            siteKeys = try await keys
            contexts = try await ctxs
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func name(forContextId id: String) -> String {
        contexts.first { $0.id == id }?.name ?? id
    }

    func save(
        key: RipulSiteKeySummary,
        allowed: [String],
        defaultId: String?,
        surfaceMap: [String: String]
    ) async -> Bool {
        do {
            _ = try await siteKeysClient.updateContextTriple(
                id: key.id,
                allowedSolutionContextIds: allowed,
                defaultSolutionContextId: defaultId,
                surfaceContextMap: surfaceMap
            )
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

@available(iOS 16.0, *)
public struct RipulSiteKeysScreen: View {
    @StateObject private var model: RipulSiteKeysModel
    @State private var editing: RipulSiteKeySummary?

    init(siteKeysClient: RipulSiteKeysClient, contextsClient: RipulSolutionContextsClient) {
        _model = StateObject(wrappedValue: RipulSiteKeysModel(
            siteKeysClient: siteKeysClient,
            contextsClient: contextsClient
        ))
    }

    public var body: some View {
        List {
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(model.siteKeys) { key in
                    Button { editing = key } label: { keyRow(key) }
                        .buttonStyle(.plain)
                }
                if model.siteKeys.isEmpty && !model.loading {
                    Text("No site keys.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("A context only reaches real sessions once a key allows it. The default is what sessions boot into; surfaces let an app screen ask for a context by name.")
            }
        }
        .uiKitIdentifier("RipulSiteKeys.list")
        .navigationTitle("Site Keys")
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(item: $editing) { key in
            NavigationStack {
                RipulSiteKeyContextEditorView(model: model, key: key)
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ key: RipulSiteKeySummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: key.hasContextBinding ? "key.fill" : "key")
                .foregroundStyle(key.hasContextBinding ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                    .font(.subheadline.weight(.semibold))
                Text(summary(key))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func summary(_ key: RipulSiteKeySummary) -> String {
        if let delegate = key.delegateSolutionContextTo {
            return "Inherits contexts from \(delegate)"
        }
        if key.allowedSolutionContextIds.isEmpty {
            return "No contexts — sessions run unrestricted"
        }
        let defaultName = key.defaultSolutionContextId.map { model.name(forContextId: $0) } ?? "none"
        let surfaces = key.surfaceContextMap.isEmpty ? "" : " · \(key.surfaceContextMap.count) surface\(key.surfaceContextMap.count == 1 ? "" : "s")"
        return "\(key.allowedSolutionContextIds.count) allowed · default \(defaultName)\(surfaces)"
    }
}

// MARK: - Triple editor

@available(iOS 16.0, *)
struct RipulSiteKeyContextEditorView: View {
    @ObservedObject var model: RipulSiteKeysModel
    let key: RipulSiteKeySummary

    @Environment(\.dismiss) private var dismiss

    @State private var allowed: [String] = []
    @State private var defaultId: String?
    @State private var surfaceMap: [String: String] = [:]
    @State private var newSurfaceName = ""
    @State private var saving = false
    @State private var didLoad = false

    var body: some View {
        Form {
            if let delegate = key.delegateSolutionContextTo {
                Section {
                    Label(
                        "This key inherits its contexts from \(delegate). Changes here are stored but ignored at runtime until the delegation is removed.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                }
            }

            Section {
                ForEach(model.contexts) { context in
                    Button {
                        toggle(context.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(context.name)
                                    .foregroundStyle(.primary)
                                Text(context.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if allowed.contains(context.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Allowed contexts")
            } footer: {
                Text(allowed.isEmpty
                     ? "None selected: this key's sessions run with no context — every tool available, no curated prompt."
                     : "Sessions may enter any of these; anything else is refused by the server.")
            }

            if !allowed.isEmpty {
                Section {
                    Picker("Default", selection: Binding(
                        get: { defaultId ?? allowed.first ?? "" },
                        set: { defaultId = $0 }
                    )) {
                        ForEach(allowed, id: \.self) { id in
                            Text(model.name(forContextId: id)).tag(id)
                        }
                    }
                } header: {
                    Text("Default context")
                } footer: {
                    Text("What a session boots into when it doesn't ask for a specific context or surface.")
                }

                Section {
                    ForEach(surfaceMap.keys.sorted(), id: \.self) { surface in
                        HStack {
                            Text(surface)
                                .font(.callout.monospaced())
                            Spacer()
                            Picker("", selection: Binding(
                                get: { surfaceMap[surface] ?? allowed.first ?? "" },
                                set: { surfaceMap[surface] = $0 }
                            )) {
                                ForEach(allowed, id: \.self) { id in
                                    Text(model.name(forContextId: id)).tag(id)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .onDelete { offsets in
                        let keys = surfaceMap.keys.sorted()
                        for index in offsets { surfaceMap.removeValue(forKey: keys[index]) }
                    }
                    HStack {
                        TextField("surface name (e.g. records)", text: $newSurfaceName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.callout.monospaced())
                        Button("Add") {
                            let name = newSurfaceName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty, let first = allowed.first else { return }
                            surfaceMap[name] = defaultId ?? first
                            newSurfaceName = ""
                        }
                        .disabled(newSurfaceName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Surfaces")
                } footer: {
                    Text("An app screen asks for a context by name (surface=records). Re-pointing a screen then becomes a config change here, not an app release.")
                }
            }
        }
        .navigationTitle(key.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving)
                    .uiKitIdentifier("RipulSiteKeys.editor.save")
            }
        }
        .onAppear(perform: loadExisting)
    }

    private func toggle(_ id: String) {
        if let index = allowed.firstIndex(of: id) {
            allowed.remove(at: index)
            // Dropping a context must not leave the default or a surface
            // pointing outside the allowed set — the server refuses that, so
            // repair it here instead of failing the save.
            if defaultId == id { defaultId = allowed.first }
            for (surface, mapped) in surfaceMap where mapped == id {
                surfaceMap.removeValue(forKey: surface)
            }
        } else {
            allowed.append(id)
            if defaultId == nil { defaultId = id }
        }
    }

    private func loadExisting() {
        guard !didLoad else { return }
        didLoad = true
        allowed = key.allowedSolutionContextIds
        defaultId = key.defaultSolutionContextId ?? key.allowedSolutionContextIds.first
        surfaceMap = key.surfaceContextMap
    }

    private func save() async {
        saving = true
        let ok = await model.save(
            key: key,
            allowed: allowed,
            defaultId: allowed.isEmpty ? nil : (defaultId ?? allowed.first),
            surfaceMap: allowed.isEmpty ? [:] : surfaceMap
        )
        saving = false
        if ok { dismiss() }
    }
}
#endif
