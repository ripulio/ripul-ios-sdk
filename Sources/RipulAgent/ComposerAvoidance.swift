#if os(iOS)
import UIKit

/// Live composer hosts, registered by their layout owner. Floating controls
/// can avoid the entire composer without scanning the chat's view tree or
/// publishing geometry through SwiftUI on every frame.
@MainActor
enum ComposerAvoidance {
    static let didChange = Notification.Name("ripul.composerAvoidance.changed")
    private static let hosts = NSMapTable<UIView, NSValue>.weakToStrongObjects()

    static func update(_ host: UIView) {
        guard let window = host.window else { remove(host); return }
        let frame = host.convert(host.bounds, to: window)
        guard hosts.object(forKey: host)?.cgRectValue != frame else { return }
        hosts.setObject(NSValue(cgRect: frame), forKey: host)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func remove(_ host: UIView) {
        guard hosts.object(forKey: host) != nil else { return }
        hosts.removeObject(forKey: host)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func frames(in view: UIView) -> [CGRect] {
        guard let window = view.window else { return [] }
        return hosts.keyEnumerator().allObjects.compactMap { object in
            guard let host = object as? UIView, let sourceWindow = host.window,
                  sourceWindow.windowScene === window.windowScene else { return nil }
            var ancestor: UIView? = host
            while let current = ancestor {
                guard !current.isHidden, current.alpha > 0.01 else { return nil }
                ancestor = current.superview
            }
            let frame = view.convert(host.bounds, from: host).intersection(view.bounds)
            return frame.isEmpty || frame.isNull ? nil : frame
        }
    }
}
#endif
