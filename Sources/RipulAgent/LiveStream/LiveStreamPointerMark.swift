#if canImport(UIKit)
import UIKit

// MARK: - Where the supporter is pointing

/// A ring on the customer's screen where the person helping them has their
/// finger, in a support session: "tap here" without anybody but the customer
/// tapping. It is drawn in a window of its own that takes no touches, so the
/// app underneath is as it was, and it is in no picture sent to the supporter
/// (whose own finger is already where it is).
@MainActor
final class LiveStreamPointerMark {
    static let shared = LiveStreamPointerMark()

    /// How long the ring stays after the finger lifts, fading.
    static let lingers: TimeInterval = 0.9
    static let diameter: CGFloat = 46

    private var window: LiveStreamPointerWindow?
    private let ring = CAShapeLayer()
    private var hiding: Task<Void, Never>?

    /// A `pointer` message: {t, fingers: [{id, phase, x, y}]}, or one finger bare. Points of `appWindow`.
    func heard(_ json: [String: Any], in appWindow: UIWindow) {
        let fingers = json["fingers"] as? [[String: Any]] ?? [json]
        guard let finger = fingers.first, let phase = finger["phase"] as? String else { return }
        switch phase {
        case "down", "move":
            guard let x = (finger["x"] as? NSNumber)?.doubleValue, let y = (finger["y"] as? NSNumber)?.doubleValue,
                  let window = raised(over: appWindow) else { return }
            let point = window.convert(CGPoint(x: x, y: y), from: appWindow)
            hiding?.cancel()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.position = point
            ring.opacity = 1
            CATransaction.commit()
            if phase == "down" {
                // It lands: a ring that closes in on the place.
                let landing = CABasicAnimation(keyPath: "transform.scale")
                landing.fromValue = 1.9
                landing.toValue = 1
                landing.duration = 0.22
                landing.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ring.add(landing, forKey: "landing")
            }
        case "up", "cancel":
            hiding?.cancel()
            let fading = CABasicAnimation(keyPath: "opacity")
            fading.fromValue = 1
            fading.toValue = 0
            fading.duration = Self.lingers
            ring.add(fading, forKey: "fading")
            ring.opacity = 0
            hiding = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((Self.lingers + 0.1) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.clear()
            }
        default:
            break
        }
    }

    func clear() {
        hiding?.cancel()
        hiding = nil
        ring.removeAllAnimations()
        ring.removeFromSuperlayer()
        window?.isHidden = true
        window = nil
    }

    private func raised(over appWindow: UIWindow) -> UIWindow? {
        if let window { return window }
        guard let scene = appWindow.windowScene else { return nil }
        let created = LiveStreamPointerWindow(windowScene: scene)
        created.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 4)
        created.backgroundColor = .clear
        created.isUserInteractionEnabled = false
        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        created.installRoot(root)
        created.isHidden = false

        let size = Self.diameter
        ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ring.path = UIBezierPath(ovalIn: ring.bounds.insetBy(dx: 2, dy: 2)).cgPath
        ring.fillColor = UIColor.systemOrange.withAlphaComponent(0.28).cgColor
        ring.strokeColor = UIColor.systemOrange.cgColor
        ring.lineWidth = 3
        ring.shadowColor = UIColor.black.cgColor
        ring.shadowOpacity = 0.35
        ring.shadowRadius = 4
        ring.shadowOffset = .zero
        ring.opacity = 0
        root.view.layer.addSublayer(ring)
        window = created
        return created
    }
}

/// Never takes a touch, and nothing is presented from it.
final class LiveStreamPointerWindow: RipulChromeWindow {
    override var acceptsPresentation: Bool { false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
#endif
