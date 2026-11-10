import SwiftUI

extension View {
    /// Inserts app-owned top chrome. In a Catalyst column beside the window
    /// controls, apply the top-edge policy inside NavigationStack as well:
    /// navigation containers can reintroduce an inset beneath the host shell.
    public func ripulTopBarInset<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        modifier(RipulTopBarInsetModifier(bar: content()))
    }
}

/// Shared geometry for `GlassTopBar` and screens that reserve space for it.
public enum GlassTopBarLayout {
    /// Extra space between the inner controls/lozenge and the outer frosted bar's edge.
    public static let outerBarPadding: CGFloat = 5
    /// Compact height of the outer frosted capsule (44pt controls + 5pt top and bottom padding,
    /// matching the 54pt height of the iPhone Duo's status bar background alongside it).
    public static let outerBarHeight: CGFloat = 44 + outerBarPadding * 2
    /// Total height below `topChrome.top` for a compact `GlassTopBar` (4pt top gutter + 44pt controls
    /// + 5pt bottom outer-bar overhang; the 5pt top overhang extends above the 44pt row).
    public static let compactHeight: CGFloat = 48 + outerBarPadding
    /// Content reservation below a floating `GlassTopBar` (compactHeight + 4pt bottom gap).
    public static let contentReservation: CGFloat = compactHeight + 4
}

private struct RipulTopBarInsetModifier<Bar: View>: ViewModifier {
    let bar: Bar
    #if targetEnvironment(macCatalyst)
    @Environment(\.ripulTopBarSafeAreaTop) private var topOverride
    #elseif os(iOS)
    @State private var topChrome = WindowTopChromeClearance()
    /// Window-space top of the screen as last laid out.
    @State private var frameTop: CGFloat?
    /// The bar sits in the band beside a camera (see `updateBand`).
    @State private var inBand = false
    /// The screen did not reach the window's top when it ran over the band;
    /// it stays out until the window changes.
    @State private var bandRefused = false
    /// GlassTopBar's 4pt gutter and 54pt outer bar, until measured.
    @State private var barHeight: CGFloat = GlassTopBarLayout.compactHeight
    #endif

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        if topOverride == 0 {
            content
                .safeAreaInset(edge: .top) { bar }
                .ignoresSafeArea(.container, edges: .top)
        } else {
            content.safeAreaInset(edge: .top) { bar }
        }
        #elseif os(iOS)
        // Beside the open Duo's camera the bar joins the band, level with the
        // status items, as the chat's does (`WindowTopChromeLayout`). Devices,
        // Files, Trainyard and the rest otherwise sat a row lower, under the
        // status items (Peter, 1 November 2026). The screen then runs to the
        // window's top and the inset carries the bar down to its row, so the
        // bar is laid out where it is drawn, and the content still starts at
        // the rectangular inset.
        content
            .safeAreaInset(edge: .top) {
                bar
                    .topChromeExclusion(inBand ? topChrome : WindowTopChromeClearance())
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                    .padding(.top, inBand ? topChrome.top : 0)
                    .padding(.bottom, inBand ? max(0, topChrome.safeTop - topChrome.top - barHeight) : 0)
            }
            .ignoresSafeArea(.container, edges: inBand ? .top : [])
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                frameTop = $0
                updateBand()
            }
            .background(WindowTopChrome {
                topChrome = $0
                bandRefused = false
                updateBand()
            })
        #else
        content.safeAreaInset(edge: .top) { bar }
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Into the band when the screen's top is the window's rectangular inset:
    /// a screen lower in the window (a sheet, a column under a bar of its own)
    /// keeps its bar where it is. In the band while the screen, run over it,
    /// starts at the window's top.
    private func updateBand() {
        guard let frameTop, topChrome.top < topChrome.safeTop, !bandRefused else {
            inBand = false
            return
        }
        if inBand {
            if abs(frameTop) >= 1 {
                inBand = false
                bandRefused = true
            }
        } else {
            inBand = abs(frameTop - topChrome.safeTop) < 1
        }
    }
    #endif
}

// MARK: - Scope

/// What a screen is scoped to, shown under the title in the lozenge: its icon
/// and name, and a tap on the lozenge that switches between the options when
/// there is another to choose. The Mac a machine screen is looking at is the
/// case in point (`machines(_:current:cache:detail:pick:)`).
public struct GlassTopBarScope {
    public struct Option: Identifiable {
        public let id: String
        public let title: String
        /// An SF Symbol.
        public let icon: String

        public init(id: String, title: String, icon: String) {
            self.id = id
            self.title = title
            self.icon = icon
        }
    }

    /// Everything the screen could be scoped to, the current one included.
    public var options: [Option]
    public var current: Option
    /// Shown after the current option's name (the Console's working directory).
    public var detail: String?
    /// Called with an option other than the current one.
    public var select: (Option) -> Void
    /// The current option IS what the screen is showing (a repo, on that
    /// repo's screen), so its name is the lozenge's title and `detail` the
    /// line under it. Otherwise the screen's own title stays and the scope
    /// reads under it (the Mac a list belongs to).
    public var currentIsTitle = false
    /// Several options shown at once, each ticked or not, in place of one
    /// chosen (`select`): Trainyard showing the yards of the Macs ticked.
    public var ticks: Ticks?

