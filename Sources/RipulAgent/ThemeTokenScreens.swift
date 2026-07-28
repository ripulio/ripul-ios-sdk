#if os(iOS)
import UIKit
import SwiftUI

// MARK: - Generic token screens (the 3-tier colour system, driven by registration)
//
// The colour hub used to be host code: a tree builder, a node screen, a component row, a
// semantic row and a palette section, all re-implemented per host even though every input
// is registration data the engine already holds — `RipulThemeVocabulary`'s labels and
// PATHS, plus the reference/alias/cycle logic the engine already owns.
//
// These screens are that hub, generic. A host registers vocabulary (which it must do
// anyway) and gets the whole thing. Nothing here switches on a token name: sections come
// from `Entry.path`, titles from `Entry.label`, and every write goes through the engine's
// colour mutators, so edits are live and durable without a host apply step.

// MARK: Tree

/// A node in a token tree, built from the tokens' author-declared paths. Branches nest;
/// leaves edit in place.
public struct RipulTokenNode: Identifiable {
    public enum Leaf {
        case component(RipulThemeVocabulary.Entry)
        case role(RipulThemeVocabulary.Entry)
        case primitive(RipulThemeVocabulary.Entry)
        case scope(RipulThemeScope, kind: String)
    }

    public let name: String
    public let path: [String]
    public var id: String { path.joined(separator: "/") }
    public var children: [RipulTokenNode] = []
    public var leaves: [Leaf] = []

    /// Build a tree from (path, leaf) pairs — the one path-nesting implementation, shared
    /// by the SDK's token screens and any host screen that nests registered scopes.
    public static func build(_ entries: [(path: [String], leaf: Leaf)]) -> [RipulTokenNode] {
        var roots: [RipulTokenNode] = []
        for entry in entries {
            // A leaf with no declared path would vanish; give it a top-level home under
            // its own name rather than dropping it silently.
            let path = entry.path.isEmpty ? [defaultName(of: entry.leaf)] : entry.path
            insert(&roots, path: path, leaf: entry.leaf, at: [])
        }
        return roots
    }

    private static func defaultName(of leaf: Leaf) -> String {
        switch leaf {
        case .component(let e), .role(let e), .primitive(let e): return e.label
        case .scope(let s, _): return s.label
        }
    }

    /// Every leaf beneath this node, depth-first.
    public var allLeaves: [Leaf] { leaves + children.flatMap(\.allLeaves) }

    /// COLLAPSE SINGLE-CHILD CHAINS. A node whose only content is one child branch offers
    /// no choice — tapping it is pure ceremony — so merge the two into one row titled
    /// "Parent › Child". Standard file-browser behaviour (IntelliJ's "compact middle
    /// packages"), and it matters here because synthesized slot scopes generate exactly
    /// this shape: `Add Shift ▸ Earnings panel ▸ Card`, where the middle level has one
    /// child and no leaves of its own.
    public var collapsingChains: RipulTokenNode {
        var node = self
        while node.leaves.isEmpty, node.children.count == 1 {
            let only = node.children[0]
            node = RipulTokenNode(name: "\(node.name) › \(only.name)", path: only.path,
                                  children: only.children, leaves: only.leaves)
        }
        return RipulTokenNode(name: node.name, path: node.path,
                              children: node.children.map(\.collapsingChains),
                              leaves: node.leaves)
    }

    private static func insert(_ nodes: inout [RipulTokenNode], path: [String],
                               leaf: Leaf, at prefix: [String]) {
        guard let head = path.first else { return }
        let nodePath = prefix + [head]
        if let idx = nodes.firstIndex(where: { $0.name == head }) {
            if path.count == 1 { nodes[idx].leaves.append(leaf) }
            else { insert(&nodes[idx].children, path: Array(path.dropFirst()), leaf: leaf, at: nodePath) }
        } else {
            var node = RipulTokenNode(name: head, path: nodePath)
            if path.count == 1 { node.leaves.append(leaf) }
            else { insert(&node.children, path: Array(path.dropFirst()), leaf: leaf, at: nodePath) }
            nodes.append(node)
        }
    }
}

