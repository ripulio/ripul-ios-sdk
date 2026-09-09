import Foundation
import Combine

/// Kept separate from AgentBridge so progress updates don't redraw its web view.
@MainActor
public final class StartupLoadState: ObservableObject {
    @Published public internal(set) var message = "Preparing app…"
    @Published public internal(set) var isTakingLonger = false
}

/// Foreground-time budget. Only actual progress (not an outstanding request or
/// a repeating auth poll) renews the idle allowance. The overall cap never moves.
struct StartupLoadBudget {
    enum Failure: Equatable { case stalled, overallLimit }
    private(set) var elapsed: TimeInterval = 0
    private(set) var idle: TimeInterval = 0
    private var lastSample: TimeInterval?
    private var wasActive = false
    private var milestones: Set<String> = []
    let idleLimit: TimeInterval = 30
    let overallLimit: TimeInterval = 120

    mutating func sample(at now: TimeInterval, isActive: Bool) {
        if let lastSample, wasActive { advance(by: now - lastSample) }
        lastSample = now
        wasActive = isActive
    }

    mutating func reachedMilestone(_ name: String) {
        if milestones.insert(name).inserted { madeProgress() }
    }

    mutating func advance(by seconds: TimeInterval) {
        elapsed += max(0, seconds)
        idle += max(0, seconds)
    }

    mutating func madeProgress() { idle = 0 }

    var failure: Failure? {
        if elapsed >= overallLimit { return .overallLimit }
        if idle >= idleLimit { return .stalled }
        return nil
    }
}
