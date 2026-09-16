#if os(iOS)
import UIKit
import XCTest
@testable import RipulAgent

@MainActor
final class ExplorerSelectionTests: XCTestCase {
    private func read(args: [String: Any] = [:]) async throws -> [String: Any] {
        let value = try await ExplorerProbeTool().execute(args: args)
        return try XCTUnwrap(value as? [String: Any])
    }

    private func fixture() -> (UIWindow, UIButton, ViewInspectorController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        root.view.frame = window.bounds

        let button = UIButton(type: .system)
        button.frame = CGRect(x: 40, y: 120, width: 200, height: 44)
        button.setTitle("Add notes", for: .normal)
        button.accessibilityIdentifier = "fixture.notes"
        button.accessibilityLabel = "Shift notes"
        root.view.addSubview(button)
        root.view.layoutIfNeeded()

        let inspector = ViewInspectorController(frame: window.bounds)
        root.view.addSubview(inspector)
        return (window, button, inspector)
    }

    func testReadReturnsExistingSelectionWithoutMovingReselectingOrPressing() async throws {
        let (window, button, inspector) = fixture()
        defer { window.isHidden = true }
        var presses = 0
        button.addAction(UIAction { _ in presses += 1 }, for: .touchUpInside)
        let selected = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 140), fire: false)
        XCTAssertEqual((selected["element"] as? [String: Any])?["id"] as? String, "fixture.notes")

        // If reading accidentally hit-tests again, this covering button would
        // replace the selection even though the user has not moved the cursor.
        let covering = UIButton(frame: button.frame)
        covering.accessibilityIdentifier = "fixture.other"
        window.rootViewController?.view.addSubview(covering)
        var cursorEvents = 0
        var selectionEvents = 0
        inspector.onCursorMoved = { _ in cursorEvents += 1 }
        inspector.onInspect = { _ in selectionEvents += 1 }

        for _ in 0..<2 {
            let result = try await read()
            let element = try XCTUnwrap(result["element"] as? [String: Any])
            XCTAssertEqual(result["isOpen"] as? Bool, true)
            XCTAssertEqual(result["hasSelection"] as? Bool, true)
            XCTAssertEqual(element["id"] as? String, "fixture.notes")
            XCTAssertEqual(element["text"] as? String, "Add notes")
            XCTAssertEqual(element["label"] as? String, "Shift notes")
            XCTAssertEqual(element["role"] as? String, "button")
            XCTAssertEqual(result["readout"] as? String, selected["readout"] as? String)
            XCTAssertEqual(result["reticule"] as? [String: Double], selected["reticule"] as? [String: Double])
            XCTAssertEqual(result["highlightFrame"] as? [String: Double], selected["highlightFrame"] as? [String: Double])
            XCTAssertNil(result["fired"])
        }
        XCTAssertEqual(cursorEvents, 0)
        XCTAssertEqual(selectionEvents, 0)
        XCTAssertEqual(presses, 0)
    }

    func testReadDoesNotOpenClosedExplorerOrInventSelection() async throws {
        RipulViewExplorer.dismiss()
        ViewInspectorController.live = nil
        let result = try await read()
        XCTAssertEqual(result["success"] as? Bool, true)
        XCTAssertEqual(result["isOpen"] as? Bool, false)
        XCTAssertEqual(result["hasSelection"] as? Bool, false)
        XCTAssertNil(result["element"])
        XCTAssertNil(ViewInspectorController.live)
        XCTAssertFalse(RipulViewExplorer.isPresented)
    }

    func testOpenExplorerBeforeFirstPickHasNoSelection() async throws {
        let (window, _, inspector) = fixture()
        defer { window.isHidden = true }
        let result = try await read()
        XCTAssertEqual(result["isOpen"] as? Bool, true)
        XCTAssertEqual(result["hasSelection"] as? Bool, false)
        XCTAssertNil(result["element"])
        XCTAssertEqual(result["readout"] as? String, "")
        XCTAssertTrue(ViewInspectorController.live === inspector)
    }

    func testRemovedSelectionIsNotReturnedAsCurrent() async throws {
        let (window, button, inspector) = fixture()
        defer { window.isHidden = true }
        _ = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 140), fire: false)
        button.removeFromSuperview()
        let result = try await read()
        XCTAssertEqual(result["isOpen"] as? Bool, true)
        XCTAssertEqual(result["hasSelection"] as? Bool, false)
        XCTAssertNil(result["element"])
        XCTAssertEqual(result["readout"] as? String, "")
    }

    func testInvalidOrFireOnlyRequestsDoNotChangeSelection() async throws {
        let (window, _, inspector) = fixture()
        defer { window.isHidden = true }
        let selected = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 140), fire: false)
        var changes = 0
        inspector.onCursorMoved = { _ in changes += 1 }
        inspector.onInspect = { _ in changes += 1 }
        let invalidRequests: [[String: Any]] = [["fire": true], ["x": 20], ["y": 20], ["x": "bad", "y": 20], ["x": Double.infinity, "y": 20]]
        for args in invalidRequests {
            let result = try await read(args: args)
            XCTAssertEqual(result["success"] as? Bool, false)
            XCTAssertNil(result["fired"])
        }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(inspector.selectionSnapshot()["readout"] as? String, selected["readout"] as? String)
    }

    func testReadReportsActualClampedCoordinates() async throws {
        let (window, _, inspector) = fixture()
        defer { window.isHidden = true }
        let selected = inspector.probe(atWindowPoint: CGPoint(x: -100, y: 1000), fire: false)
        let result = try await read()
        XCTAssertEqual(result["reticule"] as? [String: Double], ["x": 0, "y": 639])
        XCTAssertEqual(result["reticule"] as? [String: Double], selected["reticule"] as? [String: Double])
    }

    @available(iOS 26.0, *)
    private func overlayFixture() throws -> (UIWindow, UIButton, RipulDevOverlayWindow, UIButton, ViewInspectorController) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Cross-window selection needs the hosted test runner: scripts/test-host-screen-preview.sh.")
        }
        let visibleWindows = scene.windows.filter { !$0.isHidden }
        visibleWindows.forEach { $0.isHidden = true }
        addTeardownBlock { visibleWindows.forEach { $0.isHidden = false } }

        let host = UIWindow(windowScene: scene)
        host.frame = scene.screen.bounds
        let root = UIViewController()
        host.rootViewController = root
        host.isHidden = false
        let button = UIButton(frame: CGRect(x: 40, y: 120, width: 200, height: 44))
        button.accessibilityIdentifier = "host.button"
        root.view.addSubview(button)

        let agent = RipulDevOverlayWindow(windowScene: scene)
        agent.frame = host.frame
        agent.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 3)
        let agentRoot = UIViewController()
        agent.installRoot(agentRoot)
        agent.isHidden = false
        let agentButton = UIButton(frame: button.frame)
        agentButton.accessibilityIdentifier = "agent.button"
        agentRoot.view.addSubview(agentButton)

        let explorer = RipulExplorerOverlayWindow(windowScene: scene)
        explorer.frame = host.frame
        explorer.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 4)
        let explorerRoot = UIViewController()
        explorerRoot.view.tag = ripulViewExplorerOverlayTag
        explorer.installRoot(explorerRoot)
        explorer.isHidden = false
        let inspector = ViewInspectorController(frame: host.bounds)
        inspector.hostWindow = host
        explorerRoot.view.addSubview(inspector)
        [host, agent, explorer].forEach { $0.layoutIfNeeded() }
        addTeardownBlock {
            [host, agent, explorer].forEach { $0.isHidden = true }
        }
        return (host, button, agent, agentButton, inspector)
    }

    @available(iOS 26.0, *)
    func testMinimizedAgentControlsTakeTouchesBeforeInspectorCapture() throws {
        let (_, _, agent, _, inspector) = try overlayFixture()
        let explorer = try XCTUnwrap(inspector.window as? RipulExplorerOverlayWindow)
        let point = CGPoint(x: 100, y: 140)
        for frame in [CGRect(x: 72, y: 112, width: 56, height: 56),
                      CGRect(x: 12, y: 110, width: 296, height: 64)] {
            agent.interactiveFrame = frame
            XCTAssertNil(explorer.hitTest(point, with: nil))
            XCTAssertNotNil(agent.hitTest(point, with: nil))
            XCTAssertTrue(explorer.hitTest(CGPoint(x: 100, y: 300), with: nil) === inspector)
        }
        agent.isHidden = true
        XCTAssertTrue(explorer.hitTest(point, with: nil) === inspector)
        agent.isHidden = false
        agent.isUserInteractionEnabled = false
        XCTAssertTrue(explorer.hitTest(point, with: nil) === inspector)
        agent.isUserInteractionEnabled = true
        agent.isPassthrough = false
        agent.isInspectorSelectionEnabled = true
        XCTAssertTrue(explorer.hitTest(point, with: nil) === inspector)
    }

    @available(iOS 26.0, *)
    func testInspectorPanelKeepsTouchPriorityWhenCoveringMinimizedAgent() throws {
        let (_, _, agent, _, inspector) = try overlayFixture()
        let explorer = try XCTUnwrap(inspector.window as? RipulExplorerOverlayWindow)
        agent.interactiveFrame = CGRect(x: 40, y: 120, width: 200, height: 44)
        let panelRoot = RipulFloatingPanelRootView(frame: explorer.bounds)
        let panelButton = UIButton(frame: agent.interactiveFrame)
        panelRoot.addSubview(panelButton)
        panelRoot.panelView = panelButton
        explorer.rootViewController?.view.addSubview(panelRoot)
        XCTAssertTrue(explorer.hitTest(CGPoint(x: 100, y: 140), with: nil) === panelButton)
    }

    @available(iOS 26.0, *)
    func testMinimizedBubbleAndCompactBarSelectHostWithoutActivatingAgent() throws {
        let (_, _, agent, agentButton, inspector) = try overlayFixture()
        var agentPresses = 0
        agentButton.addAction(UIAction { _ in agentPresses += 1 }, for: .touchUpInside)
        // Both launcher shapes deliberately accept real touches here. Inspection
        // must ignore the whole window, not merely rely on touch passthrough.
        for frame in [CGRect(x: 72, y: 112, width: 56, height: 56),
                      CGRect(x: 12, y: 110, width: 296, height: 64)] {
            agent.interactiveFrame = frame
            XCTAssertNotNil(agent.hitTest(CGPoint(x: 100, y: 140), with: nil))
            let selected = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 140), fire: false)
            XCTAssertEqual((selected["element"] as? [String: Any])?["id"] as? String, "host.button")
        }
        XCTAssertEqual(agentPresses, 0)
    }

    @available(iOS 26.0, *)
    func testExpandedAgentCollapseResetsSeedAndNeverFallsBackIntoRetainedConsole() throws {
        let (host, _, agent, _, inspector) = try overlayFixture()
        agent.isPassthrough = false
        agent.isInspectorSelectionEnabled = true
        let expanded = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 140), fire: false)
        XCTAssertEqual((expanded["element"] as? [String: Any])?["id"] as? String, "agent.button")
        XCTAssertTrue(inspector.hostWindow === agent)

        // Collapse disables inspection before the animation changes touch
        // routing. Keep the console subtree visible to catch geometric fallback.
        agent.isInspectorSelectionEnabled = false
        XCTAssertEqual(inspector.selectionSnapshot()["hasSelection"] as? Bool, false)
        XCTAssertNil(inspector.composerSelection())
        host.isUserInteractionEnabled = false
        let collapsed = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 140), fire: false)
        XCTAssertEqual((collapsed["element"] as? [String: Any])?["id"] as? String, "host.button")
        XCTAssertTrue(inspector.hostWindow === host)

        host.isUserInteractionEnabled = true
        agent.isInspectorSelectionEnabled = true
        let restored = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 140), fire: false)
        XCTAssertEqual((restored["element"] as? [String: Any])?["id"] as? String, "agent.button")
    }

    @available(iOS 26.0, *)
    func testRetainedNativeSelectionCannotRestoreOrActivateMinimizedAgent() throws {
        let (_, _, agent, agentButton, inspector) = try overlayFixture()
        let session = InspectorSession()
        inspector.session = session
        session.controller = inspector
        agent.isPassthrough = false
        agent.isInspectorSelectionEnabled = true
        _ = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 140), fire: false)
        let selection = try XCTUnwrap(inspector.nativeSelection)
        var presses = 0
        agentButton.addAction(UIAction { _ in presses += 1 }, for: .touchUpInside)
        session.pinned = true
        agent.isInspectorSelectionEnabled = false
        XCTAssertFalse(session.pinned)
        XCTAssertFalse(session.hasSelection)
        XCTAssertNil(inspector.nativeSelection)
        inspector.activateSelection()
        XCTAssertEqual(presses, 0)
        XCTAssertFalse(session.hasSelection)
        inspector.restoreNativeSelection(selection, remembering: false)
        XCTAssertFalse(session.hasSelection)
    }
}
#endif