// MARK: Colours screen

/// The colour hub: component tokens and semantic roles nested by their registered paths,
/// user-added labels, and the primitive palette beneath them. Every row writes through the
/// engine, so edits apply live and persist with no host apply step.
@available(iOS 16.0, *)
@MainActor
public struct RipulThemeColoursScreen: View {
    /// Roles the host handles in a dedicated screen of its own (e.g. masthead gradients) —
    /// excluded here so they aren't editable in two places.
    let excludedRoles: Set<String>
    @State private var newLabelName = ""
    @State private var themeVersion = 0

    public init(excludedRoles: Set<String> = []) {
        self.excludedRoles = excludedRoles
    }

    private var vocabulary: RipulThemeVocabulary? { RipulThemeEngine.vocabulary }

    private var componentTree: [RipulTokenNode] {
        RipulTokenNode.build((vocabulary?.components ?? []).map { ($0.path, .component($0)) })
    }
    private var semanticTree: [RipulTokenNode] {
        RipulTokenNode.build((vocabulary?.roles ?? [])
            .filter { !excludedRoles.contains($0.name) }
            .map { ($0.path, .role($0)) })
    }
    private var primitiveTree: [RipulTokenNode] {
        RipulTokenNode.build((vocabulary?.primitives ?? []).map { ($0.path, .primitive($0)) })
    }

    public var body: some View {
        Form {
            Section {
                ForEach(componentTree) { node in
                    NavigationLink(node.name) { RipulTokenNodeScreen(node: node) }
                }
            } header: {
                Text("Components")
            } footer: {
                Text("What a colour is used for. Each follows a semantic role beneath it until "
                     + "you pin it to a specific colour here.")
            }
            Section {
                ForEach(semanticTree) { node in
                    NavigationLink(node.name) { RipulTokenNodeScreen(node: node) }
                }
            } header: {
                Text("Semantic")
            }
            Section {
                ForEach(RipulThemeEngine.customSemanticLabels, id: \.self) { RipulSemanticTokenRow(name: $0) }
                    .onDelete { idx in
                        let names = RipulThemeEngine.customSemanticLabels
                        idx.forEach { RipulThemeEngine.removeSemanticLabel(names[$0]) }
                    }
                HStack {
                    TextField("New label name", text: $newLabelName)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    Button("Add") {
                        guard let name = sanitizedNewLabel else { return }
                        // A neutral starting point; remap via the row's menu.
                        RipulThemeEngine.addSemanticLabel(name, reference: firstPrimitiveName ?? "#000000")
                        newLabelName = ""
                    }
                    .disabled(sanitizedNewLabel == nil)
                }
            } header: {
                Text("Semantic · Custom")
            } footer: {
                Text("Add your own semantic labels and map each to a primitive (or pin a colour). "
                     + "Swipe to delete. Component tokens can reference them by name.")
            }
            Section {
                ForEach(primitiveTree) { node in
                    NavigationLink(node.name) { RipulTokenNodeScreen(node: node) }
                }
            } header: {
                Text("Primitive palette (advanced)")
            } footer: {
                Text("The raw swatches beneath the semantic roles. Editing a primitive cascades to "
                     + "every role that references it — prefer editing the semantic roles above.")
            }
        }
        .navigationTitle("Colours")
        .navigationBarTitleDisplayMode(.inline)
        .refreshesOnThemeChange()
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in
            themeVersion &+= 1
        }
    }

    private var firstPrimitiveName: String? { vocabulary?.primitives.first?.name }

    /// A new label must be non-empty, space-free, and must not collide with a role, an
    /// existing label, or a COMPONENT TOKEN — a label sharing a token's name would be
    /// shadowed, since component references resolve the token first.
    private var sanitizedNewLabel: String? {
        let name = newLabelName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard !name.isEmpty,
              !RipulThemeEngine.isSemanticLabel(name),
              !RipulThemeEngine.isComponentToken(name) else { return nil }
        return name
    }
}

