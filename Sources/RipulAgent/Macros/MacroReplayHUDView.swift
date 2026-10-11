#if os(iOS)
import SwiftUI

/// The deterministic-replay HUD strip: a bottom-docked glass bar (the
/// mini-player idiom, matching `CompactAgentBarView`) shown while a macro
/// replays — spinner + the current executing line while running, the outcome
/// for a couple of seconds after, then it hands the bottom edge back to the
/// compact bar / bubble. Lives in the dev overlay window, which the screen
/// actuation tools already exclude from matching, so macro steps can never
/// target it.
@available(iOS 26.0, *)
struct MacroReplayHUDView: View {
    @ObservedObject var controller: MacroReplayHUDController

    var body: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .running:
                ProgressView()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Replaying \(controller.macroName)")
                        .font(.ripul(.subheadline, weight: .semibold))
                        .lineLimit(1)
                    Text("\(controller.currentIndex + 1)/\(controller.stepLabels.count) · \(controller.currentLabel ?? "")")
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(1)
                }
            case .finished:
                if let outcome = controller.outcome {
                    Image(systemName: outcome.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(outcome.success ? .ripul(.success) : .ripul(.danger))
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(outcome.success
                             ? "\(controller.macroName) completed"
                             : "\(controller.macroName) stopped at step \((outcome.failedStepIndex ?? 0) + 1)")
                            .font(.ripul(.subheadline, weight: .semibold))
                            .lineLimit(1)
                        if let error = outcome.error {
                            Text(error)
                                .font(.ripul(.caption))
                                .foregroundStyle(.ripul(.textSecondary))
                                .lineLimit(1)
                        } else {
                            Text("Tap to return to the editor")
                                .font(.ripul(.caption))
                                .foregroundStyle(.ripul(.textSecondary))
                                .lineLimit(1)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.textTertiary))
                }
            case .hidden:
                EmptyView()
            }

            Spacer()

            Button {
                controller.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.ripulIcon(size: 13, weight: .semibold))
                    .foregroundStyle(.ripul(.text))
                    .frame(width: 32, height: 32)
                    .modifier(GlassCircleModifier(glassStyle: "regular"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss replay")
            .uiKitIdentifier("MacroReplayHUD.dismissButton")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Finished: the whole strip is the return ticket to the editor.
        .onTapGesture {
            if controller.phase == .finished { controller.openContext() }
        }
        .uiKitIdentifier("MacroReplayHUD.strip")
    }
}

/// Production presenter: the dev overlay hosts the strip — available only
/// when its window exists; collapse reveals the host screen behind.
@available(iOS 26.0, *)
public struct DevOverlayReplayPresenter: MacroReplayPresenting {
    public init() {}
    public var canPresent: Bool { RipulDevAssistantOverlay.shared.hasOverlayWindow }
    public func collapseForReplay() { RipulDevAssistantOverlay.shared.collapse() }
}
#endif
