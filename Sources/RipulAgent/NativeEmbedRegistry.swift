#if os(iOS)
  import UIKit

  /// A renderer owns content and semantic events. The embedding host owns placement.
  @MainActor public protocol NativeEmbeddedRenderer: AnyObject {
    var viewController: UIViewController { get }
    var onEvent: (([String: Any]) -> Void)? { get set }
    /// Signal intrinsic-size changes and editing completion so the host can
    /// remeasure or release an offscreen responder without continuous polling.
    var onSizeChange: (() -> Void)? { get set }
    var isEditing: Bool { get }
    var accessibilityElements: [Any] { get }
    func update(snapshot: [String: Any]) throws
    func sizeThatFits(width: CGFloat) -> CGSize
  }

  @MainActor public final class NativeEmbedRegistry {
    private var factories: [String: () -> any NativeEmbeddedRenderer] = [:]
    public init() {}
    public func register(_ key: String, make: @escaping () -> any NativeEmbeddedRenderer) {
      factories[key] = make
    }
    var features: [String] { factories.keys.sorted().map { "nativeEmbed:\($0)" } }
    func make(_ key: String) -> (any NativeEmbeddedRenderer)? { factories[key]?() }
    func contains(_ key: String) -> Bool { factories[key] != nil }
    static func standard() -> NativeEmbedRegistry {
      let registry = NativeEmbedRegistry()
      registry.register("artefact.declarative/v1") { NativeDeclarativeArtefactRenderer() }
      registry.register("map/v1") { NativeMapRenderer() }
      return registry
    }
  }
#endif
