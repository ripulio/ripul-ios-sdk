#if os(iOS)
import SwiftUI
import UIKit
import Combine

// MARK: - The dock
//
// A window wide enough for the session list and the chat side by side (an open
// iPhone Duo in landscape, an iPad in landscape, the mini included) can give
// its right side to the chat's simulator or browser. Dragging either one's
// picture-in-picture panel into the window's right edge lights that side up
// as the place it would go; letting go there docks it. The app then takes a
// phone's width on the left, in its phone layout (the compact size class: a
// bottom tab bar, one column), and the simulator, live and taking touches, or
// the browser fills the right (Peter, 1 November 2026).
//
// The person's choice outlives the chat that made it: switching chats or tabs
// leaves the dock as it is, and a window that becomes too narrow (the Duo
// folded, an iPad turned upright) shows the docked one as its panel again
// until there is room, when it docks again by itself.
//
// Any of the app's own screens docks too, carried to either edge of the window
// out of Exposé, as the Duo docks an app carried out of its app switcher
// (Peter, 1 November 2026). It is the app's own split view: one web page and
// one connection to the Mac serve both sides, where a second window of the app
// would load the whole web app again. The app's home, the chat, never leaves
// the app's side, so carried to an edge it takes the app there and the other
// side offers what to put beside it (`picker`), as the Duo shows its Home
// Screen beside an app it has just docked.

/// What a window's dock holds, and how wide the app beside it is.
///
/// One per window, owned by its `RipulWindowContext`. The host lays the window
/// out with `RipulPreviewDockLayout`; the chat's preview panels
/// (`ripulPreviewPanels`) join it and offer the dock as they are dragged, and
/// the host docks its own screens (`dock(screen:side:)`, `dockPicker(side:)`)
/// and draws them (`screenContent`).
@MainActor
public final class PreviewDockState: ObservableObject {
    public enum Kind: Equatable { case simulator, browser, screen, picker }

    /// Which side of the window the dock is on.
    public enum Side: String, Equatable {
        case left, right
        public var opposite: Side { self == .left ? .right : .left }
    }

    /// One of the app's own screens in the dock, as Exposé has it.
    public struct Screen: Equatable {
        /// The Exposé document's id (`repos:<path>`, `settings`).
        public let id: String
        /// The app's tab that holds it (a `SidebarTab` raw value in the Ripul app).
        public let host: String
        public let title: String
        public let icon: String
        /// It is the Browser: the browser's picture steps aside while it is docked,
        /// as for the browser docked from its panel.
        public let showsBrowser: Bool

        public init(id: String, host: String, title: String, icon: String, showsBrowser: Bool = false) {
            self.id = id
            self.host = host
            self.title = title
            self.icon = icon
            self.showsBrowser = showsBrowser
        }
    }

    /// A simulator in the dock, as its panel had it.
    public struct Simulator: Equatable {
        let target: SimulatorTarget
        public let machineId: String
        /// The chat whose agent was using it.
        public let chatId: String
        public let name: String
        /// It opens and closes (the iPhone Duo): the fold controls apply.
        public let foldable: Bool
        /// Its screen in points, as last seen, until the live picture says.
        public let screenSize: CGSize
        public var udid: String { target.udid }
        /// Its buttons: an Android emulator's own, or a simulator's.
        var hardwareControls: [SimulatorPreviewState.Control] {
            AndroidEmulatorUDID.isAndroid(udid) ? SimulatorPreviewState.androidControls : SimulatorPreviewState.controls
        }
    }

    public enum Surface: Equatable {
        case simulator(Simulator)
        /// The local browser, on this tab (nil: the active one).
        case browser(tabId: Int?)
        /// One of the app's screens, carried out of Exposé.
        case screen(Screen)
        /// Carried out of Exposé with the app taking the other side: what goes
        /// here is still to be chosen.
        case picker

        public var kind: Kind {
            switch self {
            case .simulator: return .simulator
            case .browser: return .browser
            case .screen: return .screen
            case .picker: return .picker
            }
        }

        /// The app's screen in the dock, if it is one.
        public var screen: Screen? {
            if case .screen(let screen) = self { return screen }
            return nil
        }

        /// The Browser is in the dock, from its panel or out of Exposé.
        public var showsBrowser: Bool {
            switch self {
            case .browser: return true
            case .screen(let screen): return screen.showsBrowser
            case .simulator, .picker: return false
            }
        }

        /// The host draws it (`screenContent`), not the chat's panels.
        var isHosts: Bool { kind == .screen || kind == .picker }
    }

    /// What the person docked. Kept while the window is too narrow to show it.
    @Published public private(set) var surface: Surface? {
        didSet {
            if surface != oldValue { liveScreenSize = nil }
            refreshShown()
        }
    }
    /// What the dock shows now: what was docked, while the window has room for it.
    @Published public private(set) var shown: Surface?
    /// The side the dock is on: the right for a panel dragged in, either for a
    /// screen carried out of Exposé.
    @Published public private(set) var side: Side = .right
    /// A panel dragged into the window's edge: what would dock if it were let go.
    @Published public private(set) var hovering: Kind?
    /// The screen of the simulator being dragged in, for the indicator to show its fit.
    private(set) var hoveringScreen: CGSize?
    /// The app's width beside the dock, as the person last dragged the divider.
    @Published public private(set) var appWidth: CGFloat?
    /// A docked simulator's screen fills the dock exactly, edge to edge, with
    /// no black bars, where the app beside it can keep a phone's width (Peter,
    /// 1 November 2026: a closed Duo docked in an open one, "to complete the
    /// illusion we need to set the split perfectly"). On until the divider is
    /// let go elsewhere; the fit, the divider's menu or a drag back to it turns it on again.
    @Published public private(set) var fitsSimulator: Bool
    /// The docked simulator's screen as its live picture measures it (a fold changes it).
    @Published private(set) var liveScreenSize: CGSize?
    /// Changes when the docked simulator's live picture has to start again: a fold moves it to another screen.
    @Published private(set) var generation = UUID()
    /// What a control just said, for a few seconds.
    @Published private(set) var notice: String?