    /// The options ticked, and a tap that ticks or unticks one. The popover
    /// stays open for the next tick, and `current` is what the lozenge shows
    /// for those ticked, which the screen names.
    public struct Ticks {
        public var ticked: Set<String>
        public var toggle: (Option) -> Void

        public init(ticked: Set<String>, toggle: @escaping (Option) -> Void) {
            self.ticked = ticked
            self.toggle = toggle
        }
    }

    public init(options: [Option], current: Option, detail: String? = nil, currentIsTitle: Bool = false,
                select: @escaping (Option) -> Void) {
        self.options = options
        self.current = current
        self.detail = detail
        self.currentIsTitle = currentIsTitle
        self.select = select
    }

    /// The Macs a screen can use and the one it is looking at, each wearing
    /// the icon the user gave it. Nil when there is no Mac, so the lozenge
    /// shows the title alone.
    public static func machines(_ machines: [RemoteMachine], current: RemoteMachine?, cache: RipulSessionCache,
                                detail: String? = nil, pick: @escaping (RemoteMachine) -> Void) -> GlassTopBarScope? {
        guard let current else { return nil }
        func option(_ machine: RemoteMachine) -> Option {
            Option(id: machine.machineId, title: machine.displayName,
                   icon: machine.icon(cache: cache) ?? machine.defaultIconName)
        }
        return GlassTopBarScope(options: machines.map(option), current: option(current), detail: detail) { picked in
            if let machine = machines.first(where: { $0.machineId == picked.id }) { pick(machine) }
        }
    }
}

/// The options of a `GlassTopBarScope`, in the popover the lozenge opens.
private struct GlassTopBarScopePicker: View {
    let scope: GlassTopBarScope
    let dismiss: () -> Void

    /// More options than this and the list scrolls, so a long one (every
    /// repo on a Mac) still fits a phone.
    private static var rowsBeforeScrolling: Int { 9 }

    var body: some View {
        if scope.options.count > Self.rowsBeforeScrolling {
            ScrollView { rows }
                .frame(height: CGFloat(Self.rowsBeforeScrolling) * 44 + 22)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(scope.options.enumerated()), id: \.element.id) { index, option in
                let ticked = scope.ticks?.ticked.contains(option.id) ?? (option.id == scope.current.id)
                if index > 0 { Divider() }
                Button {
                    if let ticks = scope.ticks {
                        ticks.toggle(option)
                    } else {
                        dismiss()
                        if option.id != scope.current.id { scope.select(option) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.icon).frame(width: 24)
                        Text(option.title).ripulText().lineLimit(1)
                        Spacer(minLength: 12)
                        Image(systemName: "checkmark").opacity(ticked ? 1 : 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(ticked ? .isSelected : [])
                .uiKitIdentifier("GlassTopBar.scope.option")
            }
        }
        .frame(minWidth: 230)
        #if os(iOS)
        .presentationCompactAdaptation(.popover)
        #endif
    }
}

/// Round control disc worn by buttons inside a `GlassTopBar` title lozenge
/// (the scope dropdown chevron and the screen help question mark).
///
/// Sized at 28×28pt inside the 44pt lozenge so its 14pt radius plus the 8pt
/// top, bottom and trailing margins sit concentrically inside the lozenge's
/// 22pt capsule end-cap. Uses a crisp surface fill and hairline ring rather
/// than nested glass so both buttons read as distinct, easy-to-hit round
/// controls against the lozenge's own glass material.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassTopBarLozengeDisc: View {
    public let systemImage: String
    public var isActive: Bool

    public init(systemImage: String, isActive: Bool = false) {
        self.systemImage = systemImage
        self.isActive = isActive
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.ripulIcon(size: 12, weight: .bold))
            .foregroundStyle(.ripul(.text))
            .frame(width: 28, height: 28)
            .background(
                Color.ripul(.text).opacity(isActive ? 0.18 : 0.10),
                in: Circle()
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.ripul(.text).opacity(isActive ? 0.28 : 0.16), lineWidth: 0.75)
            }
            .contentShape(Circle())
    }
}

// MARK: - Glass Top Bar

