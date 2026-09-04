#if canImport(UIKit)
import SwiftUI
import UIKit
import QuartzCore

// MARK: - Stops

/// Where the pull comes to rest.
///
/// The gesture has always been one continuous ramp; what changed is that the
/// ramp now has a landing in the middle of it. A short pull stops at the deck —
/// the iPhone app-switcher read, one card near-full-size with its neighbours
/// peeking in — and pushing on from there opens the full board.
///
/// Expressed as a stop rather than a pair of booleans because the three states
/// are mutually exclusive and every one of them has to answer the same
/// questions: is a tap live, does the backdrop take hits, where does the spring
/// land. Two booleans would let `.deck && .grid` be spelled, and every read site
/// would have to remember which one wins.
public enum SwitcherStop: Equatable {
    /// The live screen fills the window. Nothing is mounted.
    case screen
    /// The app-switcher deck: one card centred, neighbours peeking at the edges.
    case deck
    /// The full card board, with the springboard beneath it.
    case grid
}

// MARK: - Screen Switcher Store

/// Drives the Safari-style screen overview ("Exposé") that every `GlassTopBar`
/// can summon by swiping down on its title lozenge.
///
/// **Leaf ObservableObject, deliberately.** `progress` publishes on every drag
/// frame. If the shell (`ContentView`) observed this, each frame would re-render
/// the WKWebView host and every mounted screen — the exact failure documented for
/// `AgentBridge`'s 53-field object. So the store is injected through a plain
/// `EnvironmentKey` (`\.screenSwitcher`), which hands out the reference WITHOUT
/// subscribing the reading view to `objectWillChange`. Only the overview overlay
/// takes it as an `@ObservedObject`. Top bars read it to *write* gesture events
/// and never re-render themselves.
@MainActor
public final class ScreenSwitcherStore: ObservableObject {

    /// 0 = the live screen fills the window. `deckFraction` = the app-switcher
    /// deck. 1 = the card grid is fully laid out.
    /// Every geometric property of the transition is a pure function of this one
    /// value, which is what keeps the motion continuous: there is no discrete
    /// state swap mid-flight for the eye to catch.
    @Published public private(set) var progress: CGFloat = 0

    /// True from the moment a downward drag is recognised until it settles.
    /// The overlay mounts on this, so it is not in the render tree at rest.
    @Published public private(set) var isActive: Bool = false

    /// Which of the three stops the gesture has settled on. Mid-drag this is
    /// still the stop the gesture STARTED from — it changes only when a release
    /// commits, so nothing reads a stop the user has not yet chosen.
    @Published public private(set) var stop: SwitcherStop = .screen

    /// True once the grid has settled open. Distinct from `isActive`, which is
    /// also true mid-drag while `progress` is still climbing.
    ///
    /// Derived rather than stored, and safe to observe: `stop` is `@Published`,
    /// so anything watching this object still hears about the change.
    public var isOpen: Bool { stop == .grid }

    /// True once the deck has settled. The deck is a RESTING state, not a frame
    /// of the opening animation — its cards take taps, page sideways and flick
    /// away, which is the whole reason it needs a name of its own.
    public var isDeck: Bool { stop == .deck }

    /// True at either landing. Every "is a tap live" check wants this rather
    /// than `isOpen`: both stops are places you can act from, and only the live
    /// screen is not.
    public var isSettled: Bool { stop != .screen }

    /// True while a finger is actually down. The overview blurs only in this
    /// state, so releasing always resolves to sharp regardless of which way the
    /// release went.
    @Published public private(set) var isDragging: Bool = false

    /// True once the drag has passed the point where LETTING GO OPENS rather
    /// than snaps back. This is the signal the blur reads: indistinct while you
    /// are only peeking, sharp the moment the gesture would commit — so the
    /// threshold is something you can see rather than something you discover by
    /// releasing and being wrong.
    @Published public private(set) var isCommitted: Bool = false

    /// Built, but not open.
    ///
    /// The overview's first mount is not free: a ScrollView, a laid-out cell per
    /// open document, the deck's cards. Paid when the gesture COMMITS it lands
    /// on the very frame the card should start moving, and the app stalls
    /// through it — the finger keeps going and the first frame that draws shows
    /// the card already at the size the thumb has reached. That is the snap.
    ///
    /// It is intermittent because the overview is torn down 620ms after it
    /// closes: re-open inside that window and it is still mounted and the
    /// opening is smooth; re-open after it and the whole tree is rebuilt. A race
    /// against a timer, which is why it had no reproduction.
    ///
    /// Warming pays it on TOUCH instead — in the time between a finger arriving
    /// and it having moved far enough to mean anything, where there is nothing
    /// to interrupt.
    @Published public private(set) var isWarming = false

    /// Mount the overview without opening it.
    public func prepareToOpen() {
        guard !isActive, !isSliding else { return }
        isWarming = true
    }

    /// The touch came to nothing, or turned out to be a sideways slide.
    public func cancelPrepareToOpen() {
        guard !isActive else { return }
        isWarming = false
    }

    /// Set while a quick-launch dismissal is fading out. Distinct from the
    /// progress ramp, which is a zoom — this one has nothing to zoom from.
    @Published public private(set) var isFlatDismissing: Bool = false

    // MARK: - Sideways travel

    /// True while a left/right tab change is animating.
    @Published public private(set) var isSliding: Bool = false

    /// The screen the drag started on, carried on top of the strip.
    @Published public private(set) var slideOutgoing: UIImage?

