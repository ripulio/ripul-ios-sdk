import Foundation

/// DEBUG-only switches for thermal experiments: named continuous animations
/// that can be turned off at launch, so an agent can A/B them on a device
/// without a rebuild —
///
///     xcrun devicectl device process launch --terminate-existing \
///       --device <udid> io.ripul.app -perfOff shimmer,glow,toolSpinner
///
/// (launch arguments land in UserDefaults' argument domain). Always false in
/// release builds.
enum PerfSwitch {
    #if DEBUG
    private static let off: Set<String> = Set(
        (UserDefaults.standard.string(forKey: "perfOff") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    static func isOff(_ name: String) -> Bool { off.contains(name) || off.contains("all") }
    #else
    static func isOff(_ name: String) -> Bool { false }
    #endif
}
