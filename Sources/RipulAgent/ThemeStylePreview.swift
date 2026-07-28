#if os(iOS)
import UIKit
import SwiftUI

// MARK: - Style preview registry (the host's real component, rendered by SDK surfaces)
//
// Every SDK surface that shows "what does this style look like?" — the named-style editor,
// the style picker, the remap sheet — needs to draw the HOST's actual component. Before
// this registry each surface took its own `preview:` closure, so a host wired the same
// component up once per surface and any new SDK surface meant another wiring.
//
// The host registers ONE closure per style kind at launch; every surface reads it. The
// closure receives the ELEMENT id as well as the resolution, because the same kind can
// render differently per element (a "field" kind previews a break capsule for the break
// field and a time capsule elsewhere) — that variation is host knowledge, so it lives in
// the host's closure rather than in an SDK switch.
//
// Composition note: for a PART kind (a slot's kind — e.g. "surface" under a disclosure
// panel), the host's closure receives that part's own resolution and is free to render it
// inside the whole composite. Which composite, and how, is the host's call; the SDK never
// assumes a part is previewable on its own.

/// Draws the host's real component for a style kind. `resolved` is the full resolution
/// (knobs + slots) the component should render with.
public typealias RipulStylePreviewBuilder = (_ element: String, _ resolved: RipulResolvedStyle) -> AnyView

@available(iOS 16.0, *)
@MainActor
public enum RipulStylePreviews {

    private static var builders: [String: RipulStylePreviewBuilder] = [:]

    /// Register the preview component for a style kind. Call once per kind at launch
    /// (alongside `RipulThemeEngine.configure`). Re-registering replaces.
    public static func register(kind: String, _ build: @escaping RipulStylePreviewBuilder) {
        builders[kind] = build
    }

    /// True when a kind has a registered preview — surfaces degrade gracefully (name-only
    /// rows) rather than rendering a blank space when it doesn't.
    public static func isRegistered(_ kind: String) -> Bool { builders[kind] != nil }

    /// The host's component for an explicit resolution.
    public static func view(kind: String, element: String, resolved: RipulResolvedStyle) -> AnyView? {
        builders[kind].map { $0(element, resolved) }
    }

    /// The host's component as the element WOULD look with `style` assigned — the picker
    /// path (the element's own overrides still apply, exactly as live).
    public static func view(kind: String, element: String, style: String?) -> AnyView? {
        view(kind: kind, element: element,
             resolved: RipulThemeEngine.previewResolved(kind: kind, element: element, style: style))
    }

    /// The host's component with `working` knobs merged over the kind's default tier — the
    /// path for EDITING a named style, where the style itself is on the bench.
    public static func view(kind: String, element: String, working: [String: RipulKnob]) -> AnyView? {
        view(kind: kind, element: element,
             resolved: RipulThemeEngine.mergedResolved(kind: kind, element: element, over: working))
    }
}

// MARK: - Generic style picker (one sheet for every kind)
//
// "Assign a named style to this element, choosing by looking at the component." Previously
// each host kind needed its own hand-written picker (WAC had one for panels and a
// near-identical one for field capsules); this is that screen, driven by registration:
// scope labels for the title, `allStyleNames(kind:)` for the rows, the preview registry
// for the components, and the kind's `defaultStyleLabel` for the unassigned row.

@available(iOS 26.0, *)
@MainActor
public struct RipulStylePickerView: View {
    let kind: String
    let element: String
    /// Bumped on `.ripulThemeDidChange` so rows re-read the engine after an assignment.
    @State private var themeVersion = 0
    @Environment(\.dismiss) private var dismiss

    public init(kind: String, element: String) {
        self.kind = kind
        self.element = element
    }

    private var styleKind: RipulStyleKind? { RipulThemeEngine.kind(containingScope: element) }

    /// The element's display label from the scope registry ("Add Shift · Earnings panel").
    private var title: String {
        styleKind?.scopes.first { $0.id == element }?.label ?? element
    }

    private var assigned: String? { RipulThemeEngine.current.styleAssignments[kind]?[element] }
    private var hasOverrides: Bool { RipulThemeEngine.current.styleOverrides[kind]?[element] != nil }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    styleRow(name: nil, label: styleKind?.defaultStyleLabel ?? "Default")
                    ForEach(RipulThemeEngine.allStyleNames(kind: kind), id: \.self) { name in
                        styleRow(name: name, label: name)
                    }
                } footer: {
                    Text("Each preview is the real component rendered with that style. "
                         + "Tap to assign — applies live.")
                }
                if hasOverrides {
                    Section {
                        Button(role: .destructive) {
                            RipulThemeEngine.clearOverrides(kind: kind, element: element)
                        } label: {
                            Text("Clear overrides")
                        }
                    } footer: {
                        Text("This element has knobs set on itself — they beat the named style.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in
            themeVersion &+= 1
        }
    }

    /// A tap-gesture row, NOT a Button: a preview may contain the component's own controls
    /// (a panel's legend button), and nested Buttons in a List row fight over the tap. One
    /// gesture on the label area, the preview keeps whatever interactivity the host gave it.
    private func styleRow(name: String?, label: String) -> some View {
        let isCurrent = assigned == name
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.system(size: 15, weight: .semibold))
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { RipulThemeEngine.assign(style: name, kind: kind, element: element) }

            if let preview = RipulStylePreviews.view(kind: kind, element: element, style: name) {
                preview
                    .id(themeVersion)   // re-resolve after an assignment lands
                    .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - Presenter

/// Presents the picker above whatever is on screen (the View Explorer's overlay is a child
/// of the top-most VC, so presenting FROM that VC puts the sheet over it). Half-sheet
/// detents leave the real component visible behind, so styles can be flipped and watched
/// on the picker AND the live screen at once.
@available(iOS 26.0, *)
public enum RipulStylePickerPresenter {
    @MainActor public static func present(kind: String, element: String) {
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                      ?? scene.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let host = UIHostingController(rootView: RipulStylePickerView(kind: kind, element: element))
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
        }
        top.present(host, animated: true)
    }
}
#endif
