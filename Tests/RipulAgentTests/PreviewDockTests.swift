#if os(iOS)
import XCTest
import SwiftUI
@testable import RipulAgent

/// Docking the chat's simulator or browser into the right of a wide window (PreviewDock.swift).
@MainActor
final class PreviewDockTests: XCTestCase {
    private let target = SimulatorTarget(udid: "08E561AA-A868-4196-AF4A-3501D80DF965")
    private var store: UserDefaults!

    override func setUp() async throws {
        store = UserDefaults(suiteName: "PreviewDockTests-\(UUID().uuidString)")
    }

    /// A dock in a window with room for it, as the layout leaves it, with the
    /// simulator panel's way back as the bridge joins it.
    private func roomyDock(for state: SimulatorPreviewState? = nil, width: CGFloat = 951) -> PreviewDockState {
        let dock = PreviewDockState(store: store)
        dock.layoutAppeared(true)
        dock.windowWidthChanged(width)
        dock.content = { _ in AnyView(EmptyView()) }
        dock.onRelease = { surface, reopen in
            if case .simulator(let simulator) = surface { state?.returnFromDock(simulator, open: reopen) }
        }
        state?.dock = dock
        return dock
    }

    /// Peter, 3 November 2026: a simulator floated from the Simulators screen
    /// docks as a chat's does, and comes back to its own panel.
    @available(iOS 26.0, *)
    func testAFloatedSimulatorDocksAndComesBackToItsOwnPanel() {
        let bridge = AgentBridge()
        let dock = roomyDock()
        bridge.joinPreviewDock(dock)
        let floated = bridge.floatedSimulatorPreview
        XCTAssertTrue(floated.dock === dock, "the floated panel is offered the window's dock")
        bridge.floatSimulator(udid: target.udid, machineId: "studio")
        floated.dockIntoWindow()
        guard case .simulator(let docked) = dock.shown else { return XCTFail("\(String(describing: dock.shown))") }
        XCTAssertEqual(docked.chatId, SimulatorPreviewState.floatedChatId)
        XCTAssertTrue(floated.isDocked, "its panel leaves it to the dock")
        // Undocked: back in its own panel, open; no chat's panel opens.
        dock.undock()
        XCTAssertEqual(floated.selection?.target, target)
        XCTAssertFalse(floated.collapsed)
        XCTAssertFalse(floated.isDocked)
        XCTAssertNil(bridge.simulatorPreview.selection)
        // The dock's Close takes it away, as the panel's own Close does.
        floated.dockIntoWindow()
        dock.close()
        XCTAssertNil(floated.selection)
        XCTAssertNil(bridge.simulatorPreview.selection)
    }

    func testTheAppTakesAPhonesWidthAndLeavesTheDockItsRoom() {
        // An open Duo in landscape, and an iPad mini in landscape.
        XCTAssertEqual(PreviewDockState.appWidth(in: 951, preferred: nil), 402)
        XCTAssertEqual(PreviewDockState.appWidth(in: 1133, preferred: nil), 402)
        // A wider app, as far as the dock's own minimum allows.
        XCTAssertEqual(PreviewDockState.appWidth(in: 951, preferred: 560), 560)
        XCTAssertEqual(PreviewDockState.appWidth(in: 800, preferred: 600), 480)
        // Never narrower than a phone.
        XCTAssertEqual(PreviewDockState.appWidth(in: 951, preferred: 300), 360)
    }

    func testADragIsOfferedTheDockAtTheEdgeOrPushingPastWhereThePanelStops() {
        XCTAssertFalse(FloatingPanelDocking.isOver(edgeDistance: 120, pushed: 0, wasOver: false))
        XCTAssertTrue(FloatingPanelDocking.isOver(edgeDistance: 40, pushed: 0, wasOver: false))
        XCTAssertTrue(FloatingPanelDocking.isOver(edgeDistance: 300, pushed: 60, wasOver: false))
        // Once in, a finger resting near the boundary stays in.
        XCTAssertTrue(FloatingPanelDocking.isOver(edgeDistance: 120, pushed: 0, wasOver: true))
        XCTAssertFalse(FloatingPanelDocking.isOver(edgeDistance: 200, pushed: 0, wasOver: true))
    }

