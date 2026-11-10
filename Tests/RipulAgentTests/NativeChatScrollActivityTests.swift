#if os(iOS)
import XCTest
import UIKit
@testable import RipulAgent

@MainActor
final class NativeChatScrollActivityTests: XCTestCase {
    func testReturnButtonStaysHiddenAfterFingerLiftsUntilCoastEnds() async {
        let (window, scroller, handle, button) = makeList()
        defer { window.isHidden = true }
        XCTAssertTrue(button.isVisible)

        scroller.scrollViewWillBeginDragging(scroller)
        await nextTurn()
        XCTAssertFalse(button.isVisible)

        scroller.scrollViewDidEndDragging(scroller, willDecelerate: true)
        await nextTurn()
        XCTAssertFalse(button.isVisible, "Lifting the finger does not end a flick")

        scroller.scrollViewDidEndDecelerating(scroller)
        await nextTurn()
        XCTAssertTrue(button.isVisible)
        withExtendedLifetime(handle) {}
    }

    func testNoCoastAndRemovingTheListBothReleaseTheButton() async {
        let (window, scroller, handle, button) = makeList()
        defer { window.isHidden = true }

        scroller.scrollViewWillBeginDragging(scroller)
        await nextTurn()
        scroller.scrollViewDidEndDragging(scroller, willDecelerate: false)
        await nextTurn()
        XCTAssertTrue(button.isVisible)

        scroller.scrollViewWillBeginDragging(scroller)
        await nextTurn()
        XCTAssertFalse(button.isVisible)
        scroller.removeFromSuperview()
        await nextTurn()
        XCTAssertTrue(button.isVisible, "A removed scroller must not leave the shared button hidden")
        withExtendedLifetime(handle) {}
    }

    private func makeList() -> (UIWindow, NativeChatListScroller, NativeChatListHandle, ScrollButtonModel) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        let scroller = NativeChatListScroller()
        scroller.frame = window.bounds
        let handle = NativeChatListHandle()
        let button = ScrollButtonModel()
        button.show = true
        handle.onScrollActivityChanged = { button.isScrolling = $0 }
        scroller.handle = handle
        controller.view.addSubview(scroller)
        return (window, scroller, handle, button)
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
#endif
