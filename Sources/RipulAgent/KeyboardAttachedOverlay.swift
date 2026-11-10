import SwiftUI

/// Coordinates are local to the composer container, not screen heights. This
/// avoids subtracting the tab bar twice when UIKit resizes its destination.
enum ComposerKeyboardLayout {
    static func bottomInset(bounds: CGRect, safeBottom: CGFloat, keyboard: CGRect?, docked: Bool) -> CGFloat {
        let resting = max(0, safeBottom)
        guard docked, let keyboard,
              !bounds.intersection(keyboard).isEmpty else { return resting }
        return max(resting, bounds.maxY - max(bounds.minY, keyboard.minY))
    }

    /// Move only the distance the composer travels from its resting baseline.
    /// Keeping the web's resting padding avoids a second, asynchronous DOM
    /// inset change while the native surfaces are animating.
    static func webShift(bounds: CGRect, safeBottom: CGFloat, navigationInset: CGFloat,
                         keyboard: CGRect?, docked: Bool) -> CGFloat {
        let resting = max(0, safeBottom) + max(0, navigationInset)
        return max(0, bottomInset(bounds: bounds, safeBottom: resting, keyboard: keyboard, docked: docked) - resting)
    }
}

/// Where the composer rests with the keyboard down. Normally 8pt above the
/// container's bottom safe inset, which on a phone with rounded corners also
/// keeps its ends inside the corners' curve. Where the system's tab bar stands
/// at the side as a rail (iPhone Duo), so nothing runs along the bottom, and
/// neither end of the composer reaches a rounded corner of the display, it
/// rests just clear of the home indicator instead: on the Duo's cover the
/// bottom is square, and the 34pt home-indicator inset plus 8 left a band of
/// empty glass beneath it (Peter, 31 October 2026). Level with the rail's
/// glass, 24pt up, still read as a big margin: the rail keeps that distance
/// for its rounded corner, and the composer's corner is square.
enum ComposerRestingLayout {
    /// A display corner this round or less counts as square (the Duo cover's
    /// hinge-side corners read 8pt; an iPhone's read 55 to 62).
    static let squareCorner: CGFloat = 12
    /// How far above the window's bottom edge the composer rests there: the
    /// home indicator sits in the 8 to 13pt below it.
    static let bottomGap: CGFloat = 16

    /// How far below its usual resting place the composer rests, in points (0
    /// for the usual place). Window coordinates throughout.
    /// - usualBottom: the composer's bottom edge at its usual resting place.
    /// - windowMaxY: the window's bottom edge.
    /// - composerMinX, composerMaxX: the composer's ends.
    /// - windowWidth, bottomLeftRadius, bottomRightRadius: the window and its
    ///   bottom corners, as UIKit's container-concentric corners resolve them.
    /// - besideRail: the tab bar stands at the side, not along the bottom.
    static func drop(usualBottom: CGFloat, windowMaxY: CGFloat,
                     composerMinX: CGFloat, composerMaxX: CGFloat, windowWidth: CGFloat,
                     bottomLeftRadius: CGFloat, bottomRightRadius: CGFloat, besideRail: Bool) -> CGFloat {
        guard besideRail else { return 0 }
        let reachesLeft = bottomLeftRadius > squareCorner && composerMinX < bottomLeftRadius
        let reachesRight = bottomRightRadius > squareCorner && composerMaxX > windowWidth - bottomRightRadius
        guard !reachesLeft, !reachesRight else { return 0 }
        return max(0, windowMaxY - bottomGap - usualBottom)
    }
}

/// The chat's resting content clearance has two independent measurements:
/// the expanded composer body and the space occupied by navigation below it.
/// Never substitute a compact-frame height while scrolling through a morph.
enum ComposerContentLayout {
    static let scrollButtonHeight: CGFloat = 64
    /// The compact composer's body height inside its host (`compactHeight`
    /// plus the 8pt top spacing that folds away when collapsed).
    static let compactInputHeight: CGFloat = ComposerChromeLayout.compactHeight + 8

    static func expandedInputHeight(hostHeight: CGFloat, progress: CGFloat) -> CGFloat? {
        guard progress == 0, hostHeight > scrollButtonHeight, hostHeight.isFinite else { return nil }
        return hostHeight - scrollButtonHeight
    }