    /// The two neighbours, resolved once at gesture start. Both are held for the
    /// whole drag rather than resolved per frame, because the direction can
    /// reverse mid-gesture and re-deriving on the fly would swap the incoming
    /// page under the finger.
    @Published public private(set) var slidePrevious: UIImage?
    @Published public private(set) var slideNext: UIImage?

    /// Normalised −1…1, so the overlay can multiply by whatever the window
    /// width happens to be rather than the store having to know it.
    @Published public private(set) var slideFraction: CGFloat = 0

    private var slidePreviousId: String?
    private var slideNextId: String?
    private var slideToken = 0

    /// Snapshot of the screen the drag started from, captured at gesture start so
    /// the card can be transformed freely without re-laying-out live views (and
    /// without asking a WKWebView to redraw 60 times a second).
    @Published public private(set) var activeSnapshot: UIImage?

    /// Last-known snapshot per destination id, refreshed as screens are left.
    /// Destinations never visited this launch fall back to a placeholder card.
    @Published public private(set) var snapshots: [String: UIImage] = [:]

    /// Set by the shell so the overlay knows which card is "the one you're on".
    @Published public var activeDestinationId: String = ""

    /// The open documents, in the order they were OPENED.
    ///
    /// Stable, not recency-ranked. Under an MDI metaphor the set is something
    /// you arrange and then navigate spatially — a card that moves every time
    /// you look at it cannot be found by position, and the sideways strip would
    /// re-order itself under the finger as you walked it. Visiting a document
    /// never moves it; only opening and closing change this list.
    @Published public private(set) var documents: [SwitcherDocument] = []

    /// Convenience for the overlay and the strip, which both work in ids.
    public var order: [String] { documents.map(\.id) }

    /// Open a document, or focus it if it is already open.
    ///
    /// New documents land at the END, so opening one never renumbers the cards
    /// already on screen.
    public func open(_ document: SwitcherDocument) {
        if let i = documents.firstIndex(where: { $0.id == document.id }) {
            // Already open — refresh its metadata (a chat gets renamed, a file
            // moves) but leave it exactly where it sits.
            documents[i].title = document.title
            documents[i].subtitle = document.subtitle
        } else {
            documents.append(document)
        }
        activeDestinationId = document.id
        touch(document.id)
    }

    /// Seed the set from a previous launch.
    ///
    /// Deliberately not a series of `open` calls: those mark each document as
    /// the destination in turn, and restoring is not navigating — the app has
    /// not gone anywhere yet. Anything the shell can no longer honour is culled
    /// by its own reconcile afterwards.
    public func restore(documents restored: [SwitcherDocument], activeId: String) {
        guard self.documents.isEmpty else { return }
        self.documents = restored
        if restored.contains(where: { $0.id == activeId }) {
            activeDestinationId = activeId
        }
        // Seed the ranking so a restored board is already capped: the active
        // document first, then open-order. Without this the cap would not bite
        // until the user had navigated ten times, and a launch that restores
        // thirty cards would load thirty full-resolution images before then.
        recency = ([activeId] + restored.map(\.id)).reduce(into: [String]()) { acc, id in
            if !acc.contains(id), restored.contains(where: { $0.id == id }) { acc.append(id) }
        }
    }

