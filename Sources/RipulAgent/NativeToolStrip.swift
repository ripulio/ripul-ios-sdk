import SwiftUI
import Combine

struct NativeToolStripItem: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let count: Int
    let rendererName: String?
    let symbol: String?
    var defaultAction: ToolDefaultAction? = nil
    var status: String? = nil
}

struct NativeToolStripSnapshot: Decodable, Equatable {
    let ownerId: String
    let chatId: String
    let groupId: String
    let updatedAt: Double
    let tools: [NativeToolStripItem]

    var scope: String { ownerId + ":" + groupId }
}

/// Only this leaf publishes during tool bursts. Never publish these values on
/// AgentBridge: doing so invalidates the WKWebView host during its animations.
@MainActor
public final class NativeToolStripStore: ObservableObject {
    @Published private(set) var display: NativeToolStripSnapshot?
    @Published private(set) var collapsed = false
    private(set) var usesDOMAnchor = false
    @Published private(set) var anchored = false
    var presentationChanged: ((Bool) -> Void)?
    var scopeChanged: (() -> Void)?

    func enableDOMAnchor() { usesDOMAnchor = true }
    func setAnchored(_ value: Bool) {
        guard anchored != value else { return }
        anchored = value
        acknowledge()
    }
    private var latest: NativeToolStripSnapshot?
    private var idleTask: Task<Void, Never>?
    private var send: (([String: Any]) -> Void)?
    private var presented = false
    var isPresented: Bool { presented }
    private var revealedActivity: Double?
    private var consumedTouch = false

    func receive(_ message: [String: Any], now: Double = Date().timeIntervalSince1970 * 1000) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let next = try? JSONDecoder().decode(NativeToolStripSnapshot.self, from: data),
              !next.ownerId.isEmpty, !next.chatId.isEmpty, !next.groupId.isEmpty,
              !next.tools.isEmpty, next.updatedAt.isFinite,
              next.tools.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty && $0.count > 0 }),
              Set(next.tools.map(\.id)).count == next.tools.count else { return }
        let scopeChanged = latest?.scope != next.scope
        let activityChanged = scopeChanged || latest?.updatedAt != next.updatedAt || latest?.tools != next.tools
        latest = next
        if scopeChanged || display?.tools != next.tools { display = next }
        if activityChanged {
            revealedActivity = nil
            scheduleIdle(now: now)
        }
        if scopeChanged { self.scopeChanged?(); acknowledge() }
    }

    func present(send: @escaping ([String: Any]) -> Void) {
        self.send = send
        presented = true
        presentationChanged?(true)
        scheduleIdle(now: Date().timeIntervalSince1970 * 1000)
        acknowledge()
    }

    func hide() {
        presented = false
        idleTask?.cancel()
        idleTask = nil
        presentationChanged?(false)
        acknowledge()
        send = nil
    }

    func clear(ownerId: String? = nil) {
        guard ownerId == nil || latest?.ownerId == ownerId else { return }
        if let latest {
            send?(["type": "agent-framework:toolStrip:visibility", "ownerId": latest.ownerId,
                   "groupId": latest.groupId, "visible": false])
        }
        idleTask?.cancel()
        idleTask = nil
        latest = nil
        display = nil
        scopeChanged?()
        revealedActivity = nil
        setCollapsed(false)
    }

    func beginToolTouch() { consumedTouch = false }

    func select(_ id: String, fromTouch: Bool = false) {
        guard !fromTouch || !consumedTouch else { return }
        guard let latest, latest.tools.contains(where: { $0.id == id }) else { return }
        send?(["type": "agent-framework:toolStrip:select", "ownerId": latest.ownerId,
               "groupId": latest.groupId, "toolId": id])
    }

    func performDefault(_ id: String, actionId: String, fromTouch: Bool = false) {
        guard let latest, latest.tools.contains(where: { $0.id == id && $0.defaultAction?.id == actionId }) else { return }
        if fromTouch { consumedTouch = true }
        send?(["type": "agent-framework:toolStrip:defaultAction", "ownerId": latest.ownerId,
               "groupId": latest.groupId, "toolId": id, "actionId": actionId])
    }

    func expand() {
        revealedActivity = latest?.updatedAt
        idleTask?.cancel()
        setCollapsed(false)
    }

    private func acknowledge() {
        guard let latest else { return }
        send?(["type": "agent-framework:toolStrip:visibility", "ownerId": latest.ownerId,
               "groupId": latest.groupId, "visible": presented && (!usesDOMAnchor || anchored)])
    }

    private func setCollapsed(_ next: Bool) {
        // @Published emits even for false -> false. A result heartbeat must
        // reset the deadline without redrawing the buttons already on screen.
        if collapsed != next { collapsed = next }
    }

    private func scheduleIdle(now: Double) {
        idleTask?.cancel()
        idleTask = nil
        guard let latest else { return }
        // A summary cannot simplify a single lozenge, even with many calls.
        // Also reopen a previously collapsed row if grouping reduces it to one.
        guard !latest.tools.contains(where: { ToolTaskStatus.isBusy($0.status) }) else { setCollapsed(false); return }
        guard latest.tools.count > 1 else { setCollapsed(false); return }
        guard revealedActivity != latest.updatedAt else { return }
        let remaining = max(0, min(20_000, latest.updatedAt + 20_000 - now))
        setCollapsed(remaining == 0)
        guard remaining > 0, presented else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000)) }
            catch { return }
            self?.setCollapsed(true)
        }
    }
}

