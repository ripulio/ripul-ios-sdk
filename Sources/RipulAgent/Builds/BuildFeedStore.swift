import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

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
    private var refreshTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var autoRefreshStarted = false

    /// - Parameter tokenProvider: called per fetch, so a token refreshed after
    ///   init is picked up without rebuilding the store.
    ///
    ///   The default is the machine token, which is a HOST credential — on iOS
    ///   it is only set from the web app's `host-token:set`, so a device that is
    ///   only ever a relay *controller* has none. Hosts that sign in with Clerk
    ///   should pass that token instead (falling back to the machine token),
    ///   or every feed read 401s.
    ///
    /// - Parameter autoRefresh: poll the feed on a timer and on foreground
    ///   instead of waiting for a view to drive it. A screen you navigate to can
    ///   fetch in `.task`; a banner that renders NOTHING until an update exists
    ///   cannot — SwiftUI runs no lifecycle for a view that resolves to
    ///   `EmptyView`, so the check that decides whether to show it has to be
    ///   owned here.
    public init(
        source: RipulBuildFeedSource,
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String? = { MachineTokenStore.token },
        autoRefresh: Bool = false
    ) {
        self.source = source
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        if autoRefresh { startAutoRefresh() }
    }

    deinit {
        refreshTimer?.invalidate()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Auto refresh

    /// Refresh now, then every `interval`, and again whenever the app returns to
    /// the foreground.
    ///
    /// The timer is torn down on background: a build check is a UI-freshness aid
    /// and has no business keeping the radio warm behind a locked screen. The
    /// foreground observer is what makes "publish from the Mac, pick the phone
    /// up" work without a relaunch.
    public func startAutoRefresh(interval: TimeInterval = 300) {
        // Guarded on its own flag, not on `refreshTimer`: the timer is nil for
        // the whole time the app is backgrounded, so using it as the "already
        // started" test would stack a second set of observers on the next call.
        guard !autoRefreshStarted else { return }
        autoRefreshStarted = true
        Task { await loadFirstFeed() }
        startTimer(interval: interval)
        #if os(iOS)
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopTimer() }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refresh()
                self.startTimer(interval: interval)
            }
        })
        #endif
    }

    /// Retry the FIRST load quickly, then leave it to the timer.
    ///
    /// A single shot at startup loses a race it will usually lose: the token
    /// provider reads a Clerk session that may not have landed yet, and a
    /// credential-less fetch is refused outright. Backing off to the 5-minute
    /// timer after that means a device that had an update waiting says nothing
    /// for five minutes — indistinguishable from being up to date.
    private func loadFirstFeed(attempts: Int = 6, spacing: TimeInterval = 10) async {
        for attempt in 1...attempts {
            await refresh()
            if feed != nil { return }
            guard attempt < attempts else { break }
            try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000))
        }
        RipulLog.log("[Builds] first feed load gave up after \(attempts) attempts — the timer takes over")
    }

    private func startTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
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

        let token = tokenProvider()

        // A missing credential is NOT a network failure, and reporting it as one
        // sends you debugging connectivity while the real answer is "this device
        // has no token". The hosted feed always requires auth; a static feed
        // owns its own access control and may legitimately need none.
        if case .ripulHosted = source, token == nil {
            RipulLog.error("[Builds] no credential available — the hosted feed requires a signed-in session")
            lastError = "Sign in to Ripul to see builds"
            return
        }

        let fetched = await RipulBuildFeedClient.fetch(
            source: source,
            token: token,
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

    // MARK: - Install confirmation

    /// What the user needs to know before tapping Install.
    ///
    /// Lives on the store rather than in a screen because more than one surface
    /// offers the install — the Builds list and the update banner — and a
    /// warning that differs between two buttons doing the same thing is worse
    /// than no warning.
    public func installWarning(for build: RipulBuild) -> String {
        let channel = feed?.channels.first { $0.builds.contains(build) }
        var lines: [String] = []
        if let channel, installReplacesRunningApp(channel) {
            lines.append("This replaces the app you're using now, and iOS will close it to do so.")
        } else if let channel {
            lines.append("This installs as a separate app (\(channel.bundleId)) alongside this one.")
        }
        // The constraint Ripul hosting does not remove: the build is
        // development-signed, so Apple still gates which devices may run it.
        lines.append("Development-signed: your device must be registered on the developer account, and you may need to trust the developer in Settings afterwards.")
        return lines.joined(separator: "\n\n")
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
