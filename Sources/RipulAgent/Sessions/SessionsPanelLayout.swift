import SwiftUI

private struct RipulBottomBarFrameKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    /// Visible bottom navigation chrome in owning-window coordinates. nil for
    /// hidden bars, side rails, or hosts without bottom navigation.
    public var ripulBottomBarFrame: CGRect? {
        get { self[RipulBottomBarFrameKey.self] }
        set { self[RipulBottomBarFrameKey.self] = newValue }
    }
}

enum SessionsPanelLayout {
    static let bottomGap: CGFloat = 10

    /// ConcentricRectangle and Edge.Corner.Style are "26.0" in the SDK, but
    /// macOS 26.0 beta 25A5306g doesn't have them: naming them in a view's
    /// type crashed Ripul there at launch (2026-10-06). 26.1 has them. Check
    /// this before using `shape`, and keep it out of any view's concrete type.
    static var hasConcentricShapes: Bool {
        if #available(iOS 26.1, macOS 26.1, *) { return true }
        return false
    }

    @available(iOS 26.0, macOS 26.0, *)
    static var shape: ConcentricRectangle {
        ConcentricRectangle(
            topLeadingCorner: .fixed(16), topTrailingCorner: .fixed(16),
            bottomLeadingCorner: .concentric(minimum: 16),
            bottomTrailingCorner: .concentric(minimum: 16)
        )
    }

    static func scrollBottomInset(view: CGRect, safeBottom: CGFloat, bottomBar: CGRect?, gap: CGFloat = bottomGap) -> CGFloat {
        var unobscuredBottom = safeBottom
        if let bottomBar, bottomBar.intersects(view) {
            unobscuredBottom = min(unobscuredBottom, bottomBar.minY)
        }
        return max(0, view.maxY - unobscuredBottom) + gap
    }
}

extension View {
    /// Lets a scroll view's last content scroll clear of floating bottom
    /// navigation (`ripulBottomBarFrame`). Measured against the view's real
    /// frame, so it works whether or not a host's reserved safe-area inset
    /// reached the scroll view, and never counts that inset twice.
    @available(iOS 17.0, macOS 14.0, *)
    public func ripulBottomBarScrollClearance(gap: CGFloat = 0) -> some View {
        modifier(SessionsScrollClearance(gap: gap))
    }
}

/// Leaves the panel's glass in place while the final row can scroll above
/// floating navigation. Measure locally so safe-area clearance already taken
/// by a sheet or a host is not applied a second time.
@available(iOS 17.0, macOS 14.0, *)
struct SessionsScrollClearance: ViewModifier {
    var actionBarHeight: CGFloat = 0
    var gap: CGFloat = SessionsPanelLayout.bottomGap
    @Environment(\.ripulBottomBarFrame) private var bottomBar
    @State private var measuredInset: CGFloat?

    func body(content: Content) -> some View {
        #if os(iOS)
        let bottomInset = measuredInset ?? gap
        content
            .contentMargins(.bottom, bottomInset + actionBarHeight, for: .scrollContent)
            .contentMargins(.bottom, bottomInset + actionBarHeight, for: .scrollIndicators)
            .background(SessionsScrollBoundsReader(bottomBar: bottomBar, gap: gap) { measuredInset = $0 })
        #else
        content
        #endif
    }
}

#if os(iOS)
import UIKit

struct SessionsScrollBoundsReader: UIViewRepresentable {
    let bottomBar: CGRect?
    var gap: CGFloat = SessionsPanelLayout.bottomGap
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.bottomBar = bottomBar
        view.gap = gap
        view.onChange = onChange
        view.scheduleReport()
    }

    final class ReaderView: UIView {
        var bottomBar: CGRect?
        var gap: CGFloat = SessionsPanelLayout.bottomGap
        var onChange: ((CGFloat) -> Void)?
        private var scheduled = false
        private var lastInset: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleReport()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            scheduleReport()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleReport()
        }

        func scheduleReport() {
            guard !scheduled else { return }
            scheduled = true
            // Window safe-area reads must happen outside SwiftUI evaluation.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard let window = self.window, !self.bounds.isEmpty else { return }
                let inset = SessionsPanelLayout.scrollBottomInset(
                    view: self.convert(self.bounds, to: window),
                    safeBottom: window.bounds.maxY - window.safeAreaInsets.bottom,
                    bottomBar: self.bottomBar, gap: self.gap
                )
                guard inset != self.lastInset else { return }
                self.lastInset = inset
                self.onChange?(inset)
            }
        }
    }
}
#endif