    /// The window is wide enough for a dock (`minimumWindowWidth`), set by the layout.
    private(set) var fits = false { didSet { refreshShown() } }
    /// A layout is showing this window, so there is somewhere for a dock to go.
    private(set) var hasLayout = false { didSet { refreshShown() } }
    /// What the dock draws. Set as the chat's panels join (`AgentBridge.joinPreviewDock`).
    var content: ((Surface) -> AnyView)? { didSet { refreshShown() } }
    /// The docked one leaves: back to its panel (`reopen`) or minimised there.
    var onRelease: ((Surface, _ reopen: Bool) -> Void)?
    /// The host's own screens in the dock, and the picker for choosing one.
    /// Without it nothing is carried out of Exposé.
    public var screenContent: ((Surface) -> AnyView)? { didSet { refreshShown() } }
    /// A screen or the picker leaves the dock: `reopen` asks the app beside it
    /// to show that screen instead (the docked one full screen), otherwise the
    /// app stays where it is.
    public var onScreenRelease: ((Surface, _ reopen: Bool) -> Void)?
    /// A docked simulator's hardware controls go to its Mac through this.
    var invoke: ((String, String, [Any], String) async -> [String: Any])?

    private let store: UserDefaults
    private var noticeGeneration = UUID()

    public init(store: UserDefaults = .standard) {
        self.store = store
        let saved = store.double(forKey: Self.appWidthKey)
        appWidth = saved > 0 ? CGFloat(saved) : nil
        fitsSimulator = store.object(forKey: Self.fitsSimulatorKey) as? Bool ?? true
    }

    // MARK: Widths

    /// A window narrower than this has no dock: the list and the chat no longer fit side by side.
    public static let minimumWindowWidth = WorkspaceColumns.sessionAndChatMinimum
    /// An iPhone 17 Pro's width: the app beside the dock is laid out as on a phone.
    public static let defaultAppWidth: CGFloat = 402
    public static let minimumAppWidth: CGFloat = 360
    public static let minimumDockWidth: CGFloat = 320
    /// Narrower than the dock otherwise goes: a phone's screen at full height is about 300 points wide.
    public static let minimumFittedDockWidth: CGFloat = 240
    static let appWidthKey = "ripul.previewDock.appWidth"
    static let fitsSimulatorKey = "ripul.previewDock.fitsSimulator"

    /// The app's width in a window this wide, given the person's choice.
    public static func appWidth(in width: CGFloat, preferred: CGFloat?) -> CGFloat {
        let wanted = max(minimumAppWidth, preferred ?? defaultAppWidth)
        return min(wanted, max(minimumAppWidth, width - minimumDockWidth))
    }

    /// The app's width at which a simulator's screen fills the dock exactly:
    /// the dock is the screen's shape at the window's full height (it runs
    /// under the status bar, the home indicator and the right-hand safe area),
    /// less the one-point divider. Nil where that leaves the app narrower than
    /// a phone, or the dock too narrow to use (a wide screen, a short window).
    /// `width` is the safe width the layout divides; `trailingInset` and
    /// `height`, the parts of the window the dock runs into beyond it.
    public static func fittedAppWidth(width: CGFloat, trailingInset: CGFloat, height: CGFloat, screen: CGSize) -> CGFloat? {
        guard screen.width > 0, screen.height > 0, height > 0 else { return nil }
        let dock = (height * screen.width / screen.height).rounded()
        let app = width + trailingInset - 1 - dock
        guard app >= minimumAppWidth, dock >= minimumFittedDockWidth else { return nil }
        return app
    }

    /// The screen of what is docked, when it is a simulator: as its live picture
    /// measures it, or as its panel last saw it.
    func screenSize(of surface: Surface) -> CGSize? {
        guard case .simulator(let simulator) = surface else { return nil }
        if let liveScreenSize { return liveScreenSize }
        return simulator.screenSize.width > 0 && simulator.screenSize.height > 0 ? simulator.screenSize : nil
    }

