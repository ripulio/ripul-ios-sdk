import Foundation

/// Where a chat move is. Mirrors `MoveProgress` in the web's remoteConnectBridge.ts.
public struct MoveChatProgress: Equatable, Sendable {
    /// The steps of a move, in order.
    public enum Step: String, CaseIterable, Sendable {
        case export, `import`, open, removeOriginal, done
    }

    public var step: Step
    /// 0…1 across the whole move.
    public var fraction: Double
    /// One line saying what is happening: "Sending 12 MB of 44 MB from MacBook Pro".
    public var detail: String

    public init(step: Step, fraction: Double, detail: String) {
        self.step = step
        self.fraction = fraction
        self.detail = detail
    }
}

/// What a move came to.
public struct MoveSessionOutcome: Sendable {
    public var success = false
    public var newChatId: String?
    public var effectiveCwd: String?
    public var cwdFallback = false
    public var targetMachineName: String?
    public var sourceMachineName: String?
    public var error: String?
    /// On failure: the step that failed.
    public var failedStep: MoveChatProgress.Step?
    /// The original was removed from its Mac once the target held the chat.
    public var sourceRemoved = false
    public var sourceRemoveError: String?
}

/// A move the list is running or has just finished, for the move sheet.
public struct MoveChatState: Identifiable, Equatable {
    public enum Outcome: Equatable {
        /// Moved. Notes are things to know, such as a folder that doesn't exist there.
        case moved(notes: [String])
        case failed(message: String, step: MoveChatProgress.Step)
    }

    /// Also the progress id the web reports under.
    public let id: String
    public let sessionId: String
    public let chatTitle: String
    public let sourceName: String
    public let targetName: String
    public let targetMachineId: String
    public var progress: MoveChatProgress
    /// Nil while the move runs.
    public var outcome: Outcome?

    public var isRunning: Bool { outcome == nil }

    /// What the failure leaves, in plain words. A failed export changed nothing;
    /// a stalled import may still finish on the target.
    public var failureConsequence: String? {
        guard case .failed(_, let step) = outcome else { return nil }
        switch step {
        case .export, .import:
            return "Your chat is still on \(sourceName)."
        case .open:
            return "The chat reached \(targetName), but couldn't be opened here. The original is still on \(sourceName)."
        case .removeOriginal, .done:
            return nil
        }
    }
}
