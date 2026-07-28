#if os(iOS)
import UIKit
import SwiftUI

// MARK: - Generic kind screens (style libraries + per-element assignment)
//
// The style side of a theme hub, driven entirely by registration. A kind declares its
// label, path, knobs, slots, built-ins and scopes; these screens render from that and
// nothing else — there is no per-kind branch anywhere in this file.
//
//   RipulThemeComponentsScreen  — every kind, grouped by its registered `path`
//     └ RipulStyleLibraryScreen — that kind's named styles (built-ins + user)
//         └ RipulStyleKindEditorView — one style, previewed from the registry
//     └ RipulThemeScopesScreen  — that kind's elements, nested by scope path
//         └ assignment picker + per-element override rows
//
// Writes go through the engine's mutators, so every edit is live AND persisted with no
// host apply step.

// MARK: Components hub

/// Every registered style kind, grouped by its author-declared `path`. A kind with no
/// path sits at the top level. Adding a kind — or moving one to a new branch — needs no
/// change here.
@available(iOS 16.0, *)
@MainActor
public struct RipulThemeComponentsScreen: View {
    /// Kinds to hide (a host may drive one entirely from its own screen).
    let excludedKinds: Set<String>

    public init(excludedKinds: Set<String> = []) {
        self.excludedKinds = excludedKinds
    }

    private var kinds: [RipulStyleKind] {
        RipulThemeEngine.styleKinds.filter { !excludedKinds.contains($0.name) }
    }