    /// The docked simulator's live picture measured its screen.
    func simulatorScreenChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, liveScreenSize != size else { return }
        liveScreenSize = size
    }

    /// The docked simulator fills the dock exactly again.
    public func fitSimulator() {
        fitsSimulator = true
        store.set(true, forKey: Self.fitsSimulatorKey)
    }

    // MARK: Docking

    /// A panel may dock now: a layout has room for it and nothing else is docked.
    /// `width` is the panel's container: the window, while nothing is docked.
    func canDock(containerWidth width: CGFloat) -> Bool {
        // The layout's own measure too: its safe width is what it divides.
        hasLayout && fits && content != nil && surface == nil && width >= Self.minimumWindowWidth
    }

    /// Where a card carried out of Exposé would dock on each side of a window
    /// this size, or nil where nothing can be carried out now (too narrow,
    /// something docked already, no host to draw its screens). A card whose
    /// screen docks takes the dock's width on its side; one that takes the app
    /// with it (`appMoves`: the chat, which never leaves the app) takes the
    /// app's, a phone's width.
    public func switcherTargets(in size: CGSize, appMoves: Bool) -> ScreenSwitcherStore.DockTargets? {
        guard hasLayout, fits, surface == nil, screenContent != nil,
              size.width >= Self.minimumWindowWidth, size.height > 0 else { return nil }
        let app = Self.appWidth(in: size.width, preferred: appWidth)
        let width = appMoves ? app : size.width - app - 1
        return ScreenSwitcherStore.DockTargets(
            left: CGRect(x: 0, y: 0, width: width, height: size.height),
            right: CGRect(x: size.width - width, y: 0, width: width, height: size.height),
            appMoves: appMoves)
    }

    func hover(_ kind: Kind, _ over: Bool, screen: CGSize? = nil) {
        if over {
            hoveringScreen = screen
            if hovering != kind { hovering = kind }
        } else if hovering == kind { hovering = nil }
    }

    func dock(_ next: Surface, side: Side = .right) {
        hovering = nil
        guard surface != next || self.side != side else { return }
        withAnimation(Self.motion) {
            self.side = side
            surface = next
        }
    }

    /// One of the app's screens into the dock, on this side, carried out of Exposé.
    public func dock(screen: Screen, side: Side) {
        guard surface == nil || surface?.kind == .picker else { return }
        dock(.screen(screen), side: side)
    }

    /// The picker into the dock, on this side: the app took the other, and what
    /// goes beside it is chosen here.
    public func dockPicker(side: Side) {
        guard surface == nil else { return }
        dock(.picker, side: side)
    }

    /// The docked screen or picker to the other side of the window.
    public func moveToOtherSide() {
        guard surface?.isHosts == true else { return }
        withAnimation(Self.motion) { side = side.opposite }
    }

    /// Back to its panel, open, over the app; a screen of the app's, full screen there.
    public func undock() { release(reopen: true) }

    /// Out of the dock and minimised to its panel's button; a screen of the
    /// app's or the picker, gone, the app staying where it is.
    public func close() { release(reopen: false) }

    private func release(reopen: Bool) {
        guard let leaving = surface else { return }
        withAnimation(Self.motion) { surface = nil }
        if leaving.isHosts {
            onScreenRelease?(leaving, reopen)
        } else {
            onRelease?(leaving, reopen)
        }
        // A panel docks only at the right edge; the next one starts there.
        side = .right
    }

    /// The person let go of the divider here, away from the simulator's fit.
    public func setAppWidth(_ width: CGFloat) {
        appWidth = width
        store.set(Double(width), forKey: Self.appWidthKey)
        if fitsSimulator {
            fitsSimulator = false
            store.set(false, forKey: Self.fitsSimulatorKey)
        }
    }

    func layoutAppeared(_ present: Bool) { if hasLayout != present { hasLayout = present } }
    func windowWidthChanged(_ width: CGFloat) {
        let fits = width >= Self.minimumWindowWidth
        if self.fits != fits { self.fits = fits }
    }

    private func refreshShown() {
        let next = hasLayout && fits ? surface.flatMap { view(for: $0) == nil ? nil : $0 } : nil
        if shown != next { shown = next }
    }

    /// What draws this in the dock: the chat's panels for theirs, the host for its own.
    func view(for surface: Surface) -> ((Surface) -> AnyView)? {
        surface.isHosts ? screenContent : content
    }

    /// How the dock moves: a soft spring, none with Reduce Motion.
    public static var motion: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.38, dampingFraction: 0.88)
    }

    // MARK: The docked simulator's controls

    /// A hardware control on the docked simulator's Mac, as its panel does them
    /// (`SimulatorPreviewState.control`). A fold moves the picture to the other
    /// screen, so the live picture starts again once the fold has settled.
    func control(_ action: String) async {
        guard case .simulator(let simulator) = surface, let invoke else { return }
        let response = await invoke(simulator.machineId, "simulatorControl",
                                    [simulator.target.arguments, ["action": action]], simulator.chatId)
        guard response["success"] as? Bool == true else {
            let said = response["error"] as? String
            show(notice: said.map { $0.contains("Unknown method") || $0.contains("NOT_ALLOWED") || $0.contains("not available through Direct")
                ? "Update Ripul on the Mac to use simulator controls." : $0 } ?? "The Mac didn't answer.")
            return
        }
        guard SimulatorPreviewState.foldControls.contains(where: { $0.action == action }) else { return }
        try? await Task.sleep(for: .milliseconds(700))
        guard case .simulator(let still) = surface, still == simulator else { return }
        generation = UUID()
    }

    private func show(notice text: String) {
        let generation = UUID()
        noticeGeneration = generation
        notice = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if noticeGeneration == generation { notice = nil }
        }
    }

    #if DEBUG
    /// `-ripul.fixture.previewDock simulator|browser`: docked from launch, with
    /// no panel dragged, to see the docked layout on a simulator with no Mac or
    /// chat to hand. The fixture simulator's Mac does not exist, so its viewer
    /// says it cannot reach it.
    public func dockFixture(_ name: String) {
        switch name {
        case "simulator":
            dock(.simulator(Simulator(target: SimulatorTarget(udid: "00000000-0000-4000-8000-000000000001"),
                                      machineId: "fixture", chatId: "fixture", name: "iPhone 17 Pro",
                                      foldable: false, screenSize: CGSize(width: 402, height: 874))))
        case "browser":
            dock(.browser(tabId: nil))
        default:
            break
        }
    }
    #endif
}

