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

    @MainActor public static func present(targets: [any RipulThemeRemapTarget], tap: RipulElementTap) {
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                      ?? scene.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let host = UIHostingController(rootView: RipulThemeRemapSheetView(targets: targets, tap: tap))
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
        }
        top.present(host, animated: true)
    }
}

// MARK: - The sheet (ONE consistent popup for every themeable element)

/// THE remap popup. Dumb chrome: a header identifying the tapped element, then one List
/// section per section the targets vend. All semantics — what the rows are, what selecting
/// one writes — live in the host's providers and their targets. Selecting a row applies
/// immediately (the element changes behind the sheet) and the sheet stays open; content
/// re-resolves on `.ripulThemeDidChange` so the current checkmark moves and the header
/// summary updates. Styled with system defaults — hosts restyle via their own surfaces.
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
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(String(describing: type(of: tap.view))) · \(tap.view.accessibilityIdentifier ?? "—")")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                            Text(target.summary)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.vertical, 2)

                    // Escape hatch into the host's full theme editor (hidden when the host
                    // hasn't wired one). Dismisses the sheet first so the editor can present.
                    if let editorAction = RipulThemeRemapSheetPresenter.editorAction {
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editorAction() }
                        } label: {
                            HStack {
                                Label("Open Theme editor", systemImage: "slider.horizontal.3")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                }
                ForEach(sections) { section in
                    SwiftUI.Section(section.title) {
                        ForEach(section.rows) { row in
                            rowView(row)
                        }
                    }
                }
            }
            .navigationTitle("Remap element")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in
            themeVersion += 1
        }
    }

    /// Recomputed on every render (providers are stateless value reads), so a theme change
    /// re-resolves checkmarks and summaries immediately. `themeVersion` is the re-render trigger.
    private var sections: [RipulThemeRemapSection] {
        _ = themeVersion
        return targets.flatMap { $0.remapSections() }
    }

    @ViewBuilder private func rowView(_ row: RipulThemeRemapOptionRow) -> some View {
        Button {
            let line = row.select()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            RipulThemeRemapSheetPresenter.onLog?("[RipulTheme] remap sheet: \(row.label) — \(line ?? "no change")")
        } label: {
            HStack(spacing: 12) {
                if let hex = row.swatchHex {
                    Circle()
                        .fill(Color(UIColor(ripulHexString: hex) ?? .clear))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                }
                Text(row.label)
                    .font(.system(size: 16))
                    .foregroundStyle(row.role == .destructive ? Color.red : Color.primary)
                Spacer()
                if row.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                if row.role == .navigation {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
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
}
#endif
