import SwiftUI

/// The dialog for Move to Machine: where the move is, and how it ended.
///
/// A move used to report only through a notice at the foot of the list, and
/// one that failed after a minute of silence looked like nothing had happened.
/// Now every step shows as it runs, with a progress bar across the whole move,
/// and a failure says which Mac stopped, at what, and where the chat still is.
struct MoveChatSheet: View {
    let state: MoveChatState
    let onClose: () -> Void
    let onRetry: () -> Void

    private let steps: [MoveChatProgress.Step] = [.export, .import, .open, .removeOriginal]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressView(value: min(1, max(0, state.progress.fraction)))
                            .tint(failed ? Color.ripul(.danger) : .accentColor)
                            .animation(.easeOut(duration: 0.3), value: state.progress.fraction)
                            .uiKitIdentifier("MoveChatSheet.progress.bar")
                        Text(statusLine)
                            .font(.ripul(.subheadline))
                            .foregroundStyle(.ripul(.textSecondary))
                            .contentTransition(.opacity)
                            .uiKitIdentifier("MoveChatSheet.progress.detail")
                    }
                    .padding(.vertical, 4)
                } header: { RipulSectionHeader {
                    Text("From \(state.sourceName) to \(state.targetName)")
                        .uiKitIdentifier("MoveChatSheet.progress.route")
                } }

                Section {
                    ForEach(steps, id: \.self) { step in
                        Label {
                            Text(title(for: step))
                                .foregroundStyle(status(of: step) == .pending ? .ripul(.textSecondary) : .ripul(.text))
                        } icon: {
                            icon(for: status(of: step))
                        }
                        .uiKitIdentifier("MoveChatSheet.steps.row")
                    }
                }

                if case .failed(let message, _) = state.outcome {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message)
                                    .textSelection(.enabled)
                                if let consequence = state.failureConsequence {
                                    Text(consequence)
                                        .foregroundStyle(.ripul(.textSecondary))
                                }
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.ripul(.danger))
                        }
                        .uiKitIdentifier("MoveChatSheet.result.failure")
                    } header: { RipulSectionHeader {
                        Text("The move didn't finish")
                    } }
                }

                if case .moved(let notes) = state.outcome, !notes.isEmpty {
                    Section {
                        ForEach(notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .uiKitIdentifier("MoveChatSheet.result.note")
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state.isRunning ? "Hide" : (failed ? "Close" : "Done"), action: onClose)
                        .uiKitIdentifier("MoveChatSheet.toolbar.close")
                }
                if failed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Try Again", action: onRetry)
                            .uiKitIdentifier("MoveChatSheet.toolbar.retry")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(state.isRunning)
    }

    private var failed: Bool {
        if case .failed = state.outcome { return true }
        return false
    }

    private var navigationTitle: String {
        switch state.outcome {
        case nil: return "Moving “\(state.chatTitle)”"
        case .moved: return "Moved to \(state.targetName)"
        case .failed: return "Couldn't Move “\(state.chatTitle)”"
        }
    }

    private var statusLine: String {
        if case .failed(_, let step) = state.outcome { return "Stopped at: \(title(for: step))" }
        return state.progress.detail
    }

    private func title(for step: MoveChatProgress.Step) -> String {
        switch step {
        case .export: return "Copy the chat from \(state.sourceName)"
        case .import: return "Add it to \(state.targetName)"
        case .open: return "Open it on this device"
        case .removeOriginal: return "Remove the original from \(state.sourceName)"
        case .done: return "Done"
        }
    }

    private enum StepStatus { case pending, running, done, failed }

    private func status(of step: MoveChatProgress.Step) -> StepStatus {
        let all = MoveChatProgress.Step.allCases
        guard let index = all.firstIndex(of: step) else { return .pending }
        if case .failed(_, let failedStep) = state.outcome, let failedIndex = all.firstIndex(of: failedStep) {
            return index < failedIndex ? .done : (index == failedIndex ? .failed : .pending)
        }
        guard let current = all.firstIndex(of: state.progress.step) else { return .pending }
        if index < current { return .done }
        return index == current && state.isRunning ? .running : .pending
    }

    @ViewBuilder
    private func icon(for status: StepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.ripul(.textTertiary))
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.ripul(.success))
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.ripul(.danger))
        }
    }
}

/// Presents the move sheet for whichever move the list model holds.
struct MoveChatSheetHost: View {
    let model: RipulSessionListModel

    var body: some View {
        if let state = model.moveState {
            MoveChatSheet(state: state, onClose: { model.dismissMoveSheet() }, onRetry: { model.retryMove() })
        }
    }
}