struct NativeToolStrip: View {
    @ObservedObject var store: NativeToolStripStore
    let onEvent: ([String: Any]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !store.usesDOMAnchor { NativeToolStripContent(store: store) }
        }
        .onAppear { store.present(send: onEvent) }
        .onDisappear { store.hide() }
    }
}

struct NativeToolStripContent: View {
    @ObservedObject var store: NativeToolStripStore
    var onButtonFrames: (([String: CGRect]) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressRegions = ToolPressRegions()

    var body: some View {
        Group {
            if let snapshot = store.display {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            if store.collapsed {
                                Button(action: store.expand) {
                                    Label("\(snapshot.tools.reduce(0) { $0 + $1.count }) tool calls", systemImage: "chevron.right")
                                }
                                .accessibilityHint("Show individual tools")
                                .accessibilityIdentifier("NativeToolStrip.summary")
                                .modifier(ToolStripButtonStyle())
                                .background(buttonFrame("summary"))
                            } else {
                                ForEach(snapshot.tools) { tool in
                                    ToolDefaultActionButton(action: { store.select(tool.id, fromTouch: true) },
                                        defaultAction: tool.defaultAction.map { action in { store.performDefault(tool.id, actionId: action.id) } },
                                        defaultActionTitle: tool.defaultAction?.title) {
                                        HStack(spacing: 6) {
                                            if let status = tool.status { ToolTaskStatus(status: status) }
                                            Image(systemName: tool.symbol ?? ToolIconMap.symbol(for: tool.rendererName ?? "tool"))
                                                .foregroundStyle(.secondary)
                                            Text(tool.label).lineLimit(1).frame(maxWidth: tool.status == nil ? nil : 240)
                                            if tool.count > 1 {
                                                Text("\(tool.count)")
                                                    .font(.caption2.weight(.semibold))
                                                    .monospacedDigit()
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(.quaternary, in: Capsule())
                                            }
                                        }
                                    }
                                    .accessibilityLabel("\(tool.label)\(tool.status.map { ", " + ToolTaskStatus.title($0) } ?? ""), \(tool.count) \(tool.count == 1 ? "call" : "calls")")
                                    .accessibilityHint(tool.defaultAction.map { "Open tool details. Touch and hold to \($0.title)." } ?? "Open tool details")
                                    .accessibilityIdentifier("NativeToolStrip.tool.\(tool.id)")
                                    .accessibilityAction { store.select(tool.id) }
                                    .modifier(ToolStripButtonStyle())
                                    .background(buttonFrame(tool.id))
                                    .id(tool.id)
                                    .transition(reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity))
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(height: 44)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: snapshot.tools.map(\.id))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.collapsed)
                    }
                    .scrollIndicators(.hidden)
                    // New row identities reset horizontal position. Updates in
                    // the same row leave an intentionally scrolled strip alone.
                    .id(snapshot.scope)
                    .onChange(of: store.collapsed) { _, collapsed in
                        if !collapsed, let first = snapshot.tools.first { proxy.scrollTo(first.id, anchor: .leading) }
                    }
                }
                .frame(height: 44)
                .accessibilityIdentifier("NativeToolStrip")
            }
        }
        .coordinateSpace(name: "NativeToolStrip.bounds")
        .background(ToolStripLongPressReceiver(store: store, regions: pressRegions))
        .onPreferenceChange(ToolStripButtonFrames.self) { pressRegions.frames = $0; onButtonFrames?($0) }
    }

    @ViewBuilder private func buttonFrame(_ id: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ToolStripButtonFrames.self,
                value: [id: geometry.frame(in: .named("NativeToolStrip.bounds"))])
        }
    }
}

