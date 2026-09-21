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

/// Leaves the panel's glass in place while the final row can scroll above
/// floating navigation. Measure locally so safe-area clearance already taken
/// by a sheet or a host is not applied a second time.
@available(iOS 17.0, macOS 14.0, *)
struct SessionsScrollClearance: ViewModifier {
    @Environment(\.ripulBottomBarFrame) private var bottomBar
    @State private var bottomInset: CGFloat = SessionsPanelLayout.bottomGap

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
            .background(SessionsScrollBoundsReader(bottomBar: bottomBar) { bottomInset = $0 })
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