    static func bottomClearance(inputHeight: CGFloat, navigationInset: CGFloat,
                                safeBottom: CGFloat, keyboardHeight: CGFloat = 0,
                                collapsed: Bool = false) -> CGFloat {
        let body = collapsed && inputHeight > 0 ? min(inputHeight, compactInputHeight) : inputHeight
        let navigation = collapsed ? 0 : navigationInset
        return max(0, body) + max(0, navigation) + max(0, safeBottom)
            + max(0, keyboardHeight) + 8 + 8 // below composer, then above it
    }
}

/// Resting coordinates are independent of keyboard animation and content size.
/// The same progress changes horizontal space and vertical placement together.
enum ComposerChromeLayout {
    /// The pill the composer's body folds to beside the navigation button.
    static let compactHeight: CGFloat = 48

    /// How far the composer's centre descends from full to compact, for a
    /// thumb pushing it down to follow: its bottom edge drops by the
    /// navigation's clearance, and its body folds to the pill about that
    /// centre. Both are linear in progress, so the centre is too.
    static func pushTravel(navigationInset: CGFloat, bodyHeight: CGFloat) -> CGFloat {
        // Not measured yet, the body is taken not to fold at all.
        let fold = bodyHeight > 0 ? (bodyHeight - compactHeight) / 2 : 0
        return max(0, max(0, navigationInset) + fold)
    }

    static func placement(bounds: CGRect, safeBottom: CGFloat, safeLeading: CGFloat, safeTrailing: CGFloat = 0,
                          navigation: CGRect, progress: CGFloat, bounce: CGFloat,
                          keyboardInset: CGFloat) -> (leading: CGFloat, trailing: CGFloat, bottom: CGFloat) {
        let p = min(1, max(0, progress))
        let expanded = max(safeBottom, bounds.maxY - navigation.minY)
        let resting = expanded + (safeBottom - expanded) * p
        let leading = max(0, navigation.minX + 48 + 10 - 12 - safeLeading) * p
        // The compact pair shares the native platter's two outer edges. Its
        // right edge must leave the same gutter as the compact button's left;
        // retaining the expanded composer's12pt gutter shifted the pair right.
        let trailing = max(0, bounds.maxX - safeTrailing - navigation.maxX - 12) * p
        let keyboardCoversChrome = keyboardInset > resting
        return (leading, trailing, -(max(keyboardInset, resting) + 8) + (keyboardCoversChrome ? 0 : bounce))
    }
}

#if os(iOS)
import UIKit
import Combine

@MainActor
enum ComposerKeyboardAnimation {
    static func perform(_ note: Notification, changes: @escaping () -> Void) {
        let duration = note.name == UIResponder.keyboardDidChangeFrameNotification ? 0
            : (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0)
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        if duration > 0 {
            UIView.animate(withDuration: duration, delay: 0,
                           options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction],
                           animations: changes)
        } else {
            UIView.performWithoutAnimation(changes)
        }
    }
}

/// UIKit owns positioning and uses the keyboard's frame, duration and curve.
/// No per-frame SwiftUI state or second spring is involved. Keyboard layout
/// guides were measured stuck at rest in the tab-hosted view hierarchy.
@available(iOS 16.0, *)
struct KeyboardAttachedOverlay<Content: View>: UIViewControllerRepresentable {
    @Environment(\.ripulComposerChrome) private var chrome
    let content: Content
    var onHeightChange: ((CGFloat) -> Void)?
    /// How far below its usual resting place the composer rests (see
    /// `ComposerRestingLayout`), so the chat can keep its gap above it.
    var onRestingDropChange: ((CGFloat) -> Void)?
    /// How far above the window's bottom safe area the composer rests, where its own
    /// view's safe area holds a bar beneath it (the system tab bar), so the chat can
    /// keep its gap above it.
    var onRestingLiftChange: ((CGFloat) -> Void)?

