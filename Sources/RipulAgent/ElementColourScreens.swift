#if os(iOS)
import SwiftUI

/// Explicit tiers avoid confusing a semantic role and palette entry with the same name.
enum ColourTokenAddress: Hashable, Identifiable {
    case component(String), role(String), primitive(String)
    var name: String { switch self { case .component(let n), .role(let n), .primitive(let n): return n } }
    var id: String { "\(tier)/\(name)" }
    var tier: String { switch self { case .component: return "Component token"; case .role: return "Semantic token"; case .primitive: return "Palette colour" } }
    static func token(_ name: String) -> Self? {
        if name.hasPrefix("palette:"), RipulThemeEngine.primitiveHex(name) != nil { return .primitive(String(name.dropFirst(8))) }
        if name.hasPrefix("semantic:"), RipulThemeEngine.isSemanticLabel(String(name.dropFirst(9))) { return .role(String(name.dropFirst(9))) }
        if RipulThemeEngine.isComponentToken(name) { return .component(name) }
        if RipulThemeEngine.isSemanticLabel(name) { return .role(name) }
        if RipulThemeEngine.primitiveHex(name) != nil { return .primitive(name) }
        return nil
    }
    var reference: String {
        switch self {
        case .component: return RipulThemeEngine.reference(forComponent: name)
        case .role: return RipulThemeEngine.reference(forLabel: name)
        case .primitive: return RipulThemeEngine.primitiveHex(name) ?? "#000000"
        }
    }
    var source: Self? {
        if case .primitive = self { return nil }
        if case .role = self, RipulThemeEngine.primitiveHex(reference) != nil {
            return .primitive(reference.hasPrefix("palette:") ? String(reference.dropFirst(8)) : reference)
        }
        return Self.token(reference)
    }
    var colour: UIColor {
        switch self {
        case .component: return RipulThemeEngine.color(component: name)
        case .role: return RipulThemeEngine.color(label: name)
        case .primitive: return UIColor(ripulHexString: reference) ?? .magenta
        }
    }
    func allows(_ candidate: String) -> Bool {
        switch self {
        case .component: return !RipulThemeEngine.aliasWouldCycle(component: name, to: candidate)
        case .role: return !RipulThemeEngine.isComponentToken(candidate) && !RipulThemeEngine.aliasWouldCycle(label: name, to: candidate)
        case .primitive: return false
        }
    }
    func set(_ reference: String) {
        // Preserve the established document spelling whenever it is unambiguous.
        // Qualified references are needed only to distinguish names shared by tiers.
        var reference = reference
        if reference.hasPrefix("semantic:") {
            let name = String(reference.dropFirst(9))
            if case .component = self { reference = name }
            else if RipulThemeEngine.primitiveHex(name) == nil { reference = name }
        } else if reference.hasPrefix("palette:") {
            let name = String(reference.dropFirst(8))
            if case .role = self { reference = name }
            else if !RipulThemeEngine.isComponentToken(name) && !RipulThemeEngine.isSemanticLabel(name) { reference = name }
        }
        switch self {
        case .component: RipulThemeEngine.setReference(component: name, to: reference)
        case .role: RipulThemeEngine.setReference(label: name, to: reference)
        case .primitive: RipulThemeEngine.setPrimitive(name, hex: reference)
        }
    }
    func reset() {
        var doc = RipulThemeEngine.current
        switch self {
        case .component: doc.components[name] = RipulThemeEngine.bundled.components[name]
        case .role: doc.semantic[name] = RipulThemeEngine.bundled.semantic[name]
        case .primitive: doc.primitives[name] = RipulThemeEngine.bundled.primitives[name]
        }
        if let persist = RipulThemeEngine.persistMutation { persist(doc) } else { RipulThemeEngine.adopt(doc) }
    }
}

