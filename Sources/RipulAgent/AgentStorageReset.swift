import WebKit

/// Empties the page's IndexedDB databases from outside the page.
///
/// The web app asks for this when its chat database has stopped answering and
/// a new connection did not help, and when a person taps "Clear local caches".
/// It goes through the web data store, which closes every connection to the
/// database without waiting for the page that holds it. A page cannot do that
/// for itself: its own `deleteDatabase` waits for every other page on the
/// origin, cannot be cancelled, and holds up every later open while it waits.
///
/// That was the stalled local storage of 29 August to 11 October 2026. A
/// browser tab open on the app's own address shared the page's database, WebKit
/// froze the tab, and a reset from the page then waited on it for ever, on a
/// database nothing could open again until the tab's process was stopped. The
/// web app's page now keeps its own database (`agentDatabase.ts`), so a tab no
/// longer holds it; this is what repairs whatever else can.
///
/// The page finds it by its message handler, `agentStorage`. A shell without
/// the handler is an older build, and the page falls back to what it can do
/// alone.
@MainActor
final class AgentStorageReset: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "agentStorage"

    /// How long WebKit gets before the removal is reported as failed.
    nonisolated static let deadline: TimeInterval = 20

    struct Outcome: Sendable {
        let ok: Bool
        let detail: String
    }

    private let baseHost: String?
    private let standalone: Bool
    private weak var bridge: AgentBridge?
    private var running: Task<Outcome, Never>?

    init(baseHost: String?, standalone: Bool, bridge: AgentBridge) {
        self.baseHost = baseHost
        self.standalone = standalone
        self.bridge = bridge
    }

    /// The user content controller keeps the handler alive.
    func install(in controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        // Frames can address WebKit handlers, so only the app's own page may
        // empty its storage.
        guard trusts(message) else { return replyHandler(nil, "Storage is not available to this frame") }
        guard let body = message.body as? [String: Any], body["action"] as? String == "reset" else {
            return replyHandler(nil, "Unknown storage request")
        }
        let reason = String((body["reason"] as? String ?? "no reason given").prefix(200))
        let store = message.webView?.configuration.websiteDataStore ?? .default()
        let host = message.frameInfo.securityOrigin.host
        Task { @MainActor in
            let outcome = await self.reset(store: store, host: host, reason: reason)
            replyHandler(["ok": outcome.ok, "detail": outcome.detail], nil)
        }
    }

    /// One at a time: a request that arrives while one runs gets its answer.
    private func reset(store: WKWebsiteDataStore, host: String, reason: String) async -> Outcome {
        if let running { return await running.value }
        let task = Task { @MainActor in await Self.emptyIndexedDB(in: store, host: host) }
        running = task
        let outcome = await task.value
        running = nil
        bridge?.handleConsoleLog(
            "WARN: [STORAGE_RESET] \(reason): \(outcome.ok ? "done" : "FAILED"), \(outcome.detail)")
        return outcome
    }

    /// Removes every IndexedDB database stored for `host`'s site in `store`.
    ///
    /// WebKit keeps one record per site ("ripul.io"), not per database, so
    /// this takes the browser tabs' databases for the site with it. They are
    /// caches too.
    static func emptyIndexedDB(
        in store: WKWebsiteDataStore,
        host: String,
        deadline: TimeInterval = AgentStorageReset.deadline
    ) async -> Outcome {
        let types: Set<String> = [WKWebsiteDataTypeIndexedDBDatabases]
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = Once(continuation)
            store.fetchDataRecords(ofTypes: types) { records in
                let mine = records.filter { covers($0.displayName, host: host) }
                guard !mine.isEmpty else {
                    once.finish(Outcome(ok: true, detail: "nothing was stored for \(host)"))
                    return
                }
                store.removeData(ofTypes: types, for: mine) {
                    let names = mine.map(\.displayName).joined(separator: ", ")
                    once.finish(Outcome(ok: true, detail: "IndexedDB emptied for \(names)"))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                once.finish(Outcome(ok: false, detail: "WebKit had not removed the data after \(Int(deadline))s"))
            }
        }
    }

    /// A record is named for its site: "ripul.io" covers "demo.ripul.io".
    nonisolated static func covers(_ recordName: String, host: String) -> Bool {
        let name = recordName.lowercased()
        let host = host.lowercased()
        return !name.isEmpty && (host == name || host.hasSuffix("." + name))
    }

    private func trusts(_ message: WKScriptMessage) -> Bool {
        if standalone { return BundledAgentRuntime.shared.trusts(message) }
        let origin = message.frameInfo.securityOrigin
        return message.frameInfo.isMainFrame && origin.protocol == "https" && origin.host == baseHost
            && (origin.port == 0 || origin.port == 443)
    }

    /// Resumes a continuation once, whichever of the removal and its deadline comes first.
    @MainActor
    private final class Once {
        private var continuation: CheckedContinuation<Outcome, Never>?
        init(_ continuation: CheckedContinuation<Outcome, Never>) { self.continuation = continuation }
        func finish(_ outcome: Outcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }
}
