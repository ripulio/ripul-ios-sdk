import Foundation

/// Switches for the native chat processor work of 27 October 2026, so the old
/// and new behaviour can be compared by feel on a phone: Settings > Debug >
/// Native Chat Performance. Each is on (the new behaviour) unless turned off,
/// and "All of it" off puts every one back to the old behaviour at once.
///
/// Read when used, so a change takes effect without a relaunch: the follow
/// scroll and the store read them on every use, the loops and spinners restart
/// on `changed`, and the chat asks the page again for its forwarding.
/// The DEBUG launch arguments (`-perfOff slowLoops` and the rest) still work
/// on top of these.
public enum NativeChatPerformance {
    public enum Option: String, CaseIterable, Identifiable, Sendable {
        /// The follow of a streaming tail asks for 60 frames a second; old: the display's rate.
        case followRate
        /// The composer's glow at 12 frames a second and its shimmer at 20; old: Working Animations.
        case slowLoops
        /// Spinners stepped by the render server at 8 a second, only while on screen; old: system spinners.
        case pacedSpinners
        /// The chat updates only the rows that changed; old: every row is rebuilt and compared.
        case incrementalRows
        /// The page stops its own chat pipeline and sends changes at most every 33 ms; old: both run.
        case leanForwarding
        /// In a chat of more than 80 rows the mounted band holds still during a fling and
        /// grows at rest; old: it moves with the scroll, mounting and dropping rows mid-fling.
        case steadyBand
        /// Following the end glides on a spring, at once and through layout passes, down
        /// as well as up, holding the first row on screen still (5 November 2026); old: a
        /// glide that set off at full speed, waited for layout passes, and went to the end
        /// at once when the end came up or the band shrank.
        case smoothFollow
        /// The chat drawn by a UIKit list with one owner of its scroll position (9 November
        /// 2026, `docs/plans/native-chat-viewport-owner.md`); old: the SwiftUI scroller with
        /// its band and coordinator. Read when a chat view is made.
        case ownedList

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .followRate: return "Follow at 60 fps"
            case .slowLoops: return "Slow composer glow"
            case .pacedSpinners: return "Paced spinners"
            case .incrementalRows: return "Update changed rows only"
            case .leanForwarding: return "Lean page forwarding"
            case .steadyBand: return "Steady band in long chats"
            case .smoothFollow: return "Smooth follow"
            case .ownedList: return "Owned chat list"
            }
        }

        public var detail: String {
            switch self {
            case .followRate:
                return "Scrolling to new text while a reply streams asks for 60 frames a second. Off: the display's full rate, up to 120."
            case .slowLoops:
                return "The composer's glow breathes at 12 frames a second and its shimmer sweeps at 20. Off: they run at the Working Animations rate."
            case .pacedSpinners:
                return "Spinners step 8 times a second and stop when off screen. Off: the system's spinners, at the display's rate."
            case .incrementalRows:
                return "Each streamed change updates only the rows it touched. Off: every row is rebuilt, sorted and compared on each change."
            case .leanForwarding:
                return "While native chat shows, the page stops drawing its own chat and sends changes at most every 33 ms. Off: the page keeps its full chat pipeline running."
            case .steadyBand:
                return "In a chat of more than 80 rows, the rows kept ready hold still while you fling and are added a few at a time once it stops. Off: they move with the scroll, adding and dropping rows mid-fling."
            case .smoothFollow:
                return "A sent message and a streaming reply glide to the end on a spring, at once, and the chat comes down with the keyboard. Off: the glide waits for layout and the chat goes to the end at once when the keyboard drops."
            case .ownedList:
                return "The chat is a UIKit list with one owner of its scroll position: nothing on screen moves when messages land above it or the composer folds and unfolds. Off: the SwiftUI scroller from before 9 November 2026. Open the chat again after changing it."
            }
        }

        var key: String { "ripul.nativeChatPerf.\(rawValue)" }
    }

    /// "All of it": off puts every option back to the old behaviour.
    public static let allKey = "ripul.nativeChatPerf.all"

    /// Posted when a switch changes, so running loops, spinners and the page's
    /// forwarding take it at once.
    public static let changed = Notification.Name("RipulNativeChatPerformanceChanged")

    public static func key(_ option: Option) -> String { option.key }

    /// Whether the new behaviour is on for `option`.
    public static func isEnabled(_ option: Option) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: allKey) as? Bool == false { return false }
        return defaults.object(forKey: option.key) as? Bool ?? true
    }

    /// Call after a switch changes (the settings screen writes the defaults).
    public static func notifyChanged() {
        NotificationCenter.default.post(name: changed, object: nil)
        // The loops listen for this already and restart at their new rate.
        NotificationCenter.default.post(name: PerfSwitch.loopRateChanged, object: nil)
    }
}