@MainActor
struct ColourReferencePicker: View {
    let current: String
    var allows: (String) -> Bool = { _ in true }
    let select: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    private var groups: [(String, [String])] {
        [("Component tokens", RipulThemeEngine.vocabulary?.components.map(\.name) ?? []),
         ("Semantic tokens", RipulThemeEngine.semanticLabels.map { "semantic:\($0)" }),
         ("Palette", RipulThemeEngine.vocabulary?.primitives.map { "palette:\($0.name)" } ?? [])]
    }
    var body: some View {
        List {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1.filter { allows($0) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }, id: \.self) { name in
                        Button {
                            select(name); dismiss()
                        } label: {
                            HStack {
                                ColourValueSwatch(colour: RipulThemeEngine.colourReference(name))
                                Text(ColourTokenAddress.token(name)?.name ?? name)
                                Spacer()
                                if current == name { Image(systemName: "checkmark") }
                            }
                        }
                        .uiKitIdentifier("theme.reference.\(group.0).\(name)")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Find a token")
        .navigationTitle("Choose token")
    }
}

struct ColourValueSwatch: View {
    let colour: UIColor
    var body: some View {
        RoundedRectangle(cornerRadius: 5).fill(Color(colour)).frame(width: 26, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            .accessibilityHidden(true)
    }
}

@MainActor
struct ColourTokenDefinitionScreen: View {
    let token: ColourTokenAddress
    var ancestors: Set<ColourTokenAddress> = []
    @State private var version = 0
    var body: some View {
        let _ = version
        List {
            Section {
                Text(token.name).font(.title3).textSelection(.enabled)
                Text(token.tier).foregroundStyle(.secondary)
                HStack { Text("Resulting colour"); Spacer(); Text(token.colour.ripulHexString); ColourValueSwatch(colour: token.colour) }
            } footer: {
                Text("Shared definition. Changes affect every element and token that uses \(token.name).")
            }
            if case .primitive = token {
                Section("Colour value") {
                    ColorPicker("Edit palette colour", selection: Binding(get: { Color(token.colour) }, set: { token.set(UIColor($0).ripulHexString) }), supportsOpacity: false)
                        .uiKitIdentifier("theme.token.colour")
                }
            } else {
                Section("Colour source") {
                    if let source = token.source, !ancestors.union([token]).contains(source) {
                        NavigationLink {
                            ColourTokenDefinitionScreen(token: source, ancestors: ancestors.union([token]))
                        } label: { Label("Open \(source.name)", systemImage: "arrow.turn.down.right") }
                        .uiKitIdentifier("theme.token.openSource")
                    } else {
                        Text(token.reference).textSelection(.enabled)
                    }
                    NavigationLink("Change source") {
                        ColourReferencePicker(current: token.reference, allows: token.allows, select: token.set)
                    }.uiKitIdentifier("theme.token.changeSource")
                    NavigationLink("Use a custom colour") {
                        List {
                            Section {
                                ColorPicker("Custom colour", selection: Binding(get: { Color(token.colour) }, set: { token.set(UIColor($0).ripulHexString) }), supportsOpacity: false)
                            } footer: { Text("This replaces \(token.name)’s source reference with a fixed colour. Other uses of \(token.name) follow it.") }
                        }.navigationTitle(token.name)
                    }
                }
            }
            Section {
                Button("Restore shipped definition") { token.reset() }
            }
        }
        .navigationTitle(token.name).navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in version += 1 }
    }
}

@MainActor
struct ElementColourScreen: View {
    let assignment: RipulColourAssignment
    let propertyLabel: String
    @State private var version = 0
    @State private var naming = false
    @State private var name = ""
    @State private var nameError: String?
    var body: some View {
        let _ = version
        List {
            Section {
                Text(propertyLabel).font(.title3)
                Text(ThemeChangePresentation.readable(assignment.element)).font(.subheadline).foregroundStyle(.secondary)
                LabeledContent("Assigned token", value: ColourTokenAddress.token(assignment.reference)?.name ?? assignment.reference)
                LabeledContent("Assignment", value: assignment.override == nil ? "Author default" : "Individual override")
                HStack { Text("Resulting colour"); Spacer(); ColourValueSwatch(colour: assignment.colour) }
            }
            Section {
                NavigationLink("Choose a different token") {
                    ColourReferencePicker(current: assignment.reference) { assignment.setReference($0) }
                }.uiKitIdentifier("theme.element.chooseToken")
                ColorPicker("Custom colour for this element", selection: Binding(get: { Color(assignment.colour) }, set: { assignment.setReference(UIColor($0).ripulHexString) }), supportsOpacity: false)
                    .uiKitIdentifier("theme.element.customColour")
                if assignment.override != nil {
                    Button("Use default: \(assignment.defaultToken)") { assignment.setReference(nil) }
                        .uiKitIdentifier("theme.element.reset")
                }
            } header: { Text("This element") } footer: { Text("Only this element’s \(propertyLabel.lowercased()) changes. The shared token remains unchanged.") }
            Section {
                if let token = ColourTokenAddress.token(assignment.reference) {
                    NavigationLink("Open \(token.name)") { ColourTokenDefinitionScreen(token: token) }
                        .uiKitIdentifier("theme.element.openToken")
                }
                Button("Create a shared token from this colour") { naming = true }
                if let nameError { Text(nameError).foregroundStyle(.red) }
            } header: { Text("Shared definition") } footer: { Text("Use shared tokens to group elements. Editing a shared definition changes every place that uses it.") }
        }
        .navigationTitle("Element appearance").navigationBarTitleDisplayMode(.inline)
        .alert("New shared token", isPresented: $naming) {
            TextField("Token name", text: $name)
            Button("Create") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.contains(":"), ColourTokenAddress.token(trimmed) == nil, UIColor(ripulHexString: trimmed) == nil else {
                    nameError = "Choose a unique token name."; return
                }
                RipulThemeEngine.addSemanticLabel(trimmed, reference: assignment.colour.ripulHexString)
                assignment.setReference(trimmed); nameError = nil; name = ""
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The new token starts with this colour. Assign other elements to it to form a group.") }
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in version += 1 }
    }
}

/// Persisted exceptions remain discoverable even when their screen is not open.
@MainActor
public struct RipulElementColourOverridesScreen: View {
    @State private var query = ""
    @State private var version = 0
    public init() {}
    public var body: some View {
        let _ = version
        let values = RipulThemeEngine.current.elementColors
        List {
            Section {
                Text("Most elements inherit shared tokens. Individual overrides are listed here so you can review them or return to the defaults.")
            }
            if values.isEmpty { Text("No individual colour overrides") }
            ForEach(values.keys.sorted().filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { element in
                Section(ThemeChangePresentation.readable(element)) {
                    ForEach((values[element] ?? [:]).keys.sorted(), id: \.self) { property in
                        let known = RipulElementColours.assignments.first { $0.element == element && $0.property == property }
                        if let known {
                            NavigationLink { ElementColourScreen(assignment: known, propertyLabel: property) } label: {
                                LabeledContent(property, value: values[element]?[property] ?? "")
                            }
                        } else {
                            LabeledContent(property, value: values[element]?[property] ?? "")
                        }
                        Button("Use default for \(property)") {
                            RipulColourAssignment(element: element, property: property, defaultToken: "").setReference(nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("Individual colours").searchable(text: $query, prompt: "Find an element")
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in version += 1 }
    }
}
#endif