// MARK: Node screen (one branch: child branches drill deeper, leaves edit in place)

@available(iOS 16.0, *)
@MainActor
public struct RipulTokenNodeScreen: View {
    let node: RipulTokenNode
    public init(node: RipulTokenNode) { self.node = node }

    public var body: some View {
        Form {
            if !node.children.isEmpty {
                Section {
                    ForEach(node.children) { child in
                        NavigationLink(child.name) { RipulTokenNodeScreen(node: child) }
                    }
                }
            }
            if !node.leaves.isEmpty {
                Section {
                    ForEach(Array(node.leaves.enumerated()), id: \.offset) { _, leaf in
                        switch leaf {
                        case .component(let e): RipulComponentTokenRow(name: e.name, label: e.label)
                        case .role(let e):      RipulSemanticTokenRow(name: e.name)
                        case .primitive(let e): RipulPrimitiveRow(name: e.name, label: e.label)
                        case .scope(let s, let kind): RipulScopeAssignmentRow(scope: s, kind: kind)
                        }
                    }
                }
            }
        }
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshesOnThemeChange()
    }
}

// MARK: Rows

/// One component/usage token: a menu to MAP it to a semantic role OR another component
/// token (an alias), plus a swatch to pin a one-off hex. The menu keeps the reference
/// intact (the point of the tiers); the swatch is the escape hatch.
@available(iOS 16.0, *)
@MainActor
struct RipulComponentTokenRow: View {
    let name: String
    let label: String

    var body: some View {
        let ref = RipulThemeEngine.reference(forComponent: name)
        HStack(spacing: 8) {
            Text(label).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 8)
            Menu {
                ForEach(RipulThemeEngine.semanticLabels, id: \.self) { role in
                    Button {
                        RipulThemeEngine.setReference(component: name, to: role)
                    } label: {
                        Label { Text(RipulThemeEngine.displayLabel(forLabel: role)) }
                        icon: { RipulThemeSwatch.image(RipulThemeEngine.color(label: role)) }
                    }
                }
                // Alias targets: other component tokens, minus any that would close a cycle.
                let aliases = (RipulThemeEngine.vocabulary?.components ?? []).filter {
                    $0.name != name && !RipulThemeEngine.aliasWouldCycle(component: name, to: $0.name)
                }
                if !aliases.isEmpty {
                    Divider()
                    ForEach(aliases, id: \.name) { other in
                        Button {
                            RipulThemeEngine.setReference(component: name, to: other.name)
                        } label: {
                            Label { Text("\(other.label) (token)") }
                            icon: { RipulThemeSwatch.image(RipulThemeEngine.color(component: other.name)) }
                        }
                    }
                }
            } label: {
                Text(refLabel(ref)).lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            }
            ColorPicker("", selection: Binding(
                get: { SwiftUI.Color(RipulThemeEngine.color(component: name)) },
                set: { RipulThemeEngine.setReference(component: name, to: UIColor($0).ripulHexString) }),
                supportsOpacity: false)
                .labelsHidden().frame(width: 32)
        }
    }

    /// The collapsed label: the alias target when it points at another token, the semantic
    /// label when it points at a role, else "Custom" (a pinned hex).
    private func refLabel(_ ref: String) -> String {
        if RipulThemeEngine.isComponentToken(ref) { return "\(RipulThemeEngine.displayLabel(forComponent: ref)) (token)" }
        return RipulThemeEngine.isSemanticLabel(ref) ? RipulThemeEngine.displayLabel(forLabel: ref) : "Custom"
    }
}

/// One semantic label (registered role OR user-added): a menu to MAP it to a primitive by
/// name OR to another label (an alias), plus a swatch to pin a one-off hex.
@available(iOS 16.0, *)
@MainActor
struct RipulSemanticTokenRow: View {
    let name: String

