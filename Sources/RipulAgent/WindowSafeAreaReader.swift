#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// Root floating chrome has an explicit window-top offset, but inherits
    /// horizontal safe bounds. Keep this policy shared with hosted layout tests.
    public func windowTopBarLayout(width: CGFloat? = nil) -> some View {
        frame(width: width)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.container, edges: .vertical)
            .ignoresSafeArea(.keyboard)
            // Tab transitions may fade chrome, but must not animate its layout.
            .transaction { $0.animation = nil }
    }
}

private struct RipulTopBarSafeAreaTopKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Top clearance for floating bars in a host-owned content column. nil
    /// follows the window's measured safe area. A Catalyst host may use zero
    /// ONLY beside a pinned sidebar that retains the window-control safe area,
    /// after extending that content column to the window's top edge.
    public var ripulTopBarSafeAreaTop: CGFloat? {
        get { self[RipulTopBarSafeAreaTopKey.self] }
        set { self[RipulTopBarSafeAreaTopKey.self] = newValue }
    }
}

/// Reports the hosting **window's** top safe-area inset into SwiftUI state.
///
/// Mount as a `.background` anywhere in the hierarchy; position is irrelevant
/// because it reads `window.safeAreaInsets`, not its own. That window-level
/// value is the point: floating top bars that pin themselves to the physical
/// top can't trust the inset the hierarchy hands them (ancestors consume or
/// zero it — the original under-the-notch lozenge bug), and they must not ask
/// `UIApplication`/`UIWindow` during `body` either: `UIWindow.safeAreaInsets`
/// computes status-bar visibility, which queries a SwiftUI preference, which
/// synchronously re-enters the in-flight body evaluation — in Debug builds one
/// nested pass overflows the main-thread stack (deterministic launch crash,
/// ___chkstk_darwin SIGSEGV).
///
/// This reader threads that needle: UIKit callbacks (`didMoveToWindow`,
/// `safeAreaInsetsDidChange`, `layoutSubviews` for rotation) schedule a plain
/// main-queue async read + report, so the window is never touched inside a
/// SwiftUI update transaction and the state write never lands mid-update.
struct WindowSafeAreaTopReader: UIViewRepresentable {
    @Environment(\.ripulTopBarSafeAreaTop) private var topOverride
    let onChange: (CGFloat) -> Void
    var onInsetsChange: ((UIEdgeInsets) -> Void)? = nil
    /// Where app-owned top chrome should sit — see `WindowTopChromeLayout`.
    var onClearanceChange: ((WindowTopChromeClearance) -> Void)? = nil

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = onChange
        view.onInsetsChange = onInsetsChange
        view.onClearanceChange = onClearanceChange
        view.topOverride = topOverride
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
        uiView.onInsetsChange = onInsetsChange
        uiView.onClearanceChange = onClearanceChange
        if uiView.topOverride != topOverride {
            uiView.topOverride = topOverride
            uiView.scheduleReport()
        }
    }

    final class ReaderView: UIView {
        var onChange: ((CGFloat) -> Void)?
        var onInsetsChange: ((UIEdgeInsets) -> Void)?
        var onClearanceChange: ((WindowTopChromeClearance) -> Void)?
        var topOverride: CGFloat?
        private var lastReported: CGFloat?
        private var lastInsets: UIEdgeInsets?
        private var lastClearance: WindowTopChromeClearance?

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
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let insets = window.safeAreaInsets
                if insets != self.lastInsets {
                    self.lastInsets = insets
                    self.onInsetsChange?(insets)
                }
                // Same deferred UIKit read: the status bar frame and reserved
                // regions are window facts, never touched from a SwiftUI body.
                var clearance = WindowTopChromeLayout.clearance(for: window)
                if let topOverride {
                    clearance.top = topOverride
                    clearance.left = 0
                    clearance.right = 0
                }
                if clearance != self.lastClearance {
                    self.lastClearance = clearance
                    self.onClearanceChange?(clearance)
                }
                let top = self.topOverride ?? insets.top
                guard top != self.lastReported else { return }
                self.lastReported = top
                self.onChange?(top)
            }
        }
    }
}

// MARK: - Top chrome clearance

