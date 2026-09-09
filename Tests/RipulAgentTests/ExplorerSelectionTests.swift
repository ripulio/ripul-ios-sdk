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
}
#endif
