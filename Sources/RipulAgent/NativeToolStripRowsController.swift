#if os(iOS)
import UIKit
import WebKit

/// Retain compact row state, but allocate hosting views only for mounted DOM
/// anchors. Each row has its own leaf publisher and independent idle/reveal state.
@MainActor
final class NativeToolStripRowsController {
    private struct Key: Hashable {
        let owner: String
        let group: String
        init?(_ message: [String: Any]) {
            guard let owner = message["ownerId"] as? String, !owner.isEmpty,
                  let group = message["groupId"] as? String, !group.isEmpty else { return nil }
            self.owner = owner; self.group = group
        }
    }
    @MainActor private final class Row {
        let store: NativeToolStripStore
        var geometry: [String: Any]?
        var anchor: NativeToolStripAnchorController?
        init(store: NativeToolStripStore) { self.store = store }
        func detach() {
            store.hide()
            anchor?.invalidate()
            anchor = nil
        }
    }
    private weak var webView: WKWebView?
    private weak var presenter: NativeToolStripStore?
    private var previousPresentationChanged: ((Bool) -> Void)?
    private let send: ([String: Any]) -> Void
    private var presented: Bool
    private var rows: [Key: Row] = [:]
    private var pendingAnchors: [Key: [String: Any]] = [:]
    private var pendingPlacements: Set<Key> = []
    private var settleTimer: Timer?

    /// UIKit owns the gesture and its inertia, including drags that began in
    /// web content. Read activity flags only while layout work is pending;
    /// never observe or write contentOffset to keep native views in position.
    private var isScrollIdle: Bool {
        guard let webView else { return true }
        func isMoving(_ view: UIView) -> Bool {
            if let scroll = view as? UIScrollView,
               scroll.isTracking || scroll.isDragging || scroll.isDecelerating { return true }
            return view.subviews.contains(where: isMoving)
        }
        return !isMoving(webView.scrollView)
    }

    private func requestPlacement(_ key: Key) {
        pendingPlacements.insert(key)
        flushPlacements()
    }

    private func flushPlacements() {
        guard presented, !pendingPlacements.isEmpty else { return }
        guard isScrollIdle else {
            if settleTimer == nil {
                let timer = Timer(timeInterval: 0.08, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.settleTimer = nil
                        self?.flushPlacements()
                    }
                }
                settleTimer = timer
                // Default mode naturally pauses during touch tracking. UIKit's
                // deceleration flag also keeps this work out of a flick's tail.
                RunLoop.main.add(timer, forMode: .default)
            }
            return
        }
        settleTimer?.invalidate(); settleTimer = nil
        let keys = pendingPlacements
        pendingPlacements.removeAll()
        for key in keys {
            guard let row = rows[key] else { continue }
            if row.geometry == nil { row.detach() }
            else { attach(row, key: key) }
        }
    }

    var rowCount: Int { rows.count }
    var attachmentCount: Int { rows.values.filter { $0.anchor != nil }.count }
    var framesInWebView: [String: CGRect] {
        rows.reduce(into: [:]) { frames, item in
            if let frame = item.value.anchor?.frameInWebView { frames[item.key.group] = frame }
        }
    }
    var accessibilityElements: [Any] {
        rows.values.sorted { ($0.anchor?.frameInWebView?.minY ?? .infinity) < ($1.anchor?.frameInWebView?.minY ?? .infinity) }
            .flatMap { $0.anchor?.accessibilityElements ?? [] }
    }
    func hitTest(_ point: CGPoint, event: UIEvent?) -> UIView? {
        for row in rows.values {
            if let hit = row.anchor?.hitTest(point, event: event) { return hit }
        }
        return nil
    }

    init(webView: WKWebView, presenter: NativeToolStripStore, send: @escaping ([String: Any]) -> Void) {
        self.webView = webView; self.presenter = presenter; self.send = send
        presented = presenter.isPresented
        previousPresentationChanged = presenter.presentationChanged
        presenter.presentationChanged = { [weak self] visible in
            guard let self else { return }
            self.previousPresentationChanged?(visible)
            self.presented = visible
            if visible {
                self.pendingPlacements.formUnion(self.rows.keys)
                self.flushPlacements()
            } else {
                self.settleTimer?.invalidate(); self.settleTimer = nil
                self.pendingPlacements.removeAll()
                for row in self.rows.values { row.detach() }
            }
        }
    }

    func receive(_ message: [String: Any]) {
        guard let key = Key(message) else { return }
        let row = rows[key] ?? Row(store: NativeToolStripStore())
        row.store.enableDOMAnchor()
        row.store.receive(message)
        guard row.store.display != nil else { return }
        rows[key] = row
        if let geometry = pendingAnchors.removeValue(forKey: key) {
            row.geometry = geometry
            requestPlacement(key)
        }
    }

    func receiveAnchor(_ message: [String: Any]) {
        guard let key = Key(message) else { return }
        guard message["anchor"] is [String: Any] else {
            pendingAnchors.removeValue(forKey: key)
            if let row = rows[key] {
                row.geometry = nil
                requestPlacement(key)
            }
            return
        }
        guard let row = rows[key] else {
            pendingAnchors[key] = message
            return
        }
        row.geometry = message
        requestPlacement(key)
    }

    private func attach(_ row: Row, key: Key) {
        guard presented, let webView, let geometry = row.geometry else { return }
        if row.anchor == nil {
            row.anchor = NativeToolStripAnchorController(webView: webView, store: row.store,
                accessibilityGroupId: key.group, canChangeLayout: { [weak self] in self?.isScrollIdle ?? true })
        }
        row.anchor?.receive(geometry)
        if !row.store.isPresented { row.store.present(send: send) }
    }

    func clear(ownerId: String? = nil, groupId: String? = nil) {
        let matches: (Key) -> Bool = { (ownerId == nil || $0.owner == ownerId) && (groupId == nil || $0.group == groupId) }
        pendingPlacements = pendingPlacements.filter { !matches($0) }
        if pendingPlacements.isEmpty { settleTimer?.invalidate(); settleTimer = nil }
        for key in rows.keys.filter(matches) {
            let row = rows.removeValue(forKey: key)!
            row.store.clear()
            row.detach()
        }
        for key in pendingAnchors.keys.filter(matches) { pendingAnchors.removeValue(forKey: key) }
    }

    func invalidate() {
        settleTimer?.invalidate(); settleTimer = nil
        clear()
        presenter?.presentationChanged = previousPresentationChanged
        previousPresentationChanged = nil
    }
}
#endif