    init(onHeightChange: ((CGFloat) -> Void)? = nil, onRestingDropChange: ((CGFloat) -> Void)? = nil,
         onRestingLiftChange: ((CGFloat) -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.content = content()
        self.onHeightChange = onHeightChange
        self.onRestingDropChange = onRestingDropChange
        self.onRestingLiftChange = onRestingLiftChange
    }

    func makeUIViewController(context: Context) -> KeyboardAttachedOverlayController {
        KeyboardAttachedOverlayController(content: AnyView(content), chrome: chrome, environment: context.environment,
                                          onHeightChange: onHeightChange, onRestingDropChange: onRestingDropChange,
                                          onRestingLiftChange: onRestingLiftChange)
    }

    func updateUIViewController(_ controller: KeyboardAttachedOverlayController, context: Context) {
        // Updating the same hosting controller preserves the editor, draft,
        // selection and first responder across bridge/environment changes.
        controller.update(content: AnyView(content), chrome: chrome, environment: context.environment,
                          onHeightChange: onHeightChange, onRestingDropChange: onRestingDropChange,
                          onRestingLiftChange: onRestingLiftChange)
    }
}

@available(iOS 16.0, *)
final class KeyboardAttachedOverlayController: UIViewController {
    let host: UIHostingController<AnyView>
    private var bottomConstraint: NSLayoutConstraint?
    private var keyboardFrame: CGRect?
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var chrome: RipulComposerChrome?
    private let inactiveChrome = RipulComposerChrome()
    private var chromeSubscription: AnyCancellable?
    private var lastChromeTrace = ""
    private var onHeightChange: ((CGFloat) -> Void)?
    private var lastExpandedHeight: CGFloat?
    private var heightReportScheduled = false
    private var onRestingDropChange: ((CGFloat) -> Void)?
    /// How far below its usual resting place the composer rests: beside the
    /// system's tab rail on a square bottom, just clear of the home indicator.
    private(set) var restingDrop: CGFloat = 0
    /// The part of it this container has room for (see `measureRestingDrop`).
    private(set) var appliedRestingDrop: CGFloat = 0
    private var reportedRestingDrop: CGFloat = 0
    private var onRestingLiftChange: ((CGFloat) -> Void)?
    /// How far above the window's bottom safe area the composer rests: its own view's
    /// safe area also holds the system tab bar beneath it (the open iPhone Duo held
    /// upright). Zero where the composer is placed against the shared bar.
    private var restingLift: CGFloat = 0
    private var reportedRestingLift: CGFloat = 0
    /// The window geometry `restingDrop` was measured for.
    private var restingDropKey: [CGFloat] = []
    /// The slide carrying the chat, if any: the composer rests where the chat
    /// rests, not where a swipe has it.
    private var slide: SlideDisplacement?

    init(content: AnyView, chrome: RipulComposerChrome?, environment: EnvironmentValues,
         onHeightChange: ((CGFloat) -> Void)? = nil, onRestingDropChange: ((CGFloat) -> Void)? = nil,
         onRestingLiftChange: ((CGFloat) -> Void)? = nil) {
        host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
        update(content: content, chrome: chrome, environment: environment, onHeightChange: onHeightChange,
               onRestingDropChange: onRestingDropChange, onRestingLiftChange: onRestingLiftChange)
    }

    func update(content: AnyView, chrome: RipulComposerChrome?, environment: EnvironmentValues,
                onHeightChange: ((CGFloat) -> Void)? = nil, onRestingDropChange: ((CGFloat) -> Void)? = nil,
                onRestingLiftChange: ((CGFloat) -> Void)? = nil) {
        self.onHeightChange = onHeightChange
        self.onRestingDropChange = onRestingDropChange
        self.onRestingLiftChange = onRestingLiftChange
        slide = environment.ripulSlideDisplacement
        // This wrapper is always present; enabling chrome cannot replace the editor.
        // Copy the parent environment OUTSIDE the frame observer. Copying it
        // onto content itself would override the observer's collapse value.
        host.rootView = AnyView(ComposerChromeContent(chrome: chrome ?? inactiveChrome, content: content)
            .environment(\.self, environment))
        guard self.chrome !== chrome else { return }
        self.chrome = chrome
        chromeSubscription = nil
        if let chrome {
            chromeSubscription = chrome.$frame.combineLatest(chrome.$navigationFrame).sink { [weak self] _, _ in
                // @Published delivers before storage changes. Read after this update.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isViewLoaded else { return }
                    self.updateBottomConstraint()
                    self.view.layoutIfNeeded()
                    self.scheduleExpandedHeightReport()
                    self.reportSettledEditor()
                }
            }
        }
        if isViewLoaded { updateBottomConstraint(); view.setNeedsLayout() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = KeyboardOverlayPassthroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        if #available(iOS 16.4, *) {
            // This controller owns avoidance; don't let the inner SwiftUI hierarchy
            // add another keyboard/safe-area inset as its frame moves.
            host.safeAreaRegions = []
        }
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        let bottom = host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        bottomConstraint = bottom
        // To the view's edges, inset by the side safe area as it rests
        // (`sideInsets`), not to the live guide: a slide moves this view
        // across the window, and UIKit grows its safe area by however far the
        // view has gone under the Duo's rail.
        let leading = host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        leadingConstraint = leading
        let trailing = host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        trailingConstraint = trailing
        NSLayoutConstraint.activate([
            // Insets are zero when the parent already avoided an edge, and
            // protect the same composer in a full-window host.
            leading,
            trailing,
            bottom,
        ])
        host.didMove(toParent: self)
        (view as? KeyboardOverlayPassthroughView)?.contentView = host.view
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The tab container can change its frame/safe area during keyboard
        // presentation. Reconvert the screen frame rather than retaining a height.
        updateBottomConstraint()
        scheduleExpandedHeightReport()
        ComposerAvoidance.update(host.view)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ComposerAvoidance.update(host.view)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ComposerAvoidance.remove(host.view)
    }

