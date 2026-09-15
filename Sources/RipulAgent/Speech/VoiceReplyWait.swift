import Foundation

/// Cancellation must end the wait, not turn a cancelled sleep into a busy loop.
enum VoiceReplyWait {
    @MainActor
    static func untilPlaybackEnds(
        timeout: Duration = .seconds(360),
        pollInterval: Duration = .milliseconds(200),
        isPending: @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            guard isPending() else { return true }
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: pollInterval)
        }
    }
}
