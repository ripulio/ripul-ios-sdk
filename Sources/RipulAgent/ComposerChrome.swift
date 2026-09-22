import SwiftUI

/// Window-owned coordination only. The editor and draft stay in their original
/// hosting controller; hosts opt in by supplying this environment value.
@MainActor
public final class RipulComposerChrome: ObservableObject {
    public struct Frame: Equatable {
        public var progress: CGFloat = 0
        public var bounce: CGFloat = 0
        public init(progress: CGFloat = 0, bounce: CGFloat = 0) {
            self.progress = progress; self.bounce = bounce
        }
    }
    @Published public var frame = Frame()
    @Published public var navigationFrame: CGRect = .zero
    public var report: ((String) -> Void)?
    /// Expanded navigation clearance. Consumers observe this independently of
    /// display-frame progress so chat padding cannot retain a pre-navigation value.
    @Published public var contentBottomInset: CGFloat = 0
    public var requestExpand: (() -> Void)?
    private var interactions = Set<String>()
    public var isInteracting: Bool { !interactions.isEmpty }
    public init() {}

    public func resetInteractions() { interactions.removeAll() }

    public func setInteraction(_ key: String, active: Bool) {
        if active { interactions.insert(key); requestExpand?() }
        else { interactions.remove(key) }
    }
}

private struct ComposerChromeKey: EnvironmentKey {
    static let defaultValue: RipulComposerChrome? = nil
}
private struct ComposerCollapseKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
extension EnvironmentValues {
    public var ripulComposerChrome: RipulComposerChrome? {
        get { self[ComposerChromeKey.self] }
        set { self[ComposerChromeKey.self] = newValue }
    }
    var composerCollapse: CGFloat {
        get { self[ComposerCollapseKey.self] }
        set { self[ComposerCollapseKey.self] = newValue }
    }
}

/// Only the composer subtree observes display frames, never the web/chat host.
@MainActor
struct ComposerChromeContent<Content: View>: View {
    @ObservedObject var chrome: RipulComposerChrome
    let content: Content
    var body: some View {
        content.environment(\.composerCollapse, chrome.frame.progress)
            .transaction { if chrome.frame.progress > 0 { $0.animation = nil } }
    }
}

/// Measure at the original size, then collapse the occupied space. The child
/// remains mounted with its natural layout, including menus and attachments.
@available(iOS 16.0, macOS 14.0, *)
struct ComposerFoldLayout: Layout {
    var progress: CGFloat
    var horizontal = false
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(ProposedViewSize(width: horizontal ? nil : proposal.width, height: nil))
        return CGSize(width: size.width * (horizontal ? 1 - progress : 1),
                      height: size.height * (horizontal ? 1 : 1 - progress))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        view.place(at: bounds.origin, anchor: .topLeading,
                   proposal: ProposedViewSize(width: horizontal ? nil : bounds.width, height: nil))
    }
}

@available(iOS 16.0, macOS 14.0, *)
struct ComposerFold: ViewModifier {
    @Environment(\.composerCollapse) private var progress
    var horizontal = false
    func body(content: Content) -> some View {
        ComposerFoldLayout(progress: progress, horizontal: horizontal) { content }
            .clipped().opacity(1 - progress)
            .allowsHitTesting(progress < 0.01)
            .accessibilityHidden(progress >= 0.01)
    }
}
