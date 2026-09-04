import SwiftUI

/// Which plans have a run in flight, host-wide.
///
/// The unified session list is the truth for "is an agent working this plan"
/// — but it lags a start by several seconds (session creation, plan-tag
/// propagation, the first turn-phase report). Every screen that derived state
/// only from the list showed a stale call-to-action during exactly the
/// seconds the user was watching: the plan list said "draft me" and the
/// checkpoint offered "Draft with agent" while the draft was already running.
///
/// This object bridges that gap: every start path announces here (which also
/// posts `.ripulPlanRunStarted`), and readers treat a recent announcement as
/// running until the real session state arrives or a timeout expires. It is
/// an optimistic overlay, never a second source of truth — the moment the
/// tagged session is visible and active, readers should `clear` the entry
/// and follow the list.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class PlanRunActivity: ObservableObject {
    public static let shared = PlanRunActivity()

    /// planKey → when a run last started. Cleared on finish, on real session
    /// state arriving, or by the read-side timeout.
    @Published public private(set) var startedAt: [String: Date] = [:]

    private var observers: [NSObjectProtocol] = []

    private init() {
        // Belt-and-suspenders: a poster that bypasses announceStart still
        // records, and every finish clears.
        observers.append(NotificationCenter.default.addObserver(
            forName: .ripulPlanRunStarted, object: nil, queue: .main
        ) { [weak self] note in
            guard let key = note.userInfo?["planKey"] as? String else { return }
            MainActor.assumeIsolated { self?.startedAt[key] = Date() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ripulPlanRunFinished, object: nil, queue: .main
        ) { [weak self] note in
            guard let key = note.userInfo?["planKey"] as? String else { return }
            MainActor.assumeIsolated { self?.startedAt[key] = nil }
        })
    }

    /// The one way to say "a run just started on this plan": records the
    /// optimistic entry FIRST (so the singleton exists and the state is set
    /// before any observer reacts), then posts `.ripulPlanRunStarted`.
    public static func announceStart(planKey: String) {
        shared.startedAt[planKey] = Date()
        NotificationCenter.default.post(
            name: .ripulPlanRunStarted,
            object: nil,
            userInfo: ["planKey": planKey]
        )
    }

    /// True while a start announcement is fresh. The timeout is generous —
    /// it only matters when a finish signal was missed entirely, and a
    /// briefly-stale spinner beats a call-to-action on a running plan.
    public func recentlyStarted(_ planKey: String, within seconds: TimeInterval = 150) -> Bool {
        guard let at = startedAt[planKey] else { return false }
        return Date().timeIntervalSince(at) < seconds
    }

    /// Real session state has arrived (or the run finished) — the overlay
    /// has done its job for this plan.
    public func clear(_ planKey: String) {
        if startedAt[planKey] != nil { startedAt[planKey] = nil }
    }
}
