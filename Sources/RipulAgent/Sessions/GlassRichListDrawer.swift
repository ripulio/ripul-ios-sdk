import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Rows opening and closing

/// One run of rows arriving or one run leaving, every other row staying in
/// its order: what a family opening or closing does to a list.
struct RowRunChange: Equatable {
    /// Rows arrived, rather than left.
    let opening: Bool
    /// The run, as indexes into the rows that have it: the new rows when
    /// opening, the old ones when closing.
    let start: Int
    let end: Int

    init?(old: [AnyHashable], new: [AnyHashable]) {
        let wasThere = Set(old), isThere = Set(new)
        let left = old.indices.filter { !isThere.contains(old[$0]) }
        let arrived = new.indices.filter { !wasThere.contains(new[$0]) }
        guard left.isEmpty != arrived.isEmpty else { return nil }
        let run = left.isEmpty ? arrived : left
        guard let first = run.first, let last = run.last, last - first + 1 == run.count,
              old.filter(isThere.contains) == new.filter(wasThere.contains) else { return nil }
        opening = !arrived.isEmpty
        start = first
        end = last + 1
    }
}

#if canImport(UIKit)
/// Draws a run of rows opening or closing like a drawer, in the render server.
///
/// The list takes its new rows at once, and for the 0.3 s of the motion a
/// picture of it moves instead. Rows coming in slide down out of the row above
/// them and the rows below move down with them; rows going fold up into it and
/// the rows below follow. The list's own cells and pictures of the list as it
/// was are moved by Core Animation, handed to the render server once: the main
/// thread does nothing on any frame of it.
///
/// Before this the rows' heights were changed on every frame (23 October
/// 2026), and every frame the list measured each cell on screen again: on
/// Peter's phone it jittered, and a toggle of a family cost the app a third of
/// a core. The list does not change height under a moving row here, so there
/// is nothing to measure.
///
/// - Opening: the rows above and the row the run opens under are the list's
///   own, new at once, so a family's box is whole from the first frame. The
///   run's cells slide down, clipped to below that row; the rows below are a
///   picture of the list as it was, pushed down, until the list's own rows
///   take their place at the end.
/// - Closing: the rows above and that row are a picture of the list as it was
///   until the end, so the family's box stays until the rows have gone; the
///   run is a picture folding up under that row, and the rows below are the
///   list's own cells, moving up. At the end the picture fades over the list's
///   own rows: the box goes as the dividers come back (Peter, 23 October
///   2026: "at exactly the same point").
///
/// Nothing moves where it cannot be done this way (rows going and coming at
/// once, the rows above shifting, Reduce Motion, a list that cannot be seen):
/// the rows are simply where they go.
@MainActor
final class RowDrawer {
    /// A view of the list's to find its collection view from: SwiftUI gives
    /// no way to it.
    weak var probe: UIView?
    private weak var list: UICollectionView?
    private weak var locatedFrom: UIView?
    /// From the update that changed the rows until the picture has gone.
    private(set) var isRunning = false
    /// Counts the runs, so that the end of one never ends the next.
    private var generation = 0
    /// When the rows stop moving: a change after that may open or close at once.
    private var motionEnds: CFTimeInterval = 0
    private var pending: Pending?
    private var overlay: UIView?
    /// Every animation and mask put on a layer of the list's, to take off again.
    private var animated: [(layer: CALayer, key: String)] = []
    private var masked: [(layer: CALayer, mask: CALayer)] = []
    private var restoresTouches = false

    static let duration: CFTimeInterval = 0.3
    /// How long the picture of a family that has closed takes to fade.
    static let fade: CFTimeInterval = 0.2
    private static let slideKey = "ripul.rowDrawer.slide"
    private nonisolated static let opacityKey = "ripul.rowDrawer.opacity"
    private static let coverKey = "ripul.rowDrawer.cover"

    /// The list as it was, pictured before it changed.
    private struct Pending {
        let change: RowRunChange
        let newCount: Int
        let size: CGSize
        /// Where the run meets the row above it, in the list's visible space.
        let top: CGFloat
        /// The run's height, closing.
        let runHeight: CGFloat
        /// All of it: over the list until the rows can move, then the rows
        /// below where a run arrives, or the rows above one that goes.
        let whole: UIView
        /// Closing: the run.
        let run: UIView?
    }

