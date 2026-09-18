import Foundation

public extension AgentBridge {
    /// Local catalogues can arrive before the web session handlers on a cold
    /// window. Keep the row's existing opening indicator until they are ready.
    @MainActor func waitForSessionsReady(timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isSessionsReady && !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return isSessionsReady && !Task.isCancelled
    }
}