/// The one top bar. Every iPhone screen wears this — there are no forks.
///
/// ## Layout contract
/// A two-layer `ZStack`: the title lozenge is **screen-centred**, and the
/// buttons ride an edge layer above it. This is why it is a ZStack and not the
/// obvious `HStack` — with an HStack the lozenge drifts left or right as buttons
/// appear and disappear, so the title visibly slides when a screen gains a
/// scroll-up button. Centring it and insetting symmetrically pins it.
///
/// ## Slots
/// The bar owns layout, glass, the morph namespace and the switcher gesture.
/// Call sites override *content* only, via `leading` / `center` /
/// `trailingAccessory`. Anything that needed a fork before is a slot now:
/// - the Agents|Plans segmented control is a `center` override,
/// - the agent screen's burger↔chevron opacity crossfade is a `leading` override,
/// - a screen's extra top-bar button is a `trailingAccessory`.
///
/// ## Glass morph
/// The namespace is internal and per-instance. Slot content that wants to morph
/// across a state change should carry `GlassEffectIDModifier`, which the default
/// lozenge and buttons already do.
///
/// ## Screen switcher
/// Swiping DOWN on the lozenge summons the Safari-style overview. The gesture is
/// here, once, so every screen inherits it — see `ScreenSwitcherStore`.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassTopBar<MenuContent: View, CenterContent: View>: View {
    let title: String
    var subtitle: String? = nil
    /// What the screen is scoped to. Takes the subtitle's place in the default
    /// lozenge, and makes the lozenge switch scope on a tap, unless the screen
    /// already uses that tap (`onTapTitle`) or draws its own centre.
    var scope: GlassTopBarScope? = nil
    var leadingIcon: String = "chevron.left"
    var showLeading: Bool = true
    var screenKey: String? = nil
    var screenTip: ((String) -> AnyView)? = nil
    var onLeading: (() -> Void)? = nil
    @ViewBuilder var menu: () -> MenuContent
    /// A single always-visible action, rendered as a glass button beside the
    /// overflow menu. Use this for the screen's primary verb: an action buried
    /// behind "…" reads as absent, which is precisely the bug this fixes.
    var actionIcon: String?
    var onAction: (() -> Void)?

    /// Full override of the centre lozenge's *content*. The pill, glass, inset,
    /// centring and gestures still come from the bar.
    /// NOT `(() -> AnyView)?`. Type erasure stops SwiftUI retaining the slot's
    /// modifier nodes across updates, so an `.animation(_:value:)` inside the
    /// slot never sees its value change and the content swaps with no
    /// animation at all — which is exactly how the chat title lozenge's morph
    /// died. Keep this generic.
    var center: (() -> CenterContent)? = nil
    /// Set false when the centre content brings its own glass — a segmented
    /// picker already draws a Liquid Glass track, and nesting it inside the
    /// bar's capsule stacks two materials and muddies both.
    ///
    /// This is also how a screen gets a *Liquid Glass morph* out of the centre
    /// slot: `glassEffectID("title")` is applied either way, so flipping this
    /// between states makes the two states two DIFFERENT glass shapes sharing
    /// one id inside the bar's `GlassEffectContainer` — which is what the
    /// container morphs fluidly between. A single glass shape that merely
    /// resizes gets no morph; it just changes size.
    var centerInPill: Bool = true
    /// Set true when the centre slot manages its OWN glass shape *and* its own
    /// `glassEffectID` — the bar then applies neither, and adds no padding.
    ///
    /// Required for a Liquid Glass morph in the centre slot. The container
    /// morphs when a glass id LEAVES and RE-ENTERS it; if the bar owns the id,
    /// it sits on a wrapper that never changes while the content swaps
    /// underneath, so nothing ever morphs and the swap reads as a snap. The
    /// browser chrome's address pill is the reference implementation.
    var centerOwnsGlass: Bool = false
    /// Full override of the leading button. Use when the default symbol-replace
    /// morph is wrong — e.g. when the icon change must ride another animation's
    /// timeline rather than its own.
    var leading: (() -> AnyView)? = nil
    /// Extra glass buttons between the centre and the overflow menu.
    var trailingAccessory: (() -> AnyView)? = nil
    /// Extra glass buttons OUTSIDE the overflow menu, at the bar's trailing
    /// edge. Host chrome lives here (e.g. WAC's minimise button), which is why
    /// it is a separate slot: it belongs to the embedder, not the screen, and
    /// must stay outboard of the screen's own ellipsis.
    var trailingOuter: (() -> AnyView)? = nil
    /// Fired as the overflow menu is tapped, for call sites that want to
    /// refresh the data the menu is about to render.
    var onMenuOpen: (() -> Void)? = nil
    /// Override the symmetric inset that keeps the lozenge clear of the buttons.
    /// Defaults to a count-derived value; pass this when a screen's trailing
    /// cluster is wider than the bar can infer.
    var centerInset: CGFloat? = nil
    /// Opt a screen out of the swipe-down overview (e.g. a modal detail screen
    /// that is not itself a switcher destination).
    var switcherEnabled: Bool = true
    /// Suppress the overflow button when the menu is empty at RUNTIME. The
    /// `MenuContent == EmptyView` check below only catches emptiness that is
    /// visible in the type, which a menu chosen by an `if` at render time is not.
    var showsMenu: Bool = true
    /// Double-tap on the lozenge. Used by the agent screen for Inspector.
    var onDoubleTapTitle: (() -> Void)? = nil
    /// Single tap on the lozenge. Used by the agent screen to toggle the
    /// expanded chat-title panel. Coexists with `onDoubleTapTitle`: SwiftUI
    /// resolves a lone tap as the single tap and a paired tap as the double,
    /// so the single tap carries the ~0.25s recognition delay.
    var onTapTitle: (() -> Void)? = nil
    /// Flattened string of everything the overflow menu renders. When set, the
    /// menu is hosted behind `.equatable()` keyed on this value, so parent
    /// re-renders with an unchanged key cannot re-resolve it — an OPEN menu
    /// visibly flashes on every re-resolution, even a content-identical one.
    /// nil (the default) keeps per-parent-eval re-resolution. Call sites that
    /// pass a key MUST include every state input their menu items read; a
    /// missed input shows its stale item until any included input changes.
    var menuKey: String? = nil

    @Namespace private var topBarNS
    @State private var showingScope = false
    @Environment(\.ripulRailGutters) private var railGutters
    @Environment(\.ripulRootBack) private var rootBack

    public init(
        title: String,
        subtitle: String? = nil,
        scope: GlassTopBarScope? = nil,
        leadingIcon: String = "chevron.left",
        showLeading: Bool = true,
        screenKey: String? = nil,
        screenTip: ((String) -> AnyView)? = nil,
        onLeading: (() -> Void)? = nil,
        actionIcon: String? = nil,
        onAction: (() -> Void)? = nil,
        center: (() -> CenterContent)? = nil,
        centerInPill: Bool = true,
        centerOwnsGlass: Bool = false,
        leading: (() -> AnyView)? = nil,
        trailingAccessory: (() -> AnyView)? = nil,
        trailingOuter: (() -> AnyView)? = nil,
        onMenuOpen: (() -> Void)? = nil,
        centerInset: CGFloat? = nil,
        switcherEnabled: Bool = true,
        showsMenu: Bool = true,
        onDoubleTapTitle: (() -> Void)? = nil,
        onTapTitle: (() -> Void)? = nil,
        menuKey: String? = nil,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.scope = scope
        self.leadingIcon = leadingIcon
        self.showLeading = showLeading
        self.screenKey = screenKey
        self.screenTip = screenTip
        self.onLeading = onLeading
        self.actionIcon = actionIcon
        self.onAction = onAction
        self.center = center
        self.centerInPill = centerInPill
        self.centerOwnsGlass = centerOwnsGlass
        self.leading = leading
        self.trailingAccessory = trailingAccessory
        self.trailingOuter = trailingOuter
        self.onMenuOpen = onMenuOpen
        self.centerInset = centerInset
        self.switcherEnabled = switcherEnabled
        self.showsMenu = showsMenu
        self.onDoubleTapTitle = onDoubleTapTitle
        self.onTapTitle = onTapTitle
        self.menuKey = menuKey
        self.menu = menu
    }

    /// A screen with no menu items would otherwise get an ellipsis that opens an
    /// empty sheet — worse than no affordance at all.
    private var hasMenu: Bool { showsMenu && MenuContent.self != EmptyView.self }
    private var hasLeading: Bool { leading != nil || (showLeading && onLeading != nil) || backsOut != nil }

    /// Where the sidebar button goes back to instead: a root opened from
    /// another screen (`RipulRootBack`). Only a sidebar button is replaced; a
    /// screen's own back or close keeps its action.
    private var backsOut: RipulRootBack? {
        guard leading == nil, onLeading != nil, leadingIcon == RipulRootBack.sidebarSymbol else { return nil }
        return rootBack
    }

    /// Symmetric, so the lozenge stays screen-centred rather than centred in the
    /// leftover space. Sized to the WIDER cluster: one 44pt button plus its 12pt
    /// gutter is 56, each additional button 52. The outer frosted bar already
    /// supplies `outerBarPadding` on all sides, so a side with no buttons needs 0 here.
    private var resolvedInset: CGFloat {
        if let centerInset { return centerInset }
        let leadingWidth: CGFloat = hasLeading ? 56 : 0
        var trailingWidth: CGFloat = 0
        if hasMenu { trailingWidth = 56 }
        if onAction != nil, actionIcon != nil { trailingWidth += (trailingWidth == 0 ? 56 : 52) }
        if trailingAccessory != nil { trailingWidth += (trailingWidth == 0 ? 56 : 52) }
        return max(leadingWidth, trailingWidth)
    }

    public var body: some View {
        // .top: the edge buttons pin to the bar's top. Identical to centre
        // alignment for every compact bar (both layers are 44pt), and when a
        // screen's centre lozenge grows tall — the agent screen's expanded
        // title — the buttons stay on the top row instead of floating at the
        // pill's vertical centre.
        ZStack(alignment: .top) {
            centerLayer
            edgeLayer
                #if targetEnvironment(macCatalyst)
                // Each control already has a glass label; Mac idiom's
                // automatic bezel would add a second rectangular surface.
                .buttonStyle(.plain)
                #endif
        }
        .padding(.horizontal, GlassTopBarLayout.outerBarPadding)
        .background {
            GlassTopBarOuterBackground()
                .padding(.vertical, -GlassTopBarLayout.outerBarPadding)
        }
        // A screen whose content gives its gutter way beside the system's tab
        // rail asks the bar to do the same (`ripulRailGutters`).
        .modifier(RailGutters(leading: 12, trailing: 12, active: railGutters))
        .padding(.top, 4)
        // The switcher gestures belong to the WHOLE bar row, not just the
        // lozenge. The lozenge is a small target in the middle of a wide strip
        // of chrome, and a swipe that starts an inch to either side of it is
        // plainly the same intent. `contentShape` is what makes the row's empty
        // space draggable at all — without it only the drawn pixels respond.
        .contentShape(Rectangle())
        // iOS only — the gesture is built on UIKit recognisers, so the type
        // does not exist on macOS. The composer's mirrored mount point in
        // AgentView is gated the same way.
        #if os(iOS)
        .modifier(ScreenSwitcherPullModifier(
            enabled: switcherEnabled,
            direction: .down,
            allowsHorizontal: true,
            // Centre content that brings its own glass also brings its own
            // horizontal gestures — a segmented control moves its selection on
            // a horizontal drag, so a swipe across it would change the segment
            // AND slide the strip. Running the row's drag at high priority
            // settles that in the row's favour. Taps are unaffected: the drag
            // needs 8pt of movement before it recognises, and a tap has none —
            // so segments still select, only the thumb-drag nicety is given up.
            highPriority: !centerInPill
        ))
        #endif
    }

    // MARK: - Centre

    private var hasScreenTip: Bool {
        screenKey != nil && screenTip != nil
    }

    private var hasLozengeButtons: Bool {
        center == nil && (switchesScope || hasScreenTip)
    }

    @ViewBuilder
    private var centerLayer: some View {
        Group {
            if let center {
                center()
                    .modifier(TitleTapGestures(onTap: lozengeTap, onDoubleTap: onDoubleTapTitle))
            } else {
                defaultTitleContent
            }
        }
        .padding(.leading, centerInPill && !centerOwnsGlass ? 12 : 0)
        .padding(.trailing, centerInPill && !centerOwnsGlass ? (hasLozengeButtons ? 8 : 12) : 0)
        .frame(minHeight: 44)
        .modifier(ConditionalGlassPill(active: centerInPill && !centerOwnsGlass))
        .modifier(ConditionalGlassEffectID(
            active: !centerOwnsGlass,
            id: "title",
            namespace: topBarNS
        ))
        // Before the inset, so the popover points at the pill.
        .popover(isPresented: $showingScope, arrowEdge: .top) {
            if let scope {
                GlassTopBarScopePicker(scope: scope) { showingScope = false }
            }
        }
        .padding(.horizontal, resolvedInset)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
            }
        )
        .uiKitIdentifier("GlassTopBar.titleLozenge")
    }

    /// A tap on the lozenge switches scope: there is another option to switch
    /// to, the default lozenge is the one showing it, and the screen has not
    /// taken the tap for itself. A tap gesture rather than a `Menu`, which
    /// opens on touch-down and would take the swipe that summons the switcher.
    private var switchesScope: Bool {
        guard let scope, center == nil, onTapTitle == nil else { return false }
        if scope.ticks != nil { return scope.options.count > 1 }
        return scope.options.contains { $0.id != scope.current.id }
    }

    private var lozengeTap: (() -> Void)? {
        if let onTapTitle { return onTapTitle }
        return switchesScope ? { showingScope = true } : nil
    }

    @ViewBuilder
    private var defaultTitleContent: some View {
        HStack(spacing: switchesScope && hasScreenTip ? 6 : 8) {
            HStack(spacing: 8) {
                if let scope {
                    // Beside both lines and drawn as the Machines panel draws a
                    // Mac's icon. As a caption-sized grey glyph inside the
                    // subtitle it was there, and nobody saw it.
                    Image(systemName: scope.current.icon)
                        .font(.ripulIcon(size: 16))
                        .foregroundStyle(.ripul(.info))
                        .contentTransition(.symbolEffect(.replace))
                        .uiKitIdentifier("GlassTopBar.scope.icon")
                }
                VStack(alignment: scope == nil && !hasLozengeButtons ? .center : .leading, spacing: 1) {
                    Text(scope?.currentIsTitle == true ? scope?.current.title ?? title : title)
                        .font(.ripul(.caption))
                        .fontWeight(.semibold)
                        .foregroundColor(.ripul(.text))
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                    if let scope {
                        Text(scope.currentIsTitle
                             ? scope.detail ?? ""
                             : scope.detail.map { scope.current.title + " · " + $0 } ?? scope.current.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.interpolate)
                            .font(.ripul(.caption2))
                            .foregroundStyle(.ripul(.textSecondary))
                            .uiKitIdentifier("GlassTopBar.scope")
                    } else if let subtitle {
                        Text(subtitle)
                            .font(.ripul(.caption2))
                            .foregroundStyle(.ripul(.textSecondary))
                            .contentTransition(.interpolate)
                    }
                }
                if switchesScope {
                    GlassTopBarLozengeDisc(systemImage: "chevron.down", isActive: showingScope)
                        .accessibilityLabel("Switch scope")
                        .uiKitIdentifier("GlassTopBar.scope.button")
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .modifier(TitleTapGestures(onTap: lozengeTap, onDoubleTap: onDoubleTapTitle))

            if let key = screenKey, let screenTip {
                screenTip(key)
            }
        }
    }

    // MARK: - Edges

    @ViewBuilder
    private var edgeLayer: some View {
        HStack(spacing: 8) {
            if let leading {
                // The morph id is applied HERE rather than by the call site,
                // because the namespace is per-bar and internal — that is what
                // lets a slot override the button's look without losing its
                // place in the glass container.
                leading()
                    .modifier(GlassEffectIDModifier(id: "leading", namespace: topBarNS))
            } else if let onLeading, showLeading || backsOut != nil {
                // A root opened from another screen goes back to it, sidebar
                // pinned or not (see `RipulRootBack`).
                let back = backsOut
                Button { if let back { back.handler.goBack() } else { onLeading() } } label: {
                    Image(systemName: back == nil ? leadingIcon : "chevron.left")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.ripulIcon(size: 18, weight: .semibold))
                        .foregroundStyle(.ripul(.text))
                        .frame(width: 44, height: 44)
                        .modifier(GlassCircleModifier(glassStyle: "clear"))
                        .modifier(GlassEffectIDModifier(id: "leading", namespace: topBarNS))
                }
                .modifier(BackLabel(title: back?.title))
                .uiKitIdentifier(back == nil ? "GlassTopBar.leadingButton" : "GlassTopBar.rootBack")
            }

            Spacer()

            if let trailingAccessory {
                trailingAccessory()
            }

            if let actionIcon, let onAction {
                GlassButton(icon: actionIcon, action: onAction)
                    .uiKitIdentifier("GlassTopBar.actionButton")
            }

            if hasMenu {
                TrailingMenuHost(
                    key: menuKey,
                    namespace: topBarNS,
                    onMenuOpen: onMenuOpen,
                    menu: menu
                )
                .equatable()
            }

            if let trailingOuter {
                trailingOuter()
                    .modifier(GlassEffectIDModifier(id: "accessory", namespace: topBarNS))
            }
        }
    }
}

