#if os(iOS)
import UIKit
import XCTest
@testable import RipulAgent

@MainActor
final class ComposerElementContextTests: XCTestCase {
    private func fixture() -> (UIWindow, UIButton, ViewInspectorController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let root = UIViewController()
        window.rootViewController = root; window.isHidden = false
        root.view.frame = window.bounds; root.view.backgroundColor = .white
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 40, y: 120, width: 200, height: 44)
        button.setTitle("Save shift", for: .normal)
        button.backgroundColor = .green
        button.accessibilityIdentifier = "shift.save"
        root.view.addSubview(button)
        root.view.layoutIfNeeded()
        let inspector = ViewInspectorController(frame: window.bounds)
        root.view.addSubview(inspector)
        _ = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 140), fire: false)
        return (window, button, inspector)
    }

    func testCapturesLiveSelectedElementWithoutMovingOrPressingAndCropsImage() async throws {
        let (window, button, inspector) = fixture()
        defer { window.isHidden = true }
        var events = 0
        inspector.onCursorMoved = { _ in events += 1 }
        inspector.onInspect = { _ in events += 1 }
        button.addAction(UIAction { _ in events += 1 }, for: .touchUpInside)
        button.setTitle("Approve shift", for: .normal)
        let option = RipulComposerContext.selectedElement(configuration: .init(defaults: [.instrumentedText, .screenshot]))
        let attachment = try await option.makeAttachment()
        XCTAssertTrue(attachment.title.contains("Approve shift"))
        XCTAssertTrue(attachment.selectedContent.contains("shift.save"))
        XCTAssertTrue(attachment.selectedContent.contains("x=40, y=120, width=200, height=44"))
        XCTAssertFalse(attachment.selectedContent.contains("Save shift"))
        XCTAssertEqual(events, 0)
        let image = try XCTUnwrap(UIImage(data: try XCTUnwrap(attachment.screen?.screenshotJPEG)))
        XCTAssertEqual(image.size.width / image.size.height, 200.0 / 44.0, accuracy: 0.1)
        XCTAssertEqual(attachment.screenshotAttachment?["name"], "Selected element.jpg")
        XCTAssertFalse(inspector.isHidden) // temporary exclusion restored after capture
    }

    func testDraftIsFrozenAndReselectingCapturesCurrentHighlight() async throws {
        let (window, button, inspector) = fixture()
        defer { window.isHidden = true }
        let first = try await RipulComposerContext.selectedElement.makeAttachment()
        button.setTitle("Delete shift", for: .normal)
        let second = try await RipulComposerContext.selectedElement.makeAttachment()
        XCTAssertTrue(first.selectedContent.contains("Save shift"))
        XCTAssertFalse(first.selectedContent.contains("Delete shift"))
        XCTAssertTrue(second.selectedContent.contains("Delete shift"))
        XCTAssertNotEqual(first.id, second.id)
        let next = UIButton(frame: CGRect(x: 40, y: 240, width: 200, height: 44))
        next.setTitle("Cancel", for: .normal); next.accessibilityIdentifier = "shift.cancel"
        window.rootViewController?.view.insertSubview(next, belowSubview: inspector)
        _ = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 260), fire: false)
        let third = try await RipulComposerContext.selectedElement.makeAttachment()
        XCTAssertTrue(third.selectedContent.contains("shift.cancel"))
        XCTAssertFalse(first.selectedContent.contains("shift.cancel"))
    }

    func testClosedRemovedHiddenAndExcludedSelectionsAreRejected() async throws {
        ViewInspectorController.live = nil
        do { _ = try await RipulComposerContext.selectedElement.makeAttachment(); XCTFail("No selection should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("View Explorer")) }
        let (window, button, inspector) = fixture()
        defer { window.isHidden = true }
        button.ripulAIContext = .excluded
        do { _ = try await RipulComposerContext.selectedElement.makeAttachment(); XCTFail("Excluded selection should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("excluded")) }
        button.ripulAIContext = nil
        button.isHidden = true
        XCTAssertNil(inspector.composerSelection())
        button.isHidden = false
        button.removeFromSuperview()
        XCTAssertNil(inspector.composerSelection())
    }

    func testDeveloperChoicesAndImageDeselectionUseNormalSendRules() async throws {
        let (window, button, _) = fixture()
        defer { window.isHidden = true }
        button.ripulAIContext = .init(id: "save", label: "Save shift", value: "Enabled", role: .control)
        var attachment = try await RipulComposerContext.selectedElement(configuration: .init(available: [.instrumentedText], defaults: [.instrumentedText])).makeAttachment()
        XCTAssertNil(attachment.screen?.screenshotJPEG)
        XCTAssertEqual(attachment.screen?.available, [.instrumentedText])
        XCTAssertTrue(attachment.selectedContent.contains("Save shift: Enabled"))
        attachment.screen?.selected = [.screenshot]
        XCTAssertNil(attachment.screenshotAttachment)
        XCTAssertFalse(attachment.screen!.canAttach)
    }

    func testSecureFieldCannotBeCapturedEvenWhenInstrumented() async throws {
        let (window, button, inspector) = fixture()
        defer { window.isHidden = true }
        let field = UITextField(frame: button.frame)
        field.text = "secret-password"
        field.isSecureTextEntry = true
        field.ripulAIContext = .init(id: "password", label: "Password", value: field.text, role: .value)
        window.rootViewController?.view.insertSubview(field, belowSubview: inspector)
        _ = inspector.probe(atWindowPoint: CGPoint(x: 100, y: 140), fire: false)
        do { _ = try await RipulComposerContext.selectedElement.makeAttachment(); XCTFail("Secure selection must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("excluded")) }
    }

    func testPrivateDescendantsAreMaskedAndAggregateLabelIsOmitted() async throws {
        let (window, button, inspector) = fixture()
        defer { window.isHidden = true }
        button.accessibilityLabel = "Save secret-code"
        let privateLabel = UILabel(frame: CGRect(x: 0, y: 0, width: 80, height: 44))
        privateLabel.text = "secret-code"
        privateLabel.ripulAIContext = .excluded
        button.addSubview(privateLabel)
        let option = RipulComposerContext.selectedElement(configuration: .init(defaults: [.instrumentedText, .screenshot]))
        let attachment = try await option.makeAttachment()
        XCTAssertFalse(attachment.selectedContent.contains("secret-code"))
        XCTAssertFalse(attachment.title.contains("secret-code"))
        let image = try XCTUnwrap(UIImage(data: try XCTUnwrap(attachment.screen?.screenshotJPEG))?.cgImage)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixel = ((image.height / 2) * image.width + image.width / 10) * 4
        XCTAssertLessThan(rgba[pixel], 10)
        XCTAssertLessThan(rgba[pixel + 1], 10)
        XCTAssertLessThan(rgba[pixel + 2], 10)
        XCTAssertFalse(inspector.isHidden)
    }
}
#endif
