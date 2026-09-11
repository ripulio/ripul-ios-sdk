#if os(iOS)
import UIKit
import SwiftUI

// MARK: - Theme remap primitives + sheet (the explorer's double-tap surface)
//
// The View Explorer stays abstract: it reports element taps (`RipulElementTap`). A host
// with a theme system interprets the tap as a THEME REMAP and presents THE remap sheet —
// one consistent popup for every themeable element. The sheet is dumb chrome: its contents
// are vended by the host's construct providers as typed `RipulThemeRemapSection`s (one
// section per themeable artefact on the element), so the SDK ships the UX without knowing
// anything about the host's theme vocabulary. Adding a construct kind changes nothing here.
//
// Host wiring (see the host's aggregator/interpreter):
//   RipulViewExplorer.elementTapAction = { tap in
//       let targets = aggregator.remapTargets(for: tap.view)
//       if targets.isEmpty { /* host diagnostic */ }
//       else { RipulThemeRemapSheetPresenter.present(targets: targets, tap: tap) }
//   }

/// One selectable row in the remap sheet — "Brand Secondary", "Default (theme)",
/// "Clear overrides". Self-contained: `select` applies the choice through the provider
/// that minted the row and returns a short log line (nil = no-op).
public struct RipulThemeRemapOptionRow: Identifiable {
    public enum Role { case option, navigation, destructive }
    public let id: String
    public let label: String
    /// "#RRGGBB" for colour rows; nil for style/action rows.
    public let swatchHex: String?
    /// Whether this row is the artefact's current value (draws the checkmark).
    public let isCurrent: Bool
    public let role: Role
    public let select: @MainActor () -> String?

    public init(id: String, label: String, swatchHex: String? = nil,
                isCurrent: Bool, role: Role = .option,
                select: @escaping @MainActor () -> String?) {
        self.id = id
        self.label = label
        self.swatchHex = swatchHex
        self.isCurrent = isCurrent
        self.role = role
        self.select = select
    }
}

/// One section of the remap sheet, vended by a target. A colour target typically vends one
/// section per option group ("Tokens"/"Roles"/"Primitives"); a style target vends one
/// (default / preview / clear-overrides). The sheet renders whatever it receives.
public struct RipulThemeRemapSection: Identifiable {
    public let id: String
    /// Section header: "Text colour — Roles", "Field style".
    public let title: String
    public let rows: [RipulThemeRemapOptionRow]