// MARK: - Trailing menu host

/// The overflow `Menu`, isolated so parent re-renders can't touch it while a
/// key is set. SwiftUI re-resolves a `Menu`'s content on every body eval of
/// its host, and UIKit visibly flashes an OPEN menu on every re-resolution —
/// even one that resolves to identical items (proven on the Dock screen,
/// whose menu has no live content at all). With a key, `==` skips body evals
/// until the key changes; with nil the two sides never compare equal and
/// behaviour is exactly the old always-re-resolve.
@available(iOS 15.0, macOS 13.0, *)
private struct TrailingMenuHost<MenuContent: View>: View, Equatable {
    @Environment(\.ripulWindowContext) private var workspace
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    let key: String?
    let namespace: Namespace.ID
    let onMenuOpen: (() -> Void)?
    @ViewBuilder var menu: () -> MenuContent

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard let l = lhs.key, let r = rhs.key else { return false }
        return l == r
    }

    var body: some View {
        Menu { MenuIcons {
            if supportsMultipleWindows, let open = workspace?.openWindow {
                Button("New Window", systemImage: "plus.rectangle.on.rectangle") { open(nil) }
                    .accessibilityIdentifier("Workspace.newWindow")
                Divider()
            }
            menu()
        }} label: {
            Image(systemName: "ellipsis")
                .font(.ripulIcon(size: 18, weight: .semibold))
                .foregroundStyle(.ripul(.text))
                .frame(width: 44, height: 44)
                .modifier(GlassCircleModifier(glassStyle: "clear"))
                .modifier(GlassEffectIDModifier(id: "trailing", namespace: namespace))
        }
        #if targetEnvironment(macCatalyst)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        #endif
        .modifier(MenuOpenModifier(action: onMenuOpen))
        .uiKitIdentifier("GlassTopBar.trailingMenu")
    }
}

