import SwiftUI

// MARK: - Quick-Launch Picker

/// The full-catalog launch affordance of `QuickLaunchStrip`.
///
/// The strip shows *pinned* models as circles; this shows **everything**
/// `QuickLaunchPreferences.offerableTargets` will offer, with the metadata the
/// circles can't carry — who pays for the session, and whether it can start at
/// all without a machine. It has two trigger presentations: the trailing
/// ellipsis circle when the circles are showing, and the standalone "New
/// Session" pill that replaces the whole strip when they're gated off
/// (`QuickLaunchPreferences.showCircles`).
///
/// The list itself is `ModelPickerList` in `.launch` mode: this file is now only
/// the popover chrome plus the CLI-vs-API routing a launch needs. Sections,
/// pins, ordering and the billing subtitles are the shared picker's, so every
/// other "which model?" surface says exactly the same things in the same order.
///
/// Deliberately **not** a SwiftUI `Menu`: menu rows are single buttons, so they
/// can't carry a secondary metadata line *and* an independent pin control. A
/// popover hosting a `List` gives both, and adapts to a sheet on iPhone for
/// free. (Native-first: this is the platform control for a rich picker, not a
/// re-skinned web dropdown.)
struct QuickLaunchPickerButton: View {
    /// Every offerable model, pinned or not. Resolved by the parent that owns
    /// the cache, matching how `targets` reaches the strip.
    let allTargets: [QuickLaunchTarget]
    /// Destination for CLI launches. Nil ⇒ CLI rows show but can't launch.
    let machine: RemoteMachine?
    let cache: RipulSessionCache
    /// `uiKitIdentifier` namespace, e.g. "GlassSessionsList.machines".
    let identifierPrefix: String
    @Binding var loadingId: String?
    var onNewCliSession: ((RemoteMachine, String, String?) -> Void)?
    var onNewApiSession: ((String) -> Void)?
    /// Presentation of the trigger. False is the trailing ellipsis circle that
    /// follows the pinned-model circles; true is the standalone "New Session"
    /// pill that IS the strip when the circles are gated off — same popover,
    /// same routing, only the chrome differs.
    var labelled: Bool = false
    /// A launch is in flight beyond what `loadingId` covers — the row passes
    /// its machine-level connect so the pill keeps pulsing until the session
    /// actually exists. Only the labelled pill consumes this.
    var isLaunching: Bool = false
    /// Long-press affordance: open the Claude account switcher for `machine`.
    /// Nil ⇒ no context menu.
    var onSwitchAccount: (() -> Void)? = nil

    @State private var isPresented = false

    /// The pill's in-progress state: a model pick on this button
    /// (`loadingId`) or the machine-level connect the row reports
    /// (`isLaunching`).
    private var launching: Bool { isLaunching || loadingId != nil }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            if labelled {
                Label(launching ? "Starting…" : "New Session", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    // Never wrap, never compress: the machine-row header used
                    // to place a spinner beside this pill that shrank it until
                    // "New Session" broke onto two lines.
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 14)
                    .frame(height: 32)
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
        }
        .modifier(QuickLaunchTriggerGlass(labelled: labelled))
        // The button IS the progress indicator — a sibling spinner next to it
        // was what squeezed the label, so the pill breathes instead.
        .modifier(LaunchPulse(active: labelled && launching))
        .buttonStyle(.plain)
        .disabled(labelled && launching)
        .help(labelled ? "New session" : "All models")
        .uiKitIdentifier("\(identifierPrefix).quickModelPicker")
        // The 2-tap account switch: long-press → "Switch Claude account…".
        // Lives on the launch button because "which account pays" is a launch
        // decision; Settings remains the discoverable home.
        .contextMenu {
            if let onSwitchAccount {
                Button {
                    onSwitchAccount()
                } label: {
                    Label("Switch Claude account…", systemImage: "person.2")
                }
                .uiKitIdentifier("\(identifierPrefix).quickModelPicker.switchAccount")
            }
        }
        .popover(isPresented: $isPresented) {
            ModelPickerSheetContent(
                title: "New session",
                models: allTargets.map(\.model),
                cache: cache,
                purpose: .launch(machine: machine),
                identifierPrefix: identifierPrefix,
                loadingId: $loadingId,
                onPick: { model in
                    guard let model else { return }
                    launch(model)
                },
                onDismiss: { isPresented = false }
            )
            .frame(minWidth: 340, minHeight: 420)
        }
    }

    // MARK: Actions

    /// Route the pick: a CLI model launches a harness session on the machine, an
    /// API model (platform or subscription) opens a new chat pinned to it.
    ///
    /// The picker disables rows that need a machine when there isn't one, but it
    /// knows nothing about which callbacks this caller wired up — so a pick with
    /// no handler is dropped here rather than leaving a spinner running on a
    /// launch that was never going to happen.
    private func launch(_ model: ModelInfo) {
        let target = QuickLaunchTarget.resolve(model: model)
        if let providerKey = target.providerKey {
            guard let machine, let onNewCliSession else { return }
            loadingId = target.id
            onNewCliSession(machine, providerKey, target.model.id)
        } else {
            guard let onNewApiSession else { return }
            loadingId = target.id
            onNewApiSession(target.model.id)
        }
        isPresented = false
    }
}

// MARK: - Trigger chrome

/// Gentle continuous opacity pulse marking the pill's launch-in-flight state.
/// The non-trigger `phaseAnimator` form loops for as long as the view exists,
/// so it is only installed while `active` — the if/else swap is the on/off
/// switch, and removing it restores full opacity instantly.
private struct LaunchPulse: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, phase in
                view.opacity(phase ? 0.55 : 1)
            } animation: { _ in
                .easeInOut(duration: 0.6)
            }
        } else {
            content
        }
    }
}

/// The two trigger shapes share one popover: the pill for the standalone
/// "New Session" button, the circle for the strip's trailing ellipsis. One
/// modifier so the button body stays a single `if` over its label.
private struct QuickLaunchTriggerGlass: ViewModifier {
    let labelled: Bool

    func body(content: Content) -> some View {
        if labelled {
            content.modifier(GlassPillModifier())
        } else {
            content.modifier(GlassCircleModifier(glassStyle: "regular"))
        }
    }
}
