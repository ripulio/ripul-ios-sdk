import Foundation

// The two decisions behind recovering a wedged web layer, kept apart from the
// bridge so they can be read and tested without a web view or a clock:
// which rung of the self-heal ladder comes next, and when a host bridge that
// keeps saying "unavailable" has said it for long enough to be looked into.

/// The escalating self-heal.
///
/// A plain reload() is NOT enough: the wedge often recurs on the fresh boot
/// because persisted state re-poisons it (remote-tab-pairings / cliSessionMap
/// in localStorage rebind to a dead/stranded machine; IndexedDB preloads
/// stale chat actions). That is exactly why the manual fix is "Clear cache &
/// reload" + "Clear sessions data", not just a reload. So the heal escalates:
///   attempt 1 → reload                       (cheap, fixes transient wedges)
///   attempt 2 → purge web state and reload   (auto "clear sessions data")
///   attempt 3 → purge web state and reload   (network may have settled)
///   attempt 4+ → a persistent ladder keeps purging with exponential backoff
///               (the Mac host is often unattended — giving up leaves it
///               dead). Otherwise it stops, because the user is present and
///               can tap Retry.
/// A short FLOOR between heals prevents a tight loop; the ESCALATION WINDOW
/// resets the ladder so a later, unrelated incident starts cheap again.
struct HealLadder: Equatable {
    enum Rung: Equatable {
        case reload
        case purge
        /// Attempt 4 and beyond on a persistent ladder: still purging.
        case persistentPurge
        /// Attempt 4 and beyond otherwise: nothing more is tried automatically.
        case exhausted
    }

    enum Step: Equatable {
        /// The last heal was `since` seconds ago and this attempt has to wait `floor`.
        case tooSoon(since: TimeInterval, floor: TimeInterval)
        /// `floor` is the wait this attempt had to clear.
        case heal(attempt: Int, rung: Rung, floor: TimeInterval)
    }

    /// Minimum gap between heals — stops a reload storm.
    static let baseFloor: TimeInterval = 10
    /// Maximum time between heals on a persistent ladder (5 minutes).
    static let maxFloor: TimeInterval = 300
    /// Heals within this window escalate; a heal after it resets the ladder.
    static let escalationWindow: TimeInterval = 90

    /// Keep going past the third attempt. True on macOS.
    let persistent: Bool
    private(set) var lastHealAt: Date?
    private(set) var attempts = 0

    init(persistent: Bool) {
        self.persistent = persistent
    }

    /// Gap required before `attempt`. A persistent ladder backs off
    /// exponentially after 3 attempts so an unattended host keeps retrying
    /// without hammering CPU/network/battery.
    func floor(for attempt: Int) -> TimeInterval {
        if persistent, attempt > 3 {
            let backoff = Self.baseFloor * pow(2.0, Double(min(attempt - 3, 5)))
            return min(backoff, Self.maxFloor)
        }
        return Self.baseFloor
    }

    /// How long until the floor after the last heal has passed.
    func remainingFloor(at now: Date) -> TimeInterval {
        guard let last = lastHealAt else { return 0 }
        return max(0, floor(for: attempts) - now.timeIntervalSince(last))
    }

    /// Take the next rung, unless it is too soon.
    mutating func next(at now: Date) -> Step {
        let floor = floor(for: attempts + 1)
        if let last = lastHealAt {
            let since = now.timeIntervalSince(last)
            if since < floor { return .tooSoon(since: since, floor: floor) }
            if since > Self.escalationWindow { attempts = 0 }
        }
        lastHealAt = now
        attempts += 1
        let rung: Rung
        switch attempts {
        case 1: rung = .reload
        case 2, 3: rung = .purge
        default: rung = persistent ? .persistentPurge : .exhausted
        }
        return .heal(attempt: attempts, rung: rung, floor: floor)
    }

    /// The page came back, or the user stepped in: the next incident starts
    /// at the first rung. The floor since the last heal still applies.
    mutating func reset() {
        attempts = 0
    }
}

/// When a host bridge that keeps reporting "unavailable" is worth a probe.
///
/// The host-status callable can report total failure in a way that LOOKS like
/// a successful call: `{available:false}` is a well-formed dictionary, so the
/// eval-failure counter never arms, and a permanently dead web boot is
/// indistinguishable from an idle host. Every recovery mechanism keys off an
/// *exception*, and this state produces none. So every caller reports here,
/// and once the bridge has been continuously unavailable for `grace` the
/// caller is told to probe.
struct HostBridgeBackstop: Equatable {
    enum Note: Equatable {
        /// First report of this outage.
        case armed
        /// Still inside the grace period, or probed too recently.
        case waiting
        /// Unavailable since `since`: look at the page.
        case probe(since: Date)
    }

    /// Continuous unavailability tolerated before probing. Comfortably longer
    /// than the callable-install grace so an ordinary cold boot never trips it.
    static let grace: TimeInterval = 15
    /// Minimum gap between probes — callers poll as fast as 1Hz.
    static let probeInterval: TimeInterval = 15

    private(set) var unavailableSince: Date?
    private var lastProbeAt: Date?

    /// The bridge answered normally. True when there was an outage to clear.
    mutating func noteAvailable() -> Bool {
        let wasUnavailable = unavailableSince != nil
        unavailableSince = nil
        lastProbeAt = nil
        return wasUnavailable
    }

    /// The bridge is unavailable. Safe at any cadence, from any number of callers.
    mutating func noteUnavailable(at now: Date) -> Note {
        guard let since = unavailableSince else {
            unavailableSince = now
            return .armed
        }
        guard now.timeIntervalSince(since) >= Self.grace else { return .waiting }
        if let last = lastProbeAt, now.timeIntervalSince(last) < Self.probeInterval { return .waiting }
        lastProbeAt = now
        return .probe(since: since)
    }
}
