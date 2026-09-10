#if canImport(UIKit)
import UIKit
import SwiftUI
import XCTest
@testable import RipulAgent

@MainActor
final class UXInspectionToolsTests: XCTestCase {
    func testAuditRecognizesCustomSwiftUIHostingController() {
        final class CustomHost: UIHostingController<AnyView> {}
        let host = CustomHost(rootView: AnyView(Text("Fixture")))
        host.view.accessibilityIdentifier = "fixture.customHost"
        // UIKit internals must not substitute for SwiftUI accessibility rows.
        host.view.addSubview(UIControl())
        let audit = ScreenAudit.run(on: host.view)
        XCTAssertEqual(audit.items.count, 1)
        XCTAssertEqual(audit.named, 1)
        XCTAssertEqual(audit.anonymous, 0)
        XCTAssertEqual(audit.items.first?.identity, "a11yId: fixture.customHost")
        XCTAssertTrue(audit.items.first?.className.contains("UIHostingController") == true)
    }

    func testAuditClassifiesControlsAndSkipsHiddenAndExplorerContent() {
        let root = UIView()
        let named = UIButton(); named.accessibilityIdentifier = "fixture.named"
        let automatic = UILabel(); automatic.text = "Readable label"
        let anonymous = UIControl()
        let hidden = UIControl(); hidden.isHidden = true
        let overlay = UIView(); overlay.tag = ripulViewExplorerOverlayTag
        overlay.addSubview(UIControl())
        [named, automatic, anonymous, hidden, overlay].forEach(root.addSubview)
        let audit = ScreenAudit.run(on: root)
        XCTAssertEqual(audit.items.count, 3)
        XCTAssertEqual(audit.named, 1)
        XCTAssertEqual(audit.auto, 1)
        XCTAssertEqual(audit.anonymous, 1)
        XCTAssertTrue(audit.report().contains("fixture.named"))
    }

    func testAuditRootUsesPresentedScreenInAnchorWindow() {
        final class Host: UIViewController {
            var shown: UIViewController?
            override var presentedViewController: UIViewController? { shown }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let host = Host()
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        let modal = UIViewController()
        host.shown = modal
        XCTAssertTrue(ScreenAudit.screenRoot(anchorView: host.view) === modal.view)
        host.shown = nil
        XCTAssertTrue(ScreenAudit.screenRoot(anchorView: host.view) === host.view)
    }

    func testShareInspectionReadsOnlyOfferedFileAndReportsMissingAndOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("summary.md")
        try Data("# Payroll\n78 checks · 0 differences\n".utf8).write(to: file)
        let controller = RipulShareSheet.makeController(fileURLs: [file])
        let result = ShareSheetInspection.inspect(controller, includeText: true)
        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0]["text"] as? String, "# Payroll\n78 checks · 0 differences\n")
        XCTAssertEqual((files[0]["sha256"] as? String)?.count, 64)
        XCTAssertNil(ShareSheetInspection.file(file, includeText: false)["text"])
        try Data(repeating: 65, count: 1_048_577).write(to: file)
        let large = ShareSheetInspection.file(file, includeText: true)
        XCTAssertEqual(large["truncated"] as? Bool, true)
        XCTAssertNil(large["text"]); XCTAssertNil(large["sha256"])
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(ShareSheetInspection.file(file, includeText: true)["readable"] as? Bool, false)
    }

    func testUninstrumentedShareDoesNotPretendItemsWereRead() {
        let controller = UIActivityViewController(activityItems: ["Hidden"], applicationActivities: nil)
        let result = ShareSheetInspection.inspect(controller, includeText: true)
        XCTAssertEqual(result["items_inspectable"] as? Bool, false)
        XCTAssertNil(result["files"])
        XCTAssertNotNil(result["items_error"])
    }

    func testDismissRejectsStaleIdentityAndDetachedController() async {
        let first = RipulShareSheet.makeController(fileURLs: [])
        let second = RipulShareSheet.makeController(fileURLs: [])
        let stale = await ShareSheetInspection.dismiss(second, expectedID: ShareSheetInspection.identity(first))
        XCTAssertEqual(stale["success"] as? Bool, false)
        let missing = await ShareSheetInspection.dismiss(second, expectedID: nil)
        XCTAssertEqual(missing["success"] as? Bool, false)
        let detached = await ShareSheetInspection.dismiss(first, expectedID: ShareSheetInspection.identity(first))
        XCTAssertEqual(detached["success"] as? Bool, false)
    }

    func testToolsAreAvailableOnlyOnDeveloperChannel() {
        let endUser = AgentBridge(audience: .endUser)
        endUser.registerBuiltInTools([ScreenAuditTool(), ShareSheetTool()])
        XCTAssertFalse(endUser.registeredToolSummaries.contains { ["screen_audit", "share_sheet"].contains($0.name) })
        let developer = AgentBridge(audience: .developer)
        developer.registerBuiltInTools([ScreenAuditTool(), ShareSheetTool()])
        XCTAssertEqual(Set(developer.registeredToolSummaries.map(\.name)), ["screen_audit", "share_sheet"])
    }
}
#endif
