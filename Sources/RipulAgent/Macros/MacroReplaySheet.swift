#if os(iOS)
import SwiftUI

/// The deterministic-replay sheet (docs/plans/automation-macros/phase-4
/// follow-up): one presentation that IS the confirmation, the param entry,
/// and the live per-step pass/fail readout — replacing the earlier
/// confirm-dialog → silent-run → aggregate-alert flow, which gave zero
/// feedback while the replay ran ("it did not seem to run").
///
/// The Replay button is the confirmation itself: one explicit tap that says
/// "yes, act on the host screen for real." While running, each step's status
/// icon updates live (pending → running → passed/failed, with the failing
/// step's error inline). Steps act on the host app's window behind the
/// console — minimize the console to watch them fire.
@available(iOS 16.0, *)
struct MacroReplaySheet: View {
    let macro: RipulMacro

    @State private var paramValues: [String: String] = [:]
    @State private var statuses: [StepStatus] = []
    @State private var isRunning = false
    @State private var outcome: MacroReplayResult?
    /// Brief "Copied" flip after tapping the copy-log button.
    @State private var didCopy = false
    @Environment(\.dismiss) private var dismiss

    private enum StepStatus {
        case pending, running
        case succeeded(via: String?, detail: String?, durationMs: Int)
        case failed(error: String?, detail: String?, durationMs: Int)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(macro.steps.count) step\(macro.steps.count == 1 ? "" : "s") · runs on the app screen behind this console — minimize the console to watch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !macro.parameters.isEmpty {
                    Section("Parameters") {
                        ForEach(macro.parameters, id: \.name) { parameter in
                            TextField(
                                parameter.description.isEmpty ? parameter.name : "\(parameter.name) — \(parameter.description)",
                                text: Binding(
                                    get: { paramValues[parameter.name] ?? "" },
                                    set: { paramValues[parameter.name] = $0 }
                                )
                            )
                            .autocorrectionDisabled()
                            .disabled(isRunning || outcome != nil)
                            .uiKitIdentifier("MacroReplaySheet.field.\(parameter.name)")
                        }
                    }
                }

                Section("Steps") {
                    ForEach(Array(macro.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            statusIcon(for: index)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.recordedLabel)
                                    .font(.subheadline)
                                switch status(for: index) {
                                case .failed(let error, _, let durationMs):
                                    Text("\(error ?? "failed") · \(Self.formatMs(durationMs))")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                case .succeeded(let via, let detail, let durationMs):
                                    Text([via.map { "via \($0)" }, Self.formatMs(durationMs)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let detail {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                    }
                                default:
                                    EmptyView()
                                }
                            }
                        }
                    }
                }