/// Retains Button's normal activation, while consuming the release after a recognised hold.
private struct ToolDefaultActionButton<Label: View>: View {
    let action: () -> Void
    let defaultAction: (() -> Void)?
    let defaultActionTitle: String?
    @ViewBuilder let label: () -> Label
    @GestureState private var pressing = false
    @State private var consumed = false

    var body: some View {
        #if os(iOS)
        Button(action: action, label: label)
            .accessibilityActions {
                if let defaultAction, let defaultActionTitle { Button(defaultActionTitle, action: defaultAction) }
            }
        #else
        Button { if consumed { consumed = false } else { action() } } label: { label() }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                .updating($pressing) { value, state, _ in state = value }
                .onEnded { _ in consumed = true; defaultAction?() }, including: defaultAction == nil ? .none : .all)
            .onChange(of: pressing) { _, active in if active { consumed = false } }
            .accessibilityAction { action() }
            .accessibilityActions {
                if let defaultAction, let defaultActionTitle { Button(defaultActionTitle, action: defaultAction) }
            }
        #endif
    }
}

/// Geometry is read at gesture time, without publishing during native scrolling.
private final class ToolPressRegions { var frames: [String: CGRect] = [:] }

#if os(iOS)
import UIKit

/// UIKit arbitrates the hold against the ancestor scroll pan. The store consumes
/// the recognised hold's release; a SwiftUI simultaneous hold made drags tap.
private struct ToolStripLongPressReceiver: UIViewRepresentable {
    let store: NativeToolStripStore
    let regions: ToolPressRegions
    func makeUIView(context: Context) -> Receiver {
        let view = Receiver()
        view.isUserInteractionEnabled = false
        view.onTouchBegan = { [weak store] in store?.beginToolTouch() }
        view.actionAt = { [weak store] point in
            guard let store, !store.collapsed, let tools = store.display?.tools,
                  let tool = tools.first(where: { regions.frames[$0.id]?.contains(point) == true }),
                  let action = tool.defaultAction else { return nil }
            return { [weak store] in store?.performDefault(tool.id, actionId: action.id, fromTouch: true) }
        }
        return view
    }
    func updateUIView(_ view: Receiver, context: Context) {}
    static func dismantleUIView(_ view: Receiver, coordinator: ()) { view.detach() }

    final class Receiver: UIView, UIGestureRecognizerDelegate {
        var actionAt: ((CGPoint) -> (() -> Void)?)?
        var onTouchBegan: (() -> Void)?
        private var held: (() -> Void)?
        private lazy var hold: UILongPressGestureRecognizer = {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(recognized))
            gesture.minimumPressDuration = 0.5
            gesture.allowableMovement = 10
            gesture.cancelsTouchesInView = true
            gesture.delegate = self
            return gesture
        }()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { detach(); return }
            // Attach to the containing controller, so the recognizer observes
            // touches in sibling SwiftUI buttons; its delegate limits the region.
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController {
                    if hold.view !== controller.view { hold.view?.removeGestureRecognizer(hold); controller.view.addGestureRecognizer(hold) }
                    return
                }
                responder = current.next
            }
        }
        func detach() { hold.view?.removeGestureRecognizer(hold); held = nil }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            onTouchBegan?()
            let point = touch.location(in: self)
            held = bounds.contains(point) ? actionAt?(point) : nil
            return held != nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // SwiftUI's press feedback recognizer begins immediately. The hold
            // can coexist with it, while a scroll pan must still cancel the hold.
            !(other is UIPanGestureRecognizer)
        }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let accepted = bounds.contains(gestureRecognizer.location(in: self)) && actionAt?(gestureRecognizer.location(in: self)) != nil
            return accepted
        }
        @objc private func recognized(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { held?(); held = nil }
            if gesture.state == .cancelled || gesture.state == .failed || gesture.state == .ended { held = nil }
        }
    }
}
#else
private struct ToolStripLongPressReceiver: View {
    let store: NativeToolStripStore
    let regions: ToolPressRegions
    var body: some View { EmptyView() }
}
#endif

private struct ToolStripButtonFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ToolStripButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            // Glass defaults to a rounded rectangle with Catalyst's Mac idiom.
            // Request the same capsule on every platform, retaining native sizing.
            content.font(.caption.weight(.medium)).buttonStyle(.glass)
                .buttonBorderShape(.capsule).controlSize(.regular)
        } else {
            content.font(.caption.weight(.medium)).buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}
