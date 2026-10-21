import Foundation

/// DEBUG-only switches for thermal experiments: named continuous animations
/// that can be turned off at launch, so an agent can A/B them on a device
/// without a rebuild —
///
///     xcrun devicectl device process launch --terminate-existing \
///       --device <udid> io.ripul.app -perfOff shimmer,glow,toolSpinner
///
/// (launch arguments land in UserDefaults' argument domain). Always false in
/// release builds. The frame limit below is the one switch that can also be
/// set from the app, in Settings > Debug.
public enum PerfSwitch {
    #if DEBUG
    private static let off: Set<String> = Set(
        (UserDefaults.standard.string(forKey: "perfOff") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    static func isOff(_ name: String) -> Bool { off.contains(name) || off.contains("all") }
    /// `-perfLoopFps 10`, or Settings > Debug > Working Animations: the most
    /// frames a second the turn-long loops may ask the render server for. Nil
    /// leaves the shipped limit (`RenderServerAnimations`); 120 or more lifts
    /// it. Read each time a loop starts; the setting posts `loopRateChanged`,
    /// which restarts the loops already running.
    static var loopFramesPerSecond: Float? {
        let asked = UserDefaults.standard.float(forKey: loopFramesKey)
        return asked >= 1 ? asked : nil
    }
    /// The same setting below zero: the loops do not run at all. From Settings
    /// only: a launch argument cannot carry a negative number (`-1` reads as
    /// the next argument's name), so at launch use `-perfOff glow,shimmer,listPulse`.
    static var loopsAreOff: Bool { UserDefaults.standard.float(forKey: loopFramesKey) < 0 }
    #else
    static func isOff(_ name: String) -> Bool { false }
    static var loopFramesPerSecond: Float? { nil }
    static var loopsAreOff: Bool { false }
    #endif
    /// The preference both read. Public so the app's debug settings can set it.
    public static let loopFramesKey = "perfLoopFps"

    /// Posted by the setting when the rate moves, so loops already running and
    /// the page's spinners take it at once instead of from the next turn.
    public static let loopRateChanged = Notification.Name("RipulLoopRateChanged")

    /// Sets the page's spinners to the same rate as the loops. A spinner turns
    /// once every 1.2 s in `steps(var(--ripul-spinner-steps))`
    /// (`OnScreenSpinner.tsx`), so 36 steps is thirty a second, the default; off
    /// holds them still.
    static var pageMotionScript: String {
        let steps = loopsAreOff ? 1 : max(1, Int((Double(loopFramesPerSecond ?? 30) * 1.2).rounded()))
        return "document.documentElement && document.documentElement.style.setProperty('--ripul-spinner-steps', '\(steps)');"
    }
}
