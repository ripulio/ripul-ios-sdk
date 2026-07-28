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
                    // ONE row per kind. This used to be two ("Panel styles" and
                    // "Panel styles · elements"), which doubled the hub and pushed every
                    // element a tap further away for no gain — the kind screen shows both.
                    ForEach(group.kinds, id: \.name) { kind in
                        NavigationLink(kind.label) { RipulStyleKindScreen(kind: kind.name) }
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

// MARK: One kind — its style library AND its elements, on one screen

/// Everything for a single kind without further drilling: the named-style library (with
/// live previews) and the kind's elements (each expanding in place to its assignment and
/// override knobs).
///
/// Elements inline only while there are few enough to scan; past that they move behind a
/// tree, which is the point at which nesting actually earns its tap.
@available(iOS 16.0, *)
@MainActor
public struct RipulStyleKindScreen: View {
    let kind: String
    /// Above this many elements, drilling beats one long scroll.
    private let inlineElementLimit = 8
    @State private var themeVersion = 0

    public init(kind: String) { self.kind = kind }

    private var styleKind: RipulStyleKind? {
        RipulThemeEngine.styleKinds.first { $0.name == kind }
    }
    private var elements: [RipulThemeScope] { styleKind?.scopes ?? [] }

    public var body: some View {
        Form {
            if styleKind?.supportsNamedStyles == true {
                Section {
                    RipulStyleLibraryRows(kind: kind)
                } header: {
                    Text("Styles")
                } footer: {
                    Text("Shared styles. Assign one to elements below; editing it restyles "
                         + "every element that uses it.")
                }
            }
            if !elements.isEmpty {
                Section {
                    if elements.count <= inlineElementLimit {
                        // FLAT + INLINE. Every element on one screen, expanding in place —
                        // no tree, because a tree over a handful of leaves is all ceremony.
                        ForEach(elements) { RipulScopeContent(kind: kind, scope: $0) }
                    } else {
                        NavigationLink("Browse \(elements.count) elements") {
                            RipulThemeScopesScreen(kind: kind)
                        }
                    }
                } header: {
                    Text("Elements")
                } footer: {
                    Text("Knobs set on an element apply to THAT element only and beat its "
                         + "assigned style.")
                }
            }
        }
        .navigationTitle(styleKind?.label ?? kind)
        .navigationBarTitleDisplayMode(.inline)
        .id(themeVersion)
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in
            themeVersion &+= 1
        }
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
                RipulStyleLibraryRows(kind: kind, showsPreviews: showsPreviews)
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

}

/// The style-library rows on their own — built-ins + user styles, each with a live preview,
/// plus the add-new field. Shared by the standalone library screen and the kind screen so
/// the two can never drift.
@available(iOS 16.0, *)
@MainActor
public struct RipulStyleLibraryRows: View {
    let kind: String
    let showsPreviews: Bool
    @State private var newStyleName = ""

    public init(kind: String, showsPreviews: Bool = true) {
        self.kind = kind; self.showsPreviews = showsPreviews
    }

    private var styleKind: RipulStyleKind? {
        RipulThemeEngine.styleKinds.first { $0.name == kind }
    }

    public var body: some View {
        ForEach(RipulThemeEngine.allStyleNames(kind: kind), id: \.self) { name in
            let isBuiltIn = RipulThemeEngine.isBuiltInStyle(kind: kind, name: name)
            // The link and the preview are SIBLINGS, not nested: a preview inside a
            // NavigationLink label inherits the link's tint (and any controls in it fight
            // the row's tap). Name row drills in; preview is inert chrome beneath it.
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

    /// Above this many leaves a tree earns its taps; below it, nesting is pure ceremony.
    private let flattenBelow = 12

    private var roots: [RipulTokenNode] {
        RipulTokenNode.build((styleKind?.scopes ?? []).map { ($0.path, .scope($0, kind: kind)) })
            .map(\.collapsingChains)
    }

    /// Small kinds render FLAT — every element listed by its full label, no drilling. The
    /// synthesized slot scopes are the motivating case: two leaves behind a three-level
    /// tree ("Add Shift ▸ Earnings panel ▸ Card") is all ceremony and no choice.
    private var flatLeaves: [RipulThemeScope]? {
        guard node == nil else { return nil }
        let all = roots.flatMap(\.allLeaves).compactMap { leaf -> RipulThemeScope? in
            if case .scope(let s, _) = leaf { return s }
            return nil
        }
        return all.count <= flattenBelow ? all : nil
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
            if let flat = flatLeaves {
                Section { ForEach(flat) { RipulScopeContent(kind: kind, scope: $0) } }
            } else {
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

/// ONE element's overrides as a whole screen — for kinds addressed directly rather than
/// browsed through a tree (a per-screen override editor reached from a host's own hub).
/// Same rows as `RipulScopeContent`, without the collapsible or the assignment picker when
/// the kind has no named styles to assign.
@available(iOS 16.0, *)
@MainActor
public struct RipulScopeOverridesScreen: View {
    let kind: String
    let element: String
    let title: String?

    public init(kind: String, element: String, title: String? = nil) {
        self.kind = kind; self.element = element; self.title = title
    }

    private var styleKind: RipulStyleKind? {
        RipulThemeEngine.styleKinds.first { $0.name == kind }
    }
    private var hasStyles: Bool { !RipulThemeEngine.allStyleNames(kind: kind).isEmpty }
    private var hasOverrides: Bool { RipulThemeEngine.current.styleOverrides[kind]?[element] != nil }

    public var body: some View {
        Form {
            if hasStyles {
                Section {
                    Picker("Style", selection: Binding<String?>(
                        get: { RipulThemeEngine.current.styleAssignments[kind]?[element] },
                        set: { RipulThemeEngine.assign(style: $0, kind: kind, element: element) })) {
                        Text(styleKind?.defaultStyleLabel ?? "Default").tag(String?.none)
                        ForEach(RipulThemeEngine.allStyleNames(kind: kind), id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }
            }
            Section {
                RipulStyleKnobRows(
                    knobs: styleKind?.knobs ?? [],
                    slots: styleKind?.slots ?? [],
                    working: RipulThemeEngine.current.styleOverrides[kind]?[element] ?? [:],
                    onChange: { knobs in
                        RipulThemeEngine.setOverrides(kind: kind, element: element, knobs: knobs)
                    })
            } footer: {
                Text("Each value inherits until you set it, at which point it applies to this "
                     + "element only.")
            }
            if hasOverrides {
                Section {
                    Button("Reset to inherited", role: .destructive) {
                        RipulThemeEngine.clearOverrides(kind: kind, element: element)
                    }
                }
            }
        }
        .navigationTitle(title ?? (styleKind?.scopes.first { $0.id == element }?.label ?? element))
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
