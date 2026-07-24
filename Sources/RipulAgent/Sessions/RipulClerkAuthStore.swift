import SwiftUI

/// Stores the Clerk auth token extracted from the web view.
/// Periodically refreshes to keep the token valid.
///
/// On launch, restores cached sign-in state from the injected
/// ``RipulSessionCache`` so the sign-in overlay can be skipped instantly for
/// returning users.
@MainActor
public final class RipulClerkAuthStore: ObservableObject {
    @Published public var token: String?
    @Published public var userName: String?
    @Published public var userEmail: String?
    private weak var bridge: AgentBridge?
    private var pollTask: Task<Void, Never>?
    private var pollCount = 0

    private let cache: RipulSessionCache

    private static let wasSignedInKey = "ripul.auth.wasSignedIn"
    private static let cachedNameKey = "ripul.auth.userName"
    private static let cachedEmailKey = "ripul.auth.userEmail"

    /// True when we have a live Clerk token.
    public var isSignedIn: Bool { token != nil }

    /// True if the user was signed in last time the app ran.
    /// Used to show a "Connecting" splash instead of the sign-in screen.
    @Published public var wasPreviouslySignedIn: Bool

    /// Session state reported by the last token extraction:
    /// "unknown" (Clerk not loaded yet / page unreachable), "alive" (session
    /// exists but no token — refresh failed, e.g. bad network), or "gone"
    /// (Clerk loaded, no session — authoritative sign-out). Only "gone" may
    /// clear persisted sign-in state; a connectivity outage must never look
    /// like a sign-out.
    private var lastSessionState: String = "unknown"

    public init(cache: RipulSessionCache) {
        self.cache = cache
        wasPreviouslySignedIn = cache.bool(forKey: Self.wasSignedInKey)
        // Restore cached user info for immediate display
        if wasPreviouslySignedIn {
            userName = cache.object(forKey: Self.cachedNameKey) as? String
            userEmail = cache.object(forKey: Self.cachedEmailKey) as? String
        }
    }