// MARK: - Gesture modifiers

/// A `simultaneousGesture` on the Menu label, so the call site can refresh what
/// the menu is about to show without swallowing the tap that opens it.
@available(iOS 15.0, macOS 13.0, *)
private struct MenuOpenModifier: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.simultaneousGesture(TapGesture().onEnded { action() })
        } else {
            content
        }
    }
}

/// Applies the capsule only when the centre content isn't already glass.
@available(iOS 15.0, macOS 13.0, *)
/// `glassEffectID` is conditional for the same ViewBuilder-typing reason as the
/// pill: applying it inside an `if` would change the view's type.
@available(iOS 15.0, macOS 13.0, *)
private struct ConditionalGlassEffectID: ViewModifier {
    let active: Bool
    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if active {
            content.modifier(GlassEffectIDModifier(id: id, namespace: namespace))
        } else {
            content
        }
    }
}

@available(iOS 15.0, macOS 13.0, *)
private struct ConditionalGlassPill: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.modifier(GlassPillModifier(glassStyle: "clear"))
        } else {
            content
        }
    }
}

/// Fixed optical blur parameters for `GlassTopBarOuterBackground` (chosen in UX
/// Settings on 6 November 2026: Capsule Bar Blur ON, Scroll-Edge Blur OFF, Clear
/// Glass Controls ON, Blur Radius 5.8 pt / 23%, Tint 0%).
public enum TopBarFrost {
    /// Chosen blur fraction (23% of 25pt = 5.75pt / 5.8pt Gaussian blur radius).
    public static let standard = 0.23
    /// Chosen tint opacity (0% -> pure untinted optical blur).
    public static let standardTint = 0.0
    /// Maximum Gaussian blur radius scale in points.
    public static let maxBlurRadius: CGFloat = 25.0

