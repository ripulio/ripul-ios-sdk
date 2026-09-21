#if os(iOS)
import XCTest
import UIKit
@testable import RipulAgent

@available(iOS 26.0, *)
@MainActor
final class ChatLauncherTests: XCTestCase {
    func testRepeatedRestoresLeaveTheHostInteractiveWithoutBootingAConsole() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Requires an iOS application test host")
        }
        let suiteName = "io.ripul.tests.chat-launcher.\(UUID())"
        let cache = UserDefaultsSessionCache(suiteName: suiteName)
        defer { cache.userDefaults.removePersistentDomain(forName: suiteName) }
        let hostWindow = RipulChrome.appWindow(in: scene)
        var restores = 0
        let launcher = RipulChatLauncher(cache: cache) { restores += 1 }
        defer { launcher.dismiss() }

        for cycle in 1...12 {
            launcher.show()
            try await Task.sleep(nanoseconds: 100_000_000)
            let window = try XCTUnwrap(scene.windows.first {
                !$0.isHidden && $0.rootViewController is RipulDevOverlayRootVC
            })
            window.layoutIfNeeded()
            let root = try XCTUnwrap(window.rootViewController as? RipulDevOverlayRootVC)
            root.view.layoutIfNeeded()
            let bubble = try XCTUnwrap(root.view.subviews.first {
                $0.accessibilityIdentifier == "RipulChatLauncher.restore"
            })

            XCTAssertTrue(root.children.isEmpty, "A borrowed FAB must not mount a console, compact bar or preview")
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertTrue(RipulChrome.appWindow(in: scene) === hostWindow)
            XCTAssertNil(window.hitTest(CGPoint(x: window.bounds.midX, y: window.bounds.midY), with: nil),
                         "Touches outside the FAB must reach the remote screen")
            XCTAssertNotNil(window.hitTest(bubble.center, with: nil))

            // Exercise the actual gesture action: hosts using a plain restore
            // callback still retire the launcher before the action returns.
            root.perform(NSSelectorFromString("bubbleTapped"))
            XCTAssertEqual(restores, cycle)
            XCTAssertTrue(window.isHidden)
            XCTAssertTrue(RipulChrome.appWindow(in: scene) === hostWindow)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func testDismissRemovesTheLauncherWithoutRestoringChat() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Requires an iOS application test host")
        }
        let launcher = RipulChatLauncher(cache: UserDefaultsSessionCache()) {
            XCTFail("Leaving the viewer must not reopen chat")
        }
        launcher.show()
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.dismiss()
        XCTAssertFalse(scene.windows.contains {
            !$0.isHidden && $0.rootViewController is RipulDevOverlayRootVC
        })
    }

    /// A host folding something into the bubble needs its landing spot BEFORE
    /// the bubble exists — and the spot has to be where the bubble then goes.
    func testRestingFrameIsWhereTheBubbleThenAppears() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Requires an iOS application test host")
        }
        let suiteName = "io.ripul.tests.chat-launcher.resting.\(UUID())"
        let cache = UserDefaultsSessionCache(suiteName: suiteName)
        defer { cache.userDefaults.removePersistentDomain(forName: suiteName) }
        let hostWindow = try XCTUnwrap(RipulChrome.appWindow(in: scene))

        // Nothing saved: the bottom-trailing corner, clear of the safe area.
        let safe = hostWindow.bounds.inset(by: hostWindow.safeAreaInsets)
        let predicted = RipulChatLauncher.restingFrame(cache: cache, in: hostWindow)
        XCTAssertEqual(predicted.size, CGSize(width: 56, height: 56))
        XCTAssertEqual(predicted.maxX, safe.maxX - 16, accuracy: 0.5)
        XCTAssertEqual(predicted.maxY, safe.maxY - 24, accuracy: 0.5)

        let launcher = RipulChatLauncher(cache: cache) {}
        defer { launcher.dismiss() }
        launcher.show()
        try await Task.sleep(nanoseconds: 100_000_000)
        let window = try XCTUnwrap(scene.windows.first {
            !$0.isHidden && $0.rootViewController is RipulDevOverlayRootVC
        })
        let root = try XCTUnwrap(window.rootViewController as? RipulDevOverlayRootVC)
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        let bubble = try XCTUnwrap(root.view.subviews.first {
            $0.accessibilityIdentifier == "RipulChatLauncher.restore"
        })
        XCTAssertEqual(bubble.frame.origin.x, predicted.origin.x, accuracy: 0.5)
        XCTAssertEqual(bubble.frame.origin.y, predicted.origin.y, accuracy: 0.5)

        // A remembered position is honoured, and one dragged off the glass is
        // pulled back inside the same margin the bubble keeps for itself.
        cache.set(Double(-500), forKey: "ripul.devAssistantOverlay.bubbleX")
        cache.set(Double(300), forKey: "ripul.devAssistantOverlay.restingY")
        let clamped = RipulChatLauncher.restingFrame(cache: cache, in: hostWindow)
        XCTAssertEqual(clamped.minX, safe.minX + 16, accuracy: 0.5)
        XCTAssertEqual(clamped.midY, 300, accuracy: 0.5)
    }
}
#endif
