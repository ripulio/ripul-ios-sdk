import WebKit
import XCTest

@testable import RipulAgent

@MainActor final class NativeEmbedTests: XCTestCase {
  private final class Renderer: NativeEmbeddedRenderer {
    let viewController = UIViewController()
    var onEvent: (([String: Any]) -> Void)?
    var onSizeChange: (() -> Void)?
    var isEditing = false
    var accessibilityElements: [Any] { [viewController.view!] }
    func update(snapshot: [String: Any]) throws {}
    func sizeThatFits(width: CGFloat) -> CGSize { CGSize(width: width, height: 137) }
  }
  func testRegistryAndOffscreenLifecycleAreRendererNeutral() {
    let registry = NativeEmbedRegistry()
    var creations = 0
    registry.register("unrelated.test/v1") {
      creations += 1
      return Renderer()
    }
    XCTAssertEqual(registry.features, ["nativeEmbed:unrelated.test/v1"])
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
    let host = NativeEmbedController(webView: web, registry: registry, send: { _ in })
    let update: [String: Any] = [
      "type": "agent-framework:nativeEmbed:update", "ownerId": "chat", "elementId": "element",
      "token": "new", "renderer": "unrelated.test/v1", "snapshot": ["arbitrary": "content"],
    ]
    host.receive(update)
    XCTAssertEqual(host.entryCount, 1)
    XCTAssertEqual(creations, 0)
    XCTAssertEqual(host.attachmentCount, 0)
    host.receive([
      "type": "agent-framework:nativeEmbed:clear", "ownerId": "chat", "elementId": "element",
      "token": "old",
    ])
    XCTAssertEqual(host.entryCount, 1)
    host.receive([
      "type": "agent-framework:nativeEmbed:clear", "ownerId": "chat", "elementId": "element",
      "token": "new",
    ])
    XCTAssertEqual(host.entryCount, 0)
    var unsupported = update
    unsupported["renderer"] = "missing/v1"
    host.receive(unsupported)
    XCTAssertEqual(host.entryCount, 0)
    host.clear()
  }
}
