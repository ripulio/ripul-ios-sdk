#if os(iOS)
import SwiftUI
import UIKit

/// Keeps host chrome out of the docked metadata pane on wide layouts.
public struct RipulMetadataColumnWidthKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// An inline column, never a modal presentation. Keep content in one structural
/// position while traits change so resizing cannot strand an inspector sheet.
struct DockedMetadataPane<Panel: View>: ViewModifier {
    let panel: Panel
    var isPresented: Bool? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var preferredWidth: CGFloat = 340

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let maximumWidth = max(280, min(480, geometry.size.width - 560))
            let paneWidth = min(preferredWidth, maximumWidth)
            HStack(spacing: 0) {
                content
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                if isPresented ?? (sizeClass == .regular) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1)
                        .overlay {
                            MetadataColumnResizeHandle(width: paneWidth, maximumWidth: maximumWidth) { width in
                                var transaction = Transaction(animation: nil)
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { preferredWidth = width }
                            }
                                .frame(width: 12)
                        }
                        // Let the guide draw over either adjacent pane.
                        .zIndex(1)
                    panel
                        .frame(width: paneWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color.ripul(system: .secondarySystemBackground))
                        .preference(key: RipulMetadataColumnWidthKey.self, value: paneWidth + 1)
                }
            }
        }
        // The previous inspector hosting controller supplied this opaque surface.
        // Compact navigation keeps the app sidebar mounted behind the chat.
        .background(Color.ripul(.canvas).ignoresSafeArea(.container))
        #if targetEnvironment(macCatalyst)
        .ignoresSafeArea(.container, edges: .top)
        #endif
    }
}

/// Pointer feedback stays in UIKit: no SwiftUI state, chat reflow or width
/// preference is published until release. Streaming can still update the panes.
private struct MetadataColumnResizeHandle: UIViewRepresentable {
    let width: CGFloat
    let maximumWidth: CGFloat
    let commit: (CGFloat) -> Void

    func makeUIView(context: Context) -> MetadataColumnResizeView {
        MetadataColumnResizeView()
    }

    func updateUIView(_ view: MetadataColumnResizeView, context: Context) {
        view.configure(width: width, maximumWidth: maximumWidth, commit: commit)
    }
}

final class MetadataColumnResizeView: UIView {
    private var width: CGFloat = 340
    private var maximumWidth: CGFloat = 480
    private var startWidth: CGFloat?
    private var commit: (CGFloat) -> Void = { _ in }
    private let guide = UIView()
    private(set) var previewWidth: CGFloat?
    #if targetEnvironment(macCatalyst)
    private var isHovered = false
    #endif

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityIdentifier = "metadata-column-resize"
        accessibilityLabel = "Metadata column width"
        accessibilityTraits = .adjustable
        guide.isUserInteractionEnabled = false
        guide.isHidden = true
        addSubview(guide)
        let pan = MetadataColumnPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        #if targetEnvironment(macCatalyst)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(width: CGFloat, maximumWidth: CGFloat, commit: @escaping (CGFloat) -> Void) {
        // New pane widths or limits invalidate the drag's starting geometry. Ordinary
        // chat updates with the same geometry must not interrupt the drag.
        if self.width != width || self.maximumWidth != maximumWidth { cancelDrag() }
        self.width = width
        self.maximumWidth = maximumWidth
        self.commit = commit
        accessibilityValue = "\(Int(width)) points"
    }

    @objc private func dragged(_ pan: MetadataColumnPanGestureRecognizer) {
        // The window is stationary even when the divider's own frame changes.
        handleDrag(state: pan.state, translation: pan.windowTranslation)
    }

    func handleDrag(state: UIGestureRecognizer.State, translation: CGFloat) {
        switch state {
        case .began:
            startWidth = width
            showPreview(translation: translation)
        case .changed:
            showPreview(translation: translation)
        case .ended:
            guard let startWidth else { return }
            let result = clamped(startWidth - translation)
            cancelDrag()
            if result != width { commit(result) }
        case .cancelled, .failed:
            cancelDrag()
        default: break
        }
    }

    private func clamped(_ proposed: CGFloat) -> CGFloat {
        min(maximumWidth, max(280, proposed))
    }

    private func showPreview(translation: CGFloat) {
        guard let startWidth else { return }
        previewWidth = clamped(startWidth - translation)
        layoutGuide()
    }

    private func cancelDrag() {
        startWidth = nil
        previewWidth = nil
        guide.isHidden = true
        updateCursor()
    }

    private func updateCursor() {
        #if targetEnvironment(macCatalyst)
        // Hover can end while the guide moves away from the stationary handle.
        RipulColumnResizeCursor.update?(isHovered || startWidth != nil)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        isHovered = hover.state == .began || hover.state == .changed
        updateCursor()
    }
    #endif

    private func layoutGuide() {
        guard let previewWidth else { return }
        updateCursor()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guide.backgroundColor = tintColor
        guide.frame = CGRect(x: bounds.midX - 1 + width - previewWidth,
                             y: 0, width: 2, height: bounds.height)
        guide.isHidden = false
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutGuide()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            #if targetEnvironment(macCatalyst)
            isHovered = false
            #endif
            cancelDrag()
        }
    }

    override func accessibilityIncrement() { adjust(by: 40) }
    override func accessibilityDecrement() { adjust(by: -40) }

    private func adjust(by delta: CGFloat) {
        cancelDrag()
        let result = clamped(width + delta)
        if result != width { commit(result) }
    }
}

private final class MetadataColumnPanGestureRecognizer: UIPanGestureRecognizer {
    private var startX: CGFloat?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if startX == nil { startX = touches.first?.location(in: view?.window).x }
        super.touchesBegan(touches, with: event)
    }

    // UIPan's translation omits the recognition threshold (10pt on touch).
    // Include the whole movement so the guide and release land at the pointer.
    var windowTranslation: CGFloat {
        guard let startX else { return 0 }
        return location(in: view?.window).x - startX
    }

    override func reset() {
        super.reset()
        startX = nil
    }
}
#endif
