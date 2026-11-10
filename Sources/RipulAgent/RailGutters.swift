import SwiftUI

/// Side gutters that give way to the system's own margin beside its tab rail.
///
/// On a phone our 12pt gutter keeps content off the edge of the screen. On an
/// iPhone Duo the tab bar stands at the side in a strip the safe area leaves
/// out, and the safe area already stops 12pt short of the rail's glass: a
/// gutter of our own there doubled the gap to 24 (Peter, 31 October 2026).
/// So on an edge where this view meets the safe area beside the rail, the
/// gutter is `standard` less. Measured per view, from UIKit: beside a split's
/// list, the chat's edge meets the list, not the rail. And measured where the
/// view rests: the chat's back swipe carries it toward the Duo's rail, and a
/// gutter decided mid-swipe came back under the finger (`SlideDisplacement`).
///
/// Apply it to a view whose container decides its width. A view that hugs its
/// content moves the very edge this reads when its gutter changes: the chat's
/// title pill, centred, gave the 12pt way, came off the safe line, took the
/// 12pt back, met it again, and flipped between two widths without end
/// (1 November 2026). Make such a view full width first (`.frame(maxWidth:
/// .infinity)`). Should a reading still keep changing, the reader holds it
/// (`ReaderView.changesBeforeHolding`).
@available(iOS 15.0, macOS 13.0, *)
struct RailGutters: ViewModifier {
    /// The gutter the system's margin stands in for.
    static let standard: CGFloat = 12
    let leading: CGFloat
    let trailing: CGFloat
    var active = true
    @State private var railEdges: Edge.Set = []
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @Environment(\.ripulSlideDisplacement) private var slide
    #endif

    func body(content: Content) -> some View {
        let edges = active ? railEdges : []
        content
            .padding(.leading, max(0, leading - (edges.contains(.leading) ? Self.standard : 0)))
            .padding(.trailing, max(0, trailing - (edges.contains(.trailing) ? Self.standard : 0)))
            #if os(iOS) && !targetEnvironment(macCatalyst)
            .background {
                if active { RailEdgesReader(slide: slide) { railEdges = $0 } }
            }
            #endif
    }
}

/// The edges `RailGutters` gives way on, reported for a view that pads its own
/// content: the native chat's list pads each row it hosts (`NativeChatList`).
@available(iOS 15.0, macOS 13.0, *)
struct RailEdgesReporting: ViewModifier {
    let onChange: (Edge.Set) -> Void
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @Environment(\.ripulSlideDisplacement) private var slide
    #endif

    func body(content: Content) -> some View {
        content
            #if os(iOS) && !targetEnvironment(macCatalyst)
            .background { RailEdgesReader(slide: slide, onChange: onChange) }
            #endif
    }
}

@available(iOS 15.0, macOS 13.0, *)
extension View {
    /// Side padding of `width`, less 12pt on an edge that meets the safe area
    /// beside the system's tab rail (see `RailGutters`).
    func railGutters(_ width: CGFloat) -> some View {
        modifier(RailGutters(leading: width, trailing: width))
    }

    /// Tells `onChange` the edges a `railGutters` here would give way on.
    func reportRailEdges(_ onChange: @escaping (Edge.Set) -> Void) -> some View {
        modifier(RailEdgesReporting(onChange: onChange))
    }
}

private struct RipulRailGuttersKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether a `GlassTopBar` gives its side gutter way beside the system's
    /// tab rail. Off by default: a screen turns it on where its content does
    /// the same (the chat), so the bar's buttons stay aligned with what is
    /// under them.
    var ripulRailGutters: Bool {
        get { self[RipulRailGuttersKey.self] }
        set { self[RipulRailGuttersKey.self] = newValue }
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit

/// The edges of this view that meet the window's safe area on the side where
/// the system's tab rail stands. Read in UIKit's callbacks and reported a turn
/// later, never during a SwiftUI update.
private struct RailEdgesReader: UIViewRepresentable {
    let slide: SlideDisplacement?
    let onChange: (Edge.Set) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.slide = slide
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.slide = slide
        view.onChange = onChange
    }

    final class ReaderView: UIView {
        /// A reading that changes this often within a second is a loop (the
        /// gutter moving the edge it is read from), not the window changing:
        /// the reader keeps its last reading until the window's size or safe
        /// area changes. Each change lays the view out again, every turn of
        /// the run loop: the title pill's cost 182ms of processor a second
        /// at rest on the simulator, against 2ms for a pill that held.
        static let changesBeforeHolding = 6
        var slide: SlideDisplacement?
        var onChange: ((Edge.Set) -> Void)?
        private var reported: Edge.Set?
        private var scheduled = false
        private var recentChanges: [CFTimeInterval] = []
        /// The window as it was when the reader began holding.
        private var heldFor: (bounds: CGRect, insets: UIEdgeInsets)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            schedule()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            schedule()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            schedule()
        }

        private func schedule() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                let edges = self.measure()
                guard edges != self.reported else { return }
                if let held = self.heldFor, let window = self.window,
                   held.bounds == window.bounds, held.insets == window.safeAreaInsets {
                    return
                }
                self.heldFor = nil
                let now = CACurrentMediaTime()
                self.recentChanges = self.recentChanges.filter { now - $0 < 1 } + [now]
                if self.recentChanges.count >= Self.changesBeforeHolding, let window = self.window {
                    self.heldFor = (window.bounds, window.safeAreaInsets)
                    self.recentChanges = []
                    NSLog("[RailGutters] the reading changed %ld times in a second; holding it until the window changes. Is the gutter on a view that hugs its content? %@",
                          Self.changesBeforeHolding, NSCoder.string(for: self.convert(self.bounds, to: window)))
                }
                self.reported = edges
                self.onChange?(edges)
            }
        }

        private func measure() -> Edge.Set {
            guard let window, let rail = SystemTabRail.rail(in: window)?.frame else { return [] }
            // Where the view rests, not where a slide carrying it has it.
            let frame = convert(bounds, to: window).offsetBy(dx: -(slide?.total ?? 0), dy: 0)
            let insets = window.safeAreaInsets
            let railOnRight = rail.midX > window.bounds.midX
            // The rail's side must be a strip the safe area leaves out, and
            // this view must reach the strip's edge.
            let meetsRight = railOnRight && insets.right > 0
                && abs(frame.maxX - (window.bounds.maxX - insets.right)) <= 1
            let meetsLeft = !railOnRight && insets.left > 0
                && abs(frame.minX - (window.bounds.minX + insets.left)) <= 1
            let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
            var edges: Edge.Set = []
            if meetsRight { edges.insert(rightToLeft ? .leading : .trailing) }
            if meetsLeft { edges.insert(rightToLeft ? .trailing : .leading) }
            return edges
        }
    }
}
#endif