    /// Measure the actual hosting view after UIKit lays it out. SwiftUI
    /// preferences inside the separately hosted composer did not reliably
    /// deliver an initial height to AgentView, leaving the web's cached inset.
    private func scheduleExpandedHeightReport() {
        guard onHeightChange != nil, !heightReportScheduled,
              let height = ComposerContentLayout.expandedInputHeight(
                hostHeight: host.view.bounds.height, progress: chrome?.frame.progress ?? 0),
              height != lastExpandedHeight else { return }
        heightReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightReportScheduled = false
            guard self.view.window != nil,
                  let height = ComposerContentLayout.expandedInputHeight(
                    hostHeight: self.host.view.bounds.height, progress: self.chrome?.frame.progress ?? 0),
                  height != self.lastExpandedHeight else { return }
            self.lastExpandedHeight = height
            self.onHeightChange?(height)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateBottomConstraint()
    }

    /// Measured in UIKit's callbacks, and only when the window's geometry
    /// changes: the rail and the display's corners move only with it. Where
    /// the composer rests: the chat's back swipe carries it over the Duo's
    /// rounded corner, and a drop measured there lifted it under the finger.
    private func measureRestingDrop() {
        #if !targetEnvironment(macCatalyst)
        guard let window = view.window else { return }
        let shift = slide?.total ?? 0
        let container = view.convert(view.bounds, to: window).offsetBy(dx: -shift, dy: 0)
        let composer = host.view.convert(host.view.bounds, to: window).offsetBy(dx: -shift, dy: 0)
        let rail = SystemTabRail.rail(in: window)?.frame
        // Whole points: a spring's displacement is not rounded to pixels as
        // the frames are, and a fraction must not count as a move.
        let key = [window.bounds.width, window.bounds.height, view.safeAreaInsets.bottom, container.maxY,
                   composer.minX.rounded(), composer.maxX.rounded(), rail?.minX ?? -1, rail?.maxY ?? -1]
        guard key != restingDropKey else { return }
        restingDropKey = key
        guard rail != nil, let corners = WindowCornerRadii.bottom(of: window) else {
            restingDrop = 0
            appliedRestingDrop = 0
            return
        }
        let usualBottom = container.maxY - view.safeAreaInsets.bottom - 8
        restingDrop = ComposerRestingLayout.drop(
            usualBottom: usualBottom, windowMaxY: window.bounds.maxY,
            composerMinX: composer.minX, composerMaxX: composer.maxX, windowWidth: window.bounds.width,
            bottomLeftRadius: corners.left, bottomRightRadius: corners.right, besideRail: true)
        // SwiftUI lays this container out above the bottom safe area until the
        // chat, told of the drop, lets it reach the bottom edge. Until then the
        // composer keeps its place rather than hang below its container, where
        // no touch would reach it.
        appliedRestingDrop = usualBottom + restingDrop <= container.maxY + 0.5 ? restingDrop : 0
        #endif
    }