    public static func blurRadius(_ frost: Double) -> CGFloat {
        CGFloat(min(max(frost, 0), 1)) * maxBlurRadius
    }
}

/// Translucent 54pt outer blur capsule wrapping the bar's controls and title lozenge,
/// matching the iPhone Duo status bar's height and vertical alignment (`y = 21..75`
/// around the `44pt` controls at `y = 26..70`). Uses a true `CABackdropLayer` Gaussian
/// blur at `5.8 pt` (`23%`) with `0%` tint so content scrolling underneath is smoothly
/// out of focus with no milky wash.
@available(iOS 15.0, macOS 13.0, *)
public struct GlassTopBarOuterBackground: View {
    public init() {}

    public var body: some View {
        VariableBackdropBlurView(
            blurRadius: TopBarFrost.blurRadius(TopBarFrost.standard),
            tintOpacity: TopBarFrost.standardTint,
            scrollEdgeEnabled: false
        )
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .uiKitIdentifier("GlassTopBar.outerBar")
    }
}

#if os(iOS)
private struct VariableBackdropBlurView: UIViewRepresentable {
    var blurRadius: CGFloat
    var tintOpacity: Double
    var scrollEdgeEnabled: Bool

    func makeUIView(context: Context) -> BackdropBlurEffectView {
        let view = BackdropBlurEffectView()
        view.blurRadius = blurRadius
        view.tintOpacity = tintOpacity
        view.scrollEdgeEnabled = scrollEdgeEnabled
        return view
    }

