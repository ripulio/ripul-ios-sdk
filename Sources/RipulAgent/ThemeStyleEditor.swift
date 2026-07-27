#if os(iOS)
import UIKit
import SwiftUI

// MARK: - Generic style-kind editor (a framework artefact for ANY style kind)
//
// One pushed editor screen per named style, generated entirely from the kind's registered
// knob schema (`RipulStyleKind.knobs`): a live example on top (the host's preview closure,
// re-rendered on every edit via `RipulThemeEngine.mergedStyle`), a scrolling knob list
// below (Inherit/Set semantics — the style stays sparse). Field capsules, disclosure
// panels, and every FUTURE style kind get this screen from one init — there is no
// per-kind UI.
//
// The view is dumb chrome: it owns the working knob dict and reports every change through
// `onChange`. The HOST owns persistence (map the dict to its theme value, apply — including
// copy-on-write for built-in styles) and the preview component.

@available(iOS 16.0, *)
@MainActor
public struct RipulStyleKindEditorView<Preview: View, Footer: View>: View {
    let title: String
    let knobs: [RipulStyleKnob]
    /// The kind's slots (composite kinds). Each renders as a style picker in a "Parts"
    /// section — Inherit, or a named style of the slot's kind — stored in the working dict
    /// as a string knob keyed by the slot's name (the document's slot-reference shape).
    let slots: [RipulStyleSlot]
    let onChange: ([String: RipulKnob]) -> Void
    let preview: ([String: RipulKnob]) -> Preview
    let footerSections: () -> Footer
    /// The component's author-declared namespace (from its scope's `path`), shown as a
    /// breadcrumb above the preview — where in the app this component logically lives.
    let namespace: [String]
    @State private var working: [String: RipulKnob]

    /// - title: nav title — typically the style name (or "Floating · built-in").
    /// - knobs: the kind's knob schema (from registration).
    /// - slots: the kind's slots (from registration); default none.
    /// - initial: the style's CURRENT sparse knobs (user style, or the built-in's for CoW).
    /// - onChange: called with the full working dict after every edit.
    /// - preview: host's live example — receives the working dict (merge over the default
    ///   tier with `RipulThemeEngine.mergedStyle` — or `mergedResolved` for composites —
    ///   inside the closure). PINNED: always on screen while the knobs scroll beneath it.
    /// - namespace: the previewed element's scope path — shown as a breadcrumb.
    /// - footerSections: optional host actions (Reset to built-in / Delete style).
    public init(title: String, knobs: [RipulStyleKnob], slots: [RipulStyleSlot] = [],
                initial: [String: RipulKnob],
                onChange: @escaping ([String: RipulKnob]) -> Void,
                @ViewBuilder preview: @escaping ([String: RipulKnob]) -> Preview,
                namespace: [String] = [],
                @ViewBuilder footerSections: @escaping () -> Footer = { EmptyView() }) {
        self.title = title
        self.knobs = knobs
        self.slots = slots
        self.onChange = onChange
        self.preview = preview
        self.namespace = namespace
        self.footerSections = footerSections
        _working = State(initialValue: initial)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // PINNED preview header — the example stays on screen while the knobs scroll.
            // fixedSize(vertical:) pins it to the content's IDEAL height: previewed
            // components (the DisclosurePanel especially) often carry maxHeight: .infinity
            // for their in-app layout context, which would otherwise balloon the header to
            // half the screen. The header hugs the component; the Form gets the rest.
            VStack(alignment: .leading, spacing: 6) {
                if !namespace.isEmpty {
                    Text(namespace.joined(separator: " › "))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                preview(working)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
            Divider()
            // Scrolling knobs beneath.
            Form {
                if !slots.isEmpty {
                    Section("Parts") {
                        ForEach(slots) { slot in slotRow(slot) }
                    }
                }
                Section {
                    ForEach(knobs) { knob in row(knob) }
                } footer: {
                    Text("Every knob starts on Inherit — set only what this style changes.")
                }
                footerSections()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: slot rows (composite parts — a pointer into another kind's style library)

    /// One slot = one picker over the target kind's style library. "Inherit" leaves the
    /// pointer unset (the element cascade or the slot's registered default decides).
    private func slotRow(_ slot: RipulStyleSlot) -> some View {
        Picker(slot.label, selection: Binding<String?>(
            get: { working[slot.name]?.string },
            set: { set(slot.name, $0.map { .string($0) }) })) {
            Text("Inherit").tag(String?.none)
            ForEach(RipulThemeEngine.allStyleNames(kind: slot.kind), id: \.self) { name in
                Text(name).tag(String?.some(name))
            }
        }
    }

    // MARK: knob rows (Inherit/Set semantics — sparse by construction)

    @ViewBuilder private func row(_ knob: RipulStyleKnob) -> some View {
        switch knob.kind {
        case .number(let range, let fallback, let format):
            numberRow(knob, range: range, fallback: fallback, format: format)
        case .options(let options):
            Picker(knob.label, selection: Binding<String?>(
                get: { working[knob.key]?.string },
                set: { set(knob.key, $0.map { .string($0) }) })) {
                Text("Inherit").tag(String?.none)
                ForEach(options, id: \.raw) { option in
                    Text(option.label).tag(String?.some(option.raw))
                }
            }
        case .bool:
            Picker(knob.label, selection: Binding<Bool?>(
                get: { working[knob.key]?.bool },
                set: { set(knob.key, $0.map { .bool($0) }) })) {
                Text("Inherit").tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
        }
    }

    private func numberRow(_ knob: RipulStyleKnob, range: ClosedRange<Double>,
                           fallback: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(knob.label)
                Spacer()
                if let value = working[knob.key]?.number {
                    Text(String(format: format, value))
                        .foregroundColor(.secondary).monospacedDigit()
                } else {
                    Text("Inherit").foregroundColor(.secondary)
                }
                Toggle("", isOn: Binding(
                    get: { working[knob.key] != nil },
                    set: { on in set(knob.key, on ? .number(fallback) : nil) }))
                    .labelsHidden()
            }
            if let value = working[knob.key]?.number {
                Slider(value: Binding(
                    get: { value },
                    set: { set(knob.key, .number($0)) }), in: range)
            }
        }
    }

    private func set(_ key: String, _ value: RipulKnob?) {
        if let value { working[key] = value } else { working[key] = nil }
        onChange(working)
    }
}
#endif