/// Where app-owned top chrome (GlassTopBar rows, the chat title, the masthead)
/// sits in its window, and how far it must stay from an occlusion it shares
/// the top band with.
///
/// On every ordinary device this is simply the window's top safe inset. On
/// iPhone Duo's open display the rectangular safe area is inflated by the
/// corner camera: the status bar collapses to a 2pt strip and the whole inset
/// (82pt in open portrait) is the camera's *occlusion reserved region*, which
/// spans only the trailing ~134pt. Apple's guidance for custom bars there is
/// to use the reserved-region API rather than the rectangular inset
/// ("Prepare your app for iPhone Duo", 8:08), so the bar row joins the band
/// beside the camera and its controls keep out of the region horizontally.
public struct WindowTopChromeClearance: Equatable, Sendable {
    /// Window-space y at which the bar row (its 4pt gutter included) starts.
    public var top: CGFloat
    /// Additional clearance inside the window's safe width on the window's
    /// left / right, so the row stays clear of an occlusion it now shares a
    /// band with. Zero unless `top` was pulled above the safe inset.
    public var left: CGFloat
    public var right: CGFloat
    /// The window's rectangular top safe inset, for callers that still need it.
    public var safeTop: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, right: CGFloat = 0, safeTop: CGFloat = 0) {
        self.top = top
        self.left = left
        self.right = right
        self.safeTop = safeTop
    }

    /// Window-space sides mapped onto the layout direction's leading/trailing.
    public func horizontal(for direction: LayoutDirection) -> (leading: CGFloat, trailing: CGFloat) {
        direction == .rightToLeft ? (right, left) : (left, right)
    }

    /// Clearance for content laid out below a bar of `barHeight` on this row.
    /// Chrome may share the camera's band; content still keeps to the
    /// rectangular safe area, so this is never less than `safeTop`.
    public func contentClearance(below barHeight: CGFloat) -> CGFloat {
        max(top + barHeight, safeTop)
    }
}

public enum WindowTopChromeLayout {
    /// GlassTopBar's row: a 4pt gutter above a 44pt row, so the row's centre
    /// sits 26pt below the reported `top`.
    public static let rowCentreOffset: CGFloat = 26
    /// A reclaimed band must leave room for a real bar: leading button,
    /// readable lozenge and the widest trailing cluster. Below this the
    /// controls would crowd the free span, so the row stays under the inset.
    public static let minimumFreeWidth: CGFloat = 320
    /// A status bar shorter than this is not occupying its band (the Duo's
    /// open display reports a 2pt frame beside the camera cluster).
    public static let statusBarPresenceHeight: CGFloat = 8

    /// Test seam: substitute the status bar frame and occlusion regions the
    /// resolver would otherwise read from the window.
    public static var probeOverride: ((UIWindow) -> (statusBarFrame: CGRect, occlusions: [CGRect]))?

    /// Resolve from live window facts. Call from UIKit callbacks or bridge
    /// handlers only — never from a SwiftUI body (see the reader's doc).
    public static func clearance(for window: UIWindow?) -> WindowTopChromeClearance {
        guard let window else { return WindowTopChromeClearance() }
        let probe = probeOverride?(window) ?? (
            statusBarFrame: window.windowScene?.statusBarManager?.statusBarFrame ?? .null,
            occlusions: occlusions(in: window)
        )
        return resolve(bounds: window.bounds, safeInsets: window.safeAreaInsets,
                       statusBarFrame: probe.statusBarFrame, occlusions: probe.occlusions)
    }

    /// Active occlusion reserved regions (the FaceTime camera) in window
    /// coordinates, margins included. Empty before iOS 27.1 and on every
    /// device that reports none.
    static func occlusions(in window: UIWindow) -> [CGRect] {
        // Xcode 27.0's UIKit (9127.0.84) lacks the reserved-region overlay
        // even though both toolchains are Swift 6.4; gate on the module.
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            return window.reservedRegions(kind: .occlusion).map(\.frame)
        }
        #endif
        return []
    }

    /// Pure resolution, shared with the layout tests.
    ///
    /// - `bounds` / `safeInsets`: the window's.
    /// - `statusBarFrame`: the scene's status bar frame (`.null` when unknown).
    /// - `occlusions`: active occlusion regions, window space, margins included.
    public static func resolve(bounds: CGRect, safeInsets: UIEdgeInsets,
                               statusBarFrame: CGRect, occlusions: [CGRect]) -> WindowTopChromeClearance {
        let safeTop = safeInsets.top
        let inherited = WindowTopChromeClearance(top: safeTop, safeTop: safeTop)
        guard safeTop > 0, bounds.width > 0 else { return inherited }
        // A status bar of real height owns its band on every edge; nothing
        // beside a camera is reclaimable underneath it.
        if !statusBarFrame.isNull, statusBarFrame.height >= statusBarPresenceHeight { return inherited }
        let band = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: safeTop)
        let regions = occlusions.filter { !$0.isNull && $0.intersects(band) }
        guard !regions.isEmpty else { return inherited }

        let safeMinX = bounds.minX + safeInsets.left
        let safeMaxX = bounds.maxX - safeInsets.right
        var left: CGFloat = 0
        var right: CGFloat = 0
        var union = CGRect.null
        for region in regions {
            let atLeft = region.minX <= bounds.minX + 1
            let atRight = region.maxX >= bounds.maxX - 1
            // A region touching neither edge (a centred island) or both (a
            // full-width strip) leaves no contiguous span to move into.
            guard atLeft != atRight else { return inherited }
            if atLeft { left = max(left, region.maxX - safeMinX) }
            if atRight { right = max(right, safeMaxX - region.minX) }
            union = union.union(region)
        }
        left = max(0, left)
        right = max(0, right)
        guard (safeMaxX - safeMinX) - left - right >= minimumFreeWidth else { return inherited }
        // Join the system's own band: the row centres on the region, like the
        // clock beside the camera, and never sits lower than it does today.
        let aligned = union.midY - rowCentreOffset
        let top = min(safeTop, max(bounds.minY, aligned))
        return WindowTopChromeClearance(top: top, left: left, right: right, safeTop: safeTop)
    }
}