// MARK: - A panel's way into the dock

/// What a floating panel asks while it is dragged, to dock at the window's
/// right edge (`RipulFloatingPanel(docking:)`).
struct FloatingPanelDocking {
    /// A drop could dock now, in a container this wide.
    let canDock: (CGFloat) -> Bool
    /// The drag went into the dock's edge, or out of it.
    let hover: (Bool) -> Void
    /// Let go in the edge.
    let drop: () -> Void

    /// How near the window's right edge the finger has to come, in points…
    static let edgeReach: CGFloat = 64
    /// …or how far past the place the panel stops (it stays inside the window)
    /// the drag has to push.
    static let push: CGFloat = 44
    /// Once in, the drag stays in until it is this far from the edge, so a
    /// finger resting at the boundary doesn't flicker the dock on and off.
    static let edgeRelease: CGFloat = 140

    /// Whether a drag is in the dock's edge. `edgeDistance` is from the finger to
    /// the container's right edge; `pushed`, how far past its stop the panel was dragged.
    static func isOver(edgeDistance: CGFloat, pushed: CGFloat, wasOver: Bool) -> Bool {
        wasOver ? (edgeDistance < edgeRelease || pushed > 12) : (edgeDistance < edgeReach || pushed > push)
    }
}

// MARK: - The window's layout

/// Lays a window out around its dock: the app full width while nothing is
/// docked, and beside the dock, at a phone's width and in its phone layout,
/// while something is.
///
/// Wrap the app's root in this, above everything that reads the size class:
/// the app keeps its place in the view tree whether or not a dock shows, so
/// nothing in it is rebuilt by docking, and the compact size class reaches
/// the system's own containers (its tab view turns from a rail or sidebar
/// into a bottom tab bar) as it does on a phone.
public struct RipulPreviewDockLayout<Content: View>: View {
    @ObservedObject private var dock: PreviewDockState
    private let content: Content
    /// The app's width while the divider is dragged.
    @State private var draggedAppWidth: CGFloat?
    @GestureState private var dragStart: CGFloat?
    /// The divider was tapped: Undock and Close are offered.
    @State private var offeringActions = false
    /// The tick as the divider snaps to a docked simulator's fit.
    @State private var snapFeedback = UISelectionFeedbackGenerator()
    @Namespace private var dragSpace

    public init(dock: PreviewDockState, @ViewBuilder content: () -> Content) {
        self.dock = dock
        self.content = content()
    }

    public var body: some View {
        // Whether the dock shows is decided from the width in the same pass as
        // the layout it decides. Learned a frame later, from a geometry
        // callback, a folding Duo laid out its 466-point cover once as a
        // 360-point app beside a 105-point dock, and an opening one laid the
        // app out full width and regular before docking it again.
        GeometryReader { geometry in
            let width = geometry.size.width
            let docked = width < PreviewDockState.minimumWindowWidth ? nil : dock.surface
            let draw = docked.flatMap { dock.view(for: $0) }
            let shown = draw == nil ? nil : docked
            let side = dock.side
            // Where a docked simulator's screen fills the dock exactly. The dock
            // runs under the status bar, the home indicator and the safe area on
            // its side, so it is the window's whole height.
            let insets = geometry.safeAreaInsets
            let fit = shown.flatMap(dock.screenSize(of:)).flatMap {
                PreviewDockState.fittedAppWidth(width: width, trailingInset: side == .right ? insets.trailing : insets.leading,
                                                height: geometry.size.height + insets.top + insets.bottom, screen: $0)
            }
            let resting = (dock.fitsSimulator ? fit : nil) ?? PreviewDockState.appWidth(in: width, preferred: dock.appWidth)
            let appWidth = draggedAppWidth ?? resting
            // The app is always the first child, whichever side it is on, so
            // docking, undocking and moving the dock across never rebuild it.
            DockSplitLayout(side: side, appWidth: shown == nil ? nil : appWidth) {
                content
                    // Docked, a phone's size class; otherwise the window's, untouched.
                    .transformEnvironment(\.horizontalSizeClass) { sizeClass in
                        if shown != nil { sizeClass = .compact }
                    }
                if let shown, let draw {
                    divider(appWidth: appWidth, width: width, fit: fit, surface: shown, side: side)
                    draw(shown)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(releasesOnLetGo(appWidth, width: width) ? 0.45 : 1)
                        .transition(.move(edge: side == .right ? .trailing : .leading).combined(with: .opacity))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("PreviewDock.pane")
                }
            }
            .frame(width: width, height: geometry.size.height)
        }
        .coordinateSpace(name: dragSpace)
        // The panels and the Browser tab follow the dock's state, a frame later is fine there.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { dock.windowWidthChanged($0) }
        .onAppear { dock.layoutAppeared(true) }
        .onDisappear { dock.layoutAppeared(false) }
    }

    /// Dragged this far toward the dock's edge, letting go undocks, as dragging an
    /// iPad's divider off the screen closes the app beside it. Short of the
    /// narrowest fitted dock, so letting go at a fit never undocks.
    private func releasesOnLetGo(_ appWidth: CGFloat, width: CGFloat) -> Bool {
        draggedAppWidth != nil && width - appWidth < PreviewDockState.minimumFittedDockWidth - 40
    }