    func updateUIView(_ uiView: BackdropBlurEffectView, context: Context) {
        uiView.blurRadius = blurRadius
        uiView.tintOpacity = tintOpacity
        uiView.scrollEdgeEnabled = scrollEdgeEnabled
    }
}

/// Drives the `CABackdropLayer` Gaussian blur radius (`0pt`–`25pt`) directly on a
/// `UIVisualEffectView` while scaling or hiding its `_UIVisualEffectSubview` tint overlays.
private final class BackdropBlurEffectView: UIVisualEffectView {
    var blurRadius: CGFloat = TopBarFrost.blurRadius(TopBarFrost.standard) {
        didSet {
            if abs(oldValue - blurRadius) > 0.05 {
                applyBlurSettings()
            }
        }
    }

    var tintOpacity: Double = TopBarFrost.standardTint {
        didSet {
            if abs(oldValue - tintOpacity) > 0.005 {
                applyBlurSettings()
            }
        }
    }

    var scrollEdgeEnabled: Bool = false {
        didSet {
            if oldValue != scrollEdgeEnabled {
                updateScrollEdgeInteraction()
            }
        }
    }

    private var storedEdgeInteraction: AnyObject?

    @available(iOS 26.0, *)
    private var edgeInteraction: UIScrollEdgeElementContainerInteraction {
        if let existing = storedEdgeInteraction as? UIScrollEdgeElementContainerInteraction {
            return existing
        }
        let interaction = UIScrollEdgeElementContainerInteraction()
        interaction.edge = .top
        storedEdgeInteraction = interaction
        return interaction
    }

    init() {
        super.init(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        isUserInteractionEnabled = false
        applyBlurSettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyBlurSettings()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyBlurSettings()
        updateScrollEdgeInteraction()
    }

    private func applyBlurSettings() {
        guard let backdropView = subviews.first else { return }
        let active = blurRadius > 0.05 || tintOpacity > 0.005
        backdropView.isHidden = !active
        if let filters = backdropView.layer.filters {
            for filter in filters {
                guard let obj = filter as? NSObject else { continue }
                let name = (obj.value(forKey: "name") as? String) ?? String(describing: obj)
                if name == "gaussianBlur" {
                    backdropView.layer.setValue(
                        NSNumber(value: Double(max(0, blurRadius))),
                        forKeyPath: "filters.gaussianBlur.inputRadius"
                    )
                    backdropView.layer.setValue(
                        true,
                        forKeyPath: "filters.gaussianBlur.inputNormalizeEdges"
                    )
                } else if name == "colorSaturate" {
                    let saturation = 1.0 + 0.8 * min(max(tintOpacity, 0), 1)
                    backdropView.layer.setValue(
                        NSNumber(value: saturation),
                        forKeyPath: "filters.colorSaturate.inputAmount"
                    )
                }
            }
        }
        for subview in subviews.dropFirst() {
            subview.alpha = CGFloat(min(max(tintOpacity, 0), 1))
            subview.isHidden = tintOpacity <= 0.005
        }
    }

    private func updateScrollEdgeInteraction() {
        guard #available(iOS 26.0, *) else { return }
        guard let targetContainer = superview?.superview ?? superview else { return }
        if scrollEdgeEnabled, window != nil {
            if let scrollView = Self.findScrollView(from: targetContainer) {
                edgeInteraction.scrollView = scrollView
                scrollView.topEdgeEffect.style = .soft
                scrollView.topEdgeEffect.isHidden = false
                if !targetContainer.interactions.contains(where: { $0 === edgeInteraction }) {
                    targetContainer.addInteraction(edgeInteraction)
                }
            }
        } else {
            if targetContainer.interactions.contains(where: { $0 === edgeInteraction }) {
                targetContainer.removeInteraction(edgeInteraction)
            }
            edgeInteraction.scrollView = nil
        }
    }

    private static func findScrollView(from startView: UIView) -> UIScrollView? {
        var current: UIView? = startView.superview
        while let view = current {
            if let found = firstDescendantScrollView(in: view, skipping: startView) {
                return found
            }
            current = view.superview
        }
        return nil
    }

    private static func firstDescendantScrollView(in root: UIView, skipping: UIView) -> UIScrollView? {
        guard root !== skipping else { return nil }
        if let scroll = root as? UIScrollView,
           scroll.bounds.height > 120,
           scroll.isScrollEnabled {
            return scroll
        }
        for child in root.subviews {
            if let found = firstDescendantScrollView(in: child, skipping: skipping) {
                return found
            }
        }
        return nil
    }
}
#elseif os(macOS)
private struct VariableBackdropBlurView: View {
    var blurRadius: CGFloat
    var tintOpacity: Double
    var scrollEdgeEnabled: Bool

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .opacity(min(max( Double(blurRadius) / Double(TopBarFrost.maxBlurRadius), tintOpacity), 1))
    }
}
#endif