    public init(id: String, title: String, rows: [RipulThemeRemapOptionRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// A typed remap target — one themeable thing found on a tapped element (a tokened colour,
/// a style assignment, …). Self-contained: carries everything its sheet sections and its
/// Edit-tab projection need, so neither consumer touches the source view again.
@MainActor
public protocol RipulThemeRemapTarget {
    /// Stable id, namespaced by the owning provider ("colour.textColor", "field.addShift.wacInField").
    var id: String { get }
    /// One-liner for logs and the sheet header: "Text colour · fieldLabel → accent".
    var summary: String { get }
    /// Content for the remap sheet — one or more sections of selectable rows.
    func remapSections() -> [RipulThemeRemapSection]
    /// Projection to the SDK's dumb structs for the explorer's Edit tab.
    func tokenBindings() -> [RipulTokenBinding]
}

// MARK: - Presenter

/// Presents the remap sheet above the View Explorer (top-most VC, half-sheet detents so
/// the tapped element stays visible behind the sheet while choices are flipped live).
@available(iOS 16.0, *)
public enum RipulThemeRemapSheetPresenter {

    /// Optional log sink for sheet actions (row selections). The SDK keeps no logging
    /// dependency of its own — the host routes these into its console (e.g. nlog).
    public static var onLog: ((String) -> Void)?

    /// Optional host action fired by the sheet's "Open Theme editor" row — the escape
    /// hatch from the quick remap sheet into the host's full theme editor. The sheet
    /// dismisses itself first, then fires. When nil, the row is hidden.
    public static var editorAction: (() -> Void)?

    /// Open one assignment from the inspector, using the same detail/editor as element taps.
    @MainActor public static func present(binding: RipulTokenBinding, view: UIView) {
        guard let top = RipulChrome.presentationRoot() else { return }
        let item = RipulAppearanceItem(id: binding.id, read: { [weak view] in
            guard let view else { return nil }
            return RipulTokenInspector.bindings(for: view).first { $0.id == binding.id }
        }, sections: { [weak view] in
            guard let view, let provider = RipulTokenInspector.provider,
                  let current = provider.tokenBindings(for: view).first(where: { $0.id == binding.id }) else { return [] }
            return provider.remapSections(for: current, view: view)
        })
        let host = UIHostingController(rootView: RipulAppearanceDetailSheet(item: item))
        host.sheetPresentationController?.detents = [.medium(), .large()]
        if binding.assignment != nil { host.sheetPresentationController?.selectedDetentIdentifier = .large }
        top.present(host, animated: true)
    }

    @MainActor public static func present(targets: [any RipulThemeRemapTarget], tap: RipulElementTap) {
        // Presented from the top-most chrome window when one is up — this sheet
        // is fired FROM the explorer, and presenting it from the app's window
        // would put it underneath the explorer's overlay window.
        guard let top = RipulChrome.presentationRoot() else { return }
        let host = UIHostingController(rootView: RipulThemeRemapSheetView(targets: targets, tap: tap))
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
        }
        top.present(host, animated: true)
    }
}

// MARK: - Appearance assignments and shared definitions

/// Live reads keep the assignment and its definition up to date after any theme edit.
@MainActor
struct RipulAppearanceItem: Identifiable {
    let id: String
    let read: () -> RipulTokenBinding?
    let sections: () -> [RipulThemeRemapSection]
}

@available(iOS 16.0, *)
struct RipulAppearanceRow: View {
    let binding: RipulTokenBinding

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(binding.property)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(binding.tokenName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if binding.kind == .colourToken {
                RipulAppearanceSwatch(hex: binding.swatchHex)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@available(iOS 16.0, *)
private struct RipulAppearanceSwatch: View {
    let hex: String
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(UIColor(ripulHexString: hex) ?? .clear))
            .frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

@available(iOS 16.0, *)
@MainActor
private struct RipulAppearanceDetailSheet: View {
    let item: RipulAppearanceItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            RipulAppearanceDetailView(item: item)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .uiKitIdentifier("inspector.appearance.done")
                    }
                }
        }
    }
}

@available(iOS 16.0, *)
@MainActor
struct RipulAppearanceDetailView: View {
    let item: RipulAppearanceItem
    @State private var themeVersion = 0

    var body: some View {
        if let binding = item.read(), let assignment = binding.assignment {
            ElementColourScreen(assignment: assignment, propertyLabel: binding.property)
        } else {
            legacyBody
        }
    }

    @ViewBuilder private var legacyBody: some View {
        let _ = themeVersion
        let binding = item.read()
        List {
            if let binding {
                Section {
                    Text(binding.tokenName)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    detail("Used for", binding.property)
                    if binding.kind == .colourToken {
                        if let source = binding.resolvesTo { detail("Colour source", source) }
                        HStack {
                            Text("Resulting colour")
                            Spacer()
                            Text(binding.swatchHex).font(.system(size: 13, design: .monospaced))
                            RipulAppearanceSwatch(hex: binding.swatchHex)
                        }
                        .accessibilityElement(children: .combine)
                    } else if let summary = binding.resolvesTo {
                        detail("Style settings", summary)
                    }
                }
                Section {
                    NavigationLink {
                        RipulAppearanceOptionsView(item: item)
                    } label: {
                        Text(binding.kind == .colourToken ? "Edit shared token" : "Change style")
                    }
                    .uiKitIdentifier("inspector.appearance.edit.\(binding.id)")
                } footer: {
                    Text(binding.kind == .colourToken
                         ? "Changes apply wherever this token is used."
                         : "The style assignment applies to this element. Individual overrides still apply.")
                }
            } else {
                Text("This appearance assignment is no longer available.")
            }
        }
        .navigationTitle(binding?.kind == .colourToken ? "Shared token" : "Style assignment")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in themeVersion += 1 }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15)).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

