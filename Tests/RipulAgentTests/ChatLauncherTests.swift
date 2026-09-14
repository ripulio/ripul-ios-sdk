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

            // Exercise the shared gesture's actual action, including its
            // window teardown before the host restores the mounted chat.
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
}
#endif