    /// The side safe area as it is where this view rests: read at rest, and
    /// held while a slide carries the view (Peter, 5 November 2026: the chat
    /// composer narrowed as the chat slid toward the Duo's rail, 382 to
    /// 298 pt, and sprang back at rest). A view first laid out mid-slide has
    /// nothing read yet, nor one whose window has changed since (a rotation
    /// with the drawer open): the window's side insets its resting frame reaches.
    private var restingSides: (left: CGFloat, right: CGFloat, window: CGSize)?

    private func sideInsets() -> (left: CGFloat, right: CGFloat) {
        let live = (left: view.safeAreaInsets.left, right: view.safeAreaInsets.right)
        let shift = slide?.total ?? 0
        guard abs(shift) >= 0.5 else {
            restingSides = (live.left, live.right, view.window?.bounds.size ?? .zero)
            return live
        }
        guard let window = view.window else { return live }
        if let restingSides, restingSides.window == window.bounds.size {
            return (restingSides.left, restingSides.right)
        }
        let frame = view.convert(view.bounds, to: window).offsetBy(dx: -shift, dy: 0)
        let safe = window.safeAreaInsets
        return (left: min(safe.left, max(0, window.bounds.minX + safe.left - frame.minX)),
                right: min(safe.right, max(0, frame.maxX - (window.bounds.maxX - safe.right))))
    }

    /// Deferred: the chat's clearance is SwiftUI state, never set mid-layout.
    private func reportRestingDrop() {
        if restingLift != reportedRestingLift, let onRestingLiftChange {
            reportedRestingLift = restingLift
            let lift = restingLift
            DispatchQueue.main.async { onRestingLiftChange(lift) }
        }
        guard restingDrop != reportedRestingDrop, let onRestingDropChange else { return }
        reportedRestingDrop = restingDrop
        let drop = restingDrop
        DispatchQueue.main.async { onRestingDropChange(drop) }
    }

    @discardableResult
    private func updateBottomConstraint() -> Bool {
        guard let bottomConstraint else { return false }
        measureRestingDrop()
        defer { reportRestingDrop() }
        var localKeyboard: CGRect?
        var docked = false
        if let window = view.window, let keyboardFrame {
            localKeyboard = view.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let inWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            docked = inWindow.maxY >= window.bounds.maxY - 1
        }
        let inset = ComposerKeyboardLayout.bottomInset(
            bounds: view.bounds, safeBottom: max(0, view.safeAreaInsets.bottom - appliedRestingDrop),
            keyboard: localKeyboard, docked: docked)
        var next = -(inset + 8)
        let sides = sideInsets()
        let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let safeLeading = rightToLeft ? sides.right : sides.left
        let safeTrailing = rightToLeft ? sides.left : sides.right
        var nextLeading: CGFloat = safeLeading
        var nextTrailing: CGFloat = -safeTrailing
        // Placed by this view's safe area alone, the composer stands above whatever bar
        // that safe area holds (the system tab bar along the open Duo's bottom), which
        // the window's own safe area leaves out: the chat measured its gap from the
        // window's, and its last message sat on the composer (Peter, 5 November 2026).
        restingLift = (view.window.map { max(0, view.safeAreaInsets.bottom - $0.safeAreaInsets.bottom) } ?? 0).rounded()
        if let chrome, let window = view.window, chrome.navigationFrame.height > 0 {
            restingLift = 0
            // The bar stays put while a slide carries this view: placed
            // against it where the view rests.
            let navigation = view.convert(chrome.navigationFrame, from: window).offsetBy(dx: slide?.total ?? 0, dy: 0)
            let placement = ComposerChromeLayout.placement(
                bounds: view.bounds, safeBottom: view.safeAreaInsets.bottom,
                safeLeading: sides.left, safeTrailing: sides.right, navigation: navigation,
                progress: chrome.frame.progress, bounce: chrome.frame.bounce, keyboardInset: inset)
            nextLeading = safeLeading + placement.leading
            nextTrailing = -(safeTrailing + placement.trailing)
            next = placement.bottom
        }
        var changed = false
        for (constraint, constant) in [(leadingConstraint, nextLeading), (trailingConstraint, nextTrailing), (Optional(bottomConstraint), next)] {
            if let constraint, abs(constraint.constant - constant) > 0.01 {
                constraint.constant = constant
                changed = true
            }
        }
        return changed
    }