/// "Back to Home" on a sidebar button that goes back (`RipulRootBack`); a
/// sidebar button keeps the label it has.
private struct BackLabel: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content.accessibilityLabel("Back to \(title)")
        } else {
            content
        }
    }
}

/// Shared by the bar's centre slot and the chat title's sibling overlay.
/// The double tap must fail before a single tap can mutate the pill's layout.
/// Apply to the title header, keeping disclosed controls outside its hit area.
///
/// On an iPhone these are UIKit taps (`TitleTapRecognizer`), because a SwiftUI
/// tap in the window's top 64 points never fires: UIKit's scroll-to-top region
/// takes it, and the iPhone Duo's bar sits in that band.
@available(iOS 15.0, macOS 13.0, *)
struct TitleTapGestures: ViewModifier {
    let onTap: (() -> Void)?
    let onDoubleTap: (() -> Void)?

    func body(content: Content) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            if onTap == nil && onDoubleTap == nil {
                content
            } else {
                content.gesture(TitleTapRecognizer(onTap: onTap, onDoubleTap: onDoubleTap))
            }
        } else {
            swiftUITaps(content)
        }
        #else
        swiftUITaps(content)
        #endif
    }

    @ViewBuilder
    private func swiftUITaps(_ content: Content) -> some View {
        if let onTap, let onDoubleTap {
            content.gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { value in
                        switch value {
                        case .first: onDoubleTap()
                        case .second: onTap()
                        }
                    }
            )
        } else if let onDoubleTap {
            content.onTapGesture(count: 2, perform: onDoubleTap)
        } else if let onTap {
            content.onTapGesture(count: 1, perform: onTap)
        } else {
            content
        }
    }
}

// MARK: - Convenience inits

// Back-button convenience (preserves existing call sites using onBack:)
/// Every screen that does not override the centre slot. `center` defaults to
/// nil, which leaves `CenterContent` with nothing to infer from — so pinning it
/// to `EmptyView` here is what keeps those call sites source-identical.
@available(iOS 15.0, macOS 13.0, *)
public extension GlassTopBar where CenterContent == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        scope: GlassTopBarScope? = nil,
        leadingIcon: String = "chevron.left",
        showLeading: Bool = true,
        screenKey: String? = nil,
        screenTip: ((String) -> AnyView)? = nil,
        onLeading: (() -> Void)? = nil,
        actionIcon: String? = nil,
        onAction: (() -> Void)? = nil,
        centerInPill: Bool = true,
        centerOwnsGlass: Bool = false,
        leading: (() -> AnyView)? = nil,
        trailingAccessory: (() -> AnyView)? = nil,
        trailingOuter: (() -> AnyView)? = nil,
        onMenuOpen: (() -> Void)? = nil,
        centerInset: CGFloat? = nil,
        switcherEnabled: Bool = true,
        showsMenu: Bool = true,
        onDoubleTapTitle: (() -> Void)? = nil,
        onTapTitle: (() -> Void)? = nil,
        menuKey: String? = nil,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            scope: scope,
            leadingIcon: leadingIcon,
            showLeading: showLeading,
            screenKey: screenKey,
            screenTip: screenTip,
            onLeading: onLeading,
            actionIcon: actionIcon,
            onAction: onAction,
            center: nil,
            centerInPill: centerInPill,
            centerOwnsGlass: centerOwnsGlass,
            leading: leading,
            trailingAccessory: trailingAccessory,
            trailingOuter: trailingOuter,
            onMenuOpen: onMenuOpen,
            centerInset: centerInset,
            switcherEnabled: switcherEnabled,
            showsMenu: showsMenu,
            onDoubleTapTitle: onDoubleTapTitle,
            onTapTitle: onTapTitle,
            menuKey: menuKey,
            menu: menu
        )
    }

    init(
        title: String,
        subtitle: String? = nil,
        screenTip: ((String) -> AnyView)? = nil,
        onBack: (() -> Void)?,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            leadingIcon: "chevron.left",
            showLeading: onBack != nil,
            screenTip: screenTip,
            onLeading: onBack,
            menu: menu
        )
    }
}

// Convenience: no menu (back + lozenge only)
@available(iOS 15.0, macOS 13.0, *)
public extension GlassTopBar where MenuContent == EmptyView, CenterContent == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        onBack: (() -> Void)? = nil
    ) {
        self.init(title: title, subtitle: subtitle, onBack: onBack) {
            EmptyView()
        }
    }
}
