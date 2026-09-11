#if os(iOS)
import SwiftUI
import XCTest
@testable import RipulAgent

@MainActor
final class HostScreenPreviewTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "HostScreenPreviewTests." + UUID().uuidString
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }

    private func window(color: UIColor) throws -> UIWindow {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Host-window rendering needs a hosted app: run scripts/test-host-screen-preview.sh.")
        }
        let result = UIWindow(windowScene: scene)
        result.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        result.rootViewController = UIViewController()
        result.rootViewController?.view.backgroundColor = color
        result.isHidden = false
        result.layoutIfNeeded()
        addTeardownBlock { result.isHidden = true }
        return result
    }

    private func rgb(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes
    }

    func testCoveredHostCaptureExcludesAgentAndReflectsHostChangesWithoutInput() async throws {
        let host = try window(color: .green)
        try await Task.sleep(nanoseconds: 200_000_000)
        let chrome = RipulChromeWindow(windowScene: try XCTUnwrap(host.windowScene))
        chrome.frame = host.frame
        let root = UIViewController()
        root.view.backgroundColor = .red
        chrome.installRoot(root)
        chrome.windowLevel = .alert
        chrome.isHidden = false
        defer { chrome.isHidden = true }
        let button = UIButton(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        var presses = 0
        button.addAction(UIAction { _ in presses += 1 }, for: .touchUpInside)
        host.rootViewController?.view.addSubview(button)

        let first = try XCTUnwrap(HostScreenPreviewState.capture(host, maxDimension: 400))
        XCTAssertEqual(first.size, CGSize(width: 200, height: 400))
        let green = try rgb(first)
        XCTAssertGreaterThan(green[1], 240)
        XCTAssertLessThan(green[0], 10)
        host.rootViewController?.view.backgroundColor = .blue
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = try XCTUnwrap(HostScreenPreviewState.capture(host, maxDimension: 400))
        XCTAssertGreaterThan(try rgb(second)[2], 240)
        XCTAssertNil(HostScreenPreviewState.capture(chrome))
        XCTAssertEqual(presses, 0)
        XCTAssertTrue(button.superview === host.rootViewController?.view)
        XCTAssertFalse(host.isHidden)
    }

    func testCaptureStopsWhenCollapsedDisabledMinimisedOrBackgrounded() async throws {
        let host = try window(color: .white)
        try await Task.sleep(nanoseconds: 200_000_000)
        var captures = 0
        let state = HostScreenPreviewState(store: defaults()) { captures += 1; return host }
        state.didBecomeActive()
        XCTAssertEqual(captures, 0)
        state.setAgentExpanded(true)
        XCTAssertNotNil(state.frame.image)
        XCTAssertTrue(state.isCapturing)
        state.isCollapsed = true
        let beforeWait = captures
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(captures, beforeWait)
        XCTAssertFalse(state.isCapturing)

        state.isCollapsed = false
        XCTAssertGreaterThan(captures, beforeWait)
        state.isEnabled = false
        XCTAssertFalse(state.isCapturing)
        XCTAssertNil(state.frame.image)
        state.isEnabled = true
        XCTAssertTrue(state.isCapturing)
        state.setAgentExpanded(false)
        XCTAssertFalse(state.isCapturing)
        XCTAssertNil(state.frame.image)
        state.setAgentExpanded(true)
        state.willResignActive()
        XCTAssertFalse(state.isCapturing)
        XCTAssertNil(state.frame.image)
        state.didBecomeActive()
        XCTAssertTrue(state.isCapturing)
        state.setAgentExpanded(false)
    }

    func testOffAndCollapsedPreferencesSurviveRecreationWithoutCapturing() {
        let store = defaults()
        let first = HostScreenPreviewState(store: store) { XCTFail("Hidden preview captured"); return nil }
        XCTAssertTrue(first.isEnabled)
        first.isCollapsed = true
        first.isEnabled = false
        let restored = HostScreenPreviewState(store: store) { XCTFail("Disabled preview captured"); return nil }
        restored.didBecomeActive()
        restored.setAgentExpanded(true)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertTrue(restored.isCollapsed)
        XCTAssertFalse(restored.isCapturing)
        restored.isEnabled = true
        XCTAssertTrue(restored.isCollapsed)
        XCTAssertFalse(restored.isCapturing)
    }

    func testOnlyPanelTouchesAreClaimedByPreviewOverlay() {
        let overlay = HostScreenPreviewPassthroughView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        // SwiftUI may provisionally return its background instead of a panel
        // descendant. The overlay must still route the touch to the panel.
        let hostingBackground = PreviewHostingBackground(frame: overlay.bounds)
        overlay.addSubview(hostingBackground)
        let floatingRoot = RipulFloatingPanelRootView(frame: overlay.bounds)
        hostingBackground.addSubview(floatingRoot)
        let panel = UIView(frame: CGRect(x: 20, y: 80, width: 160, height: 320))
        floatingRoot.addSubview(panel)
        floatingRoot.panelView = panel
        XCTAssertTrue(overlay.hitTest(CGPoint(x: 100, y: 200), with: nil) === panel)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 280, y: 200), with: nil))
        XCTAssertNil(overlay.hitTest(CGPoint(x: 100, y: 600), with: nil))
        panel.isHidden = true
        XCTAssertNil(overlay.hitTest(CGPoint(x: 100, y: 200), with: nil))
        panel.isHidden = false
        hostingBackground.isUserInteractionEnabled = false
        XCTAssertNil(overlay.hitTest(CGPoint(x: 100, y: 200), with: nil))
    }

    func testAspectResizeFitsAvailableSpaceAndKeyboard() async throws {
        let host = try window(color: .white)
        let controller = RipulFloatingPanelController(
            content: Color.clear.frame(width: 120, height: 240),
            size: CGSize(width: 120, height: 240), minSize: CGSize(width: 80, height: 160),
            showsResizeGrip: true, gripTint: .white,
            posXKey: "x", posYKey: "y", store: defaults(), aspectRatio: 0.5,
            contentInsets: UIEdgeInsets(top: 40, left: 0, bottom: 60, right: 0),
            avoidsKeyboard: true, onResize: { _ in }, onResizeEnded: { _ in })
        host.rootViewController = controller
        try await Task.sleep(nanoseconds: 200_000_000)
        let panel = try XCTUnwrap((controller.view as? RipulFloatingPanelRootView)?.panelView)
        let large = controller.clampedSize(CGSize(width: 4000, height: 4000))
        XCTAssertEqual(large.width / large.height, 0.5, accuracy: 0.001)
        XCTAssertLessThanOrEqual(panel.frame.minY + large.height,
            controller.view.bounds.maxY - host.safeAreaInsets.bottom - 68 + 1)
        let small = controller.clampedSize(.zero)
        XCTAssertEqual(small, CGSize(width: 80, height: 160))

        let keyboardY = controller.view.bounds.maxY - 200
        let keyboard = controller.view.convert(CGRect(x: 0, y: keyboardY, width: 320, height: 200),
            to: host.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: keyboard])
        controller.view.layoutIfNeeded()
        let aboveKeyboard = controller.clampedSize(CGSize(width: 4000, height: 4000))
        XCTAssertLessThan(aboveKeyboard.height, large.height)
        XCTAssertEqual(aboveKeyboard.width / aboveKeyboard.height, 0.5, accuracy: 0.001)
        XCTAssertLessThanOrEqual(panel.frame.minY + aboveKeyboard.height, keyboardY - 68 + 1)
    }

    @available(iOS 26.0, *)
    func testPreviewShrinksToFABRestoresSizeAndDisablesHitRegion() async throws {
        let host = try window(color: .green)
        try await Task.sleep(nanoseconds: 200_000_000)
        let state = HostScreenPreviewState(store: defaults()) { host }
        let preview = HostScreenPreviewController(state: state)
        preview.view.backgroundColor = .systemBackground // opaque expanded agent surface
        let overlay = RipulChromeWindow(windowScene: try XCTUnwrap(host.windowScene))
        overlay.frame = host.frame
        overlay.installRoot(preview)
        overlay.isHidden = false
        defer { overlay.isHidden = true; state.setAgentExpanded(false) }
        state.didBecomeActive()
        state.setAgentExpanded(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        func panel(in view: UIView) -> UIView? {
            if let root = view as? RipulFloatingPanelRootView { return root.panelView }
            return view.subviews.lazy.compactMap { panel(in: $0) }.first
        }
        let expandedPanel = try XCTUnwrap(panel(in: preview.view))
        let expandedSize = expandedPanel.bounds.size
        XCTAssertGreaterThan(expandedSize.width, 100)
        XCTAssertEqual(expandedSize.width / expandedSize.height, 0.5, accuracy: 0.02)
        state.isCollapsed = true
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(expandedPanel.bounds.width, 56, accuracy: 1)
        XCTAssertEqual(expandedPanel.bounds.height, 56, accuracy: 1)
        state.isCollapsed = false
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(expandedPanel.bounds.width, expandedSize.width, accuracy: 1)
        XCTAssertEqual(expandedPanel.bounds.height, expandedSize.height, accuracy: 1)
        let attachment = XCTAttachment(image: try XCTUnwrap(overlay.rootViewController?.view.snapshotImageForPreviewTest()))
        attachment.name = "Host screen preview"
        attachment.lifetime = .keepAlways
        add(attachment)
        state.isEnabled = false
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(preview.view.hitTest(CGPoint(x: 40, y: 150), with: nil))
    }
}

private final class PreviewHostingBackground: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { self }
}

private extension UIView {
    func snapshotImageForPreviewTest() -> UIImage {
        UIGraphicsImageRenderer(bounds: bounds).image { _ in drawHierarchy(in: bounds, afterScreenUpdates: false) }
    }
}
#endif
