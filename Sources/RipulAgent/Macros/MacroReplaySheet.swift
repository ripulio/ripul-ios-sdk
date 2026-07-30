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
    @Environment(\.dismiss) private var dismiss

    private enum StepStatus {
        case pending, running, succeeded(via: String?), failed(error: String?)
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
                                if case .failed(let error) = status(for: index), let error {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else if case .succeeded(let via) = status(for: index), let via {
                                    Text("via \(via)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
        isRunning = true
        statuses = Array(repeating: .pending, count: macro.steps.count)
        let result = await MacroReplayEngine.replay(
            macro,
            parameters: paramValues,
            resolver: LiveScreenResolver()
        ) { event in
            guard statuses.indices.contains(event.index) else { return }
            switch event.phase {
            case .started:
                statuses[event.index] = .running
            case .succeeded(let via):
                statuses[event.index] = .succeeded(via: via)
            case .failed(let error):
                statuses[event.index] = .failed(error: error)
            }
        }
        outcome = result
        isRunning = false
    }
}
#endif