/// Public face of the reader's top-chrome resolution. Mount as a
/// `.background`; pad the bar by `top` and apply `topChromeExclusion` to any
/// row that may now share the band with a camera.
public struct WindowTopChrome: View {
    let onChange: (WindowTopChromeClearance) -> Void

    public init(onChange: @escaping (WindowTopChromeClearance) -> Void) {
        self.onChange = onChange
    }

    public var body: some View {
        WindowSafeAreaTopReader(onChange: { _ in }, onClearanceChange: onChange)
    }
}

extension View {
    /// Keeps a bar row that shares the window's top band with an occlusion
    /// clear of it, on the side the occlusion occupies. No-op elsewhere.
    public func topChromeExclusion(_ clearance: WindowTopChromeClearance) -> some View {
        modifier(TopChromeExclusionModifier(clearance: clearance))
    }
}

private struct TopChromeExclusionModifier: ViewModifier {
    @Environment(\.layoutDirection) private var direction
    let clearance: WindowTopChromeClearance

    func body(content: Content) -> some View {
        let sides = clearance.horizontal(for: direction)
        content
            .padding(.leading, sides.leading)
            .padding(.trailing, sides.trailing)
    }
}

/// Public face of `WindowSafeAreaTopReader` for hosts that build their own
/// floating bars (the first-party Agents|Plans root bar). Mount as a
/// `.background` and pad by the reported value — a `GeometryReader`'s
/// `safeAreaInsets` at those levels reads zero because ancestors consume the
/// region (the trap documented on the reader above).
public struct WindowSafeAreaTop: View {
    let onChange: (CGFloat) -> Void

    public init(onChange: @escaping (CGFloat) -> Void) {
        self.onChange = onChange
    }

    public var body: some View {
        WindowSafeAreaTopReader(onChange: onChange)
    }
}

/// Deferred measurements from this view's own window, including inset-only
/// changes. Use when a full-height surface manages its own scroll clearance.
public struct WindowSafeAreaInsets: View {
    let onChange: (UIEdgeInsets) -> Void

    public init(onChange: @escaping (UIEdgeInsets) -> Void) { self.onChange = onChange }

    public var body: some View {
        WindowSafeAreaTopReader(onChange: { _ in }, onInsetsChange: onChange)
    }
}

/// The owning window's safe rectangle, intersected with this view's bounds
/// and converted to local coordinates. Use for deliberately edge-to-edge
/// overlays; ordinary content should retain its inherited safe area instead.
/// Conversion prevents adding the window's side inset twice inside a column.
public struct WindowSafeAreaBounds: View {
    let onChange: (CGRect) -> Void

    public init(onChange: @escaping (CGRect) -> Void) {
        self.onChange = onChange
    }

    public var body: some View {
        WindowSafeAreaBoundsReader(onChange: onChange)
    }
}

struct WindowSafeAreaBoundsReader: UIViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.scheduleReport()
    }

    final class ReaderView: UIView {
        var onChange: ((CGRect) -> Void)?
        private var lastReported: CGRect?
        private var reportScheduled = false

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
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                guard let window = self.window, !self.bounds.isEmpty else { return }
                let windowSafe = window.bounds.inset(by: window.safeAreaInsets)
                let intersection = self.bounds.intersection(self.convert(windowSafe, from: window))
                let safe = intersection.isNull ? CGRect.zero : intersection
                guard safe != self.lastReported else { return }
                self.lastReported = safe
                self.onChange?(safe)
            }
        }
    }
}
#endif
