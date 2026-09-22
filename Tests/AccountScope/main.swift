import Foundation

// Checks for RipulAccountScopedCache — the account stamp that keeps one
// signed-in user's machines and sessions from surviving into the next one's
// list. Reported symptom: signing out of an account that owned a Mac and back
// in as a Mac-less account still showed the first account's machines.

var failures = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("  ok   \(name)") } else { print("  FAIL \(name)"); failures += 1 }
}

/// A cache primed as if account A had been using the app.
func primed(account: String?) -> MemoryCache {
    let cache = MemoryCache()
    for key in RipulAccountScopedCache.keys { cache.set("A-data", forKey: key) }
    if let account { cache.set(account, forKey: RipulAccountScopedCache.accountIdKey) }
    return cache
}

@main struct Checks {
    static func main() {
    print("RipulAccountIdentity")
    check("reads the sub claim", RipulAccountIdentity.subject(ofJWT: jwt("user_alice")) == "user_alice")
    check("nil token is unknown", RipulAccountIdentity.subject(ofJWT: nil) == nil)
    check("malformed token is unknown", RipulAccountIdentity.subject(ofJWT: "not.a.jwt") == nil)
    check("single-segment token is unknown", RipulAccountIdentity.subject(ofJWT: "opaque") == nil)

    print("RipulAccountScopedCache.reconcile")

    // The reported bug: A's machines must not survive into B's list.
    do {
        let cache = primed(account: "user_a")
        let purged = RipulAccountScopedCache.reconcile(subject: "user_b", cache: cache)
        check("a different account purges", purged)
        check("every scoped key is gone", RipulAccountScopedCache.keys.allSatisfy { cache.object(forKey: $0) == nil })
        check("the stamp is now B's",
              cache.object(forKey: RipulAccountScopedCache.accountIdKey) as? String == "user_b")
    }

    // The common case: one person, one account, every launch and every 30s poll.
    do {
        let cache = primed(account: "user_a")
        let purged = RipulAccountScopedCache.reconcile(subject: "user_a", cache: cache)
        check("the same account does not purge", !purged)
        check("cached data survives", cache.object(forKey: "ripulCachedMachines") as? String == "A-data")
    }

    // The pre-auth window of a cold launch: the token provider returns nil for a
    // second or two. Purging there would wipe the cache on every single start.
    do {
        let cache = primed(account: "user_a")
        let purged = RipulAccountScopedCache.reconcile(subject: nil, cache: cache)
        check("an unknown subject does not purge", !purged)
        check("the stamp is untouched",
              cache.object(forKey: RipulAccountScopedCache.accountIdKey) as? String == "user_a")
        check("cached data survives", cache.object(forKey: "ripulCachedMachines") as? String == "A-data")
    }

    // An install upgrading into this code has caches but no stamp — and the broken
    // installs this fixes are exactly that shape, so they must self-heal.
    do {
        let cache = primed(account: nil)
        let purged = RipulAccountScopedCache.reconcile(subject: "user_b", cache: cache)
        check("an unstamped cache purges", purged)
        check("every scoped key is gone", RipulAccountScopedCache.keys.allSatisfy { cache.object(forKey: $0) == nil })
        check("the stamp is written", cache.object(forKey: RipulAccountScopedCache.accountIdKey) as? String == "user_b")
    }

    // Second call in a row — the 30s machine poll — must be a no-op.
    do {
        let cache = primed(account: nil)
        RipulAccountScopedCache.reconcile(subject: "user_b", cache: cache)
        cache.set("B-data", forKey: "ripulCachedMachines")
        let purged = RipulAccountScopedCache.reconcile(subject: "user_b", cache: cache)
        check("reconcile is idempotent", !purged)
        check("B's own data survives the second call",
              cache.object(forKey: "ripulCachedMachines") as? String == "B-data")
    }

    print("RipulAccountScopedCache.purge")
    do {
        let cache = primed(account: "user_a")
        cache.set("keep me", forKey: "ripulQuickLaunchModelIds")
        RipulAccountScopedCache.purge(cache: cache)
        check("scoped keys are gone", RipulAccountScopedCache.keys.allSatisfy { cache.object(forKey: $0) == nil })
        check("the stamp is gone", cache.object(forKey: RipulAccountScopedCache.accountIdKey) == nil)
        check("device preferences are NOT purged",
              cache.object(forKey: "ripulQuickLaunchModelIds") as? String == "keep me")
    }
    do {
        let cache = MemoryCache()
        RipulAccountScopedCache.purge(cache: cache)
        check("purging an empty cache is safe", cache.values.isEmpty)
    }

    print("")
    if failures == 0 {
        print("All checks passed.")
    } else {
        print("\(failures) check(s) failed.")
        exit(1)
    }
    }
}
