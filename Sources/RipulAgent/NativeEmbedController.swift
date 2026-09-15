#if os(iOS)
  import UIKit
  import WebKit

  struct NativeContentRect: Decodable, Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
  }

  struct NativeEmbedGeometry: Decodable {
    let anchor: NativeContentRect?
    let viewport: NativeContentRect?
    let contentHeight: CGFloat?
    let viewportWidth: CGFloat?
  }

  /// Generic content-coordinate attachment. WebKit's internal overflow hierarchy
  /// is not a DOM API; failed matching deliberately leaves the web fallback visible.
  @MainActor final class NativeEmbedController {
    private struct Key: Hashable {
      let owner: String
      let element: String
      init?(_ message: [String: Any]) {
        guard let owner = message["ownerId"] as? String, !owner.isEmpty,
          let element = message["elementId"] as? String, !element.isEmpty
        else { return nil }
        self.owner = owner
        self.element = element
      }
    }
    private final class Entry {
      let token: String
      let kind: String
      var snapshot: [String: Any]
      var geometry: NativeEmbedGeometry?
      var renderer: (any NativeEmbeddedRenderer)?
      weak var scroller: UIScrollView?
      var retries = 0
      var lastHeight: CGFloat?
      var visible = false
      init(token: String, kind: String, snapshot: [String: Any]) {
        self.token = token
        self.kind = kind
        self.snapshot = snapshot
      }
    }
    private weak var webView: WKWebView?
    private let registry: NativeEmbedRegistry
    private let send: ([String: Any]) -> Void
    private var entries: [Key: Entry] = [:]
    private var pending: Set<Key> = []
    private var timer: Timer?
    var entryCount: Int { entries.count }
    var attachmentCount: Int { entries.values.filter { $0.visible }.count }
    init(webView: WKWebView, registry: NativeEmbedRegistry, send: @escaping ([String: Any]) -> Void)
    {
      self.webView = webView
      self.registry = registry
      self.send = send
    }
    var isScrollIdle: Bool {
      func moving(_ view: UIView) -> Bool {
        if let scroll = view as? UIScrollView,
          scroll.isTracking || scroll.isDragging || scroll.isDecelerating
        {
          return true
        }
        return view.subviews.contains(where: moving)
      }
      return webView.map { !moving($0.scrollView) } ?? true
    }
    func receive(_ message: [String: Any]) {
      guard let key = Key(message), let token = message["token"] as? String,
        let type = message["type"] as? String
      else { return }
      if type.hasSuffix(":clear") {
        guard let entry = entries[key], entry.token == token else { return }
        remove(key, entry: entry)
        return
      }
      if type.hasSuffix(":update") {
        guard let kind = message["renderer"] as? String, registry.contains(kind),
          let snapshot = message["snapshot"] as? [String: Any]
        else { return }
        if let old = entries[key], old.token != token || old.kind != kind {
          remove(key, entry: old)
        }
        let entry = entries[key] ?? Entry(token: token, kind: kind, snapshot: snapshot)
        entries[key] = entry
        entry.snapshot = snapshot
        if let renderer = entry.renderer {
          do { try renderer.update(snapshot: snapshot) } catch {
            detach(key, entry: entry)
            return
          }
        }
        schedule(key)
        return
      }
      guard type.hasSuffix(":anchor"), let entry = entries[key], entry.token == token,
        let data = try? JSONSerialization.data(withJSONObject: message),
        let geometry = try? JSONDecoder().decode(NativeEmbedGeometry.self, from: data)
      else { return }
      entry.geometry = geometry
      entry.retries = 0
      schedule(key)
    }
    private func schedule(_ key: Key, delay: TimeInterval = 0.032) {
      pending.insert(key)
      if timer == nil {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.timer = nil
            self?.flush()
          }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .default)
      }
    }
    private func flush() {
      let work = pending
      pending.removeAll()
      for key in work {
        guard let entry = entries[key] else { continue }
        guard isScrollIdle else {
          schedule(key, delay: 0.08)
          continue
        }
        guard entry.geometry?.anchor != nil else {
          // The renderer signals editing completion through onSizeChange.
          // Keep the responder alive without an idle polling loop.
          if entry.renderer?.isEditing != true { detach(key, entry: entry) }
          continue
        }
        if !place(key, entry: entry) {
          entry.retries += 1
          if entry.retries < 8 {
            schedule(key)
          } else if entry.renderer?.isEditing != true {
            detach(key, entry: entry)
          }
        }
      }
    }
    private func placement(_ geometry: NativeEmbedGeometry) -> (UIScrollView, CGRect, CGFloat)? {
      guard let webView, let a = geometry.anchor, a.isValid,
        let v = geometry.viewport, v.isValid,
        let height = geometry.contentHeight, height.isFinite, height > 0,
        let width = geometry.viewportWidth, width.isFinite, width > 0
      else { return nil }
      let scale = webView.bounds.width / width
      let expected = CGRect(
        x: v.x * scale, y: v.y * scale, width: v.width * scale, height: v.height * scale)
      var candidates: [(UIScrollView, CGFloat)] = []
      func visit(_ view: UIView) {
        // Renderer-owned scroll views must never be mistaken for WebKit content.
        if entries.values.contains(where: { $0.renderer?.viewController.viewIfLoaded === view }) {
          return
        }
        if let scroll = view as? UIScrollView, scroll !== webView.scrollView, !scroll.isHidden {
          let actual = scroll.convert(scroll.bounds, to: webView)
          let error =
            abs(actual.minX - expected.minX) + abs(actual.minY - expected.minY)
            + abs(actual.width - expected.width) + abs(actual.height - expected.height)
          let contentScale = scroll.bounds.width / v.width
          if error < 8,
            abs(scroll.contentSize.height - height * contentScale)
              < max(8, height * contentScale * 0.01)
          {
            candidates.append((scroll, error))
          }
        }
        view.subviews.forEach(visit)
      }
      visit(webView.scrollView)
      if let scroll = candidates.min(by: { $0.1 < $1.1 })?.0 {
        let contentScale = scroll.bounds.width / v.width
        return (
          scroll,
          CGRect(
            x: a.x * contentScale, y: a.y * contentScale, width: a.width * contentScale,
            height: a.height * contentScale), scale
        )
      }
      guard height <= v.height + 1 else { return nil }
      let frame = CGRect(
        x: expected.minX + a.x * scale, y: expected.minY + a.y * scale, width: a.width * scale,
        height: a.height * scale)
      return (webView.scrollView, webView.scrollView.convert(frame, from: webView), scale)
    }
    private func place(_ key: Key, entry: Entry) -> Bool {
      guard let webView, let geometry = entry.geometry,
        let (target, frame, scale) = placement(geometry)
      else { return false }
      if entry.renderer == nil {
        guard let renderer = registry.make(entry.kind) else { return false }
        do { try renderer.update(snapshot: entry.snapshot) } catch { return false }
        renderer.onEvent = { [weak self, weak entry] event in
          guard let self, let entry, self.entries[key] === entry, entry.visible else { return }
          self.send([
            "type": "agent-framework:nativeEmbed:event", "ownerId": key.owner,
            "elementId": key.element, "token": entry.token, "event": event,
          ])
        }
        renderer.onSizeChange = { [weak self, weak entry] in
          guard let self, let entry, self.entries[key] === entry else { return }
          self.schedule(key)
        }
        entry.renderer = renderer
      }
      guard let renderer = entry.renderer else { return false }
    let controller = renderer.viewController
    controller.view.backgroundColor = .clear
    controller.view.isHidden = !entry.visible
      if controller.parent == nil {
        var responder: UIResponder? = webView
        while let current = responder {
          if let parent = current as? UIViewController {
            parent.addChild(controller)
            target.addSubview(controller.view)
            controller.didMove(toParent: parent)
            break
          }
          responder = current.next
        }
      }
      if controller.view.superview !== target { target.addSubview(controller.view) }
      entry.scroller = target
      controller.view.frame = frame
      let desired =
        ceil(renderer.sizeThatFits(width: frame.width).height * UIScreen.main.scale)
        / UIScreen.main.scale
      guard desired.isFinite, desired > 0, desired <= 20000 else { return false }
      let height = desired / scale
      // DOM space must be committed before showing an initially attached view.
      // Existing focused controls keep their identity while their slot grows.
      if abs(frame.height - desired) > 1 {
        controller.view.isHidden = !entry.visible
        acknowledge(key, entry: entry, visible: entry.visible, height: height)
        return true
      }
      controller.view.frame.size.height = desired
      controller.view.isHidden = false
      controller.view.layoutIfNeeded()
      acknowledge(key, entry: entry, visible: true, height: height)
      entry.retries = 0
      return true
    }
    private func acknowledge(_ key: Key, entry: Entry, visible: Bool, height: CGFloat? = nil) {
      guard entry.visible != visible || (height != nil && entry.lastHeight != height) else {
        return
      }
      entry.visible = visible
      if let height { entry.lastHeight = height }
      var message: [String: Any] = [
        "type": "agent-framework:nativeEmbed:placement", "ownerId": key.owner,
        "elementId": key.element, "token": entry.token, "visible": visible,
      ]
      if let height = entry.lastHeight { message["height"] = height }
      send(message)
    }
    private func detach(_ key: Key, entry: Entry) {
      let controller = entry.renderer?.viewController
      controller?.view.endEditing(true)
      controller?.willMove(toParent: nil)
      controller?.view.removeFromSuperview()
      controller?.removeFromParent()
      entry.renderer?.onEvent = nil
      entry.renderer?.onSizeChange = nil
      entry.renderer = nil
      entry.scroller = nil
      if entry.visible || entry.lastHeight != nil {
        entry.visible = false
        entry.lastHeight = nil
        send([
          "type": "agent-framework:nativeEmbed:placement", "ownerId": key.owner,
          "elementId": key.element, "token": entry.token, "visible": false, "height": NSNull(),
        ])
      }
    }
    private func remove(_ key: Key, entry: Entry) {
      detach(key, entry: entry)
      entries.removeValue(forKey: key)
      pending.remove(key)
    }
    func clear() {
      timer?.invalidate()
      timer = nil
      for (key, entry) in entries { detach(key, entry: entry) }
      entries.removeAll()
      pending.removeAll()
    }
    func hitTest(_ point: CGPoint, event: UIEvent?) -> UIView? {
      guard let webView, webView.bounds.contains(point) else { return nil }
      for entry in entries.values where entry.visible {
        guard let view = entry.renderer?.viewController.view, let scroll = entry.scroller,
          scroll.convert(scroll.bounds, to: webView).contains(point)
        else { continue }
        let local = view.convert(point, from: webView)
        if view.bounds.contains(local), let hit = view.hitTest(local, with: event) { return hit }
      }
      return nil
    }
    var accessibilityElements: [Any] {
      guard let webView else { return [] }
      return entries.values.filter { entry in
        guard entry.visible, let view = entry.renderer?.viewController.view,
          let scroll = entry.scroller
        else { return false }
        return view.convert(view.bounds, to: webView).intersects(
          scroll.convert(scroll.bounds, to: webView))
      }.sorted { lhs, rhs in
        lhs.renderer!.viewController.view.convert(.zero, to: webView).y
          < rhs.renderer!.viewController.view.convert(.zero, to: webView).y
      }.flatMap { $0.renderer?.accessibilityElements ?? [] }
    }
  }
#endif