    var body: some View {
        let ref = RipulThemeEngine.reference(forLabel: name)
        let isPrimitive = RipulThemeEngine.current.primitives[ref] != nil
        HStack(spacing: 8) {
            Text(RipulThemeEngine.displayLabel(forLabel: name)).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 8)
            Menu {
                ForEach(RipulThemeEngine.vocabulary?.primitives ?? [], id: \.name) { prim in
                    Button {
                        RipulThemeEngine.setReference(label: name, to: prim.name)
                    } label: {
                        Label { Text(prim.label) }
                        icon: { RipulThemeSwatch.image(UIColor(ripulHexString: RipulThemeEngine.primitiveHex(prim.name) ?? "") ?? .clear) }
                    }
                }
                let aliases = RipulThemeEngine.semanticLabels.filter {
                    $0 != name && !RipulThemeEngine.aliasWouldCycle(label: name, to: $0)
                }
                if !aliases.isEmpty {
                    Divider()
                    ForEach(aliases, id: \.self) { other in
                        Button {
                            RipulThemeEngine.setReference(label: name, to: other)
                        } label: {
                            Label { Text("\(RipulThemeEngine.displayLabel(forLabel: other)) (label)") }
                            icon: { RipulThemeSwatch.image(RipulThemeEngine.color(label: other)) }
                        }
                    }
                }
            } label: {
                Text(isPrimitive ? ref
                     : (RipulThemeEngine.isSemanticLabel(ref)
                        ? "\(RipulThemeEngine.displayLabel(forLabel: ref)) (label)" : "Custom"))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            }
            ColorPicker("", selection: Binding(
                get: { SwiftUI.Color(RipulThemeEngine.color(label: name)) },
                set: { RipulThemeEngine.setReference(label: name, to: UIColor($0).ripulHexString) }),
                supportsOpacity: false)
                .labelsHidden().frame(width: 32)
        }
    }
}

/// One primitive: the bottom tier, edited as a raw colour. Editing cascades to every role
/// and token referencing it.
@available(iOS 16.0, *)
@MainActor
struct RipulPrimitiveRow: View {
    let name: String
    let label: String

    var body: some View {
        ColorPicker(label, selection: Binding(
            get: { SwiftUI.Color(UIColor(ripulHexString: RipulThemeEngine.primitiveHex(name) ?? "") ?? .magenta) },
            set: { RipulThemeEngine.setPrimitive(name, hex: UIColor($0).ripulHexString) }),
            supportsOpacity: false)
    }
}

/// One element's named-style assignment plus its per-element override rows — the style
/// counterpart of a token row, used by kind/scope screens.
@available(iOS 16.0, *)
@MainActor
struct RipulScopeAssignmentRow: View {
    let scope: RipulThemeScope
    let kind: String

    var body: some View {
        let styleKind = RipulThemeEngine.styleKinds.first { $0.name == kind }
        Picker(scope.label, selection: Binding<String?>(
            get: { RipulThemeEngine.current.styleAssignments[kind]?[scope.id] },
            set: { RipulThemeEngine.assign(style: $0, kind: kind, element: scope.id) })) {
            Text(styleKind?.defaultStyleLabel ?? "Default").tag(String?.none)
            ForEach(RipulThemeEngine.allStyleNames(kind: kind), id: \.self) { name in
                Text(name).tag(String?.some(name))
            }
        }
    }
}

// MARK: Swatch

enum RipulThemeSwatch {
    /// A colour swatch for a MENU item. Rendered to a UIImage in `.alwaysOriginal` mode: a
    /// UIMenu tints template images with the menu's tint, so an SF-symbol swatch would lose
    /// its colour — a rendered original keeps the true colour you're linking to.
    @MainActor static func image(_ color: UIColor) -> Image {
        let size = CGSize(width: 18, height: 18)
        let ui = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4).fill()
        }.withRenderingMode(.alwaysOriginal)
        return Image(uiImage: ui)
    }
}
#endif
