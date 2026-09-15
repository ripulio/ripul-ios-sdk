import MapKit
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
  func testMapContractAndInteractionAreIndependentOfPlaces() throws {
    let renderer = NativeMapRenderer()
    let snapshot: [String: Any] = [
      "camera": ["latitude": 37.8, "longitude": -122.4, "latitudeDelta": 0.1, "longitudeDelta": 0.1],
      "pins": [["id": "arbitrary", "title": "A different city", "latitude": 37.8, "longitude": -122.4]],
    ]
    try renderer.update(snapshot: snapshot)
    XCTAssertEqual(renderer.map.annotations.count, 1)
    XCTAssertEqual(renderer.map.annotations.first?.title, "A different city")
    XCTAssertFalse(renderer.map.isScrollEnabled)
    XCTAssertFalse(renderer.isEditing)
    renderer.toggleExplore()
    XCTAssertTrue(renderer.map.isScrollEnabled)
    XCTAssertTrue(renderer.map.isZoomEnabled)
    XCTAssertTrue(renderer.isEditing)
    renderer.toggleExplore()
    XCTAssertFalse(renderer.map.isScrollEnabled)
    var event: [String: Any]?
    renderer.onEvent = { event = $0 }
    renderer.mapView(renderer.map, didSelect: renderer.map.annotations[0])
    XCTAssertEqual(event?["id"] as? String, "arbitrary")
    var invalid = snapshot
    invalid["camera"] = ["latitude": Double.nan]
    XCTAssertThrowsError(try renderer.update(snapshot: invalid))
    invalid = snapshot
    let original = snapshot["pins"] as! [[String: Any]]
    invalid["pins"] = original + original
    XCTAssertThrowsError(try renderer.update(snapshot: invalid))
    XCTAssertEqual(renderer.map.annotations.count, 1)
    XCTAssertEqual(renderer.sizeThatFits(width: 390).height, 360)
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
