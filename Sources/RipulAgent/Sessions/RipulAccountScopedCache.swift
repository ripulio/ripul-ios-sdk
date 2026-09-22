import Foundation

/// The `UserDefaults` keys that hold ONE Clerk account's server-derived data,
/// and the account stamp that says whose.
///
/// ## Why this exists
///
/// Signing out only clears the token, the cached name and the cached email
/// (`RipulClerkAuthStore.signOut`, the app's `AuthTokenStore.signOut`). The
/// session list's own caches were never account-scoped at all, so they survived
/// a sign-out and were still on screen after the next sign-in:
///
///  - `RipulSessionListModel` seeds `machines`/`unifiedSessions` from these
///    keys in `init`, and it is a `@StateObject` — it outlives a sign-out that
///    doesn't relaunch the app, so the previous account's rows stay in memory
///    even before the cache is re-read.
///  - `loadMachinesFromAPI` deliberately refuses to let an EMPTY 200 overwrite
///    the cache, because an empty list is normally a host past its registry
///    TTL. For an account that genuinely owns no Mac, `[]` is the authoritative
///    answer — so the guard pinned the old account's machines forever.
///
/// Stamping the caches with the Clerk subject fixes both: the stale data is
/// gone before the first fetch, so the empty-response guard has nothing left to
/// preserve and can keep protecting the transient case it was written for.
///
/// ## What counts as account-scoped
///
/// Anything keyed by, or holding, a machine id, a session id, or a
/// server-derived per-account id. Device preferences that merely *mention*
/// models or layout (quick-launch order, panel expansion) are NOT scoped —
/// they belong to the device, and wiping them would punish the common case of
/// one person with one account.
public enum RipulAccountScopedCache {

    /// The Clerk subject the cached data below belongs to.
    public static let accountIdKey = "ripul.sessionCacheAccountId"

    /// Every key purged when the account changes.
    ///
    /// Kept as one list, rather than each owner clearing its own, so a new
    /// cache can't be added in one file and silently miss the reset. The
    /// literals mirror the private `cacheKey` constants at their definition
    /// sites; the comment on each says which.
    public static let keys: [String] = [
        "ripulCachedMachines",                  // RemoteMachine.cacheKey
        "ripulMachineIcons",                    // RemoteMachine.iconsKey
        "ripulDisabledMachineIds",              // RemoteMachine.disabledKey
        "ripulDefaultMachineId",                // GlassSessionsList / SessionListMenu
        "ripulCachedRemoteActions",             // RemoteActionDescriptor.cacheKey
        "ripulUnifiedSessionsCacheV2",          // UnifiedSession.cacheKey
        "ripulRemoteSessionsByMachineIdV2",     // RipulSessionListModel.remoteSessionsCacheKey
        "ripulLastActiveTimeByChatId",          // RipulSessionListModel.lastActiveTimeCacheKey
        "ripulLastActiveBySessionId",           // RipulSessionListModel.lastActiveBySessionIdCacheKey
        "ripulSessionModelIds",                 // SessionModelSelectionCache.key
        "ripulRawModeSessions",                 // RipulAgentScreen / RipulSessionListModel
        "ripulSessionProviders",                // RipulAgentScreen / RipulSessionListModel
        "ripulFavoriteFiles",                   // RipulAgentScreen
        "ripul.hasSuccessfulMachinesFetch",     // RipulSessionListModel
        "ripul.embeddedOnboardingDismissed",    // GlassSessionsList
        "ripulSeededDevContextId",              // RipulSeededContextCache.devContextIdKey
    ]

    /// Forget every cached artefact of whichever account was last signed in,
    /// and the stamp with it. Safe to call when nothing is cached.
    public static func purge(cache: RipulSessionCache) {
        for key in keys { cache.removeObject(forKey: key) }
        cache.removeObject(forKey: accountIdKey)
    }

    /// Reconcile the cache stamp with the account a token actually belongs to.
    ///
    /// Returns true when the caches were purged, so a caller holding derived
    /// in-memory state can drop it in the same breath.
    ///
    /// - A nil `subject` means "unknown" — the pre-auth window of a launch, or
    ///   a token that failed to refresh. Nothing happens; a real sign-out is
    ///   handled by `purge` at the sign-out itself.
    /// - A nil STAMP with a known subject purges. An install upgrading into
    ///   this code has unstamped caches that may belong to anyone, and the
    ///   already-broken installs this fixes are exactly that shape. The cost is
    ///   one cold list on first launch after the upgrade; the API refills it in
    ///   a second.
    @discardableResult
    public static func reconcile(subject: String?, cache: RipulSessionCache) -> Bool {
        guard let subject else { return false }
        let stamped = cache.object(forKey: accountIdKey) as? String
        guard stamped != subject else { return false }
        purge(cache: cache)
        cache.set(subject, forKey: accountIdKey)
        return true
    }
}