    func testOnlyAWindowWithRoomAndALayoutOffersTheDock() {
        let dock = PreviewDockState(store: store)
        XCTAssertFalse(dock.canDock(containerWidth: 951), "no layout yet")
        dock.layoutAppeared(true)
        dock.content = { _ in AnyView(EmptyView()) }
        XCTAssertFalse(dock.canDock(containerWidth: 951), "the layout has not measured its own room")
        dock.windowWidthChanged(951)
        XCTAssertTrue(dock.canDock(containerWidth: 951))
        XCTAssertTrue(dock.canDock(containerWidth: 1133))
        XCTAssertFalse(dock.canDock(containerWidth: 669), "an open Duo held upright has no split")
        XCTAssertFalse(dock.canDock(containerWidth: 466), "the Duo's cover screen")
        dock.dock(.browser(tabId: nil))
        XCTAssertFalse(dock.canDock(containerWidth: 951), "one thing docks at a time")
    }

    func testDockingTakesTheSimulatorFromItsPanelAndUndockingGivesItBackOpen() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        state.live = true
        let dock = roomyDock(for: state)
        state.dockIntoWindow()
        guard case .simulator(let docked) = dock.shown else { return XCTFail("the dock shows the simulator") }
        XCTAssertEqual(docked.udid, target.udid)
        XCTAssertEqual(docked.machineId, "host")
        XCTAssertEqual(docked.chatId, "chat")
        XCTAssertTrue(state.isDocked, "the panel leaves it to the dock")
        XCTAssertFalse(state.live, "the dock has its own live picture")
        var asked = 0
        await state.refresh { _, _, _, _ in asked += 1; return ["success": false] }
        XCTAssertEqual(asked, 0, "no stills while docked")