    /// The owner has opened or closed rows: pictures the list as it stands and
    /// covers it until the new rows can move.
    ///
    /// Called while SwiftUI updates the list, before the list has the new
    /// rows: what is on screen is still the list as it was.
    func begin(old: [AnyHashable], new: [AnyHashable]) {
        if isRunning {
            // Changed again while the rows were still moving: no motion to
            // turn round, so they are simply where they go.
            let moving = CACurrentMediaTime() < motionEnds
            finish()
            if moving { return }
        }
        guard !UIAccessibility.isReduceMotionEnabled,
              let change = RowRunChange(old: old, new: new),
              let list = locateList(), let host = list.superview, list.window != nil,
              list.numberOfSections == 1, list.numberOfItems(inSection: 0) == old.count else { return }
        let size = list.bounds.size
        let offset = list.bounds.minY
        guard size.width > 0, size.height > 0 else { return }
        func frame(_ item: Int) -> CGRect? {
            list.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame
        }
        let top: CGFloat
        var runHeight: CGFloat = 0
        if change.opening {
            guard let y = change.start == 0 ? frame(0)?.minY : frame(change.start - 1)?.maxY else { return }
            top = y - offset
        } else {
            guard let first = frame(change.start), let last = frame(change.end - 1) else { return }
            top = first.minY - offset
            runHeight = last.maxY - first.minY
        }
        // Rows changing out of sight move nothing that shows.
        guard top < size.height, change.opening || top + runHeight > 0 else { return }
        let edge = max(top, 0)
        guard let whole = list.snapshotView(afterScreenUpdates: false) else { return }
        let runFoot = min(top + runHeight, size.height)
        let run = change.opening || runFoot - edge < 1 ? nil
            : list.resizableSnapshotView(from: CGRect(x: 0, y: offset + edge, width: size.width, height: runFoot - edge),
                                         afterScreenUpdates: false, withCapInsets: .zero)
        pending = Pending(change: change, newCount: new.count, size: size, top: top, runHeight: runHeight,
                          whole: whole, run: run)

        let overlay = UIView(frame: list.frame)
        overlay.isUserInteractionEnabled = false
        overlay.clipsToBounds = true
        whole.frame = CGRect(origin: .zero, size: size)
        overlay.addSubview(whole)
        host.insertSubview(overlay, aboveSubview: list)
        self.overlay = overlay
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hide(list.layer, for: 2, key: Self.coverKey)
        CATransaction.commit()
        // A touch would land on the rows where they are going, not where they show.
        if list.isUserInteractionEnabled {
            list.isUserInteractionEnabled = false
            restoresTouches = true
        }
        isRunning = true
        motionEnds = .infinity
        generation += 1
        let generation = generation
        DispatchQueue.main.async { [weak self] in self?.move(generation, attempt: 0) }
        // Should the rows never come, the list shows as it is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if let self, self.generation == generation { self.finish() }
        }
    }

    /// The list has its new rows: hands the motion to the render server.
    private func move(_ generation: Int, attempt: Int) {
        guard generation == self.generation, let pending, let overlay, let list, list.window != nil else { return }
        // The list takes its new rows in an update of its own: wait for it.
        guard list.numberOfSections == 1, list.numberOfItems(inSection: 0) == pending.newCount else {
            if attempt < 30 {
                DispatchQueue.main.async { [weak self] in self?.move(generation, attempt: attempt + 1) }
            } else {
                finish()
            }
            return
        }
        list.layoutIfNeeded()
        let size = list.bounds.size
        let offset = list.bounds.minY
        func frame(_ item: Int) -> CGRect? {
            list.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame
        }
        let change = pending.change
        let top: CGFloat
        let runHeight: CGFloat
        if change.opening {
            guard let first = frame(change.start), let last = frame(change.end - 1) else { finish(); return }
            top = first.minY - offset
            runHeight = last.maxY - first.minY
        } else {
            let y = change.start < pending.newCount ? frame(change.start)?.minY
                : change.start > 0 ? frame(change.start - 1)?.maxY : nil
            guard let y else { finish(); return }
            top = y - offset
            runHeight = pending.runHeight
        }
        // The rows above the run moved: a list scrolled to its end keeps its
        // end in place as rows go. No drawer for that.
        guard size == pending.size, abs(top - pending.top) < 1 else { finish(); return }
        let distance = min(runHeight, size.height - top)
        guard distance >= 1 else { finish(); return }
        let edge = max(top, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        list.layer.removeAnimation(forKey: Self.coverKey)
        for indexPath in list.indexPathsForVisibleItems {
            guard let cell = list.cellForItem(at: indexPath) else { continue }
            let item = indexPath.item
            if change.opening {
                if item >= change.end {
                    hide(cell.layer, for: Self.duration)
                } else if item >= change.start {
                    slide(cell.layer, by: -distance)
                    clip(cell, below: offset + edge, sliding: distance)
                }
            } else if item < change.start {
                hide(cell.layer, for: Self.duration)
            } else {
                slide(cell.layer, by: distance)
            }
        }
        // The list draws a row's separator as a view of its own beside the
        // cells, not in the row's cell: each goes with the row it is under.
        // A run's rows are a family's, which draws its own dividers.
        for view in list.subviews where view is UICollectionReusableView && !(view is UICollectionViewCell)
            && view.frame.height <= 2 && !view.isHidden {
            let y = view.frame.midY - offset
            if change.opening {
                if y > top { hide(view.layer, for: Self.duration) }
            } else if y < top {
                hide(view.layer, for: Self.duration)
            } else {
                slide(view.layer, by: distance)
            }
        }
        // The picture of the whole list, cut to the part that is wanted.
        let part = UIView()
        part.clipsToBounds = true
        overlay.addSubview(part)
        part.addSubview(pending.whole)
        if change.opening {
            // The rows below, pushed down by the run.
            part.frame = CGRect(x: 0, y: edge + distance, width: size.width, height: size.height - edge)
            pending.whole.frame = CGRect(x: 0, y: -edge, width: size.width, height: size.height)
            slide(part.layer, by: -distance)
            showWhileMoving(part.layer)
        } else {
            // The rows above and the row the run folds into, as they were.
            part.frame = CGRect(x: 0, y: 0, width: size.width, height: edge)
            pending.whole.frame = CGRect(origin: .zero, size: size)
            fadeAfterMoving(part.layer)
        }
        if let run = pending.run {
            // Below the row it folds into, and nowhere else.
            let under = UIView(frame: CGRect(x: 0, y: edge, width: size.width, height: size.height - edge))
            under.clipsToBounds = true
            run.frame = CGRect(x: 0, y: -distance, width: size.width, height: run.bounds.height)
            under.addSubview(run)
            overlay.addSubview(under)
            slide(run.layer, by: distance)
            showWhileMoving(run.layer)
        }
        CATransaction.commit()
        motionEnds = CACurrentMediaTime() + Self.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak self] in
            if let self, self.generation == generation { self.restoreTouches() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + Self.fade + 0.05) { [weak self] in
            if let self, self.generation == generation { self.finish() }
        }
    }

    /// Ends a run at once, wherever it is: the list shows as it is.
    func finish() {
        generation += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, key) in animated { layer.removeAnimation(forKey: key) }
        for (layer, mask) in masked where layer.mask === mask { layer.mask = nil }
        overlay?.removeFromSuperview()
        CATransaction.commit()
        animated = []
        masked = []
        overlay = nil
        pending = nil
        restoreTouches()
        isRunning = false
    }

    private func restoreTouches() {
        guard restoresTouches else { return }
        restoresTouches = false
        list?.isUserInteractionEnabled = true
    }

    /// Moves a layer from `offset` below where it is to where it is.
    private func slide(_ layer: CALayer, by offset: CGFloat) {
        let animation = CABasicAnimation(keyPath: "position.y")
        animation.fromValue = offset
        animation.toValue = 0
        animation.isAdditive = true
        animation.duration = Self.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = Self.frameRates
        layer.add(animation, forKey: Self.slideKey)
        animated.append((layer, Self.slideKey))
    }

    /// As often as the screen can draw, 120 times a second on a ProMotion
    /// phone, where an animation that does not ask may be drawn at 60. It
    /// costs the main thread nothing, and the render server 0.3 s of it a
    /// toggle.
    private static var frameRates: CAFrameRateRange {
        CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    }

    /// Clips a cell sliding down out of the row above it to what has come
    /// out: below `y`, in the list's content. The clip slides up inside the
    /// cell as the cell slides down, so it stays at `y`.
    private func clip(_ cell: UICollectionViewCell, below y: CGFloat, sliding distance: CGFloat) {
        guard cell.layer.mask == nil else { return }
        let mask = CALayer()
        mask.backgroundColor = UIColor.black.cgColor // theme-exempt: a mask, never drawn; only its alpha counts
        let reach: CGFloat = 10_000
        mask.frame = CGRect(x: -reach, y: y - cell.frame.minY, width: cell.bounds.width + 2 * reach, height: reach)
        cell.layer.mask = mask
        masked.append((cell.layer, mask))
        slide(mask, by: distance)
    }

    /// Not drawn for `duration`: the list's own row while a picture of it shows.
    private func hide(_ layer: CALayer, for duration: CFTimeInterval, key: String = opacityKey) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 0
        animation.duration = duration
        layer.add(animation, forKey: key)
        animated.append((layer, key))
    }

    /// Drawn while the rows move, and gone on the frame the list's own rows
    /// show again.
    private func showWhileMoving(_ layer: CALayer) {
        layer.opacity = 0
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 1
        animation.duration = Self.duration
        layer.add(animation, forKey: Self.opacityKey)
        animated.append((layer, Self.opacityKey))
    }

    /// Drawn while the rows move, then fading over the list's own rows.
    private func fadeAfterMoving(_ layer: CALayer) {
        layer.opacity = 0
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 1, 0]
        animation.keyTimes = [0, NSNumber(value: Self.duration / (Self.duration + Self.fade)), 1]
        animation.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut)]
        animation.duration = Self.duration + Self.fade
        animation.preferredFrameRateRange = Self.frameRates
        layer.add(animation, forKey: Self.opacityKey)
        animated.append((layer, Self.opacityKey))
    }

    /// The list's collection view: up from the probe when the probe is inside
    /// it, otherwise the nearest one beside it round the same place. The
    /// collection view runs on under the bars at its top and foot, where the
    /// probe stops at them.
    func locateList() -> UICollectionView? {
        if let list, list.window != nil, locatedFrom === probe { return list }
        guard let probe, let window = probe.window else { return nil }
        locatedFrom = probe
        var view = probe.superview
        while let current = view {
            if let found = current as? UICollectionView { list = found; return found }
            view = current.superview
        }
        let place = probe.convert(probe.bounds, to: window)
        var ancestor = probe.superview
        for _ in 0..<8 {
            guard let current = ancestor else { break }
            if let found = Self.list(in: current, at: place, window: window, depth: 12) {
                list = found
                return found
            }
            ancestor = current.superview
        }
        return nil
    }

    private static func list(in view: UIView, at place: CGRect, window: UIWindow, depth: Int) -> UICollectionView? {
        for subview in view.subviews {
            if let found = subview as? UICollectionView {
                let frame = found.convert(found.bounds, to: window)
                if frame.insetBy(dx: -2, dy: -2).contains(place), abs(frame.width - place.width) < 2 { return found }
            } else if depth > 0, let found = list(in: subview, at: place, window: window, depth: depth - 1) {
                return found
            }
        }
        return nil
    }
}

/// Puts a view of the list's where the drawer can find the list from.
struct RowDrawerProbe: UIViewRepresentable {
    let drawer: RowDrawer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        drawer.probe = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        drawer.probe = view
    }
}
#else
/// No drawer where the list is AppKit's: rows are simply where they go.
@MainActor
final class RowDrawer {
    var isRunning: Bool { false }
}
#endif
