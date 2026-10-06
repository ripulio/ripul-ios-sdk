import WebKit
import XCTest
@testable import RipulAgent

/// How the bridge decides the web layer is unwell and what it does about it:
/// the context probe's verdicts, the self-heal ladder, the host-bridge
/// backstop, crash records, and what crosses to the page on foreground.
///
/// The ladder and the backstop read `recoveryClock`, so their floors and
/// windows are stepped through here rather than waited for.
@MainActor
final class WebViewRecoveryTests: XCTestCase {
    private static let keys = ["ripulWebViewCrashEvents", "ripulWebViewHealthReports"]

    override func setUp() async throws { Self.keys.forEach(UserDefaults.standard.removeObject) }
    override func tearDown() async throws {
        AgentBridge.webViewHealRecorder = nil
        Self.keys.forEach(UserDefaults.standard.removeObject)
    }

    // MARK: - Fixtures

    private final class Loader: NSObject, WKNavigationDelegate {
        var completion: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion?() }
    }

    /// A request that never answers, so the page stays loading.
    private final class NeverAnswers: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {}
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    /// A web view whose data store is its own: a heal that purges web state
    /// must not reach the store other tests share.
    private func webView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(NeverAnswers(), forURLScheme: "hang")
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func page(_ script: String = "", attachedTo bridge: AgentBridge) async -> WKWebView {
        let web = webView()
        let loader = Loader()
        let loaded = expectation(description: "Page ready")
        loader.completion = { loaded.fulfill() }
        web.navigationDelegate = loader
        web.loadHTMLString("<script>\(script)</script>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        web.navigationDelegate = nil
        bridge.attach(to: web)
        return web
    }

    private final class Heals {
        var seen: [(reason: String, attempt: Int)] = []
        var attempts: [Int] { seen.map(\.attempt) }
    }

    /// Heals whose reason carries `token`. A heal a previous test left
    /// scheduled reports to whichever recorder is installed when it fires.
    private func watchHeals(_ token: String) -> Heals {
        let heals = Heals()
        AgentBridge.webViewHealRecorder = { reason, attempt in
            if reason.contains(token) { heals.seen.append((reason, attempt)) }
        }
        return heals
    }

    private func console(_ bridge: AgentBridge, _ tag: String) -> [String] {
        bridge.consoleLogs.map { "\($0.level) \($0.message)" }.filter { $0.contains(tag) }
    }

    private func eventually(_ timeout: TimeInterval = 4, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    // MARK: - The self-heal ladder

    func testTheFirstHealReloadsAndASecondInsideTheFloorIsSkipped() async {
        let bridge = AgentBridge()
        let web = await page(attachedTo: bridge)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        bridge.recoveryClock = { now }
        defer { bridge.recoveryClock = { Date() } }
        let heals = watchHeals("floor")

        let first = await bridge.healWebContext(reason: "floor one")
        now += 5
        let second = await bridge.healWebContext(reason: "floor two")
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(heals.attempts, [1])
        XCTAssertEqual(console(bridge, "[WEBVIEW_HEAL]").prefix(2), [
            "ERROR [WEBVIEW_HEAL] attempt 1 (floor one) — reloading web app",
            "WARN [WEBVIEW_HEAL] skipped, healed 5s ago (floor 10s) — floor two",
        ])
        withExtendedLifetime(web) {}
    }

    #if os(macOS)
    /// The Mac host is often unattended, so past the third attempt it keeps
    /// purging with a floor that doubles. iOS stops there instead; that branch
    /// is compiled out here.
    func testAnUnattendedMacClimbsFromReloadToPurgeThenBacksOff() async {
        let bridge = AgentBridge()
        let web = await page(attachedTo: bridge)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        bridge.recoveryClock = { now }
        defer { bridge.recoveryClock = { Date() } }
        let heals = watchHeals("climb")
        var results: [Bool] = []
        func heal(after seconds: TimeInterval, _ label: String) async {
            now += seconds
            results.append(await bridge.healWebContext(reason: "climb \(label)"))
        }

        await heal(after: 0, "1")
        await heal(after: 11, "2")
        await heal(after: 11, "3")
        await heal(after: 11, "4 early")   // attempt 4 waits 20s, not 10
        await heal(after: 10, "4")
        await heal(after: 41, "5")         // attempt 5 waits 40s
        await heal(after: 91, "fresh")     // more than 90s on: a new incident starts cheap

        XCTAssertEqual(results, [true, true, true, false, true, true, true])
        XCTAssertEqual(heals.attempts, [1, 2, 3, 4, 5, 1])
        XCTAssertEqual(console(bridge, "[WEBVIEW_HEAL]").filter { $0.contains("climb") && !$0.contains("purged") }, [
            "ERROR [WEBVIEW_HEAL] attempt 1 (climb 1) — reloading web app",
            "ERROR [WEBVIEW_HEAL] attempt 2 (climb 2) — reload didn't stick; purging session state + reloading",
            "ERROR [WEBVIEW_HEAL] attempt 3 (climb 3) — reload didn't stick; purging session state + reloading",
            "WARN [WEBVIEW_HEAL] skipped, healed 11s ago (floor 20s) — climb 4 early",
            "ERROR [WEBVIEW_HEAL] attempt 4 (climb 4) — macOS host, continuing purge + reload with 20s floor",
            "ERROR [WEBVIEW_HEAL] attempt 5 (climb 5) — macOS host, continuing purge + reload with 40s floor",
            "ERROR [WEBVIEW_HEAL] attempt 1 (climb fresh) — reloading web app",
        ])
        withExtendedLifetime(web) {}
    }
    #endif

    func testALoadStillInFlightIsLeftAloneUnlessForced() async {
        let bridge = AgentBridge()
        let web = webView()
        bridge.attach(to: web)
        web.load(URLRequest(url: URL(string: "hang://never")!))
        bridge.pageDidStartLoading()
        XCTAssertTrue(web.isLoading)
        let heals = watchHeals("flight")

        let left = await bridge.healWebContext(reason: "flight")
        XCTAssertFalse(left)
        XCTAssertTrue(heals.seen.isEmpty)
        XCTAssertEqual(console(bridge, "[WEBVIEW_HEAL]"), ["LOG [WEBVIEW_HEAL] load still in flight — leaving it alone (flight)"])

        let forced = await bridge.healWebContext(reason: "flight forced", force: true)
        XCTAssertTrue(forced)
        XCTAssertEqual(heals.attempts, [1])
    }

    // MARK: - The context probe

    private func verdict(_ script: String) async -> AgentBridge.WebContextProbe {
        let bridge = AgentBridge()
        let web = await page(script, attachedTo: bridge)
        let probe = await bridge.probeWebContext()
        withExtendedLifetime(web) {}
        return probe
    }

    func testTheProbeTellsAPageThatIsBootingFromOneThatIsBroken() async {
        let none = await AgentBridge().probeWebContext()
        XCTAssertEqual(none.health, .noWebView)

        let healthy = await verdict("window.__ripulOpenRemoteSession = () => {};")
        XCTAssertEqual(healthy.health, .healthy)
        XCTAssertEqual(healthy.readyState, "complete")
        XCTAssertEqual(healthy.ripulGlobals, 1)
        XCTAssertEqual(healthy.uaNative, false)

        let crashed = await verdict("window.__ripulOpenRemoteSession = () => {}; window.__ripulWebAppCrashed = true;")
        XCTAssertEqual(crashed.health, .webCrashed, "A crashed app is crashed even with its callables installed")

        let young = await verdict("")
        XCTAssertEqual(young.health, .callablesMissing, "A young document may still be booting")

        let old = await verdict("performance.now = () => 9000;")
        XCTAssertEqual(old.health, .callablesAbsent, "Settled for 8s with no callables: the boot broke")
        XCTAssertTrue(old.digest.contains("ready=complete age=9s"), old.digest)

        let booting = await verdict("window.__ripulBoot = {phase:'importing', history:[], build:'b1'};")
        XCTAssertEqual(booting.health, .callablesMissing)
        XCTAssertEqual(booting.bootPhase, "importing")

        let failed = await verdict("window.__ripulBoot = {phase:'boot-failed', error:'chunk 404', history:[], build:'b1'};")
        XCTAssertEqual(failed.health, .callablesAbsent, "The beacon says the boot chain ended")
        XCTAssertEqual(failed.bootError, "chunk 404")
        XCTAssertTrue(failed.digest.hasSuffix("boot=boot-failed bootErr=chunk 404 build=b1"), failed.digest)
    }

    // MARK: - The host-bridge backstop

    func testAnUnavailableHostBridgeIsProbedOnceItHasStayedThatWay() async {
        let bridge = AgentBridge()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        bridge.recoveryClock = { now }
        defer { bridge.recoveryClock = { Date() } }

        bridge.noteHostBridgeUnavailable(reason: "stuck")
        now += 10
        bridge.noteHostBridgeUnavailable(reason: "stuck")
        XCTAssertEqual(console(bridge, "[HOST_BRIDGE]"), [
            "WARN [HOST_BRIDGE] unavailable (stuck) — backstop armed; probing in 15s if it persists",
        ])

        now += 6
        bridge.noteHostBridgeUnavailable(reason: "stuck")
        now += 5
        bridge.noteHostBridgeUnavailable(reason: "stuck")   // inside the 15s between probes
        let probed = await eventually { self.console(bridge, "[HOST_BRIDGE]").count >= 2 }
        XCTAssertTrue(probed)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(Array(console(bridge, "[HOST_BRIDGE]").dropFirst()), [
            "WARN [HOST_BRIDGE] unavailable 21s (stuck) — probe=noWebView",
        ], "One probe, not one per note")

        bridge.noteHostBridgeAvailable()
        XCTAssertEqual(console(bridge, "[HOST_BRIDGE]").last, "LOG [HOST_BRIDGE] available again — clearing unavailability backstop")
        bridge.noteHostBridgeAvailable()
        XCTAssertEqual(console(bridge, "[HOST_BRIDGE]").count, 3, "Nothing to clear the second time")
        bridge.noteHostBridgeUnavailable(reason: "again")
        XCTAssertEqual(console(bridge, "[HOST_BRIDGE]").last, "WARN [HOST_BRIDGE] unavailable (again) — backstop armed; probing in 15s if it persists")
    }

    func testABridgeThatStaysUnavailableOnABrokenPageIsHealed() async {
        let bridge = AgentBridge()
        let web = await page("performance.now = () => 9000;", attachedTo: bridge)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        bridge.recoveryClock = { now }
        defer { bridge.recoveryClock = { Date() } }
        let heals = watchHeals("host bridge unavailable")

        bridge.noteHostBridgeUnavailable(reason: "not mounted")
        now += 16
        bridge.noteHostBridgeUnavailable(reason: "not mounted")
        let healed = await eventually { !heals.seen.isEmpty }
        XCTAssertTrue(healed)
        XCTAssertEqual(heals.seen.first?.reason, "host bridge unavailable 16s: not mounted — callablesAbsent")
        XCTAssertEqual(heals.attempts, [1])
        withExtendedLifetime(web) {}
    }

    func testAHealthyPageWithAnUnavailableBridgeIsNotHealed() async {
        let bridge = AgentBridge()
        let web = await page("window.__ripulOpenRemoteSession = () => {};", attachedTo: bridge)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        bridge.recoveryClock = { now }
        defer { bridge.recoveryClock = { Date() } }
        let heals = watchHeals("host bridge unavailable")

        bridge.noteHostBridgeUnavailable(reason: "provider")
        now += 16
        bridge.noteHostBridgeUnavailable(reason: "provider")
        let said = await eventually { self.console(bridge, "not healing").count == 1 }
        XCTAssertTrue(said)
        XCTAssertEqual(console(bridge, "not healing"), [
            "WARN [HOST_BRIDGE] context healthy but bridge unavailable 16s — web-side provider problem, not healing",
        ])
        XCTAssertTrue(heals.seen.isEmpty)
        withExtendedLifetime(web) {}
    }

    // MARK: - Script failures

    func testAThrowingScriptIsLoggedAndAnUnbridgeableResultIsNot() async {
        let bridge = AgentBridge()
        let web = await page(attachedTo: bridge)
        let heals = watchHeals("consecutive JS eval failures")
        for _ in 0..<3 {
            let done = expectation(description: "Script finished")
            bridge.evaluateJavaScript("throw new Error('boom')") { _ in done.fulfill() }
            await fulfillment(of: [done], timeout: 5)
        }
        let quiet = expectation(description: "Script finished")
        bridge.evaluateJavaScript("document.body") { _ in quiet.fulfill() }
        await fulfillment(of: [quiet], timeout: 5)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(console(bridge, "[JS_EVAL]"), Array(repeating:
            "ERROR [JS_EVAL] WKErrorDomain#4 JavaScriptExceptionOccurred | script: throw new Error('boom')", count: 3))
        XCTAssertTrue(heals.seen.isEmpty, "Three failures lead to a probe, and a live context is not healed")
        withExtendedLifetime(web) {}
    }

    // MARK: - Coming back to the foreground

    private let counters = """
        window.__fg = 0; window.__net = 0; window.__vis = 0;
        window.__ripulForegrounded = () => { window.__fg++; };
        document.addEventListener('visibilitychange', () => { window.__vis++; });
        """

    private func counts(_ web: WKWebView) async -> String {
        (try? await web.evaluateJavaScript("[window.__fg, window.__vis, window.__net].join(',')") as? String) ?? "gone"
    }

    func testForegroundTellsALivePageAndHealsACrashedOne() async {
        let bridge = AgentBridge()
        let web = await page(counters, attachedTo: bridge)
        bridge.notifyAppBackgrounded()
        XCTAssertFalse(bridge.appIsForeground)
        bridge.notifyWebViewBecameVisible()
        XCTAssertTrue(bridge.appIsForeground)
        let told = await eventually { await self.counts(web) == "1,1,0" }
        XCTAssertTrue(told, "One foreground call and one visibilitychange")

        let crashedBridge = AgentBridge()
        let crashed = await page(counters + "window.__ripulWebAppCrashed = true;", attachedTo: crashedBridge)
        let heals = watchHeals("foreground")
        crashedBridge.notifyWebViewBecameVisible()
        let healed = await eventually { !heals.seen.isEmpty }
        XCTAssertTrue(healed)
        XCTAssertEqual(heals.seen.first?.reason, "foreground: context webCrashed")
        XCTAssertEqual(console(crashedBridge, "on foreground"), [
            "WARN [WEBVIEW_HEAL] context webCrashed on foreground — healing before foreground sync",
        ])
        withExtendedLifetime((web, crashed)) {}
    }

    func testANetworkChangeUsesItsOwnCallableAndFallsBackToForeground() async {
        let bridge = AgentBridge()
        let old = await page(counters, attachedTo: bridge)
        bridge.notifyNetworkPathChanged()
        let fellBack = await eventually { await self.counts(old) == "1,0,0" }
        XCTAssertTrue(fellBack, "No network callable: the foreground one, and no fake visibilitychange")

        let newBridge = AgentBridge()
        let new = await page(counters + "window.__ripulNetworkChanged = () => { window.__net++; };", attachedTo: newBridge)
        newBridge.notifyNetworkPathChanged()
        let used = await eventually { await self.counts(new) == "0,0,1" }
        XCTAssertTrue(used)
        withExtendedLifetime((old, new)) {}
    }

    // MARK: - Crash records and health reports

    func testATerminatedPageIsRecordedAndTheRecordSurvivesARelaunch() {
        let bridge = AgentBridge()
        XCTAssertTrue(bridge.crashEvents.isEmpty)
        bridge.recordProcessTermination()
        bridge.recordProcessTermination()
        XCTAssertEqual(bridge.sessionCrashCount, 2)
        XCTAssertEqual(bridge.crashEvents.map(\.crashNumber), [1, 2])
        XCTAssertEqual(bridge.crashEvents.map(\.wasConnected), [false, false])
        let lines = console(bridge, "[CRASH]")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("ERROR [CRASH] Web content process terminated (#2 this session). RSS="), lines[1])
        XCTAssertTrue(lines[1].hasSuffix("URL=nil Bridge=disconnected"), lines[1])

        let relaunched = AgentBridge()
        XCTAssertEqual(relaunched.crashEvents.map(\.id), bridge.crashEvents.map(\.id))
        XCTAssertEqual(relaunched.sessionCrashCount, 0, "The count is per launch; the records are not")

        for _ in 0..<19 { relaunched.recordProcessTermination() }
        XCTAssertEqual(relaunched.crashEvents.count, 21)
        XCTAssertEqual(AgentBridge().crashEvents.count, 20, "Twenty are kept across launches")

        relaunched.clearCrashEvents()
        XCTAssertTrue(relaunched.crashEvents.isEmpty)
        XCTAssertTrue(AgentBridge().crashEvents.isEmpty)
    }

    func testAHealthReportSaysWhetherThePageIsAliveAndIsKept() async {
        let detached = AgentBridge()
        let none = await detached.probeWebViewHealth(trigger: "test")
        XCTAssertFalse(none.webViewExists)
        XCTAssertFalse(none.jsContextAlive)
        XCTAssertEqual(none.trigger, "test")
        XCTAssertEqual(console(detached, "PROBE]").first?.prefix(60), "ERROR [TEST PROBE] WebView Health Report\n  JS Context: DEAD\n".prefix(60))

        let bridge = AgentBridge()
        XCTAssertEqual(bridge.healthReports.map(\.id), [none.id], "Kept across launches")
        let web = await page("window.__memoryStats = () => ({chatsLoadedInMemory: 2, totalChatsInIndex: 9, estimatedMemoryBytes: 1048576, totalMemoryCacheKeys: 4});", attachedTo: bridge)
        let alive = await bridge.probeWebViewHealth()
        XCTAssertTrue(alive.webViewExists)
        XCTAssertTrue(alive.jsContextAlive)
        XCTAssertEqual(alive.trigger, "manual")
        XCTAssertEqual(alive.documentReadyState, "complete")
        XCTAssertEqual([alive.sessionsInMemory, alive.sessionsTotal, alive.sessionMemoryBytes, alive.cacheKeys], [2, 9, 1_048_576, 4])
        let report = console(bridge, "PROBE]").last ?? ""
        XCTAssertTrue(report.hasPrefix("LOG [MANUAL PROBE] WebView Health Report\n  JS Context: Alive\n  Bridge: Disconnected\n  WebView: Exists\n"), report)
        XCTAssertTrue(report.contains("\n  Sessions: 2/9 loaded\n  Session Memory: 1.0 MB\n  Cache Keys: 4"), report)
        XCTAssertEqual(bridge.healthReports.count, 2)

        bridge.clearHealthReports()
        XCTAssertTrue(bridge.healthReports.isEmpty)
        XCTAssertTrue(AgentBridge().healthReports.isEmpty)
        withExtendedLifetime(web) {}
    }
}