    /// How near the fit the divider has to come to snap to it.
    private static var snapDistance: CGFloat { 18 }

    /// What the divider's menu calls the docked one.
    private static func name(of surface: PreviewDockState.Surface) -> String {
        switch surface {
        case .simulator: return "Simulator"
        case .browser: return "Browser"
        case .screen(let screen): return screen.title
        case .picker: return "Split View"
        }
    }

    /// A line between the two, with a grip: dragged, it sizes them (and off the
    /// dock's edge, undocks; near a docked simulator's fit, it snaps to it with a
    /// tick); tapped, it offers the fit, the simulator's hardware, Undock and Close.
    ///
    /// The dock's own controls are here rather than at its top middle, where
    /// iPadOS put a window's: the top of the window takes its own touches
    /// (iPadOS 26's menu bar, and on the Duo UIKit's scroll-to-top region,
    /// where a SwiftUI tap never fires), and a tap there did nothing.
    private func divider(appWidth: CGFloat, width: CGFloat, fit: CGFloat?, surface: PreviewDockState.Surface,
                         side: PreviewDockState.Side) -> some View {
        let thing = Self.name(of: surface)
        // With the dock on the left the app is on the right: a drag to the right narrows it.
        let toward: CGFloat = side == .right ? 1 : -1
        return Rectangle()
            .fill(Color.ripul(.separator))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea()
            .overlay {
                Button { offeringActions = true } label: {
                    ZStack {
                        Color.clear
                        Capsule()
                            .fill(Color.ripul(.textSecondary).opacity(dragStart == nil ? 0.5 : 0.9))
                            .frame(width: 5, height: 44)
                    }
                    .frame(width: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A drag takes the touch from the tap. Measured in the stationary
                // layout, not in the divider that follows the finger.
                .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(dragSpace))
                    .updating($dragStart) { _, start, _ in if start == nil { start = appWidth } }
                    .onChanged { value in
                        let proposed = (dragStart ?? appWidth) + toward * value.translation.width
                        // Free toward the dock's edge, so the dock can be dragged away;
                        // never narrower than a phone on the app's side.
                        var next = min(max(PreviewDockState.minimumAppWidth, proposed), width - 80)
                        if let fit, abs(next - fit) < Self.snapDistance { next = fit }
                        if let fit, next == fit, draggedAppWidth != fit { snapFeedback.selectionChanged() }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { draggedAppWidth = next }
                    }
                    .onEnded { _ in
                        guard let dragged = draggedAppWidth else { return }
                        if let fit, dragged == fit {
                            dock.fitSimulator()
                            draggedAppWidth = nil
                        } else if releasesOnLetGo(dragged, width: width) {
                            draggedAppWidth = nil
                            dock.undock()
                        } else {
                            let settled = PreviewDockState.appWidth(in: width, preferred: dragged)
                            dock.setAppWidth(settled)
                            withAnimation(PreviewDockState.motion) { draggedAppWidth = nil }
                        }
                    })
                // Our own menu in a popover, not a confirmation dialog: iOS 26 drew the
                // dialog as glass over the dimmed screen and resolved its buttons'
                // colour, the window's tint (the theme's teal), and its red to their
                // pale dark-mode variants on light grey capsules, which could not be
                // read (Peter, 1 November 2026).
                .popover(isPresented: $offeringActions, attachmentAnchor: .rect(.bounds),
                         arrowEdge: side == .right ? .leading : .trailing) {
                    PreviewDockMenu(surface: surface, thing: thing, side: side,
                                    canFit: fit.map { abs(appWidth - $0) > 0.5 } ?? false,
                                    simulator: { if case .simulator(let simulator) = surface { return simulator }; return nil }()) { choice in
                        offeringActions = false
                        switch choice {
                        case .fit: withAnimation(PreviewDockState.motion) { dock.fitSimulator() }
                        case .control(let action): Task { await dock.control(action) }
                        case .moveAcross: dock.moveToOtherSide()
                        case .undock: dock.undock()
                        case .close: dock.close()
                        }
                    }
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(Color.ripul(.surface))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dock width")
            .accessibilityValue("\(Int(width - appWidth)) points")
            .accessibilityHint("Drag the divider off the dock's edge to undock. Tap for its controls, undock and close.")
            .accessibilityIdentifier("PreviewDock.divider")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? -40 : 40
                dock.setAppWidth(PreviewDockState.appWidth(in: width, preferred: appWidth + step))
            }
            .accessibilityAction(named: "Fit Simulator") { if fit != nil { dock.fitSimulator() } }
            .accessibilityAction(named: "Undock") { dock.undock() }
            .accessibilityAction(named: "Close") { dock.close() }
            .zIndex(1)
    }
}

/// The app beside the dock, on either side of it, at the app's width; the
/// window's whole width while nothing is docked. The app is always the first
/// subview, the divider and the dock after it, so which side the dock is on
/// changes where they are placed, never what they are: an `HStack` would have
/// to reorder its children to put the dock on the left, and the app (the web
/// view, the chat) would be rebuilt.
struct DockSplitLayout: Layout {
    let side: PreviewDockState.Side
    /// Nil: nothing docked, the app fills the window.
    let appWidth: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let app = subviews.first else { return }
        guard let appWidth, subviews.count >= 3 else {
            app.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let frames = Self.frames(in: bounds, side: side, appWidth: appWidth)
        app.place(at: frames.app.origin, proposal: ProposedViewSize(frames.app.size))
        subviews[1].place(at: frames.divider.origin, proposal: ProposedViewSize(frames.divider.size))
        subviews[2].place(at: frames.dock.origin, proposal: ProposedViewSize(frames.dock.size))
    }

