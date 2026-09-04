import SwiftUI

// MARK: - Quick-Launch Strip

/// The row of circular quick-start buttons, shared by the collapsed Machines
/// panel header (`GlassSessionsList`) and each folded machine row
/// (`MachineRowExpandable`).
///
/// It exists because those two sites each had their own copy of the loop and had
/// already drifted: the header had grown model-aligned API circles while both
/// kept harness-aligned CLI circles, so the same panel showed two different icon
/// vocabularies. One component, one vocabulary — the model's `ModelIdentity`
/// glyph and colour, with a small harness badge so an Opus session carried by
/// Claude Code still reads differently from an Opus session over the API.
///
/// `machine` is the CLI target's destination, and CLI targets can't launch
/// without one. API targets can, so they render even when no machine is passed.
///
/// That is a statement about *launching*, not about execution: an API chat still
/// reaches the paired-or-default machine for its repo tools
/// (`resolveRepoTarget` in `RepoToolsCore.ts`). Don't read "no machine required"
/// as "never touches a machine", and don't read either as a billing claim —
/// billing is the harness sign-in vs Ripul's platform key, which is a separate
/// axis entirely. `QuickLaunchPicker` is where that gets spelled out.
///
/// The circles are the opt-in presentation (`showCircles`, backed by
/// `QuickLaunchPreferences.showCircles`). The default strip is a single
/// "New Session" button — the picker's labelled presentation — which opens the
/// same full catalog the ellipsis does when the circles are on.
struct QuickLaunchStrip: View {
    /// Resolved shortcuts, in user order. Resolution happens in the parent —
    /// the view that owns the `RipulSessionCache` — matching how every other
    /// cache-derived value reaches `MachineRowExpandable`.
    let targets: [QuickLaunchTarget]
    /// Destination for CLI launches. Nil ⇒ CLI circles are omitted.
    let machine: RemoteMachine?
    /// Id of the target currently launching, shown as a spinner. Owned by the
    /// parent because it also clears it on session-count / connect changes.
    @Binding var loadingId: String?
    /// `uiKitIdentifier` namespace, e.g. "GlassSessionsList.machines".
    let identifierPrefix: String
    /// (machine, providerKey, modelId) — the model id is what makes the shortcut
    /// model-aligned rather than "whatever this harness defaults to". Optional
    /// in the signature to match the shared callback (menu entries pass nil for
    /// "harness default"); the strip always names a model.
    var onNewCliSession: ((RemoteMachine, String, String?) -> Void)?
    var onNewApiSession: ((String) -> Void)?
    /// Every offerable model, for the trailing "more models" picker. Empty ⇒ no
    /// picker button, which is the default so embedded SDK hosts that render
    /// this strip keep exactly the UI they have today.
    var allTargets: [QuickLaunchTarget] = []
    /// Needed to persist pin/unpin from the picker. Nil ⇒ no picker button.
    var cache: RipulSessionCache?
    /// Whether the pinned-model circles show. Resolved by the parent from
    /// `QuickLaunchPreferences.showCircles`. Default true so embedded hosts
    /// that never thread the preference keep the circles they render today.
    /// False ⇒ the strip's only affordance is the picker's "New Session"
    /// button — which needs the picker wiring, so a false here with no picker
    /// falls back to the circles rather than rendering nothing at all.
    var showCircles: Bool = true
    /// A launch is in flight beyond what `loadingId` covers — e.g. the
    /// machine-level connect that follows a model pick. Only the labelled
    /// "New Session" pill uses it (it animates itself); the launching circle
    /// already swaps its icon for a spinner inside its fixed 32×32 frame.
    var isLaunching: Bool = false
    /// Opens the Claude account switcher for `machine` (long-press on the
    /// picker button). Nil ⇒ no context menu — embedded hosts keep exactly
    /// the UI they have today.
    var onSwitchAccount: (() -> Void)? = nil

    /// Targets we can actually launch given what the caller wired up. CLI and
    /// axis-2 subscription both need a host; only platform-API can start without.
    private var launchable: [QuickLaunchTarget] {
        targets.filter { target in
            if target.isCli { return machine != nil && onNewCliSession != nil }
            if target.model.isSubscription { return machine != nil && onNewApiSession != nil }
            return onNewApiSession != nil
        }
    }

    /// The picker is additive: it appears only when the caller supplies both the
    /// full catalog and a cache to write pins to.
    private var pickerCache: RipulSessionCache? {
        allTargets.isEmpty ? nil : cache
    }

    /// What the strip actually draws. The circles only yield to the lone
    /// "New Session" button when the picker exists to replace them — otherwise
    /// the gate would erase the strip's every launch affordance.
    private var effectiveShowCircles: Bool {
        showCircles || pickerCache == nil
    }

    var body: some View {
        HStack(spacing: 6) {
            if effectiveShowCircles {
                ForEach(launchable) { target in
                    Button {
                        loadingId = target.id
                        if let providerKey = target.providerKey, let machine {
                            onNewCliSession?(machine, providerKey, target.model.id)
                        } else {
                            onNewApiSession?(target.model.id)
                        }
                    } label: {
                        icon(for: target)
                            .frame(width: 32, height: 32)
                    }
                    .modifier(GlassCircleModifier(glassStyle: "regular"))
                    .buttonStyle(.plain)
                    .help(helpText(for: target))
                    .uiKitIdentifier("\(identifierPrefix).quickModel\(target.model.id)")
                }
            }
            if let pickerCache {
                QuickLaunchPickerButton(
                    allTargets: allTargets,
                    machine: machine,
                    cache: pickerCache,
                    identifierPrefix: identifierPrefix,
                    loadingId: $loadingId,
                    onNewCliSession: onNewCliSession,
                    onNewApiSession: onNewApiSession,
                    labelled: !effectiveShowCircles,
                    isLaunching: isLaunching,
                    onSwitchAccount: onSwitchAccount
                )
            }
        }
    }

    @ViewBuilder
    private func icon(for target: QuickLaunchTarget) -> some View {
        if loadingId == target.id {
            ProgressView().controlSize(.small)
        } else if let identity = target.identity {
            // Model-aligned: the same text glyph the chat's respondent lozenge
            // uses for this family.
            Text(identity.glyph)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(identity.color)
                .overlay(alignment: .bottomTrailing) { harnessBadge(for: target) }
        } else {
            // Unknown family — fall back to the harness glyph so the button is
            // still recognisable rather than blank.
            Image(systemName: target.providerSymbol ?? "message.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(target.color)
        }
    }

    /// Tiny harness mark on CLI targets. Keeps the model as the identity while
    /// still distinguishing "Opus via Claude Code" from "Opus via the API",
    /// which would otherwise be the same glyph twice in one strip.
    @ViewBuilder
    private func harnessBadge(for target: QuickLaunchTarget) -> some View {
        if let symbol = target.providerSymbol {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
                .offset(x: 4, y: 3)
        }
    }

    private func helpText(for target: QuickLaunchTarget) -> String {
        guard let key = target.providerKey else { return "New \(target.displayLabel) chat" }
        return "New \(target.displayLabel) session (\(ProviderConstants.legacyLabel(for: key)))"
    }
}