                if let outcome {
                    Section {
                        Label(
                            outcome.success
                                ? "All \(outcome.totalSteps) steps completed."
                                : "Stopped at step \((outcome.failedStepIndex ?? 0) + 1) of \(outcome.totalSteps) — \(outcome.error ?? "unknown error")",
                            systemImage: outcome.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(outcome.success ? .green : .red)
                        .font(.subheadline.weight(.medium))
                    }
                }
            }
            .navigationTitle("Replay \(macro.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(outcome != nil ? "Done" : "Cancel") { dismiss() }
                        .uiKitIdentifier("MacroReplaySheet.dismissButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if outcome == nil {
                        Button {
                            Task { await start() }
                        } label: {
                            if isRunning {
                                ProgressView()
                            } else {
                                Text("Replay")
                                    .fontWeight(.semibold)
                            }
                        }
                        .disabled(isRunning)
                        .uiKitIdentifier("MacroReplaySheet.replayButton")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        copyLog()
                    } label: {
                        Label(didCopy ? "Copied" : "Copy log", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.subheadline)
                    }
                    // Only meaningful once something has happened — before the
                    // first Replay tap there's no log to take.
                    .disabled(statuses.allSatisfy { if case .pending = $0 { return true } else { return false } })
                    .uiKitIdentifier("MacroReplaySheet.copyLogButton")
                }
            }
        }
        .onAppear {
            if statuses.isEmpty {
                statuses = Array(repeating: .pending, count: macro.steps.count)
            }
        }
    }

    private func status(for index: Int) -> StepStatus? {
        statuses.indices.contains(index) ? statuses[index] : nil
    }

    @ViewBuilder
    private func statusIcon(for index: Int) -> some View {
        switch status(for: index) {
        case .running:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        default:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }

    private func start() async {
        // HUD mode (the overlay exists — iOS 26+ only, which is also the
        // overlay's own floor, so below 26 there is never a HUD to host):
        // hand the run to the replay HUD — this sheet closes, the console
        // collapses, and a bottom strip shows the current executing line
        // while the host screen stays visible and touchable. Otherwise (a
        // console not hosted in the overlay) keep the in-sheet live view.
        if #available(iOS 26.0, *),
           MacroReplayHUDController.shared.begin(
               macro,
               parameters: paramValues,
               resolver: LiveScreenResolver(),
               presenter: DevOverlayReplayPresenter()
           ) {
            dismiss()
            return
        }
        isRunning = true
        statuses = Array(repeating: .pending, count: macro.steps.count)
        guard let result = try? await (MacroReplayEngine.replay(
            macro,
            parameters: paramValues,
            resolver: LiveScreenResolver()
        ) { event in
            guard statuses.indices.contains(event.index) else { return }
            switch event.phase {
            case .started:
                statuses[event.index] = .running
            case .succeeded(let via, let detail, let durationMs):
                statuses[event.index] = .succeeded(via: via, detail: detail, durationMs: durationMs)
            case .failed(let error, let detail, let durationMs):
                statuses[event.index] = .failed(error: error, detail: detail, durationMs: durationMs)
            }
        }) else {
            isRunning = false
            return
        }
        outcome = result
        isRunning = false
    }

    /// The full replay transcript as plain text — paste-ready for a bug
    /// report or a chat message: macro name, param values used, and per step
    /// the action outcome (via path + duration), the selector it looked for,
    /// and the element it actually matched. The outcome line carries the
    /// total wall-clock time.
    private func logText() -> String {
        var lines: [String] = ["Replay: \(macro.name) — \(macro.steps.count) step\(macro.steps.count == 1 ? "" : "s")"]
        for parameter in macro.parameters {
            lines.append("  \(parameter.name) = \"\(paramValues[parameter.name] ?? "")\"")
        }
        for (index, step) in macro.steps.enumerated() {
            let prefix = "\(index + 1). \(step.recordedLabel)"
            switch status(for: index) {
            case .succeeded(let via, let detail, let durationMs):
                let viaPart = via.map { "via \($0) · " } ?? ""
                lines.append("✓ \(prefix) — \(viaPart)\(Self.formatMs(durationMs))")
                if !step.selector.compactSummary.isEmpty {
                    lines.append("   selector: \(step.selector.compactSummary)")
                }
                if let detail { lines.append("   matched: \(detail)") }
            case .failed(let error, _, let durationMs):
                lines.append("✗ \(prefix) — \(error ?? "failed") · \(Self.formatMs(durationMs))")
                if !step.selector.compactSummary.isEmpty {
                    lines.append("   selector: \(step.selector.compactSummary)")
                }
            case .running:
                lines.append("… \(prefix) (running)")
            default:
                lines.append("· \(prefix) (pending)")
            }
        }
        if let outcome {
            let totalMs = outcome.stepResults.map(\.durationMs).reduce(0, +)
            lines.append(outcome.success
                ? "Outcome: all \(outcome.totalSteps) steps completed in \(Self.formatMs(totalMs))."
                : "Outcome: stopped at step \((outcome.failedStepIndex ?? 0) + 1) of \(outcome.totalSteps) — \(outcome.error ?? "unknown error")")
        } else if isRunning {
            lines.append("Outcome: running…")
        }
        return lines.joined(separator: "\n")
    }

    /// "240ms" below a second, "1.2s" above — log-friendly durations.
    static func formatMs(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
    }

    private func copyLog() {
        UIPasteboard.general.string = logText()
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}
#endif