    private func reportSettledEditor() {
        #if DEBUG
        guard let chrome, chrome.frame.progress == 0 || chrome.frame.progress == 1 else { return }
        func editor(in view: UIView) -> UITextView? {
            if let text = view as? ChatTextView { return text }
            for child in view.subviews { if let found = editor(in: child) { return found } }
            return nil
        }
        guard let editor = editor(in: host.view) else { return }
        let line = "LOG: [AgentChrome] editor=\(ObjectIdentifier(editor)) parent=\(String(describing: editor.superview.map(ObjectIdentifier.init))) progress=\(chrome.frame.progress) frame=\(editor.convert(editor.bounds, to: view.window)) focused=\(editor.isFirstResponder)"
        if line != lastChromeTrace { lastChromeTrace = line; chrome.report?(line) }
        #endif
    }

    @objc private func keyboardChanged(_ note: Notification) {
        view.layoutIfNeeded()
        keyboardFrame = note.name == UIResponder.keyboardWillHideNotification ? nil
            : note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        ChatSlideProbe.mark("composer \(note.name.rawValue.replacingOccurrences(of: "UIKeyboard", with: "")) "
            + (keyboardFrame.map { "end=\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none")
            + " view=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
        guard updateBottomConstraint() else { return }
        ComposerKeyboardAnimation.perform(note) { self.view.layoutIfNeeded() }
    }
}

private final class KeyboardOverlayPassthroughView: UIView {
    weak var contentView: UIView?
    let overflowHitRegions = NSHashTable<UIView>.weakObjects()

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0, isUserInteractionEnabled, let contentView else { return nil }
        let localPoint = convert(point, to: contentView)
        // The reserved space above the input contains only the jump button.
        // A transparent UIHostingView still claims taps, so admit them there
        // only over the visible button's actual bounds.
        if localPoint.y < ComposerContentLayout.scrollButtonHeight,
           !overflowHitRegions.allObjects.contains(where: {
               $0.window === window && $0.bounds.insetBy(dx: -4, dy: -4).contains(convert(point, to: $0))
           }) {
            return nil
        }
        // The full-screen layout container must not intercept the chat behind it.
        // Keep hits on the hosting view itself: SwiftUI buttons use its gestures.
        return contentView.hitTest(localPoint, with: event)
    }
}

/// Marks the jump button's bounds without publishing per-frame SwiftUI geometry.
struct KeyboardOverlayHitRegion: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { KeyboardOverlayHitRegionView() }
    func updateUIView(_ view: UIView, context: Context) {}
}

private final class KeyboardOverlayHitRegionView: UIView {
    private weak var overlay: KeyboardOverlayPassthroughView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isUserInteractionEnabled = false
        overlay?.overflowHitRegions.remove(self)
        overlay = nil
        guard window != nil else { return }
        var ancestor = superview
        while let view = ancestor {
            if let container = view as? KeyboardOverlayPassthroughView {
                overlay = container
                container.overflowHitRegions.add(self)
                break
            }
            ancestor = view.superview
        }
    }
}
#endif

@available(iOS 16.0, macOS 14.0, *)
struct KeyboardAttachedOverlayModifier: ViewModifier {
    var onHeightChange: ((CGFloat) -> Void)? = nil
    var onRestingDropChange: ((CGFloat) -> Void)? = nil
    var onRestingLiftChange: ((CGFloat) -> Void)? = nil
    /// Let the container reach the window's bottom edge, under the bottom
    /// safe area, so a composer resting below its usual place stays inside
    /// it. Only where there is a resting drop: elsewhere the layout is as it
    /// always was.
    var reachesBottomEdge = false
    func body(content: Content) -> some View {
        #if os(iOS)
        KeyboardAttachedOverlay(onHeightChange: onHeightChange, onRestingDropChange: onRestingDropChange,
                                onRestingLiftChange: onRestingLiftChange) { content }
            // Sideways the controller keeps the composer out of the safe area
            // itself, as it rests (`sideInsets`). Left to SwiftUI, a slide
            // carrying the chat toward the Duo's rail gave this container as
            // much less width as the chat had gone under the rail, and the
            // composer narrowed with it, 382 to 298 pt (Peter, 5 November 2026).
            .ignoresSafeArea(.container, edges: reachesBottomEdge ? [.bottom, .horizontal] : .horizontal)
            .ignoresSafeArea(.keyboard)
        #else
        content
        #endif
    }
}