    /// Where the app, the one-point divider and the dock go.
    static func frames(in bounds: CGRect, side: PreviewDockState.Side, appWidth: CGFloat)
        -> (app: CGRect, divider: CGRect, dock: CGRect) {
        let dockWidth = max(0, bounds.width - appWidth - 1)
        let height = bounds.height
        switch side {
        case .right:
            return (CGRect(x: bounds.minX, y: bounds.minY, width: appWidth, height: height),
                    CGRect(x: bounds.minX + appWidth, y: bounds.minY, width: 1, height: height),
                    CGRect(x: bounds.minX + appWidth + 1, y: bounds.minY, width: dockWidth, height: height))
        case .left:
            return (CGRect(x: bounds.maxX - appWidth, y: bounds.minY, width: appWidth, height: height),
                    CGRect(x: bounds.minX + dockWidth, y: bounds.minY, width: 1, height: height),
                    CGRect(x: bounds.minX, y: bounds.minY, width: dockWidth, height: height))
        }
    }
}

/// What the divider offers when tapped: the fit, a docked simulator's
/// hardware (its toolbar has no room beside a fitted screen), Undock and Close.
/// In the theme's own colours, rows with icons, the fold controls apart under
/// their own heading, so the fold's Close is not taken for closing the simulator.
/// A screen of the app's moves to the other side, or goes full screen; the
/// picker only closes.
private struct PreviewDockMenu: View {
    enum Choice { case fit, control(String), moveAcross, undock, close }
    let surface: PreviewDockState.Surface
    let thing: String
    let side: PreviewDockState.Side
    let canFit: Bool
    let simulator: PreviewDockState.Simulator?
    let choose: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if canFit {
                row("Fit \(thing)", symbol: "aspectratio", id: "fit") { choose(.fit) }
                separator
            }
            if let simulator {
                ForEach(simulator.hardwareControls) { item in
                    row(item.title, symbol: item.symbol, id: item.action) { choose(.control(item.action)) }
                }
                if simulator.foldable {
                    Text("Fold")
                        .font(.ripul(.footnote, weight: .semibold))
                        .foregroundStyle(.ripul(.textSecondary))
                        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(SimulatorPreviewState.foldControls) { item in
                        row(item.title, symbol: item.symbol, id: item.action) { choose(.control(item.action)) }
                    }
                }
                separator
            }
            switch surface.kind {
            case .screen:
                row(side == .right ? "Move to the Left" : "Move to the Right",
                    symbol: side == .right ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled",
                    id: "move") { choose(.moveAcross) }
                row("Show \(thing) Full Screen", symbol: "arrow.up.left.and.arrow.down.right", id: "undock") { choose(.undock) }
                row("Close \(thing)", symbol: "xmark", id: "close", destructive: true) { choose(.close) }
            case .picker:
                row(side == .right ? "Move to the Left" : "Move to the Right",
                    symbol: side == .right ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled",
                    id: "move") { choose(.moveAcross) }
                row("Close Split View", symbol: "xmark", id: "close", destructive: true) { choose(.close) }
            case .simulator, .browser:
                row("Undock \(thing)", symbol: "pip.enter", id: "undock") { choose(.undock) }
                row("Close \(thing)", symbol: "xmark", id: "close", destructive: true) { choose(.close) }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 250)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PreviewDock.menu")
    }

    private var separator: some View {
        Rectangle().fill(Color.ripul(.separator)).frame(height: 1).padding(.vertical, 6)
    }

    private func row(_ title: String, symbol: String, id: String, destructive: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.ripulIcon(size: 16, weight: .medium))
                    .frame(width: 24)
                Text(title).font(.ripul(.body))
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? .ripul(.danger) : .ripul(.text))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PreviewDockMenuRowStyle())
        .accessibilityIdentifier("PreviewDock.menu.\(id)")
    }
}

/// A row that shows it is pressed, as a menu's rows do.
private struct PreviewDockMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.ripul(.textSecondary).opacity(configuration.isPressed ? 0.15 : 0))
    }
}

// MARK: - Where it would go

/// The right of the window lit up while a panel is dragged into its edge: the
/// place it would take, at the size it would have.
@available(iOS 26.0, *)
struct PreviewDockIndicator: View {
    @ObservedObject var dock: PreviewDockState

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // The layout divides the window's safe width; the dock runs on to its
            // right edge, and for a simulator it fits, at the size it would fit.
            let insets = geometry.safeAreaInsets
            let safeWidth = size.width - insets.leading - insets.trailing
            let fitted = dock.fitsSimulator && dock.hovering == .simulator
                ? dock.hoveringScreen.flatMap {
                    PreviewDockState.fittedAppWidth(width: safeWidth, trailingInset: insets.trailing, height: size.height, screen: $0)
                } : nil
            let appWidth = insets.leading + (fitted ?? PreviewDockState.appWidth(in: safeWidth, preferred: dock.appWidth))
            if let kind = dock.hovering {
                RipulDockDropTarget(symbol: kind == .simulator ? "iphone" : "safari",
                                    title: kind == .simulator ? "Release to dock the simulator" : "Release to dock the browser",
                                    detail: "The app moves to a phone's width beside it")
                .frame(width: max(0, size.width - appWidth - 20), height: max(0, size.height - 24))
                .position(x: appWidth + (size.width - appWidth) / 2, y: size.height / 2)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .accessibilityIdentifier("PreviewDock.indicator")
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(PreviewDockState.motion, value: dock.hovering)
    }
}

