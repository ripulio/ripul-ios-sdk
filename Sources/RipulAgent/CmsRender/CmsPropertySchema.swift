import Foundation

/// Native mirror of the web designer's PropertySchema (PropertySchema.ts):
/// each block type declares its editable properties as declarative field
/// descriptors, and a generic inspector Form (`CmsPropertyInspectorView`)
/// renders the controls — no per-block hand-built panels, exactly like the
/// web's SchemaPropertyEditor. Field kinds map to NATIVE controls (Toggle,
/// Picker, Stepper, ColorPicker) — same semantics, platform presentation.

public struct CmsPropertyOption: Equatable {
    public let value: String
    public let label: String
    public init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

public enum CmsPropertyKind: Equatable {
    /// Single-line text.
    case string(placeholder: String? = nil)
    /// Number; renders a Stepper with the range (a wide fallback range when
    /// min/max are absent). Persisted as a JSON number.
    case number(min: Double? = nil, max: Double? = nil, step: Double? = nil, unit: String? = nil)
    /// Number edited like `number` but PERSISTED AS A STRING (CSS points
    /// convention — e.g. the grid's `height`, read via `CmsCss.points`).
    case numberString(min: Double? = nil, max: Double? = nil, step: Double? = nil, unit: String? = nil)
    case boolean
    /// ≤3 options render segmented (the web's `appearance: 'toggle'`); more
    /// render a menu picker.
    case select(options: [CmsPropertyOption])
    /// CSS colour string or theme token. Clearable — absent = inherit the
    /// renderer default.
    case color
    /// Picker over the definition's saved queries; empty = unbound.
    case queryRef(emptyLabel: String? = nil)
    /// Picker over the definition's card views; empty = auto-derive.
    case cardViewRef(emptyLabel: String? = nil)
    /// Rich column-config editor for data-bound grids. The string names the
    /// sibling prop that holds the bound query slug (e.g. "querySlug").
    case columns(querySlugKey: String)

    /// Complex sub-editors that genuinely benefit from being zoomed into a
    /// full-height view (columns today; future rich editors opt in here).
    /// Drives two inspector behaviours: the group-zoom affordance is always
    /// offered for groups containing one, and the zoomed view gives the
    /// editor the remaining sheet height instead of the compact inline cap.
    var isComplexEditor: Bool {
        if case .columns = self { return true }
        return false
    }
}

/// Conditional visibility — mirror of the web's `visibleWhen`
/// (`{ key, equals }` / `{ key, notEquals }`). An absent prop reads as
/// `.null`, which matches the web's `undefined` comparisons for the patterns
/// the schemas use.
public struct CmsPropertyVisibility: Equatable {
    public let key: String
    public var equals: CmsJSON?
    public var notEquals: CmsJSON?

    public init(key: String, equals: CmsJSON? = nil, notEquals: CmsJSON? = nil) {
        self.key = key
        self.equals = equals
        self.notEquals = notEquals
    }
}

public struct CmsPropertyField {
    public let key: String
    public let label: String
    public let kind: CmsPropertyKind
    public let group: String
    public let helperText: String?
    public let visibleWhen: CmsPropertyVisibility?
    /// Value shown when the prop is ABSENT — the renderer's own fallback
    /// (e.g. enableSorting defaults true in the renderer, so the Toggle must
    /// show ON for an absent prop). Never written until the user edits.
    public let defaultValue: CmsJSON?

    public init(
        key: String,
        label: String,
        kind: CmsPropertyKind,
        group: String,
        helperText: String? = nil,
        visibleWhen: CmsPropertyVisibility? = nil,
        default defaultValue: CmsJSON? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.group = group
        self.helperText = helperText
        self.visibleWhen = visibleWhen
        self.defaultValue = defaultValue
    }

    public func isVisible(in props: [String: CmsJSON]) -> Bool {
        guard let rule = visibleWhen else { return true }
        let value = props[rule.key] ?? .null
        if let equals = rule.equals, value != equals { return false }
        if let notEquals = rule.notEquals, value == notEquals { return false }
        return true
    }

    /// Effective current value: the persisted prop, else the declared
    /// renderer default.
    public func value(in props: [String: CmsJSON]) -> CmsJSON? {
        props[key] ?? defaultValue
    }
}

public struct CmsPropertyGroup {
    public let id: String
    public let label: String
    /// Reserved — native Form sections are always expanded; kept for parity
    /// with the web group metadata so schemas can share the vocabulary.
    public let defaultExpanded: Bool

    public init(id: String, label: String, defaultExpanded: Bool = true) {
        self.id = id
        self.label = label
        self.defaultExpanded = defaultExpanded
    }
}

public struct CmsInspectorSchema {
    public let groups: [CmsPropertyGroup]
    public let fields: [CmsPropertyField]

    public init(groups: [CmsPropertyGroup], fields: [CmsPropertyField]) {
        self.groups = groups
        self.fields = fields
    }

    public func fields(in group: String, props: [String: CmsJSON]) -> [CmsPropertyField] {
        fields.filter { $0.group == group && $0.isVisible(in: props) }
    }
}

/// Inspector schema registry — parallel to `CmsBlockRegistry`'s renderers.
/// A block type without a schema still renders its identity section in the
/// inspector; schemas land per block as the native renderer gains coverage.
public enum CmsInspectorSchemas {
    public static func schema(for blockType: String) -> CmsInspectorSchema? {
        switch blockType {
        case "agGrid": return CmsAgGridInspector.schema
        default: return nil
        }
    }
}
