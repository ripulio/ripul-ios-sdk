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

    func testPinchKeepsThePointBetweenTheFingersAndMayTakeTheWholeRegion() async throws {
        // The point between the fingers stays where it was on the panel, a
        // point outside it counting as its nearest edge.
        let start = CGRect(x: 100, y: 200, width: 120, height: 240)
        let anchor = CGPoint(x: 130, y: 260)
        XCTAssertEqual(FloatingPanelPinch.origin(start: start, anchor: anchor, size: CGSize(width: 240, height: 480)),
                       CGPoint(x: 70, y: 140))
        XCTAssertEqual(FloatingPanelPinch.origin(start: start, anchor: anchor, size: start.size), start.origin)
        XCTAssertEqual(FloatingPanelPinch.origin(start: start, anchor: CGPoint(x: 400, y: 100), size: CGSize(width: 60, height: 120)),
                       CGPoint(x: 340, y: 100))

        // Low in the window, the grip has little room below the panel; a pinch
        // has the whole region, since the panel moves to make room.
        let host = try window(color: .white)
        let store = defaults()
        store.set(400.0, forKey: "y")
        let controller = RipulFloatingPanelController(
            content: Color.clear.frame(width: 120, height: 240),
            size: CGSize(width: 120, height: 240), minSize: CGSize(width: 80, height: 160),
            showsResizeGrip: true, gripTint: .white,
            posXKey: "x", posYKey: "y", store: store, aspectRatio: 0.5,
            contentInsets: UIEdgeInsets(top: 40, left: 0, bottom: 60, right: 0),
            onResize: { _ in }, onResizeEnded: { _ in })
        host.rootViewController = controller
        try await Task.sleep(nanoseconds: 200_000_000)
        let insets = host.safeAreaInsets
        let regionWidth = controller.view.bounds.width - insets.left - insets.right - 16
        let regionHeight = controller.view.bounds.height - insets.top - insets.bottom - 40 - 60 - 16
        let start120 = CGSize(width: 120, height: 240)
        let largest = controller.pinchedSize(from: start120, scale: 100)
        XCTAssertEqual(largest.width, min(regionWidth, regionHeight * 0.5), accuracy: 0.5)
        XCTAssertEqual(largest.width / largest.height, 0.5, accuracy: 0.001)
        XCTAssertLessThan(controller.clampedSize(CGSize(width: 4000, height: 4000)).height, largest.height)
        XCTAssertEqual(controller.pinchedSize(from: start120, scale: 1.5), CGSize(width: 180, height: 360))
        XCTAssertEqual(controller.pinchedSize(from: start120, scale: 0.01), CGSize(width: 80, height: 160))
        XCTAssertEqual(controller.pinchedSize(from: start120, scale: .nan), start120)
    }

    func testAToolbarAboveTheLockedAreaIsLeftOutOfItsRatio() async throws {
        let host = try window(color: .white)
        let controller = RipulFloatingPanelController(
            content: Color.clear.frame(width: 120, height: 270),
            size: CGSize(width: 120, height: 270), minSize: CGSize(width: 80, height: 190),
            showsResizeGrip: true, gripTint: .white,
            posXKey: "x", posYKey: "y", store: defaults(), aspectRatio: 0.5, toolbarHeight: 30,
            contentInsets: UIEdgeInsets(top: 40, left: 0, bottom: 60, right: 0),
            onResize: { _ in }, onResizeEnded: { _ in })
        host.rootViewController = controller
        try await Task.sleep(nanoseconds: 200_000_000)
        // Below the 30-point bar the ratio holds, at every size.
        let start = CGSize(width: 120, height: 270)
        XCTAssertEqual(controller.pinchedSize(from: start, scale: 1.5), CGSize(width: 180, height: 390))
        XCTAssertEqual(controller.pinchedSize(from: start, scale: 0.01), CGSize(width: 80, height: 190))
        XCTAssertEqual(controller.clampedSize(CGSize(width: 140, height: 310)), CGSize(width: 140, height: 310))
        // The largest still fits the region, bar and all.
        let insets = host.safeAreaInsets
        let regionHeight = controller.view.bounds.height - insets.top - insets.bottom - 40 - 60 - 16
        let largest = controller.pinchedSize(from: start, scale: 100)
        XCTAssertLessThanOrEqual(largest.height, regionHeight + 0.5)
        XCTAssertEqual((largest.height - 30) * 0.5, largest.width, accuracy: 0.001)
        let gripped = controller.clampedSize(CGSize(width: 4000, height: 4000))
        XCTAssertLessThanOrEqual(gripped.height, regionHeight + 0.5)
        XCTAssertEqual((gripped.height - 30) * 0.5, gripped.width, accuracy: 0.001)
    }

    func testAPanelThatMovesToTheWindowsEdgesGoesOverTheBarsAndIsSizedBetweenThem() async throws {
        let host = try window(color: .white)
        let insets = host.safeAreaInsets
        let regionHeight = host.bounds.height - insets.top - insets.bottom - 40 - 60 - 16
        var placed: [CGRect] = []
        var gripped: [CGSize] = []
        var last: (controller: UIViewController, panel: UIView)?
        // Never placed; then left past the window's top-left; then past its foot.
        for stored in [nil, CGPoint(x: -500, y: -500), CGPoint(x: 5000, y: 5000)] {
            let store = defaults()
            if let stored {
                store.set(Double(stored.x), forKey: "x")
                store.set(Double(stored.y), forKey: "y")
            }
            let controller = RipulFloatingPanelController(
                content: Color.clear.frame(width: 120, height: 270),
                size: CGSize(width: 120, height: 270), minSize: CGSize(width: 80, height: 190),
                showsResizeGrip: true, gripTint: .white,
                posXKey: "x", posYKey: "y", store: store, aspectRatio: 0.5, toolbarHeight: 30,
                contentInsets: UIEdgeInsets(top: 40, left: 0, bottom: 60, right: 0),
                avoidsKeyboard: true, onResize: { _ in }, onResizeEnded: { _ in })
            controller.movesToWindowEdges = true
            host.rootViewController = controller
            try await Task.sleep(nanoseconds: 200_000_000)
            let panel = try XCTUnwrap((controller.view as? RipulFloatingPanelRootView)?.panelView)
            placed.append(panel.frame)
            gripped.append(controller.clampedSize(CGSize(width: 4000, height: 4000)))
            last = (controller, panel)
        }
        // Never placed, it starts clear of the host's top bar, as a panel kept inside does.
        XCTAssertEqual(placed[0].minX, insets.left + 8, accuracy: 0.5)
        XCTAssertEqual(placed[0].minY, insets.top + 40 + 8, accuracy: 0.5)
        // It goes over the top bar up to the status bar, where the system takes
        // every touch, and over the bottom bar and the home indicator right
        // down to the window's foot.
        XCTAssertEqual(placed[1].minX, insets.left, accuracy: 0.5)
        XCTAssertEqual(placed[1].minY, insets.top, accuracy: 0.5)
        XCTAssertEqual(placed[2].maxX, host.bounds.width - insets.right, accuracy: 0.5)
        XCTAssertEqual(placed[2].maxY, host.bounds.height, accuracy: 0.5)
        // At the window's foot the grip keeps the size it has, where the room
        // below the safe area would have shrunk it to the smallest...
        XCTAssertEqual(gripped[2].width, placed[2].width, accuracy: 0.5)
        XCTAssertEqual(gripped[2].height, placed[2].height, accuracy: 0.5)
        // ...and from the top-left it grows only as big as the room between the bars.
        XCTAssertLessThanOrEqual(gripped[1].height, regionHeight + 0.5)
        XCTAssertEqual((gripped[1].height - 30) * 0.5, gripped[1].width, accuracy: 0.001)

        // The keyboard up, the panel keeps clear of it and of the bar above it.
        let (controller, panel) = try XCTUnwrap(last)
        let keyboardY = controller.view.bounds.maxY - 200
        let keyboard = controller.view.convert(CGRect(x: 0, y: keyboardY, width: host.bounds.width, height: 200),
            to: host.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: keyboard])
        controller.view.layoutIfNeeded()
        XCTAssertEqual(panel.frame.maxY, keyboardY - 60 - 8, accuracy: 0.5)
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