    /// Update a document's labels without opening or moving it.
    public func refresh(id: String, title: String, subtitle: String?) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        guard documents[i].title != title || documents[i].subtitle != subtitle else { return }
        documents[i].title = title
        documents[i].subtitle = subtitle
    }

    public func document(for id: String) -> SwitcherDocument? {
        documents.first { $0.id == id }
    }

    /// Whether a card should offer a close affordance.
    ///
    /// One rule, and it is about the SET rather than the document: the last card
    /// standing cannot be closed. Closing the active document hands off to a
    /// neighbour — that is what makes it honest, because the screen you dismissed
    /// is genuinely replaced by another. With nothing to hand off to there is no
    /// handoff to make, and the button would only delete the card while leaving
    /// its screen sitting right there on the glass, which is the one outcome a
    /// close button must never produce.
    ///
    /// Deliberately not enforced inside `close(id:)`. That call is also the
    /// shell's mechanical cull for documents standing in for something it owns
    /// (a browser tab closed elsewhere), and a card for a tab that no longer
    /// exists has to go whether or not it happens to be the last one.
    public func canClose(_ id: String) -> Bool {
        documents.count > 1 && documents.contains { $0.id == id }
    }

    /// Close a document. Closing the ACTIVE one hands off to its neighbour —
    /// preferring the one to its right, the way a tab strip does, and falling
    /// back to the left when it was last.
    public func close(id: String) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (id == activeDestinationId)
        documents.remove(at: i)
        snapshots[id] = nil
        onClose?(id)

        guard wasActive else { return }
        guard !documents.isEmpty else {
            activeDestinationId = ""
            close()
            return
        }
        let neighbour = documents[min(i, documents.count - 1)]
        onSelect?(neighbour.id)
        activeDestinationId = neighbour.id
        touch(neighbour.id)
    }

    /// Everything that a close-all would actually take.
    public var closableCount: Int {
        documents.filter { $0.id != activeDestinationId }.count
    }

    /// Clear the board, keeping the screen being looked at.
    ///
    /// The active document survives, and not as a caveat bolted onto a
    /// close-everything: closing it is defined as handing off to a neighbour,
    /// and once nothing is left there is no handoff to make. `canClose` already
    /// refuses the last card for that reason. Taking the board to empty would
    /// also leave the switcher with nothing to show until the shell next
    /// navigated and re-registered a document, so the one screen you are
    /// certainly still on is exactly the one worth keeping.
    ///
    /// Closes one at a time through the normal path rather than emptying the
    /// array, because documents that stand for something the shell owns — a
    /// browser tab — have to be closed there too, and that only happens via
    /// `onClose`.
    public func closeAllExceptActive() {
        for id in documents.map(\.id) where id != activeDestinationId {
            close(id: id)
        }
    }

    /// Put `id` where `target` currently sits, sliding everything between them
    /// along. The other half of the promise `documents` makes.
    ///
    /// Open-order is stable precisely so a card can be found by position — but a
    /// position you cannot choose is an accident of when you happened to open
    /// things, not an arrangement. Nothing else in the switcher may reorder:
    /// visiting, sliding and selecting all leave the set alone, so the order is
    /// only ever what someone put there by hand.
    ///
    /// Expressed as "land on the target's index" rather than "insert before it"
    /// because a drag arrives from either side, and inserting before the target
    /// when travelling left-to-right drops the card one slot short of where the
    /// finger is.
    public func move(id: String, to target: String) {
        guard id != target,
              let from = documents.firstIndex(where: { $0.id == id }),
              let to = documents.firstIndex(where: { $0.id == target })
        else { return }
        documents.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        onReorder?()
    }

    /// Raised when a card is chosen. The shell owns navigation, so it performs
    /// the switch; the store only reports intent.
    public var onSelect: ((String) -> Void)?

    /// Raised when the set has been rearranged by hand, so the shell can write
    /// the new order down. Opening and closing already reach the shell through
    /// their own paths; a reorder changes nothing but the order, so without this
    /// it would survive only as long as the process did.
    public var onReorder: (() -> Void)?

    /// Raised when a card is dismissed, after the document has gone. Documents
    /// that stand for something the shell owns — a browser tab, say — have to be
    /// closed there too, or the card comes back the next time the two are
    /// reconciled. Same division as `onSelect`: the store reports, the shell acts.
    public var onClose: ((String) -> Void)?

    public init() {}

    // MARK: - Snapshots

    /// How many snapshots stay in memory. Everything past this is dropped from
    /// RAM, oldest-used first — the picture itself survives on disk.
    ///
    /// These are full-resolution window captures. One is around 14MB on a 6.9"
    /// device, and the set grew with every screen ever visited: thirty cards is
    /// most of a gigabyte, and it never shrank. Two separate costs came out of
    /// that — the memory, and the flush that walks the whole set redrawing and
    /// JPEG-encoding each one on the main thread, which is what made resuming
    /// the app freeze for seconds.
    public static let snapshotCap = 10

    /// Document ids in most-recently-used order, newest first. Distinct from
    /// `documents`, which is deliberately open-order and must not be disturbed —
    /// cards are found by position, so recency cannot be expressed by moving
    /// them. This is a private ranking used only to decide what to evict.
    private var recency: [String] = []

    /// Reloads a snapshot the cap evicted. Set by the shell to read the
    /// thumbnail back off disk, so a card that falls out of memory shows its
    /// last picture rather than a blank placeholder — the exact "looks like the
    /// app forgot" failure the persistence exists to prevent.
    public var snapshotReloader: ((String) -> UIImage?)?

    public func store(snapshot: UIImage?, for id: String) {
        guard let snapshot else { return }
        snapshots[id] = snapshot
        touch(id)
    }

    public func snapshot(for id: String) -> UIImage? {
        if let held = snapshots[id] { return held }
        // Evicted, or never held this launch: fall back to disk. Not written
        // into `snapshots` — that would re-grow the very set the cap bounds.
        return snapshotReloader?(id)
    }

    /// Mark a document as just-used and drop anything now past the cap.
    private func touch(_ id: String) {
        recency.removeAll { $0 == id }
        recency.insert(id, at: 0)
        guard recency.count > Self.snapshotCap else { return }
        for evicted in recency.dropFirst(Self.snapshotCap) where snapshots[evicted] != nil {
            snapshots[evicted] = nil
        }
    }

    /// The ids whose snapshots are worth writing out, newest first — i.e. the
    /// ones actually held in memory. A flush over this is bounded work.
    public var snapshotIdsForPersistence: [String] {
        recency.prefix(Self.snapshotCap).filter { snapshots[$0] != nil }
    }

    // MARK: - Interactive open

    private let commitVelocity: CGFloat = 420

    /// Where on the `0...1` ramp the deck sits.
    ///
    /// Set by the overlay from real geometry — the deck card's bottom edge has a
    /// known distance to cover, and so does the grid slot, so the deck's share of
    /// the total travel is a measurement rather than a guess. Keeping it
    /// proportional is what lets one linear `progress` track the finger across
    /// BOTH phases: the card's bottom edge moves at a constant rate the whole
    /// way up, and the deck is simply the point it passes through.
    public var deckFraction: CGFloat = 0.3 {
        didSet { deckFraction = max(0.1, min(0.8, deckFraction)) }
    }

    /// Release past this and you land on the deck rather than snapping back.
    /// A fraction of the deck's own travel, not a fixed distance: the deck is a
    /// cheap, shallow stop and should not demand the pull the grid does.
    private var deckThreshold: CGFloat { deckFraction * 0.6 }

    /// Release past this and you land on the grid, skipping the deck.
    private var gridThreshold: CGFloat { deckFraction + (1 - deckFraction) * 0.5 }

    /// The progress the current drag started from. A pull that begins at the
    /// deck has to CONTINUE the ramp rather than restart it — otherwise pushing
    /// on toward the grid would first snap the deck back to full screen.
    private var interactiveBase: CGFloat = 0

    /// Total travel that maps to one full unit of `progress`.
    ///
    /// Set by the overlay to the distance the active card's bottom edge actually
    /// has to cover, so that edge sits under the thumb for the whole drag rather
    /// than running away from it. A fixed distance cannot do that: the edge has
    /// to cross from the bottom of the screen to a grid slot two thirds of the
    /// way up it, so any value short of that is the card moving faster than the
    /// finger — which reads as the gesture being over-accelerated even though
    /// nothing is accelerating.
    public var travelDistance: CGFloat = 220

    /// Set the ramp's length from the window, once, before a gesture starts.
    ///
    /// These used to be MEASURED from the grid's laid-out slot, which arrives
    /// through a preference — i.e. after the overlay has mounted, and therefore
    /// after the drag has already been computing progress against the defaults.
    /// The default was 220 against a real 302, so progress ran a third too fast
    /// and then dropped the moment the measurement landed; the grid scrolling
    /// itself to the active card moved the slot and did it again. Whether that
    /// showed depended on how quickly the layout settled relative to the finger,
    /// which is what made the snap intermittent and unreproducible.
    ///
    /// Derived from the window instead, so it is known BEFORE the first frame
    /// and cannot change underneath a gesture. It gives up being exact about
    /// where the grid actually put the card — deliberately, because keeping a
    /// card edge welded to a thumb was never worth a recalibration mid-drag, and
    /// on a centred card the two agree to within a few points anyway.
    ///
    /// The flying card's TARGET is still measured. That has to be exact, and it
    /// is read at a point where changing it moves nothing.
    public func calibrate(windowHeight: CGFloat) {
        guard windowHeight > 0 else { return }
        travelDistance = max(160, windowHeight * Self.travelFraction)
        deckFraction = windowHeight * Self.deckStopFraction / travelDistance
    }

    /// How far the active card's bottom edge travels to reach its grid slot,
    /// as a fraction of window height: half the window, less half a grid card.
    ///
    /// Tied to `ScreenSwitcherOverlay`'s grid metrics — three columns at the
    /// window's aspect — and to its `deckScale` below. Both are laid out there
    /// and stated here, so a real change to either wants this revisited.
    private static let travelFraction: CGFloat = 0.36

    /// And to reach the DECK stop: half of what the deck card does not cover,
    /// i.e. `(1 - deckScale) / 2`.
    private static let deckStopFraction: CGFloat = 0.11

    public func beginInteractive(snapshot: UIImage?) {
        guard !isOpen else { return }
        // Only capture when starting from the live screen. Resuming the pull
        // FROM the deck must not re-snapshot: the key window is the deck at that
        // point, so capturing would paste a picture of the switcher onto the
        // card and the screen it stands for would be lost behind its own
        // reflection.
        if stop == .screen {
            activeSnapshot = snapshot ?? ScreenSnapshotter.captureKeyWindow()
            if let activeSnapshot { snapshots[activeDestinationId] = activeSnapshot }
            deckPosition = CGFloat(order.firstIndex(of: activeDestinationId) ?? 0)
            progress = 0
        }
        interactiveBase = progress
        isActive = true
        // The mount already happened, on touch. This only reveals it.
        isWarming = false
        isDragging = true
        isCommitted = stop == .deck
    }

    public func updateInteractive(translation: CGFloat) {
        guard isActive, !isOpen else { return }
        // Relative to where the drag began, not to zero. Clamped at both ends so
        // an overshoot in either direction cannot invert the transform.
        progress = max(0, min(1, interactiveBase + translation / travelDistance))
        // Distance only, not velocity: velocity is a property of the release,
        // and the blur has to answer "what happens if I let go NOW" on every
        // frame while the finger is still moving.
        isCommitted = progress >= deckThreshold
    }

    public func endInteractive(translation: CGFloat, velocity: CGFloat) {
        guard isActive, !isOpen else { return }
        isDragging = false
        settle(to: destination(velocity: velocity))
    }

    /// Which stop a release lands on.
    ///
    /// Distance decides, and velocity can only promote by ONE stop in the
    /// direction of travel. A flick that jumped straight from the live screen to
    /// the grid would make the deck unreachable by anyone who swipes briskly —
    /// which is most people — and the deck is the stop this gesture now exists
    /// to offer.
    private func destination(velocity: CGFloat) -> SwitcherStop {
        let flickUp = velocity > commitVelocity
        let flickDown = velocity < -commitVelocity

        if flickDown {
            // Step back one stop rather than all the way out, so a downward
            // flick from between the two landings lands on the deck.
            return progress > deckFraction ? .deck : .screen
        }
        if progress >= gridThreshold { return .grid }
        if flickUp { return progress >= deckFraction ? .grid : .deck }
        if progress >= deckThreshold { return .deck }
        return .screen
    }

    public func cancelInteractive() {
        guard isActive, !isOpen else { return }
        isDragging = false
        // Back to whichever stop the drag began at — a cancelled gesture is one
        // that never happened, not one that dismissed.
        settle(to: interactiveBase >= gridThreshold ? .grid
                 : interactiveBase >= deckThreshold ? .deck : .screen)
    }

    // MARK: - Deck paging

    /// Where the deck is scrolled to, measured in CARDS — 2.5 is resting exactly
    /// between the third card and the fourth.
    ///
    /// Continuous, not an index, and it does NOT snap. The app switcher is a
    /// free-scrolling surface: one flick glides across as many cards as the
    /// throw earns and coasts to a stop wherever it runs out, which is what lets
    /// you cross a long deck in one gesture. Snapping to the nearest card would
    /// cap every gesture at one card of travel however hard it was thrown, and
    /// that is the "jerky, one at a time" feel it replaces.
    ///
    /// Browse position ONLY — scrolling does not change `activeDestinationId`.
    /// Walking the deck is looking, not choosing: the shell navigates on
    /// `onSelect`, so a cursor that moved the active document would fire a
    /// navigation per card slid past, mounting screens you were only glancing
    /// at. It also keeps dismissal honest — letting the deck fall back down
    /// returns you to the screen you left, the way closing the app switcher
    /// without tapping does.
    @Published public private(set) var deckPosition: CGFloat = 0

    /// The card nearest the centre. Derived, for the few places that need a
    /// whole card rather than a position.
    public var deckIndex: Int {
        guard !documents.isEmpty else { return 0 }
        return max(0, min(documents.count - 1, Int(deckPosition.rounded())))
    }

    /// Where the current scroll gesture started from. The drag is applied to
    /// this rather than accumulated, so a reversal inside one gesture retraces
    /// exactly instead of drifting.
    private var deckPanStart: CGFloat = 0

    /// The deck cannot be scrolled past its ends.
    private var deckLimit: CGFloat { max(0, CGFloat(documents.count - 1)) }

    private func clampedDeck(_ v: CGFloat) -> CGFloat { max(0, min(deckLimit, v)) }

    /// Give at the ends rather than stopping dead — pulling against nothing
    /// should say so.
    private func rubberBandedDeck(_ v: CGFloat) -> CGFloat {
        if v < 0 { return v * 0.3 }
        if v > deckLimit { return deckLimit + (v - deckLimit) * 0.3 }
        return v
    }

    /// The card being flicked away, and how far it has gone. One at a time —
    /// a second finger on a second card is not a gesture anyone makes, and
    /// modelling it would mean per-card state for a case that cannot arise.
    @Published public private(set) var deckCardId: String?
    @Published public private(set) var deckCardOffset: CGFloat = 0

    public func beginDeckPan() {
        guard stop == .deck else { return }
        // Adopt wherever the glide had actually reached. `deckPosition` is
        // truthful precisely BECAUSE the coast is integrated rather than handed
        // to `withAnimation` — that sets the property to its final value on the
        // first frame and only interpolates the rendering, so grabbing a moving
        // deck would baseline against where it was going to stop rather than
        // where it visibly was, and the deck would jump the remaining distance
        // the instant the axis locked.
        endGlide()
        deckPanStart = deckPosition
    }

    /// Stop any coast in progress, leaving the deck exactly where it had got to.
    private func endGlide() {
        glideTask?.cancel()
        glideTask = nil
    }

    private var glideTask: Task<Void, Never>?

    public func updateDeckPan(translation: CGFloat, pitch: CGFloat) {
        guard stop == .deck, pitch > 0 else { return }
        // Dragging left (negative) walks FORWARD through the deck, so the
        // content moves opposite the finger — the cards are under the thumb,
        // not pushed by it.
        deckPosition = rubberBandedDeck(deckPanStart - translation / pitch)
    }

    /// Coast to where the throw was heading.
    ///
    /// `predictedEndTranslation` is UIKit's own deceleration model, so the
    /// DISTANCE is the system's rather than one invented here — a hard flick
    /// crosses many cards, a gentle push moves one, and neither is quantised on
    /// the way.
    ///
    /// The curve is the other half, and the one that decides whether it reads as
    /// gliding or as braking. A real scroll decays exponentially: most of the
    /// speed goes early and the last stretch is a long, barely-moving tail.
    /// `.easeOut` is far too symmetric for that — it carries speed most of the
    /// way and then stops over a short distance, which is felt as hitting
    /// something. `easeOutExpo` as a bezier has the tail.
    ///
    /// Duration has to grow with distance and be allowed to get genuinely long.
    /// A cap forces a long throw to cover more ground in the same time, so the
    /// harder you flick the harder it stops — exactly backwards.
    /// Coast on from the release speed, integrated frame by frame.
    ///
    /// Deliberately NOT `withAnimation`. A declarative animation is opaque while
    /// it runs: the property is already at its destination and only the
    /// rendering is in between, so nothing can ask where the deck currently is —
    /// which is exactly what the next gesture needs to know. Integrating it here
    /// keeps `deckPosition` true on every frame, so a coast can be caught,
    /// redirected or reversed at any instant with nothing to reconcile.
    ///
    /// It is also the more honest motion. A bezier has a fixed duration and has
    /// to arrive whatever it is doing, so a long throw covers more ground in the
    /// same time and stops harder the harder it was thrown. Exponential friction
    /// has no duration at all — it simply runs out, and the tail is as long as
    /// the throw deserves.
    public func endDeckPan(velocity: CGFloat, pitch: CGFloat) {
        guard stop == .deck, pitch > 0 else { return }
        endGlide()

        // Points per second on the finger, into cards per second on the deck.
        // Negated because dragging left walks FORWARD through the deck.
        var speed = -velocity / pitch * Self.deckFlingBoost

        // Nothing to do only if it is standing still AND inside its bounds.
        // Being outside them is reason enough to run: that is the release that
        // has to be handed back to the edge.
        let parked = clampedDeck(deckPosition) == deckPosition
        guard abs(speed) > Self.deckGlideCutoff || !parked else { return }

        glideTask = Task { @MainActor [weak self] in
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000)
                guard let self, !Task.isCancelled else { return }

                let now = CACurrentMediaTime()
                // Clamped so a stalled frame cannot teleport the deck.
                let dt = min(0.05, now - last)
                last = now

                let overshoot = self.deckPosition - self.clampedDeck(self.deckPosition)

                if overshoot == 0 {
                    // Open deck: exponential friction. The rate is per
                    // millisecond, matching how UIScrollView states its own, so
                    // the exponent is in milliseconds too.
                    speed *= pow(Self.deckFriction, CGFloat(dt) * 1000)
                } else {
                    // Past the end. The edge spring takes the throw over: it
                    // absorbs what is left of the speed, stops the deck a short
                    // way out, and hands it back. This is the bounce — a coast
                    // that simply stopped dead at the boundary read as hitting
                    // a wall, because the deck was still visibly moving in the
                    // frame before it was not.
                    speed += (-Self.deckEdgeStiffness * overshoot
                              - Self.deckEdgeDamping * speed) * CGFloat(dt)
                }

                self.deckPosition += speed * CGFloat(dt)

                // Rest is both conditions at once. Checking speed alone would
                // stop at the top of the bounce, where the deck is momentarily
                // still but a third of a card outside itself.
                let settled = self.deckPosition - self.clampedDeck(self.deckPosition)
                if abs(speed) < Self.deckGlideCutoff, abs(settled) < 0.002 {
                    self.deckPosition = self.clampedDeck(self.deckPosition)
                    return
                }
            }
            // Deliberately does NOT clear `glideTask`. By the time a coast ends
            // the handle may already belong to the NEXT one, and a finishing
            // task niling it would leave that one running with nothing able to
            // cancel it. Cancelling an already-finished task is a no-op, so a
            // stale handle costs nothing.
        }
    }

    /// Fraction of speed kept per millisecond, as `UIScrollView` models it.
    ///
    /// Its own "normal" rate is 0.998; this is deliberately nearer 1, which is a
    /// longer, looser coast. THE knob for how far a flick carries — and note it
    /// is a rate, not a distance, so raising it lengthens the tail rather than
    /// making the start faster.
    private static let deckFriction: CGFloat = 0.9985

    /// The edge spring the bounce runs on.
    ///
    /// The damping RATIO is what makes it springy — `damping / (2 * sqrt(stiffness))`,
    /// here about 0.6. Under 1 the deck overshoots home and comes back a second
    /// time before settling, which is the springiness; at 0.85 it returned in
    /// one move and read as merely elastic.
    ///
    /// Stiffness sets how far it goes out, since overshoot scales as
    /// speed / sqrt(stiffness). Kept high enough that even a violent throw only
    /// clears the end by a fraction of a card — sail a whole card past and it
    /// stops reading as a boundary at all.
    private static let deckEdgeStiffness: CGFloat = 380
    private static let deckEdgeDamping: CGFloat = 24

    /// Multiplies the release speed. Separate from friction so "how hard the
    /// throw lands" and "how long it takes to die" tune independently.
    private static let deckFlingBoost: CGFloat = 1.25

    /// Below this many cards per second there is no visible motion left.
    private static let deckGlideCutoff: CGFloat = 0.04

    // MARK: - Deck flick-to-close

    public func beginDeckCardDrag(id: String) {
        guard stop == .deck else { return }
        // A hand on a card stops the deck, the way it would on paper.
        endGlide()
        endCardSpring()
        // Catching the SAME card mid-settle picks it up where it is rather than
        // snapping it back to rest first — the offset is live, so there is a
        // real position to adopt. A different card starts clean.
        if deckCardId != id { deckCardOffset = 0 }
        deckCardId = id
        cardDragStart = deckCardOffset
    }

    /// Upward only. A downward drag on a card is the deck being pulled back
    /// down, which belongs to the ramp — see `updateInteractive`.
    public func updateDeckCardDrag(translation: CGFloat) {
        guard deckCardId != nil else { return }
        deckCardOffset = min(0, cardDragStart + translation)
    }

    /// Where the card was when this drag took hold.
    private var cardDragStart: CGFloat = 0
    private var cardSpringTask: Task<Void, Never>?

    private func endCardSpring() {
        cardSpringTask?.cancel()
        cardSpringTask = nil
    }

    /// Settle a card that was lifted but not thrown far enough to go.
    ///
    /// Integrated rather than handed to `withAnimation`, for the reason the deck
    /// coast is: the offset stays true every frame, so grabbing the card again
    /// mid-settle continues from where it visibly is instead of jumping.
    ///
    /// Carrying the release velocity in is what makes it read as a physical
    /// thing rather than a UI element returning to a slot — let go while still
    /// moving upward and it keeps going a moment, runs out, and falls back.
    private func springCardBack(velocity initial: CGFloat) {
        endCardSpring()
        var speed = initial
        cardSpringTask = Task { @MainActor [weak self] in
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000)
                guard let self, !Task.isCancelled else { return }

                let now = CACurrentMediaTime()
                let dt = min(0.05, now - last)
                last = now

                let x = self.deckCardOffset
                // Plain damped harmonic motion. Underdamped on purpose — the
                // overshoot IS the bounce, and it is what tells you the card
                // was let go rather than put down.
                speed += (-Self.cardSpringStiffness * x - Self.cardSpringDamping * speed) * CGFloat(dt)
                self.deckCardOffset = x + speed * CGFloat(dt)

                // Landed: near home and no longer moving enough to see.
                if abs(self.deckCardOffset) < 0.4, abs(speed) < 12 {
                    self.deckCardOffset = 0
                    self.deckCardId = nil
                    return
                }
            }
        }
    }

    /// Tuned together: the damping ratio is `damping / (2 * sqrt(stiffness))`,
    /// and at roughly 0.72 the card overshoots home by a couple of points and
    /// comes back once. Enough to read as a landing, not enough to wobble.
    private static let cardSpringStiffness: CGFloat = 230
    private static let cardSpringDamping: CGFloat = 22

    public func endDeckCardDrag(velocity: CGFloat, height: CGFloat) {
        guard let id = deckCardId, height > 0 else { return }
        // Distance OR speed. A card dragged most of the way up should go even if
        // it was released standing still, and a card barely lifted should go if
        // it was properly flicked.
        let shouldClose = canClose(id)
            && (deckCardOffset < -height * 0.2 || velocity < -900)

        guard shouldClose else {
            springCardBack(velocity: velocity)
            return
        }

        // Throw it the rest of the way, then remove it once it is off-screen —
        // so the gap closes behind a card that has already gone rather than
        // under one still visibly present.
        let removed = documents.firstIndex { $0.id == id }
        withAnimation(.easeOut(duration: 0.22)) { deckCardOffset = -height * 1.25 }
        deckCardToken &+= 1
        let token = deckCardToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard self.deckCardToken == token else { return }
            self.deckCardId = nil
            self.deckCardOffset = 0
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                self.close(id: id)
                // The deck is indexed by position, and a removal below the
                // cursor shifts everything under it. Without this the deck
                // would jump a card every time you closed one above where you
                // were standing.
                if let removed, CGFloat(removed) < self.deckPosition { self.deckPosition -= 1 }
                self.deckPosition = self.clampedDeck(self.deckPosition)
            }
        }
    }

    private var deckCardToken = 0

    // MARK: - Programmatic

    public func open() { present(.grid) }

    /// Summon the deck directly, without a drag.
    public func openDeck() { present(.deck) }

    private func present(_ target: SwitcherStop) {
        guard stop != target else { return }
        if stop == .screen {
            if activeSnapshot == nil { activeSnapshot = ScreenSnapshotter.captureKeyWindow() }
            if let activeSnapshot { snapshots[activeDestinationId] = activeSnapshot }
            deckPosition = CGFloat(order.firstIndex(of: activeDestinationId) ?? 0)
        }
        isActive = true
        settle(to: target)
    }

    public func close() {
        guard isActive else { return }
        settle(to: .screen)
    }

    public func select(_ id: String) {
        onSelect?(id)
        // Nothing to defer any more: under stable open-order, visiting a
        // document does not move it, so the flying card's origin slot is still
        // valid at the moment it is read. (This used to reorder here, which
        // recomputed every zoom's origin as slot 0.)
        // The card zooms back to full screen on the SAME progress ramp it left
        // on, so choosing a card is the open animation played backwards rather
        // than a separate presentation.
        activeDestinationId = id
        touch(id)
        activeSnapshot = snapshot(for: id)
        // `deckPosition` is deliberately NOT re-centred here. Selecting dismisses,
        // and the deck is re-derived from the active document the next time the
        // pull begins — so moving it now would only slide the peers sideways
        // underneath a card that is already on its way to full screen.
        settle(to: .screen)
    }

    /// Open a screen that has no card yet, from the quick-launch row.
    ///
    /// Dismisses flat rather than zooming: a screen never opened this launch has
    /// no snapshot, so there is nothing to zoom FROM, and flying a grey
    /// placeholder to full screen would advertise the absence.
    public func launch(_ document: SwitcherDocument) {
        guard isActive else { return }
        // Open FIRST: the shell resolves the id back to a document to know where
        // to navigate, so it has to exist in the set before onSelect fires.
        open(document)
        onSelect?(document.id)
        isFlatDismissing = true
        settleToken &+= 1
        let token = settleToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard self.settleToken == token else { return }
            self.teardown()
        }
    }

    // MARK: - Sideways travel

    /// Walk the card strip, Safari-toolbar style — interactive, finger-tracked,
    /// with a threshold you have to pass before it commits.
    ///
    /// **Deliberately does not reorder.** `order` is recency-ranked, and a strip
    /// that re-ranks as you walk it is not a strip — swipe left then right and
    /// you would not be back where you started. Reordering stays the business of
    /// *choosing* a destination (a card, a launch pill, the sidebar); swiping
    /// only moves along what choosing has already arranged. That also keeps the
    /// flip-between-two case exact: two adjacent entries, left then right.
    ///
    /// **Nothing is switched until release.** The drag is pure presentation: two
    /// snapshots on a strip under the finger. Switching at gesture start would
    /// mean a cancelled swipe had already mounted a screen and fired its loads,
    /// and every abandoned drag would leave that behind.
    /// `snapshot` is the picture the gesture already took during its dead zone.
    /// Capturing here instead puts a full-window render on the frame the slide
    /// starts — see `ScreenSwitcherPullModifier.prepared`.
    public func beginSlide(snapshot: UIImage? = nil) {
        guard !isActive, !isSliding else { return }
        guard let i = order.firstIndex(of: activeDestinationId) else { return }

        slideOutgoing = snapshot ?? ScreenSnapshotter.captureKeyWindow()
        if let slideOutgoing { snapshots[activeDestinationId] = slideOutgoing }

        slidePreviousId = i > 0 ? order[i - 1] : nil
        slideNextId = order.indices.contains(i + 1) ? order[i + 1] : nil
        slidePrevious = slidePreviousId.flatMap { snapshots[$0] }
        slideNext = slideNextId.flatMap { snapshots[$0] }

        slideFraction = 0
        isSliding = true
    }

    public func updateSlide(translation: CGFloat, width: CGFloat) {
        guard isSliding, width > 0 else { return }
        var f = translation / width
        // Rubber-band at the ends of the strip. Pulling against nothing should
        // give a little and say so, not feel like a dead control.
        if f < 0, slideNextId == nil { f = max(-0.055, f * 0.2) }
        if f > 0, slidePreviousId == nil { f = min(0.055, f * 0.2) }
        slideFraction = max(-1, min(1, f))
    }

    public func endSlide(predicted: CGFloat, width: CGFloat) {
        guard isSliding, width > 0 else { return }

        let f = slideFraction
        let committed: CGFloat = 0.3
        let flick = width * 0.3
        var target: CGFloat = 0
        var targetId: String?

        if f < 0, let next = slideNextId, f <= -committed || predicted <= -flick {
            target = -1
            targetId = next
        } else if f > 0, let previous = slidePreviousId, f >= committed || predicted >= flick {
            target = 1
            targetId = previous
        }

        if let targetId {
            // Switch NOW, at release, rather than after the animation: it gives
            // the incoming screen the whole travel to mount and render before
            // the snapshot lifts off it, so what lands is live content and not a
            // stale frame that then corrects itself.
            onSelect?(targetId)
            activeDestinationId = targetId
            touch(targetId)
        }

        withAnimation(.easeOut(duration: 0.28)) {
            slideFraction = target
        }

        slideToken &+= 1
        let token = slideToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard self.slideToken == token else { return }
            self.endSlideTeardown()
        }
    }

    public func cancelSlide() {
        guard isSliding else { return }
        withAnimation(.easeOut(duration: 0.24)) { slideFraction = 0 }
        slideToken &+= 1
        let token = slideToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard self.slideToken == token else { return }
            self.endSlideTeardown()
        }
    }

    private func endSlideTeardown() {
        isSliding = false
        slideOutgoing = nil
        slidePrevious = nil
        slideNext = nil
        slidePreviousId = nil
        slideNextId = nil
        slideFraction = 0
    }

    private func teardown() {
        endGlide()
        endCardSpring()
        isActive = false
        isWarming = false
        stop = .screen
        isFlatDismissing = false
        isDragging = false
        progress = 0
        interactiveBase = 0
        activeSnapshot = nil
        deckPosition = 0
        deckCardId = nil
        deckCardOffset = 0
    }

    /// Invalidates a pending unmount when a new gesture starts before the last
    /// one has finished settling. Without it, a quick pull-release-pull would
    /// let the FIRST settle's timer fire mid-second-drag and tear the overlay
    /// down under the finger.
    private var settleToken = 0

    /// Where on the ramp each stop sits.
    private func progress(of target: SwitcherStop) -> CGFloat {
        switch target {
        case .screen: return 0
        case .deck: return deckFraction
        case .grid: return 1
        }
    }

    /// The single settle path — every release, tap and cancel funnels here so
    /// there is exactly one spring in the system and no two animations can
    /// disagree about where the card is.
    private func settle(to target: SwitcherStop) {
        stop = target
        isDragging = false
        isCommitted = target != .screen
        interactiveBase = progress(of: target)
        // Leaving the deck takes its transient gesture state with it, or a card
        // half-flicked when the grid opened would still be sitting off its slot
        // when you came back.
        if target != .deck {
            endGlide()
            endCardSpring()
            deckCardId = nil
            deckCardOffset = 0
        }
        settleToken &+= 1
        let token = settleToken
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            progress = progress(of: target)
        }
        guard target == .screen else { return }
        // Unmount only after the spring has visually come to rest. A 0.42
        // response at 0.86 damping is still perceptibly moving at 460ms; cutting
        // it there flashes the peer cards out instead of fading them.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 620_000_000)
            guard self.settleToken == token, self.progress == 0 else { return }
            self.teardown()
        }
    }
}

// MARK: - Snapshotting

public enum ScreenSnapshotter {
    /// Renders the current key window to an image.
    ///
    /// `afterScreenUpdates: false` is load-bearing: `true` forces a synchronous
    /// layout pass, which on a screen hosting a WKWebView costs enough to drop
    /// the first frames of the drag. We want what is already on the glass.
    @MainActor
    public static func captureKeyWindow() -> UIImage? {
        let scenes = UIApplication.shared.connectedScenes
        guard let window = scenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
        else { return nil }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}

// MARK: - Environment

private struct ScreenSwitcherKey: EnvironmentKey {
    static let defaultValue: ScreenSwitcherStore? = nil
}

public extension EnvironmentValues {
    /// Plain reference, NOT an `@EnvironmentObject` — see the store's doc comment
    /// for why the distinction matters to the web view's frame rate.
    var screenSwitcher: ScreenSwitcherStore? {
        get { self[ScreenSwitcherKey.self] }
        set { self[ScreenSwitcherKey.self] = newValue }
    }
}

public extension View {
    func screenSwitcher(_ store: ScreenSwitcherStore) -> some View {
        environment(\.screenSwitcher, store)
    }
}
#endif