        dock.undock()
        XCTAssertNil(dock.shown)
        XCTAssertFalse(state.isDocked)
        XCTAssertEqual(state.selection?.target, target)
        XCTAssertFalse(state.collapsed, "undocked, the panel is open again")
    }

    func testTheDockKeepsItsSimulatorAcrossChatsAndClosingLeavesItMinimisedInItsChat() {
        let state = SimulatorPreviewState()
        state.show(chatId: "first")
        state.open(target, machineId: "host", chatId: "first")
        let dock = roomyDock(for: state)
        state.dockIntoWindow()
        state.show(chatId: "second")
        XCTAssertNotNil(dock.shown, "another chat leaves the dock as it is")
        XCTAssertNil(state.selection)

        dock.close()
        XCTAssertNil(dock.shown)
        XCTAssertNil(state.selection, "the second chat gets no panel it never had")
        state.show(chatId: "first")
        XCTAssertEqual(state.selection?.target, target)
        XCTAssertTrue(state.collapsed, "closed in the dock, it waits as its panel's button")
        XCTAssertFalse(state.isDocked)
    }

    func testANarrowWindowShowsTheDockedSimulatorInItsPanelUntilThereIsRoomAgain() {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        let dock = roomyDock(for: state)
        state.dockIntoWindow()
        XCTAssertTrue(state.isDocked)
        // Folded to the cover screen: the dock has no room, the panel shows.
        dock.windowWidthChanged(466)
        XCTAssertNil(dock.shown)
        XCTAssertNotNil(dock.surface, "the choice is kept")
        XCTAssertFalse(state.isDocked)
        // Opened again: docked again by itself.
        dock.windowWidthChanged(951)
        XCTAssertNotNil(dock.shown)
        XCTAssertTrue(state.isDocked)
    }

    func testTheBrowserDocksAndItsPictureStepsAside() async {
        let browser = BrowserPreviewState()
        var captures = 0
        browser.capture = { _ in captures += 1; return BrowserPreviewSnapshot(image: nil, title: "Page") }
        browser.open(chatId: "chat", tabId: 3)
        let dock = roomyDock()
        dock.onRelease = { surface, reopen in
            if case .browser(let tabId) = surface { browser.returnFromDock(tabId: tabId, chatId: "chat", open: reopen) }
        }
        browser.dock = dock
        browser.dockIntoWindow()
        XCTAssertEqual(dock.shown, .browser(tabId: 3))
        XCTAssertTrue(browser.browserDocked)
        await browser.refresh()
        XCTAssertEqual(captures, 0, "no pictures of a browser that is on screen")

        dock.undock()
        XCTAssertFalse(browser.browserDocked)
        XCTAssertEqual(browser.chatId, "chat")
        XCTAssertFalse(browser.collapsed)
        await browser.refresh()
        XCTAssertEqual(captures, 1)

        browser.dockIntoWindow()
        dock.close()
        XCTAssertNil(browser.chatId, "closed, as the panel's own Close leaves none")
    }

    // MARK: - The app's own screens, carried out of Exposé

    private let repos = PreviewDockState.Screen(id: "repos:/x", host: "repos", title: "Repos", icon: "folder")

    /// A roomy dock whose host draws its own screens, recording what leaves it.
    private func hostsDock(released: @escaping (PreviewDockState.Surface, Bool) -> Void = { _, _ in }) -> PreviewDockState {
        let dock = roomyDock()
        dock.screenContent = { _ in AnyView(EmptyView()) }
        dock.onScreenRelease = released
        return dock
    }

    func testAScreenDocksOnEitherSideAndLeavesThroughTheHost() {
        var released: [(PreviewDockState.Surface, Bool)] = []
        let dock = hostsDock { released.append(($0, $1)) }
        dock.dock(screen: repos, side: .left)
        XCTAssertEqual(dock.shown, .screen(repos))
        XCTAssertEqual(dock.side, .left)
        XCTAssertFalse(dock.canDock(containerWidth: 951), "a panel can't dock beside it")
        dock.moveToOtherSide()
        XCTAssertEqual(dock.side, .right)
        dock.undock()
        XCTAssertNil(dock.shown)
        XCTAssertEqual(released.map(\.0), [.screen(repos)])
        XCTAssertEqual(released.map(\.1), [true], "undocked, the app shows it full screen")
        XCTAssertEqual(dock.side, .right, "a panel docks only at the right edge")
    }

    func testThePickerIsFilledByTheScreenChosenThere() {
        var released: [PreviewDockState.Surface] = []
        let dock = hostsDock { surface, _ in released.append(surface) }
        dock.dockPicker(side: .left)
        XCTAssertEqual(dock.shown, .picker)
        let settings = PreviewDockState.Screen(id: "settings", host: "settings", title: "Settings", icon: "gear")
        dock.dock(screen: settings, side: dock.side)
        XCTAssertEqual(dock.shown, .screen(settings))
        XCTAssertEqual(dock.side, .left)
        XCTAssertEqual(released, [], "choosing is not leaving")
        dock.dock(screen: repos, side: .left)
        XCTAssertEqual(dock.shown, .screen(settings), "a docked screen is not replaced; the picker only")
        dock.close()
        XCTAssertEqual(released, [.screen(settings)])
    }

    func testScreensNeedTheHostToDrawThem() {
        let dock = roomyDock()
        XCTAssertNil(dock.switcherTargets(in: CGSize(width: 951, height: 669), appMoves: false),
                     "nothing to draw them with, so nothing is carried out of Exposé")
        dock.dock(screen: repos, side: .right)
        XCTAssertNil(dock.shown)
        dock.screenContent = { _ in AnyView(EmptyView()) }
        XCTAssertEqual(dock.shown, .screen(repos))
    }

    func testExposesTargetsAreTheDocksWidthOrTheAppsOnEachSide() {
        let dock = hostsDock()
        let size = CGSize(width: 951, height: 669)
        let screen = dock.switcherTargets(in: size, appMoves: false)
        XCTAssertEqual(screen?.left, CGRect(x: 0, y: 0, width: 548, height: 669))
        XCTAssertEqual(screen?.right, CGRect(x: 403, y: 0, width: 548, height: 669))
        XCTAssertEqual(screen?.appMoves, false)
        let app = dock.switcherTargets(in: size, appMoves: true)
        XCTAssertEqual(app?.right, CGRect(x: 549, y: 0, width: 402, height: 669), "the chat takes the app, a phone's width")
        XCTAssertEqual(app?.appMoves, true)
        XCTAssertNil(dock.switcherTargets(in: CGSize(width: 669, height: 951), appMoves: false), "an open Duo held upright has no split")
        dock.dock(.browser(tabId: nil))
        XCTAssertNil(dock.switcherTargets(in: size, appMoves: false), "one thing docks at a time")
    }

    func testABrowserCarriedOutOfExposeIsTheBrowserDocked() {
        let browser = BrowserPreviewState()
        browser.capture = { _ in BrowserPreviewSnapshot(image: nil, title: "Page") }
        browser.open(chatId: "chat", tabId: 3)
        let dock = hostsDock()
        browser.dock = dock
        dock.dock(screen: .init(id: "browser:7", host: "browser", title: "Page", icon: "globe", showsBrowser: true), side: .left)
        XCTAssertEqual(dock.shown?.showsBrowser, true)
        XCTAssertTrue(browser.browserDocked, "its picture steps aside")
    }

    func testTheSplitPutsTheAppOnTheOtherSideOfTheDock() {
        let bounds = CGRect(x: 0, y: 0, width: 951, height: 669)
        let right = DockSplitLayout.frames(in: bounds, side: .right, appWidth: 402)
        XCTAssertEqual(right.app, CGRect(x: 0, y: 0, width: 402, height: 669))
        XCTAssertEqual(right.divider, CGRect(x: 402, y: 0, width: 1, height: 669))
        XCTAssertEqual(right.dock, CGRect(x: 403, y: 0, width: 548, height: 669))
        let left = DockSplitLayout.frames(in: bounds, side: .left, appWidth: 402)
        XCTAssertEqual(left.dock, CGRect(x: 0, y: 0, width: 548, height: 669))
        XCTAssertEqual(left.divider, CGRect(x: 548, y: 0, width: 1, height: 669))
        XCTAssertEqual(left.app, CGRect(x: 549, y: 0, width: 402, height: 669))
    }

    func testTheDividersWidthIsRemembered() {
        let dock = PreviewDockState(store: store)
        XCTAssertNil(dock.appWidth)
        dock.setAppWidth(450)
        XCTAssertEqual(PreviewDockState(store: store).appWidth, 450)
    }

    func testADockedSimulatorsScreenFillsTheDockExactly() {
        // A closed Duo (its 466x678 cover) docked in an open Duo held landscape (951x669).
        XCTAssertEqual(PreviewDockState.fittedAppWidth(width: 951, trailingInset: 0, height: 669,
                                                       screen: CGSize(width: 466, height: 678)), 490)
        // The dock runs into the right-hand safe area, so the app gives up less.
        XCTAssertEqual(PreviewDockState.fittedAppWidth(width: 900, trailingInset: 51, height: 669,
                                                       screen: CGSize(width: 466, height: 678)), 490)
        // An iPhone 17 Pro beside an iPad mini's app in landscape: a wider app, as wide as the fit needs.
        XCTAssertEqual(PreviewDockState.fittedAppWidth(width: 1133, trailingInset: 0, height: 744,
                                                       screen: CGSize(width: 402, height: 874)), 790)
        // An iPad's screen in a Duo would leave no app; a short window, no usable dock.
        XCTAssertNil(PreviewDockState.fittedAppWidth(width: 951, trailingInset: 0, height: 669,
                                                     screen: CGSize(width: 1133, height: 744)))
        XCTAssertNil(PreviewDockState.fittedAppWidth(width: 951, trailingInset: 0, height: 400,
                                                     screen: CGSize(width: 402, height: 874)))
        XCTAssertNil(PreviewDockState.fittedAppWidth(width: 951, trailingInset: 0, height: 669, screen: .zero))
    }

    func testTheFitIsOnUntilTheDividerIsLetGoElsewhereAndRemembered() {
        let dock = PreviewDockState(store: store)
        XCTAssertTrue(dock.fitsSimulator, "a docked simulator fits from the first")
        dock.setAppWidth(520)
        XCTAssertFalse(dock.fitsSimulator)
        XCTAssertFalse(PreviewDockState(store: store).fitsSimulator, "remembered")
        dock.fitSimulator()
        XCTAssertTrue(dock.fitsSimulator)
        XCTAssertTrue(PreviewDockState(store: store).fitsSimulator)
    }

    func testTheFitFollowsTheLivePictureAndForgetsItWithTheSimulator() {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        let dock = roomyDock(for: state)
        state.dockIntoWindow()
        guard let docked = dock.surface else { return XCTFail("docked") }
        XCTAssertEqual(dock.screenSize(of: docked), state.effectiveScreenSize, "as its panel last saw it")
        dock.simulatorScreenChanged(CGSize(width: 466, height: 678))
        XCTAssertEqual(dock.screenSize(of: docked), CGSize(width: 466, height: 678), "as its live picture measures it")
        dock.undock()
        XCTAssertNil(dock.liveScreenSize, "the next one docked is measured afresh")
        XCTAssertNil(dock.screenSize(of: .browser(tabId: nil)), "a browser has no screen to fit")
    }

    func testTheDockedSimulatorsControlsAskItsMacAndAFoldStartsThePictureAgain() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        let dock = roomyDock(for: state)
        state.dockIntoWindow()
        var calls: [(String, String, String?, String)] = []
        dock.invoke = { machine, method, args, chat in
            calls.append((machine, method, (args.last as? [String: Any])?["action"] as? String, chat))
            return ["success": true]
        }
        let before = dock.generation
        await dock.control("home")
        XCTAssertEqual(dock.generation, before, "Home changes nothing the picture holds")
        await dock.control("open")
        XCTAssertNotEqual(dock.generation, before, "a fold moves the picture to the other screen")
        XCTAssertEqual(calls.map(\.0), ["host", "host"])
        XCTAssertEqual(calls.map(\.1), ["simulatorControl", "simulatorControl"])
        XCTAssertEqual(calls.map(\.2), ["home", "open"])
        XCTAssertEqual(calls.map(\.3), ["chat", "chat"])
    }
}
#endif