/// Where a dragged thing would dock, lit up: what it is, what letting go does,
/// and what happens beside it. Fills the frame it is given; the panels' drag
/// and Exposé's carry place it.
@available(iOS 26.0, *)
public struct RipulDockDropTarget: View {
    private let symbol: String
    private let title: String
    private let detail: String

    public init(symbol: String, title: String, detail: String) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.ripulIcon(size: 34, weight: .regular))
                .foregroundStyle(.tint)
            Text(title)
                .font(.ripul(.headline))
                .foregroundStyle(.ripul(.text))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.ripul(.footnote))
                .foregroundStyle(.ripul(.textSecondary))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.10), in: shape)
        .glassEffect(.clear, in: shape)
        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2))
        .accessibilityElement(children: .combine)
    }
}

/// Joins the window's dock to this window's chat panels, and draws where a
/// dragged panel would dock. Part of `ripulPreviewPanels`.
struct PreviewDockPresenter: ViewModifier {
    let bridge: AgentBridge
    @Environment(\.ripulWindowContext) private var workspace

    func body(content: Content) -> some View {
        content
            .overlay {
                if #available(iOS 26.0, *), let dock = workspace?.previewDock { PreviewDockIndicator(dock: dock) }
            }
            .onAppear { bridge.joinPreviewDock(workspace?.previewDock) }
            .onChange(of: workspace?.id) { _, _ in bridge.joinPreviewDock(workspace?.previewDock) }
    }
}

// MARK: - The browser's own screen while it is docked

/// The browser's screen in its tab, or a note while it is docked: one browser
/// screen at a time holds the tabs' pages, so while the dock shows the browser
/// the tab says where it went.
public struct RipulDockedBrowserSlot<Content: View>: View {
    private let content: Content
    @Environment(\.ripulWindowContext) private var workspace

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        if let dock = workspace?.previewDock {
            Slot(dock: dock, content: content)
        } else {
            content
        }
    }

    private struct Slot: View {
        @ObservedObject var dock: PreviewDockState
        let content: Content
        var body: some View {
            if dock.shown?.showsBrowser == true {
                DockedElsewhereNote(title: "The browser is docked on the \(dock.side.rawValue)", side: dock.side,
                                    identifier: "PreviewDock.browserSlot") { dock.undock() }
            } else {
                content
            }
        }
    }
}

/// A tab's screen, or a note while that screen is docked beside the app: the
/// app has one of each screen, so while the dock shows it the tab says where
/// it went. `host` is the tab, as the docked screen names it.
public struct RipulDockedScreenSlot<Content: View>: View {
    private let host: String
    private let content: Content
    @Environment(\.ripulWindowContext) private var workspace

    public init(host: String, @ViewBuilder content: () -> Content) {
        self.host = host
        self.content = content()
    }

    public var body: some View {
        if let dock = workspace?.previewDock {
            Slot(dock: dock, host: host, content: content)
        } else {
            content
        }
    }

    /// Hears only whether this tab's screen is docked, and on which side: every
    /// tab has one of these, and a tab held out of sight must not be redrawn
    /// for the dock's other news (a panel dragged over its edge, a notice).
    private struct Slot: View {
        let dock: PreviewDockState
        let host: String
        let content: Content
        @State private var docked: Docked?

        struct Docked: Equatable {
            let title: String
            let side: PreviewDockState.Side
        }

        init(dock: PreviewDockState, host: String, content: Content) {
            self.dock = dock
            self.host = host
            self.content = content
            // As it is now, so a tab first opened while its screen is docked
            // never draws the screen for a frame.
            _docked = State(initialValue: dock.shown?.screen.flatMap {
                $0.host == host ? Docked(title: $0.title, side: dock.side) : nil
            })
        }

        var body: some View {
            Group {
                if let docked {
                    DockedElsewhereNote(title: "\(docked.title) is docked on the \(docked.side.rawValue)", side: docked.side,
                                        identifier: "PreviewDock.screenSlot") { dock.undock() }
                } else {
                    content
                }
            }
            .onReceive(dock.$shown.combineLatest(dock.$side).map { [host] shown, side in
                shown?.screen.flatMap { $0.host == host ? Docked(title: $0.title, side: side) : nil }
            }.removeDuplicates()) { next in
                if docked != next { docked = next }
            }
        }
    }
}

/// What a tab shows while its screen is in the dock: where it went, and a way
/// to have it back here.
private struct DockedElsewhereNote: View {
    let title: String
    let side: PreviewDockState.Side
    let identifier: String
    let undock: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: side == .right ? "rectangle.righthalf.inset.filled" : "rectangle.lefthalf.inset.filled")
                .font(.ripulIcon(size: 40, weight: .regular))
                .foregroundStyle(.ripul(.textSecondary))
            Text(title)
                .font(.ripul(.headline))
                .foregroundStyle(.ripul(.text))
                .multilineTextAlignment(.center)
            Button("Undock", action: undock)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(identifier).undock")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ripul(.canvas))
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - The docked simulator

/// The docked simulator, live: the host's full-screen viewer with its controls,
/// whose restore button undocks.
@available(iOS 26.0, *)
struct DockedSimulatorPane: View {
    let bridge: AgentBridge
    @ObservedObject var dock: PreviewDockState
    let simulator: PreviewDockState.Simulator

