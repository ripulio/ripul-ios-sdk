import Foundation
import CoreGraphics

/// Where the native chat's visible top goes: the one owner of its scroll offset,
/// as pure arithmetic (8 November 2026).
///
/// Before it, eight places wrote the chat's offset, each on its own signal: the
/// entry hold, the follow glide, the reading-row correction, the keyboard, band
/// growth, stuck-layout recovery, jumps and restoration. A screenshot card landing
/// above a following chat was corrected twice (once by the entry hold on the new
/// content size, again by the row correction on the live offset) and the chat
/// "nods a few times" (Peter, on his Duo). The plan and the evidence are in
/// `docs/plans/native-chat-viewport-owner.md`.
///
/// The list (`NativeChatListScroller`) hands every committed layout to `commit`,
/// which answers the offset to apply in that same layout pass, and asks `advance`
/// for the next glide step each frame. Nothing else writes the offset; UIKit's own
/// finger, coast and bounce move it, and `noteManualOffset` tells the model.
///
/// The rules:
/// - Content that changes above the reference row moves the offset by exactly its
///   translation, so nothing on screen moves. Following, the reference is the newest
///   row present before and after; reading, the row being read; under a finger, the
///   first row on screen.
/// - Following, only growth below that row (a new row, a streaming or resizing tail
///   row) and a change of the clearance below the rows (the keyboard, the composer)
///   become distance to glide. A glide in flight keeps its lag and speed through a
///   history change: the change neither adds to it nor consumes it.
/// - Entering, the chat sits at its end on every commit, without a glide.
/// - Each layout is consumed once: committing the same geometry again moves nothing.
///   An intent set since (the end at once, a row to hold) is placed by that commit.
struct NativeChatViewport: Equatable {
    enum Intent: Equatable {
        /// Just entered: at the end on every commit, no glide, until a touch or `enterUntil`.
        case entering
        /// At the end and staying there; new tail content glides in.
        case following
        /// A row held at a place on screen: `screenOffset` is its top less the offset.
        case reading(rowID: String, screenOffset: CGFloat)
        /// A finger or a coast moves the chat; the first row on screen holds still
        /// through layout changes, and the offset is UIKit's.
        case manual
    }

    /// One committed layout, in the scroll view's content coordinates.
    struct Geometry: Equatable {
        /// Row ids top to bottom, and each row's top.
        var order: [String] = []
        var tops: [String: CGFloat] = [:]
        var contentHeight: CGFloat = 0
        var viewportHeight: CGFloat = 0
        /// Space above the first row and below the last that scrolls with the content:
        /// the bar's clearance and the composer's.
        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0

        /// The largest offset: the last row resting above the bottom clearance.
        var end: CGFloat { max(-topInset, contentHeight + bottomInset - viewportHeight) }
        var start: CGFloat { -topInset }

        /// The row on screen at `offset`: the last whose top is at or above it, else the
        /// first, with its top. A binary search: it runs on every frame of a scroll.
        func firstVisible(at offset: CGFloat) -> (id: String, top: CGFloat)? {
            guard !order.isEmpty else { return nil }
            var low = 0
            var high = order.count
            while low < high {
                let mid = (low + high) / 2
                if (tops[order[mid]] ?? .infinity) <= offset { low = mid + 1 } else { high = mid }
            }
            let id = order[max(0, low - 1)]
            return tops[id].map { (id, $0) }
        }
    }

    /// Spring rates for the follow glide, in radians a second. A sent message settles in
    /// about a third of a second; coming down to an end that rose (the keyboard going
    /// down), about 0.2 s, the keyboard's own.
    static let followSpring: Double = 16
    static let followSpringDown: Double = 30

    private(set) var intent: Intent = .entering
    /// The offset the model last decided or heard of.
    private(set) var offset: CGFloat = 0
    /// The last committed layout.
    private(set) var geometry: Geometry?
    /// The glide's speed toward the end, points a second.
    private(set) var velocity: CGFloat = 0
    /// Until when an entry holds the chat at its end (seconds, the caller's clock).
    private(set) var enterUntil: Double = 0
    /// Until when glides use the stiffer spring: the keyboard or composer is moving.
    private(set) var stiffUntil: Double = 0
    /// `follow(instantly:)` asked for the end: the next commit goes there.
    private var jumpToEnd = false

    /// Distance from the end: positive while the end is below the screen.
    var lag: CGFloat { (geometry?.end ?? offset) - offset }
    var isFollowing: Bool { intent == .entering || intent == .following }
    var isGliding: Bool { isFollowing && abs(lag) > 0.5 }

    // MARK: Intents

    /// A chat was entered: hold it at its end for `seconds`.
    mutating func enter(now: Double, seconds: Double = 3) {
        intent = .entering
        enterUntil = now + seconds
        velocity = 0
        if let geometry { offset = geometry.end }
    }

    /// Go to the end and stay there; `instantly` jumps instead of gliding.
    mutating func follow(instantly: Bool = false) {
        if intent != .entering { intent = .following }
        if instantly {
            jumpToEnd = true
            velocity = 0
        }
    }

    /// Hold `rowID` where it is now on screen (or `screenOffset` below the visible top).
    mutating func read(rowID: String, screenOffset: CGFloat? = nil) {
        let top = geometry?.tops[rowID] ?? offset
        intent = .reading(rowID: rowID, screenOffset: screenOffset ?? (top - offset))
        velocity = 0
    }

    /// A finger took the chat, or it coasts: the offset is UIKit's until `settle`.
    mutating func beginManual() {
        intent = .manual
        velocity = 0
        enterUntil = 0
    }

