import Foundation
#if os(iOS)
import UIKit
#endif

// ---------------------------------------------------------------------------
// RipulBuildInstaller — hand a build to the system installer
// ---------------------------------------------------------------------------
// There is deliberately NO "installing…" state modelled here, and that is not
// an omission:
//
//   * iOS gives no completion callback for an itms-services install. Opening
//     the URL transfers control to the system install daemon and that is the
//     last this process hears about it.
//   * When the build being installed shares the running app's bundle id, iOS
//     TERMINATES this app to replace it. Any in-memory "installing" flag dies
//     with the process, so a UI that depends on one is wrong precisely when the
//     install is working.
//
// So progress is not tracked; it is re-derived. On next launch the feed check
// compares CFBundleVersion against the channel and the answer is authoritative.
// ---------------------------------------------------------------------------

public enum RipulBuildInstaller {

    /// Whether this platform can install an OTA build in place.
    ///
    /// itms-services is an iOS mechanism. On macOS the Builds screen is still
    /// worth showing — it is a useful view of what has shipped — but the
    /// install action is not available.
    public static var canInstall: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Reasons an install can't be started, for the UI to explain.
    public enum Unavailable: Equatable, Sendable {
        /// Not iOS.
        case unsupportedPlatform
        /// The signed URL in the feed has expired — refreshing the feed fixes it.
        case installLinkExpired
        /// The feed handed back something that isn't a usable URL.
        case malformedInstallURL
    }

    /// Why `build` can't be installed right now, or nil when it can.
    public static func unavailableReason(for build: RipulBuild) -> Unavailable? {
        guard canInstall else { return .unsupportedPlatform }
        guard build.installURLIsLive else { return .installLinkExpired }
        guard URL(string: build.installURL) != nil else { return .malformedInstallURL }
        return nil
    }

    /// Start an install. Returns false when it couldn't be handed off.
    ///
    /// On success this app may not be alive much longer — see the note above.
    @discardableResult
    @MainActor
    public static func install(_ build: RipulBuild) -> Bool {
        guard unavailableReason(for: build) == nil else {
            RipulLog.error("[Builds] install refused for \(build.build): \(String(describing: unavailableReason(for: build)))")
            return false
        }
        #if os(iOS)
        guard let url = URL(string: build.installURL) else { return false }
        RipulLog.log("[Builds] handing build \(build.build) to the system installer")
        UIApplication.shared.open(url)
        return true
        #else
        return false
        #endif
    }
}
