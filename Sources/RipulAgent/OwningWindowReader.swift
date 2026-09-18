#if os(iOS)
import SwiftUI

/// Resolves only the window containing this view, including moves between scenes.
public struct OwningWindowReader: UIViewRepresentable {
    private let resolve: (UIWindow?) -> Void
    public init(_ resolve: @escaping (UIWindow?) -> Void) { self.resolve = resolve }
    public func makeUIView(context: Context) -> Reader { Reader(resolve: resolve) }
    public func updateUIView(_ view: Reader, context: Context) { view.resolve = resolve }
    public final class Reader: UIView {
        var resolve: (UIWindow?) -> Void
        init(resolve: @escaping (UIWindow?) -> Void) {
            self.resolve = resolve
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            resolve(window)
        }
    }
}
#endif
