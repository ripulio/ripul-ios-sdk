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
  func testStreamingAndOffscreenRecyclingKeepReservedSize() async throws {
    let registry = NativeEmbedRegistry()
    var creations = 0
    registry.register("unrelated.test/v1") { creations += 1; return Renderer() }
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
    let scroller = UIScrollView(frame: web.bounds)
    scroller.contentSize = CGSize(width: 390, height: 1400)
    web.scrollView.addSubview(scroller)
    var messages: [[String: Any]] = []
    let host = NativeEmbedController(webView: web, registry: registry, send: { messages.append($0) })
    let identity: [String: Any] = ["ownerId": "streaming", "elementId": "example", "token": "one"]
    func send(_ type: String, _ payload: [String: Any]) {
      host.receive(identity.merging(payload) { _, value in value }.merging(["type":"agent-framework:nativeEmbed:" + type]) { _, value in value })
    }
    let geometry: [String: Any] = [
      "anchor": ["x": 10, "y": 450, "width": 370, "height": 137],
      "viewport": ["x": 0, "y": 0, "width": 390, "height": 800],
      "contentHeight": 1400, "viewportWidth": 390,
    ]
    send("update", ["renderer": "unrelated.test/v1", "snapshot": [:]])
    send("anchor", geometry)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(host.attachmentCount, 1)
    XCTAssertEqual(creations, 1)
    // Native content size can lead the asynchronous web geometry report.
    // A previously matched scroller remains the same owner during streaming.
    scroller.contentSize.height = 1800
    send("anchor", geometry)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(host.attachmentCount, 1)
    XCTAssertEqual(creations, 1)
    send("anchor", ["anchor": NSNull()])
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(host.attachmentCount, 0)
    XCTAssertEqual(messages.last?["height"] as? CGFloat, 137)
    XCTAssertEqual(messages.last?["visible"] as? Bool, false)
    send("anchor", geometry.merging(["contentHeight":1800]) { _, value in value })
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(host.attachmentCount, 1)
    // Offscreen embeds are kept (parked), not rebuilt: returning re-attaches
    // the same renderer.
    XCTAssertEqual(creations, 1)
    XCTAssertTrue(messages.allSatisfy { ($0["height"] as? CGFloat) == 137 })
    host.clear()
  }
  /// NativeSlotAttachment: content rides the slot's own WebKit view (here a
  /// stand-in with the slot's frame), so reflow above the slot moves it with no
  /// report; a rebuilt slot view is followed; unrelated views sharing the slot
  /// rect are ambiguous and leave the content on the scroller.
  func testContentRidesItsSlotViewAndRefusesAmbiguousSlots() async throws {
    let registry = NativeEmbedRegistry()
    var made: [Renderer] = []
    registry.register("unrelated.test/v1") { let r = Renderer(); made.append(r); return r }
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
    let web = WKWebView(frame: window.bounds)
    window.addSubview(web)
    window.isHidden = false
    let scroller = UIScrollView(frame: web.bounds)
    scroller.contentSize = CGSize(width: 390, height: 1400)
    web.scrollView.addSubview(scroller)
    let slot = UIView(frame: CGRect(x: 10, y: 450, width: 370, height: 137))
    scroller.addSubview(slot)
    let host = NativeEmbedController(webView: web, registry: registry, send: { _ in })
    func send(_ element: String, _ type: String, _ payload: [String: Any]) {
      host.receive(["ownerId": "slots", "elementId": element, "token": "one",
                    "type": "agent-framework:nativeEmbed:" + type].merging(payload) { _, value in value })
    }
    func geometry(y: CGFloat) -> [String: Any] {
      ["anchor": ["x": 10, "y": y, "width": 370, "height": 137],
       "viewport": ["x": 0, "y": 0, "width": 390, "height": 800],
       "contentHeight": 1400, "viewportWidth": 390]
    }
    send("riding", "update", ["renderer": "unrelated.test/v1", "snapshot": [:]])
    send("riding", "anchor", geometry(y: 450))
    try await Task.sleep(for: .milliseconds(150))
    let view = try XCTUnwrap(made.first?.viewController.view)
    XCTAssertTrue(view.superview?.superview === slot, "mounted in the slot's own view")
    // Content above reflows: WebKit moves the slot's view. No report yet.
    slot.frame.origin.y = 950
    XCTAssertEqual(view.convert(view.bounds, to: scroller).minY, 950, accuracy: 0.5)
    // WebKit rebuilds the slot's view: ours is dropped, then re-placed on the new one.
    slot.removeFromSuperview()
    let rebuilt = UIView(frame: CGRect(x: 10, y: 950, width: 370, height: 137))
    scroller.addSubview(rebuilt)
    send("riding", "anchor", geometry(y: 950))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(view.superview?.superview === rebuilt, "re-placed on the rebuilt slot view")
    XCTAssertEqual(host.attachmentCount, 1)
    // Two unrelated views share another slot's rect: no guess, scroller instead.
    let twinA = UIView(frame: CGRect(x: 10, y: 200, width: 370, height: 137))
    let twinB = UIView(frame: CGRect(x: 10, y: 200, width: 370, height: 137))
    scroller.addSubview(twinA)
    scroller.addSubview(twinB)
    send("ambiguous", "update", ["renderer": "unrelated.test/v1", "snapshot": [:]])
    send("ambiguous", "anchor", geometry(y: 200))
    try await Task.sleep(for: .milliseconds(150))
    let other = try XCTUnwrap(made.last?.viewController.view)
    XCTAssertTrue(other !== view)
    XCTAssertTrue(other.superview?.superview === scroller, "ambiguous slot falls back to the scroller")
    // A layered slot: its empty mount wins over a same-rect box that has
    // content (the web fallback's clipping layer).
    let fallbackBox = UIView(frame: CGRect(x: 10, y: 1150, width: 370, height: 137))
    fallbackBox.addSubview(UIView(frame: CGRect(x: 0, y: 0, width: 370, height: 40)))
    let mount = UIView(frame: CGRect(x: 10, y: 1150, width: 370, height: 137))
    scroller.addSubview(fallbackBox)
    scroller.addSubview(mount)
    send("layered", "update", ["renderer": "unrelated.test/v1", "snapshot": [:]])
    send("layered", "anchor", geometry(y: 1150).merging(["layered": true]) { _, value in value })
    try await Task.sleep(for: .milliseconds(150))
    let layered = try XCTUnwrap(made.last?.viewController.view)
    XCTAssertTrue(layered.superview?.superview === mount, "the empty mount is chosen")
    host.clear()
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
