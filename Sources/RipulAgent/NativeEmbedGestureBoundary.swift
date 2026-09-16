#if os(iOS)
  import UIKit
  import WebKit

  /// Native descendants of WebKit overflow views must not also dispatch DOM
  /// touches. Suspend ancestor recognizers only for a native-origin touch;
  /// keep UIKit scrolling unless the renderer explicitly owns pan/pinch.
  @MainActor final class NativeEmbedGestureBoundary {
    private final class TouchLifetime: UIGestureRecognizer {
      var finished: (() -> Void)?
      private(set) var active = Set<UITouch>()
      override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
      override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
      override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        active.formUnion(touches)
      }
      override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
      override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
      override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
      private func finish(_ touches: Set<UITouch>) {
        active.subtract(touches)
        if active.isEmpty { finished?(); state = .failed }
      }
      override func reset() {
        super.reset()
        active.removeAll()
        finished?()
      }
    }
    private weak var webView: WKWebView?
    private let lifetime = TouchLifetime()
    private var suspended: [UIGestureRecognizer] = []
    private var cleanupScheduled = false
    init(webView: WKWebView) {
      self.webView = webView
      lifetime.cancelsTouchesInView = false
      lifetime.delaysTouchesBegan = false
      lifetime.delaysTouchesEnded = false
      lifetime.finished = { [weak self] in self?.restore() }
      attach()
    }
    func attach() {
      guard let webView, lifetime.view !== webView else { return }
      webView.addGestureRecognizer(lifetime)
    }
    func prepare(root: UIView, ownsScrollGestures: Bool, event: UIEvent?) {
      guard event?.type == .touches, let webView else { return }
      var ancestor = root.superview
      while let view = ancestor {
        for recognizer in view.gestureRecognizers ?? [] where recognizer !== lifetime && recognizer.isEnabled {
          let scroll = view as? UIScrollView
          let isScroll = recognizer === scroll?.panGestureRecognizer || recognizer === scroll?.pinchGestureRecognizer
          if ownsScrollGestures || !isScroll {
            suspended.append(recognizer)
            recognizer.isEnabled = false
          }
        }
        if view === webView { break }
        ancestor = view.superview
      }
      // hitTest may be queried without dispatching a touch. Do not leave a
      // recognizer suspended after such a probe or a cancelled delivery.
      if !cleanupScheduled {
        cleanupScheduled = true
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.cleanupScheduled = false
          if self.lifetime.active.isEmpty { self.restore() }
        }
      }
    }
    private func restore() {
      let previous = suspended
      suspended.removeAll()
      for recognizer in previous where recognizer.view != nil { recognizer.isEnabled = true }
    }
    func detach() {
      restore()
      lifetime.view?.removeGestureRecognizer(lifetime)
    }
  }
#endif