@available(iOS 16.0, *)
@MainActor
private struct RipulAppearanceOptionsView: View {
    let item: RipulAppearanceItem
    @State private var themeVersion = 0

    var body: some View {
        let _ = themeVersion
        let binding = item.read()
        List {
            if let binding {
                Section {
                    Text(binding.tokenName).font(.system(size: 17, weight: .semibold, design: .monospaced))
                    Text(binding.kind == .colourToken
                         ? "Choose where this shared token gets its colour. Changes apply wherever this token is used."
                         : "Choose a style for this element. Individual overrides still apply until cleared.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                ForEach(item.sections()) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            Button {
                                let line = row.select()
                                themeVersion += 1
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                RipulThemeRemapSheetPresenter.onLog?("[RipulTheme] appearance: \(row.label) — \(line ?? "no change")")
                            } label: {
                                HStack(spacing: 12) {
                                    if let hex = row.swatchHex { RipulAppearanceSwatch(hex: hex) }
                                    Text(row.label)
                                        .foregroundStyle(row.role == .destructive ? Color.red : Color.primary)
                                    Spacer()
                                    if row.isCurrent { Image(systemName: "checkmark") }
                                    if row.role == .navigation {
                                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }
                                }
                                .frame(minHeight: 32)
                            }
                            .uiKitIdentifier("inspector.appearance.option.\(item.id).\(row.id)")
                        }
                    }
                }
            } else {
                Text("This appearance assignment is no longer available.")
            }
        }
        .navigationTitle(binding?.kind == .colourToken ? "Edit shared token" : "Change style")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in themeVersion += 1 }
    }
}

/// Element taps open the same assignment-first presentation as the inspector.
@available(iOS 16.0, *)
@MainActor
public struct RipulThemeRemapSheetView: View {
    let targets: [any RipulThemeRemapTarget]
    let tap: RipulElementTap
    @Environment(\.dismiss) private var dismiss
    @State private var themeVersion = 0

    public init(targets: [any RipulThemeRemapTarget], tap: RipulElementTap) {
        self.targets = targets
        self.tap = tap
    }

    public var body: some View {
        let _ = themeVersion
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        if let binding = item.read() {
                            NavigationLink {
                                RipulAppearanceDetailView(item: item)
                            } label: {
                                RipulAppearanceRow(binding: binding)
                            }
                            .uiKitIdentifier("inspector.appearance.\(item.id)")
                        }
                    }
                } header: {
                    Text(tap.view.accessibilityIdentifier ?? String(describing: type(of: tap.view)))
                }
                if let editorAction = RipulThemeRemapSheetPresenter.editorAction {
                    Section {
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editorAction() }
                        } label: {
                            Label("Open Theme editor", systemImage: "slider.horizontal.3")
                        }
                        .uiKitIdentifier("inspector.appearance.themeEditor")
                    }
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .uiKitIdentifier("inspector.appearance.done")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in themeVersion += 1 }
    }

    private var items: [RipulAppearanceItem] {
        targets.flatMap { target in
            target.tokenBindings().map { binding in
                RipulAppearanceItem(id: binding.id,
                                    read: { target.tokenBindings().first { $0.id == binding.id } },
                                    sections: { target.remapSections() })
            }
        }
    }
}

// MARK: - Hex parsing (self-contained; the SDK has no host colour utilities)

extension UIColor {
    /// Parse a `#RRGGBB` / `RRGGBB` hex string. Returns nil on malformed input.
    convenience init?(ripulHexString hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let rgb = UInt64(s, radix: 16) else { return nil }
        self.init(red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
                  green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
                  blue: CGFloat(rgb & 0x0000FF) / 255.0,
                  alpha: 1.0)
    }

    /// `#RRGGBB` for this colour — what a colour-picker edit writes back into the document.
    /// Resolved in the extended-sRGB space first so P3 picks (the system picker's default
    /// gamut) clamp to a valid sRGB hex instead of producing out-of-range components.
    var ripulHexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        let clamp = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}
#endif
