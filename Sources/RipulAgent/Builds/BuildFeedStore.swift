import Foundation
import Combine

// ---------------------------------------------------------------------------
// RipulBuildFeedStore — load state + "am I on the latest build?"
// ---------------------------------------------------------------------------
// Deliberately a LEAF ObservableObject: nothing else observes it and it is not
// folded into a shared store. A @Published flip on an object the agent web view
// also observes re-renders AgentView and stalls the WKWebView mid-scroll, so
// state that changes on a timer or a network response has to live on its own.
//
// This is the binary-side counterpart to the web app's `LIVE ✓ / STALE ✗`
// check. The web app has compared its running bundle against the deployed one
// for a while; the native binary never did, despite already stamping a
// minute-resolution build number into CFBundleVersion.
// ---------------------------------------------------------------------------

/// Where the running app sits relative to what's published.
public enum RipulBuildStatus: Equatable, Sendable {
    /// No feed yet, or the running build isn't in any channel we can compare to.
    case unknown
    /// Running the newest build published to this app's own channel.
    case upToDate
    /// A newer build exists for the channel this app belongs to.
    case updateAvailable(RipulBuild)
}

@MainActor
public final class RipulBuildFeedStore: ObservableObject {

    /// Loaded feed, or nil before the first successful load.
    @Published public private(set) var feed: RipulBuildFeed?
    @Published public private(set) var isLoading = false
    /// Set when the last attempt failed. Distinct from `feed == nil` so the UI
    /// can say "couldn't reach Ripul" rather than "no builds published".
    @Published public private(set) var lastError: String?
    @Published public private(set) var status: RipulBuildStatus = .unknown

    private let source: RipulBuildFeedSource
    private let baseURL: URL
    private let tokenProvider: () -> String?

    /// - Parameter tokenProvider: called per fetch, so a token refreshed after
    ///   init is picked up without rebuilding the store.
    public init(
        source: RipulBuildFeedSource,
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String? = { MachineTokenStore.token }
    ) {
        self.source = source
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    // MARK: - Running build identity

    /// CFBundleVersion of the running app, e.g. "202607281530".
    public static var runningBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    /// CFBundleShortVersionString of the running app.
    public static var runningVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    public static var runningBundleId: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    /// The channel the running app belongs to, matched on bundle id.
    public var ownChannel: RipulBuildChannel? {
        feed?.channel(forBundleId: Self.runningBundleId)
    }

    /// Whether installing a build from `channel` replaces this app or installs
    /// alongside it. Same bundle id means iOS overwrites in place.
    public func installReplacesRunningApp(_ channel: RipulBuildChannel) -> Bool {
        channel.bundleId == Self.runningBundleId
    }

    // MARK: - Loading

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let fetched = await RipulBuildFeedClient.fetch(
            source: source,
            token: tokenProvider(),
            baseURL: baseURL
        )

        guard let fetched else {
            // Keep any previously loaded feed on screen — a stale list with an
            // error note beats blanking the screen on one failed poll.
            lastError = "Couldn't reach the build service"
            return
        }

        lastError = nil
        feed = fetched
        status = Self.status(for: fetched, runningBuild: Self.runningBuild, bundleId: Self.runningBundleId)
        logStatus()
    }

    // MARK: - Comparison

    /// Compare the running build against the newest in its own channel.
    ///
    /// Build numbers are minute-resolution timestamps (YYYYMMDDHHmm) so numeric
    /// comparison is the intent. A build that isn't numeric at all — an
    /// unstamped local build defaulting to "1" — must not be reported as
    /// up-to-date just because string comparison happened to favour it.
    static func status(
        for feed: RipulBuildFeed,
        runningBuild: String,
        bundleId: String
    ) -> RipulBuildStatus {
        guard let channel = feed.channel(forBundleId: bundleId),
              let newest = channel.newestBuild else {
            return .unknown
        }
        guard let running = Int(runningBuild), let latest = Int(newest.build) else {
            return .unknown
        }
        return latest > running ? .updateAvailable(newest) : .upToDate
    }

    private func logStatus() {
        switch status {
        case .unknown:
            RipulLog.log("[Builds] app build=\(Self.runningBuild) latest=unknown (no matching channel for \(Self.runningBundleId))")
        case .upToDate:
            RipulLog.log("[Builds] LATEST app build=\(Self.runningBuild)")
        case .updateAvailable(let build):
            RipulLog.log("[Builds] UPDATE app build=\(Self.runningBuild) latest=\(build.build)")
        }
    }
}
