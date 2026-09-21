#if os(iOS)
import UIKit

/// Re-runs window layout when the app returns to the foreground.
///
/// The gesture settles (`settleAfterInterruption` on the switcher store, the
/// chat slide, the sidebar and the slide panels) put finger-tracked STATE back
/// to rest. This is the backstop for the other half of a "came back parked
/// mid-transition" report: GEOMETRY the app never re-measured. A rotation or a
/// window resize that lands while the process is suspended reaches UIKit
/// before any SwiftUI update can run, and every width-derived offset in the
/// agent screen — the chat's resting slide, a panel's closed edge — is only as
/// current as the last `onGeometryChange` it received. Asking each window's
/// root view to lay out against its current bounds costs nothing when nothing
/// changed and re-measures everything when something did.
public enum ForegroundLayoutNudge {
    @MainActor private static var installed = false

    /// Observe `didBecomeActive` once per process. Idempotent, so every bridge
    /// can call it without stacking observers.
    @MainActor
    public static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = relayoutAllWindows(reason: "didBecomeActive") }
        }
    }

    /// Mark every connected window's root view for layout. Returns how many
    /// windows were touched — for the log line, and for the hosted test.
    @MainActor
    @discardableResult
    public static func relayoutAllWindows(reason: String) -> Int {
        var touched = 0
        var summary = ""
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                guard let root = window.rootViewController?.view else { continue }
                root.setNeedsLayout()
                touched += 1
                if summary.isEmpty {
                    let size = window.bounds.size
                    let orientation = windowScene.interfaceOrientation.isLandscape ? "landscape" : "portrait"
                    summary = " \(Int(size.width))x\(Int(size.height)) \(orientation)"
                }
            }
        }
        // One line per foreground, so a rotation report can be read off the
        // device log next to the gesture settles' own `[FGSETTLE]` lines.
        if touched > 0 {
            NSLog("[FGSETTLE] relayout \(touched) window(s)\(summary) (\(reason))")
        }
        return touched
    }
}
#endif