    var body: some View {
        // Docked, the simulator is full screen on its side, as the Simulators
        // screen's full screen is: the whole pane, under the status bar's band
        // and the Duo's strip at the right edge, with the status bar hidden
        // (Peter, 1 November 2026: "take over the right hand bar"). The home
        // indicator stays, and the first swipe from an edge goes to the
        // simulator, as there; on the app's side too, while it is docked.
        ZStack {
            Color.ripul(system: .black)
            if let presentation = bridge.simulatorFullScreenPresentation {
                presentation(simulator.udid, simulator.machineId, controls)
                    .id("\(simulator.machineId)-\(simulator.udid)-\(dock.generation)")
            } else if let live = bridge.simulatorFullScreenContent ?? bridge.simulatorLiveContent {
                live(simulator.udid, simulator.machineId)
                    .id("\(simulator.machineId)-\(simulator.udid)-\(dock.generation)")
                    .overlay(alignment: .topTrailing) { fallbackControls }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.visible)
        .defersSystemGestures(on: .all)
        .overlay(alignment: .bottom) {
            if let notice = dock.notice {
                Text(notice).ripulText().font(.ripul(.caption)).multilineTextAlignment(.center) // theme-mapping: a control's notice, as the panel's
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.clear, in: Capsule())
                    .padding(16)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("PreviewDock.notice")
            }
        }
    }

    private var controls: SimulatorFullScreenControls {
        let hardware = simulator.hardwareControls + (simulator.foldable ? SimulatorPreviewState.foldControls : [])
        let actions = hardware.map { item in
            SimulatorFullScreenControls.Action(id: item.action, title: item.title, symbol: item.symbol,
                perform: { [dock] in Task { await dock.control(item.action) } })
        }
        return SimulatorFullScreenControls(screenSize: dock.screenSize(of: .simulator(simulator)) ?? simulator.screenSize,
                                           actions: actions, simulatorMenu: nil,
                                           restore: { [dock] in dock.undock() },
                                           docked: true, close: { [dock] in dock.close() },
                                           hidesToolbarWithoutRoom: true,
                                           onScreenSize: { [dock] size in dock.simulatorScreenChanged(size) })
    }

    /// Without the host's own controls (a host that gives only the video).
    private var fallbackControls: some View {
        HStack(spacing: 8) {
            button("pip.enter", label: "Undock simulator", id: "undock") { dock.undock() }
            button("xmark", label: "Close simulator", id: "close") { dock.close() }
        }
        .padding(12)
    }

    private func button(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ripulIcon(size: 15, weight: .semibold))
                .foregroundStyle(.ripul(.text))
                .frame(width: 40, height: 40)
                .glassEffect(.clear.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .uiKitIdentifier("PreviewDock.\(id)")
    }
}

// MARK: - The bridge's part

extension AgentBridge {
    /// This window's chat panels can dock into `dock`: called as they appear.
    func joinPreviewDock(_ dock: PreviewDockState?) {
        guard previewDock !== dock else { return }
        previewDock = dock
        simulatorPreview.dock = dock
        // A simulator floated from the Simulators screen docks as a chat's does
        // (Peter, 3 November 2026).
        floatedSimulatorPreview.dock = dock
        browserPreview.dock = dock
        guard let dock else { return }
        dock.invoke = { [weak self] machineId, method, args, chatId in
            guard let self else { return ["success": false] }
            return await self.mirrorInvoke(machineId: machineId, capability: "screenWindows", method: method, args: args, chatId: chatId)
        }
        dock.content = { [weak self, weak dock] surface in
            guard let self, let dock else { return AnyView(EmptyView()) }
            return self.previewDockContent(surface, dock: dock)
        }
        dock.onRelease = { [weak self] surface, reopen in
            guard let self else { return }
            switch surface {
            case .simulator(let simulator) where simulator.chatId == SimulatorPreviewState.floatedChatId:
                // Back to its own panel, open; closed, gone, as that panel's Close takes it.
                if reopen {
                    if #available(iOS 26.0, *) { self.floatedSimulatorPreview.returnFromDock(simulator, open: true) }
                } else {
                    self.floatedSimulatorPreview.close()
                }
            case .simulator(let simulator):
                if #available(iOS 26.0, *) { self.simulatorPreview.returnFromDock(simulator, open: reopen) }
            case .browser(let tabId):
                self.browserPreview.returnFromDock(tabId: tabId, chatId: self.currentSourceChatId, open: reopen)
            case .screen, .picker:
                // The host's own: they leave through `onScreenRelease`.
                break
            }
        }
    }

    private func previewDockContent(_ surface: PreviewDockState.Surface, dock: PreviewDockState) -> AnyView {
        switch surface {
        case .simulator(let simulator):
            if #available(iOS 26.0, *) {
                return AnyView(DockedSimulatorPane(bridge: self, dock: dock, simulator: simulator))
            }
            return AnyView(EmptyView())
        case .browser(let tabId):
            return browserDockContent?(tabId) ?? AnyView(EmptyView())
        case .screen, .picker:
            // Drawn by the host (`screenContent`).
            return AnyView(EmptyView())
        }
    }

    /// The browser is in the dock: an agent's tab shows there, not in a panel or the Browser tab.
    public var previewDockShowsBrowser: Bool { previewDock?.shown?.showsBrowser == true }
}
#endif