    /// Group label -> kinds, preserving registration order of both.
    private var groups: [(name: String, kinds: [RipulStyleKind])] {
        var order: [String] = []
        var byGroup: [String: [RipulStyleKind]] = [:]
        for kind in kinds {
            let key = kind.path.first ?? ""
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(kind)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    public var body: some View {
        Form {
            ForEach(groups, id: \.name) { group in
                Section {
                    ForEach(group.kinds, id: \.name) { kind in
                        NavigationLink(kind.label) { RipulStyleLibraryScreen(kind: kind.name) }
                        if !kind.scopes.isEmpty {
                            NavigationLink("\(kind.label) · elements") {
                                RipulThemeScopesScreen(kind: kind.name)
                            }
                        }
                    }
                } header: {
                    if !group.name.isEmpty { Text(group.name) }
                }
            }
        }
        .navigationTitle("Components")
        .navigationBarTitleDisplayMode(.inline)
        .refreshesOnThemeChange()
    }
}

// MARK: Style library

/// One kind's named styles: the built-in library plus the user's own, drilling into the
/// generic editor. Editing a built-in copies-on-write; removing the copy restores stock.
///
/// Each row carries a LIVE preview of the style — the host's real component rendered with
/// that style's knobs merged over the kind's default tier — so the library is browsed by
/// looking at the components rather than by drilling into each name in turn. Rows fall
/// back to name-only when the kind has no registered preview.
@available(iOS 16.0, *)
@MainActor
public struct RipulStyleLibraryScreen: View {
    let kind: String
    /// Row previews on/off. On by default; a host can suppress them for a kind whose
    /// component does not read well at row size.
    let showsPreviews: Bool
    @State private var newStyleName = ""
    @State private var themeVersion = 0

    public init(kind: String, showsPreviews: Bool = true) {
        self.kind = kind
        self.showsPreviews = showsPreviews
    }

    private var styleKind: RipulStyleKind? {
        RipulThemeEngine.styleKinds.first { $0.name == kind }
    }

    public var body: some View {
        Form {
            Section {
                ForEach(RipulThemeEngine.allStyleNames(kind: kind), id: \.self) { name in
                    let isBuiltIn = RipulThemeEngine.isBuiltInStyle(kind: kind, name: name)
                    // The link and the preview are SIBLINGS, not nested: a preview inside a
                    // NavigationLink label inherits the link's tint (and any controls in it
                    // fight the row's tap). This keeps the name row as the drill-in and the
                    // preview as inert, honestly-coloured chrome beneath it.
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink(isBuiltIn ? "\(name) · built-in" : name) {
                            editor(name: name, isBuiltIn: isBuiltIn)
                        }
                        if showsPreviews, let preview = rowPreview(name: name) {
                            preview
                                .allowsHitTesting(false)   // a preview, not a second tap target
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                HStack {
                    TextField("New style name", text: $newStyleName)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    Button("Add") {
                        let name = newStyleName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        RipulThemeEngine.setNamedStyle(kind: kind, name: name, knobs: [:])
                        newStyleName = ""
                    }
                    .disabled(newStyleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("Shared styles for \(styleKind?.label.lowercased() ?? kind). Assign one to "
                     + "elements; editing it restyles every element that uses it. Editing a "
                     + "built-in makes your own copy (Reset restores stock).")
            }
        }
        .navigationTitle(styleKind?.label ?? kind)
        .navigationBarTitleDisplayMode(.inline)
        .id(themeVersion)
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in
            themeVersion &+= 1
        }
    }

    /// The host's component rendered with THIS style's knobs merged over the kind's default
    /// tier — "what does this style look like", independent of any element's assignment or
    /// overrides (which is what the picker sheet shows instead).
    private func rowPreview(name: String) -> AnyView? {
        guard let element = styleKind?.previewElement else { return nil }
        return RipulStylePreviews.view(kind: kind, element: element,
                                       working: RipulThemeEngine.namedStyle(kind: kind, name: name) ?? [:])
    }

    @ViewBuilder
    private func editor(name: String, isBuiltIn: Bool) -> some View {
        if let kindDef = styleKind {
            RipulStyleKindEditorView(
                kind: kindDef,
                styleName: name,
                initial: RipulThemeEngine.namedStyle(kind: kind, name: name) ?? [:],
                title: isBuiltIn ? "\(name) · built-in" : name,
                onChange: { knobs in
                    RipulThemeEngine.setNamedStyle(kind: kind, name: name, knobs: knobs)
                },
                footerSections: {
                    Section {
                        if isBuiltIn {
                            if RipulThemeEngine.hasUserStyle(kind: kind, name: name) {
                                Button("Reset to built-in", role: .destructive) {
                                    RipulThemeEngine.removeNamedStyle(kind: kind, name: name)
                                }
                            }
                        } else {
                            Button("Delete style", role: .destructive) {
                                RipulThemeEngine.removeNamedStyle(kind: kind, name: name)
                            }
                        }
                    }
                })
        }
    }
}

// MARK: Scopes (per-element assignment + overrides)

/// One kind's elements, nested by their registered scope paths. Each leaf offers the
/// element's named-style assignment and its own sparse overrides — the "style this one
/// independently" tier.
@available(iOS 16.0, *)
@MainActor
public struct RipulThemeScopesScreen: View {
    let kind: String
    /// nil at the root — the screen builds the tree from the kind's scopes.
    let node: RipulTokenNode?

    public init(kind: String) { self.kind = kind; self.node = nil }
    init(kind: String, node: RipulTokenNode) { self.kind = kind; self.node = node }

    private var styleKind: RipulStyleKind? {
        RipulThemeEngine.styleKinds.first { $0.name == kind }
    }

    private var roots: [RipulTokenNode] {
        RipulTokenNode.build((styleKind?.scopes ?? []).map { ($0.path, .scope($0, kind: kind)) })
    }

    private var children: [RipulTokenNode] { node?.children ?? roots }

    private var leaves: [RipulThemeScope] {
        (node?.leaves ?? []).compactMap {
            if case .scope(let s, _) = $0 { return s }
            return nil
        }
    }

    public var body: some View {
        Form {
            if !children.isEmpty {
                Section {
                    ForEach(children) { child in
                        NavigationLink(child.name) { RipulThemeScopesScreen(kind: kind, node: child) }
                    }
                }
            }
            if !leaves.isEmpty {
                Section { ForEach(leaves) { RipulScopeContent(kind: kind, scope: $0) } }
            }
            if node == nil {
                Section {
                    EmptyView()
                } footer: {
                    Text("Each element uses its assigned style unless you set knobs here — "
                         + "those apply to THIS element only and beat its named style.")
                }
            }
        }
        .navigationTitle(node?.name ?? (styleKind.map { "\($0.label) · elements" } ?? kind))
        .navigationBarTitleDisplayMode(.inline)
        .refreshesOnThemeChange()
    }
}

/// One element: a collapsible carrying its style assignment and its own override knobs
/// (the kind's knob schema plus its slots, so a composite element can re-point a part).
@available(iOS 16.0, *)
@MainActor
struct RipulScopeContent: View {
    let kind: String
    let scope: RipulThemeScope
    @State private var expanded = false

    private var styleKind: RipulStyleKind? {
        RipulThemeEngine.styleKinds.first { $0.name == kind }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Picker("Style", selection: Binding<String?>(
                get: { RipulThemeEngine.current.styleAssignments[kind]?[scope.id] },
                set: { RipulThemeEngine.assign(style: $0, kind: kind, element: scope.id) })) {
                Text(styleKind?.defaultStyleLabel ?? "Default").tag(String?.none)
                ForEach(RipulThemeEngine.allStyleNames(kind: kind), id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            RipulStyleKnobRows(
                knobs: styleKind?.knobs ?? [],
                slots: styleKind?.slots ?? [],
                working: RipulThemeEngine.current.styleOverrides[kind]?[scope.id] ?? [:],
                onChange: { knobs in
                    RipulThemeEngine.setOverrides(kind: kind, element: scope.id, knobs: knobs)
                })
        } label: {
            Text(scope.label).font(.subheadline.weight(.semibold))
        }
    }
}
#endif