    public func startPolling(bridge: AgentBridge) {
        self.bridge = bridge
        pollCount = 0
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // Wait for the bridge to connect (web app loaded + handshake) before
            // fast polling. Clerk only initializes after the page loads, so 500ms
            // polls before that are IPC calls into a JS engine that's still
            // compiling — pure thermal load with no chance of a token. Use a 1s
            // pre-connection probe so we don't stall on a slow connection.
            while !Task.isCancelled {
                guard let self else { return }
                if bridge.isConnected { break }
                await self.extractToken() // may return quickly; no-op pre-Clerk
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s pre-connection
            }

            while !Task.isCancelled {
                await self?.extractToken()
                guard let self else { break }
                let hasToken = self.token != nil
                let interval: UInt64
                if hasToken {
                    interval = 30_000_000_000 // 30s — steady state
                } else if self.pollCount < 30 {
                    interval = 500_000_000    // 500ms — fast initial probing (post-connect)
                } else {
                    // Bridge connected but no token after fast probing. If the
                    // web app confirms the Clerk session is ALIVE yet never
                    // yields a token for minutes, the refresh token has likely
                    // expired — drop the returning-user flag so the UI shows
                    // sign-in instead of an infinite spinner. ("gone" clears
                    // immediately in extractToken; "unknown" — network down,
                    // page unreachable — never clears: an outage must not
                    // sign the user out.)
                    if bridge.isConnected && self.wasPreviouslySignedIn && self.lastSessionState == "alive" && self.pollCount > 120 {
                        NSLog("[AuthTokenStore] Session alive but no token after %d polls — treating as expired, showing sign-in", self.pollCount)
                        self.wasPreviouslySignedIn = false
                        self.cache.set(false, forKey: Self.wasSignedInKey)
                    }
                    interval = 2_000_000_000  // 2s — waiting for web view
                }
                self.pollCount += 1
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Open the app's custom sign-in modal in the web view.
    /// Retries until the React app has registered __ripulOpenAuthModal.
    public func openSignIn() async {
        guard let bridge else { return }
        for attempt in 1...20 {
            do {
                let result = try await bridge.callAsyncJavaScript(
                    "if (window.__ripulOpenAuthModal) { window.__ripulOpenAuthModal(); return true; } return false;"
                )
                if let success = result as? Bool, success {
                    return
                }
            } catch {
                NSLog("[AuthTokenStore] openSignIn attempt %d error: %@", attempt, error.localizedDescription)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        NSLog("[AuthTokenStore] openSignIn: __ripulOpenAuthModal not available after retries")
    }

    /// Sign out via Clerk and clear local state.
    public func signOut() async {
        guard let bridge else { return }
        do {
            _ = try await bridge.callAsyncJavaScript(
                "await window.Clerk?.signOut();"
            )
        } catch {
            NSLog("[AuthTokenStore] signOut error: %@", error.localizedDescription)
        }
        token = nil
        userName = nil
        userEmail = nil
        wasPreviouslySignedIn = false
        cache.set(false, forKey: Self.wasSignedInKey)
        cache.removeObject(forKey: Self.cachedNameKey)
        cache.removeObject(forKey: Self.cachedEmailKey)
    }

    private func extractToken() async {
        guard let bridge else { return }
        do {
            // The JS reports the Clerk session state explicitly so Swift can
            // distinguish an authoritative sign-out ("gone") from a failed
            // token refresh under bad connectivity ("alive") and from Clerk
            // still initializing ("unknown"). Previously every empty token
            // was treated as a sign-out, so a network blip wiped the token
            // AND the persisted returning-user flag.
            let result = try await bridge.callAsyncJavaScript(
                """
                try {
                    const clerk = window.Clerk;
                    if (!clerk) return { token: '', session: 'unknown' };
                    if (clerk.loaded === false) return { token: '', session: 'unknown' };
                    if (clerk.session === undefined || clerk.session === null) {
                        // undefined → still initializing; null → loaded, signed out
                        return { token: '', session: clerk.session === null ? 'gone' : 'unknown' };
                    }
                    try {
                        const token = await clerk.session.getToken();
                        if (!token) return { token: '', session: 'alive' };
                        const user = clerk.user;
                        return {
                            token: token,
                            session: 'alive',
                            name: user?.firstName || user?.fullName || '',
                            email: user?.primaryEmailAddress?.emailAddress || ''
                        };
                    } catch (e) {
                        // getToken() rejects when the refresh request fails
                        // (bad network) — transient, NOT a sign-out.
                        return { token: '', session: 'alive' };
                    }
                } catch(e) { return { token: '', session: 'unknown' }; }
                """
            )
            guard let dict = result as? [String: Any] else { return }
            let sessionState = dict["session"] as? String ?? "unknown"
            if let t = dict["token"] as? String, !t.isEmpty {
                self.token = t
                lastSessionState = "alive"
                if let name = dict["name"] as? String, !name.isEmpty {
                    self.userName = name
                }
                if let email = dict["email"] as? String, !email.isEmpty {
                    self.userEmail = email
                }
                // Persist sign-in state for instant launch next time
                if !wasPreviouslySignedIn {
                    wasPreviouslySignedIn = true
                }
                cache.set(true, forKey: Self.wasSignedInKey)
                if let n = userName { cache.set(n, forKey: Self.cachedNameKey) }
                if let e = userEmail { cache.set(e, forKey: Self.cachedEmailKey) }
            } else {
                lastSessionState = sessionState
                if sessionState == "gone" {
                    // Clerk is loaded and reports NO session — authoritative
                    // sign-out (user signed out here or elsewhere, or the
                    // session truly expired).
                    if token != nil || wasPreviouslySignedIn {
                        token = nil
                        userName = nil
                        userEmail = nil
                        wasPreviouslySignedIn = false
                        cache.set(false, forKey: Self.wasSignedInKey)
                    }
                }
                // "alive" without a token (refresh failed — bad network) and
                // "unknown" (Clerk still loading / page unreachable) are
                // transient: keep the current token and returning-user flag.
            }
        } catch {
            NSLog("[AuthTokenStore] extractToken error: %@", error.localizedDescription)
        }
    }

    deinit {
        pollTask?.cancel()
    }
}
