import SwiftUI

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
    /// Double-tap on the lozenge. Used by the agent screen for the element debugger.
    var onDoubleTapTitle: (() -> Void)? = nil
    /// Corner radius for the centre pill, for screens whose centre content can
    /// grow tall (the agent screen's expanded title). nil = `Capsule`, whose
    /// radius is half the HEIGHT — correct for a fixed 44pt row, an oval that
    /// clips its own corners for anything taller. See `GlassGrowablePillModifier`.
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

    public init(
        title: String,
        subtitle: String? = nil,
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
    private var hasLeading: Bool { leading != nil || (showLeading && onLeading != nil) }

    /// Symmetric, so the lozenge stays screen-centred rather than centred in the
    /// leftover space. Sized to the WIDER cluster: one 44pt button plus its 12pt
    /// gutter is 56, each additional button 52.
    private var resolvedInset: CGFloat {
        if let centerInset { return centerInset }
        let leadingWidth: CGFloat = hasLeading ? 56 : 12
        var trailingWidth: CGFloat = 12
        if hasMenu { trailingWidth = 56 }
        if onAction != nil, actionIcon != nil { trailingWidth += 52 }
        if trailingAccessory != nil { trailingWidth += 52 }
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
        }
        .padding(.horizontal, 12)
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

    @ViewBuilder
    private var centerLayer: some View {
        Group {
            if let center {
                center()
            } else {
                defaultTitleContent
            }
        }
        .padding(.horizontal, centerInPill && !centerOwnsGlass ? 12 : 0)
        .frame(minHeight: 44)
        .modifier(ConditionalGlassPill(active: centerInPill && !centerOwnsGlass))
        .modifier(ConditionalGlassEffectID(
            active: !centerOwnsGlass,
            id: "title",
            namespace: topBarNS
        ))
        .padding(.horizontal, resolvedInset)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
            }
        )
        .modifier(TitleTapModifier(action: onTapTitle))
        .modifier(TitleDoubleTapModifier(action: onDoubleTapTitle))
        .uiKitIdentifier("GlassTopBar.titleLozenge")
    }

    @ViewBuilder
    private var defaultTitleContent: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                if let key = screenKey, let screenTip {
                    screenTip(key)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
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
            } else if showLeading, let onLeading {
                Button(action: onLeading) {
                    Image(systemName: leadingIcon)
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .modifier(GlassCircleModifier(glassStyle: "regular"))
                        .modifier(GlassEffectIDModifier(id: "leading", namespace: topBarNS))
                }
                .uiKitIdentifier("GlassTopBar.leadingButton")
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
    let key: String?
    let namespace: Namespace.ID
    let onMenuOpen: (() -> Void)?
    @ViewBuilder var menu: () -> MenuContent

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard let l = lhs.key, let r = rhs.key else { return false }
        return l == r
    }

    var body: some View {
        Menu {
            menu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .modifier(GlassCircleModifier(glassStyle: "regular"))
                .modifier(GlassEffectIDModifier(id: "trailing", namespace: namespace))
        }
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
            content.modifier(GlassPillModifier())
        } else {
            content
        }
    }
}

/// Single tap is conditional for the same reason as the double tap below.
/// Applied BEFORE the double-tap modifier so the two recognise as an
/// exclusive sequence (a paired tap resolves to the double, a lone tap to
/// the single after the double's recognition window fails).
@available(iOS 15.0, macOS 13.0, *)
private struct TitleTapModifier: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(count: 1, perform: action)
        } else {
            content
        }
    }
}

/// Double-tap is conditional, and `.onTapGesture(count:)` cannot be applied
/// conditionally inside a `ViewBuilder` without changing the view's type — which
/// would tear down the glass namespace on every state change.
@available(iOS 15.0, macOS 13.0, *)
private struct TitleDoubleTapModifier: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(count: 2, perform: action)
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