    /// UIKit moved the offset (a finger, a coast, a bounce).
    mutating func noteManualOffset(_ offset: CGFloat) {
        self.offset = offset
    }

    /// The finger and any coast are done: follow when within `pinDistance` of the end,
    /// else read the first row on screen.
    mutating func settle(pinDistance: CGFloat = 32) {
        guard let geometry else { intent = .following; return }
        if geometry.end - offset <= pinDistance {
            intent = .following
        } else if let row = geometry.firstVisible(at: offset) {
            intent = .reading(rowID: row.id, screenOffset: row.top - offset)
        }
        velocity = 0
    }

    /// The keyboard or the composer is moving: glides take the stiffer spring for a moment.
    mutating func clearanceMoving(now: Double, seconds: Double = 0.45) {
        stiffUntil = max(stiffUntil, now + seconds)
    }

    // MARK: Layout

    /// A layout was committed, or the same one again after an intent changed. Returns
    /// the offset to apply in the same pass. Entering and reading place the chat by
    /// their own rule on every commit; following and manual carry the live offset by
    /// the reference row's translation, which is nothing when the layout is the same.
    mutating func commit(_ new: Geometry, liveOffset: CGFloat, now: Double) -> CGFloat {
        if intent == .entering, now >= enterUntil { intent = .following }
        let jump = jumpToEnd
        jumpToEnd = false
        guard let old = geometry else {
            geometry = new
            offset = isFollowing ? new.end : clamp(liveOffset, in: new)
            return offset
        }
        geometry = new
        switch intent {
        case .entering:
            offset = new.end
            velocity = 0
        case .following:
            if jump {
                offset = new.end
                velocity = 0
            } else if old == new {
                offset = liveOffset
            } else {
                offset = clampForFollow(liveOffset + translation(of: Self.newestSurvivor(old, new), old, new), in: new)
            }
        case .reading(let rowID, let screenOffset):
            if let top = new.tops[rowID] {
                offset = clamp(top - screenOffset, in: new)
            } else if let survivor = Self.nearestSurvivor(of: rowID, old, new) {
                // The row went: hold the nearest row that stayed, as it was on screen.
                let next = clamp(liveOffset + translation(of: survivor, old, new), in: new)
                intent = .reading(rowID: survivor, screenOffset: (new.tops[survivor] ?? next) - next)
                offset = next
            } else {
                offset = clamp(liveOffset, in: new)
            }
        case .manual:
            if old == new {
                offset = liveOffset
            } else {
                let row = old.firstVisible(at: liveOffset)?.id
                offset = liveOffset + translation(of: row, old, new)
            }
        }
        return offset
    }

    /// The next glide step after `dt` seconds, or nil when there is nothing to glide.
    mutating func advance(by dt: Double, now: Double) -> CGFloat? {
        guard intent == .following, let geometry, dt > 0 else { return nil }
        let target = geometry.end
        let away = target - offset
        if abs(away) <= 0.5 && abs(velocity) < 1 {
            if away != 0 { offset = target }
            velocity = 0
            return away != 0 ? offset : nil
        }
        // A critically damped spring toward the end; its speed carries over as the end moves.
        let omega = (away < 0 || now < stiffUntil) ? Self.followSpringDown : Self.followSpring
        let x0 = Double(-away)
        let v0 = Double(velocity)
        let decay = exp(-omega * dt)
        let x = (x0 + (v0 + omega * x0) * dt) * decay
        let v = (v0 - omega * (v0 + omega * x0) * dt) * decay
        let nextAway = CGFloat(-x)
        // Stop at the end rather than pass it, from either side.
        let arrived = abs(nextAway) <= 0.5 || (away < 0) != (nextAway < 0)
        offset = arrived ? target : target - nextAway
        velocity = arrived ? 0 : CGFloat(v)
        return offset
    }

    // MARK: Helpers

    /// How far `rowID` moved between the layouts (0 when it isn't in both).
    private func translation(of rowID: String?, _ old: Geometry, _ new: Geometry) -> CGFloat {
        guard let rowID, let before = old.tops[rowID], let after = new.tops[rowID] else { return 0 }
        return after - before
    }

    /// Following, the reference: the newest row present before and after.
    static func newestSurvivor(_ old: Geometry, _ new: Geometry) -> String? {
        old.order.last(where: { new.tops[$0] != nil })
    }

    /// The row that stayed nearest to `rowID` in the old order, looking up then down.
    static func nearestSurvivor(of rowID: String, _ old: Geometry, _ new: Geometry) -> String? {
        guard let index = old.order.firstIndex(of: rowID) else { return newestSurvivor(old, new) }
        for i in stride(from: index - 1, through: 0, by: -1) where new.tops[old.order[i]] != nil { return old.order[i] }
        for i in index + 1..<old.order.count where new.tops[old.order[i]] != nil { return old.order[i] }
        return nil
    }

    private func clamp(_ value: CGFloat, in geometry: Geometry) -> CGFloat {
        min(max(value, geometry.start), max(geometry.start, geometry.end))
    }

    /// Following, the offset may sit past the end while the end rises (the keyboard
    /// going down, the composer shrinking): the glide brings it down. Never above the
    /// start, and never more than a screen and a quarter past the end.
    private func clampForFollow(_ value: CGFloat, in geometry: Geometry) -> CGFloat {
        let ceiling = geometry.end + geometry.viewportHeight * 1.25
        return min(max(value, geometry.start), ceiling)
    }
}
