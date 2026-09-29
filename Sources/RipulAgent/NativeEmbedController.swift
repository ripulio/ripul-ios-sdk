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
    let layered: Bool?
  }

  /// Renderer-neutral native content in web slots, mounted via
  /// `NativeSlotAttachment` (the slot's own WebKit view when it has one, else the
  /// chat scroller). WebKit's internal hierarchy is not a DOM API; failed
  /// matching deliberately leaves the web fallback visible.
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
      var attachment: NativeSlotAttachment?
      var slotGeometry: NativeSlotGeometry? {
        geometry.flatMap {
          NativeSlotGeometry(anchor: $0.anchor, viewport: $0.viewport,
                             contentHeight: $0.contentHeight, viewportWidth: $0.viewportWidth,
                             layered: $0.layered ?? false)
        }
      }
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
    private let gestures: NativeEmbedGestureBoundary
    private let send: ([String: Any]) -> Void
    private var entries: [Key: Entry] = [:]
    private var pending: Set<Key> = []
    private var timer: Timer?
    /// Renderers kept alive off screen, oldest first. Releasing an embed when
    /// it scrolled away rebuilt it on return (a map reloading its tiles) and
    /// showed the web fallback meanwhile; a kept one re-attaches at once.
    private var parked: [Key] = []
    private static let parkedLimit = 5
    private var lastAttachAt: CFTimeInterval = 0
    private static let fadeKey = "NativeEmbed.appear"
    var entryCount: Int { entries.count }
    var attachmentCount: Int { entries.values.filter { $0.visible }.count }
    init(webView: WKWebView, registry: NativeEmbedRegistry, send: @escaping ([String: Any]) -> Void)
    {
      self.webView = webView
      self.gestures = NativeEmbedGestureBoundary(webView: webView)
      self.registry = registry
      self.send = send
    }
    var isScrollIdle: Bool {
      MainThreadSampler.count("embed.idleWalk")
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
        gestures.attach()
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
            detach(key, entry: entry, resetSize: true)
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
      // A visible embed whose slot only moved takes its new position now, even
      // mid-scroll. Creation, reparenting and size negotiation wait below.
      if reposition(entry) { return }
      schedule(key)
    }

    /// Same-parent position fix for a visible, settled embed: the report's
    /// size must match what is mounted (else it is a size negotiation).
    private func reposition(_ entry: Entry) -> Bool {
      guard entry.visible, entry.renderer != nil, let attachment = entry.attachment, attachment.isMounted,
        let g = entry.slotGeometry, let target = attachment.scroller, let mounted = attachment.frameInScroller,
        let placed = attachment.placement(in: target, for: g),
        abs(placed.rect.width - mounted.width) <= 1, abs(placed.rect.height - mounted.height) <= 1
      else { return false }
      return attachment.reposition(geometry: g) { $0.rect }
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
        // Common modes: re-attaching kept renderers proceeds during touch
        // tracking, within the one-per-frame budget below.
        RunLoop.main.add(timer, forMode: .common)
      }
    }
    /// Whether an embed may be attached now. Re-attaching a kept renderer is
    /// cheap and lands correctly mid-scroll (it rides its slot's view), so it
    /// goes one per frame while scrolling; creating a renderer (a map, a form)
    /// still waits for the scroll to stop.
    private func mayAttach(_ entry: Entry) -> Bool {
      let idle = isScrollIdle
      guard entry.renderer != nil else { return idle }
      if idle { return true }
      let now = CACurrentMediaTime()
      guard now - lastAttachAt >= 1.0 / 60 else { return false }
      lastAttachAt = now
      return true
    }
    private func flush() {
      MainThreadSampler.count("embed.flush")
      let work = pending
      pending.removeAll()
      for key in work {
        guard let entry = entries[key] else { continue }
        guard entry.geometry?.anchor != nil else {
          // The renderer signals editing completion through onSizeChange.
          // Keep the responder alive without an idle polling loop.
          if entry.renderer?.isEditing != true { park(key, entry: entry) }
          continue
        }
        guard mayAttach(entry) else {
          schedule(key, delay: entry.renderer == nil ? 0.08 : 1.0 / 60)
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
    private func place(_ key: Key, entry: Entry) -> Bool {
      guard let webView, let g = entry.slotGeometry else { return false }
      if entry.renderer == nil {
        guard let renderer = registry.make(entry.kind) else { return false }
        do { try renderer.update(snapshot: entry.snapshot) } catch {
          detach(key, entry: entry, resetSize: true)
          return false
        }
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
      let attachment = entry.attachment ?? {
        let made = NativeSlotAttachment(webView: webView, label: "embed \(entry.kind) \(key.element)")
        made.onDropped = { [weak self, weak entry] in
          guard let self, let entry, self.entries[key] === entry else { return }
          self.schedule(key)
        }
        entry.attachment = made
        return made
      }()
      guard let placed = attachment.place(content: controller.view, controller: controller, geometry: g,
                                          frame: { $0.rect })
      else { return false }
      let frame = placed.rect
      let desired =
        ceil(renderer.sizeThatFits(width: frame.width).height * max(1, webView.traitCollection.displayScale))
        / max(1, webView.traitCollection.displayScale)
      guard desired.isFinite, desired > 0, desired <= 20000 else { return false }
      let height = desired / placed.pageScale
      // DOM space must be committed before showing an initially attached view.
      // Existing focused controls keep their identity while their slot grows.
      if abs(frame.height - desired) > 1 {
        controller.view.isHidden = !entry.visible
        acknowledge(key, entry: entry, visible: entry.visible, height: height)
        return true
      }
      attachment.setFrame(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: desired))
      let appearing = !entry.visible || controller.view.isHidden
      controller.view.isHidden = false
      controller.view.layoutIfNeeded()
      parked.removeAll { $0 == key }
      if appearing && !UIAccessibility.isReduceMotionEnabled {
        // Fades in over the web fallback as that fades out (180ms each): a
        // crossfade, rather than two different renderings swapping in a frame.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        attachment.container.layer.add(fade, forKey: Self.fadeKey)
      }
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
    /// Takes an embed off screen but keeps its renderer for a quick return.
    /// Beyond `parkedLimit`, the longest-parked is released.
    private func park(_ key: Key, entry: Entry) {
      guard let renderer = entry.renderer else { return }
      MainThreadSampler.count("embed.park")
      let controller = renderer.viewController
      controller.view.endEditing(true)
      entry.attachment?.container.layer.removeAnimation(forKey: Self.fadeKey)
      entry.attachment?.unmount(removing: controller)
      entry.attachment = nil
      acknowledge(key, entry: entry, visible: false)
      parked.removeAll { $0 == key }
      parked.append(key)
      while parked.count > Self.parkedLimit {
        let oldest = parked.removeFirst()
        if let old = entries[oldest], old.attachment == nil { detach(oldest, entry: old) }
      }
    }
    private func detach(_ key: Key, entry: Entry, resetSize: Bool = false) {
      parked.removeAll { $0 == key }
      let controller = entry.renderer?.viewController
      if let view = controller?.view {
        NativeComposerFocusTrace.shared.record("nativeEmbed.detach", view: view)
      }
      controller?.view.endEditing(true)
      entry.attachment?.unmount(removing: controller)
      controller?.view.removeFromSuperview()
      entry.attachment = nil
      entry.renderer?.onEvent = nil
      entry.renderer?.onSizeChange = nil
      entry.renderer = nil
      // Releasing an offscreen native view must not change document height.
      // Only an invalid renderer snapshot invalidates the reserved size.
      if !resetSize {
        acknowledge(key, entry: entry, visible: false)
      } else if entry.visible || entry.lastHeight != nil {
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
      gestures.detach()
      timer?.invalidate()
      timer = nil
      for (key, entry) in entries { detach(key, entry: entry) }
      entries.removeAll()
      pending.removeAll()
      parked.removeAll()
    }
    func hitTest(_ point: CGPoint, event: UIEvent?) -> UIView? {
      guard let webView, webView.bounds.contains(point) else { return nil }
      for entry in entries.values where entry.visible {
        guard let view = entry.renderer?.viewController.view, let scroll = entry.attachment?.scroller,
          scroll.convert(scroll.bounds, to: webView).contains(point)
        else { continue }
        let local = view.convert(point, from: webView)
        if view.bounds.contains(local), let hit = view.hitTest(local, with: event) {
          gestures.prepare(root: view, ownsScrollGestures: entry.renderer?.ownsScrollGestures == true, event: event)
          return hit
        }
      }
      return nil
    }
    var accessibilityElements: [Any] {
      guard let webView else { return [] }
      return entries.values.filter { entry in
        guard entry.visible, let view = entry.renderer?.viewController.view,
          let scroll = entry.attachment?.scroller
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
