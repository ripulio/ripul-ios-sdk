import SwiftUI
import UIKit
@testable import RipulAgent

/// A message of the reader's own, and the reply streaming in after it, in a long
/// chat that has sat quiet (Peter, 5 November 2026: "when the user's chat goes
/// in ... it's never smooth, it's always a jump", and replies "scroll up in
/// blocks"). Opens a chat of 150 rows at its end, waits while the chat is quiet
/// (its band grows toward every row), sends, then streams a reply a sentence at a
/// time with a tool row partway, watching the chat's offset every frame.
///
/// A jump is a frame that reaches the end from more than 24 pt short of it: the
/// screen moved that far at once. A glide gets there in small steps.
struct NativeChatFollowHarness: View {
    private static let chatId = "chat-follow"
    private static let rows = 150

    @State private var bridge = AgentBridge()
    @State private var report = "waiting"
    @State private var recorder = FollowRecorder()

    var body: some View {
        AgentView(configuration: AgentConfiguration(baseURL: URL(string: "http://127.0.0.1:9")!), bridge: bridge) { _ in EmptyView() }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Text(report)
                    .font(.caption2.monospaced())
                    .padding(6)
                    .background(.thinMaterial)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("NativeChatFollowHarness.result")
                    .padding(.top, 70)
            }
            .onAppear {
                // `--old-follow`: Smooth follow off, the control.
                let old = ProcessInfo.processInfo.arguments.contains("--old-follow")
                UserDefaults.standard.set(old ? false : nil, forKey: NativeChatPerformance.key(.smoothFollow))
                bridge.nativeChatScrollerEnabled = true
                Task { @MainActor in await run() }
            }
    }

    @MainActor
    private func run() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        await bridge.focusSession(id: Self.chatId)
        bridge.nativeChat.applyBackfill((0..<Self.rows).map(Self.history), chatId: Self.chatId)
        report = "quiet"
        // Quiet for longer than the chat's 3 s of activity, so its band grows.
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        NativeChatScrollCoordinator.debugInstantFollows = []
        NativeChatListScroller.debugCorrections = []
        recorder.trackedRowId = "f-\(Self.rows - 1)"
        // The keyboard comes up, as for typing the message, and the message is typed:
        // four lines, so the composer grows. The chat rides up with both.
        recorder.phase = "keyboard"
        recorder.start()
        Self.postKeyboard(up: true)
        bridge.pendingInputText = Self.sentText
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        // Send: a tapped Send lowers the keyboard, and the page hands the message
        // back a moment later.
        recorder.phase = "send"
        report = "sending"
        // A message of more than one line drops the inset twice: the keyboard going down
        // (a tapped Send lowers it), then the composer shrinking as its text clears once
        // the page has taken the message, as the message itself comes back.
        let sentAt = Self.rows
        recorder.sentRowId = "f-\(sentAt)"
        Self.postKeyboard(up: false)
        try? await Task.sleep(nanoseconds: 80_000_000)
        bridge.nativeChat.applyPatch([Self.own(sentAt)], chatId: Self.chatId)
        try? await Task.sleep(nanoseconds: 70_000_000)
        bridge.pendingInputText = ""
        try? await Task.sleep(nanoseconds: 700_000_000)
        recorder.phase = "stream"
        let replyId = "f-\(sentAt + 1)"
        var sentences: [String] = []
        for chunk in 0..<24 {
            sentences.append("Sentence \(chunk + 1) of the reply, long enough to wrap onto another line now and then as it grows.")
            var reply = Self.reply(replyId, index: sentAt + 1, content: sentences.joined(separator: " "), status: "streaming")
            if chunk == 12 {
                // A paragraph break partway, as a reply that moves on to a new point.
                sentences.append("\n\nA new paragraph.")
                reply = Self.reply(replyId, index: sentAt + 1, content: sentences.joined(separator: " "), status: "streaming")
            }
            bridge.nativeChat.applyPatch([reply], chatId: Self.chatId)
            try? await Task.sleep(nanoseconds: 140_000_000)
        }
        bridge.nativeChat.applyPatch([Self.reply(replyId, index: sentAt + 1, content: sentences.joined(separator: " "),
                                                 status: "complete")], chatId: Self.chatId)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        recorder.stop()
        report = "done " + recorder.summary + " corr=" + NativeChatListScroller.debugCorrections.joined(separator: ",")
            + " instant=" + NativeChatScrollCoordinator.debugInstantFollows.joined(separator: ",")
    }

    /// The system's keyboard notices, as a keyboard 336 pt tall coming up or going
    /// down: `KeyboardObserver` raises the chat's bottom inset by it, on the
    /// keyboard's curve.
    @MainActor
    private static func postKeyboard(up: Bool) {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first
            ?? CGRect(x: 0, y: 0, width: 402, height: 874)
        let frame = CGRect(x: 0, y: screen.height - (up ? 336 : 0), width: screen.width, height: up ? 336 : 0)
        NotificationCenter.default.post(name: up ? UIResponder.keyboardWillShowNotification : UIResponder.keyboardWillHideNotification,
                                        object: nil,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: up ? frame : CGRect(x: 0, y: screen.height, width: screen.width, height: 336),
                                                   UIResponder.keyboardAnimationDurationUserInfoKey: 0.25])
    }

    private static func history(_ index: Int) -> [String: Any] {
        let user = index % 2 == 0
        let paragraphs = user ? 1 : 1 + (index * 7) % 4
        let text = (0..<paragraphs).map { paragraph in
            "Paragraph \(paragraph + 1) of message \(index). "
                + String(repeating: "A reply that follows the chat to its end. ", count: 2 + (index + paragraph) % 4)
        }.joined(separator: "\n\n")
        return ["messageId": "f-\(index)", "chatId": chatId, "role": user ? "user" : "assistant",
                "kind": user ? "user" : "assistant", "content": text, "status": "complete",
                "timestamp": 1_729_900_000_000.0 + Double(index) * 1000, "isOwnMessage": user]
    }

    /// Four lines, as Peter tested on 5 November 2026 ("anything over 1 line just appears").
    private static let sentText = "Can you make the chat glide\nwhen I send a message\nof more than\none line?"

    private static func own(_ index: Int) -> [String: Any] {
        ["messageId": "f-\(index)", "chatId": chatId, "role": "user", "kind": "user",
         "content": sentText,
         "timestamp": 1_729_900_000_000.0 + Double(index) * 1000, "isOwnMessage": true]
    }

    private static func reply(_ id: String, index: Int, content: String, status: String) -> [String: Any] {
        ["messageId": id, "chatId": chatId, "role": "assistant", "kind": "assistant", "content": content,
         "status": status, "timestamp": 1_729_900_000_000.0 + Double(index) * 1000]
    }
}

/// The chat's offset and end, every frame.
@MainActor
private final class FollowRecorder {
    private struct Phase {
        var started: CFTimeInterval = 0
        var frames = 0
        var jumps = 0
        var biggestJump: CGFloat = 0
        var biggestStep: CGFloat = 0
        var farthestBehind: CGFloat = 0
        /// From the phase's start to the first frame the chat moved, and to the
        /// first it was back at its end after being away from it.
        var firstMoveMs: Int?
        var atEndMs: Int?
        var wasAway = false
        /// The longest wait between frames, and how many waits ran past 25 ms.
        var worstGapMs = 0
        var longGaps = 0
        var lastFrameAt: CFTimeInterval = 0
        /// What the eye sees: the last row of the history, where it is drawn on screen.
        /// A frame that moves it more than 24 pt is a visible jump.
        var seenJumps = 0
        var biggestSeenJump: CGFloat = 0
    }

    var phase = "send" {
        didSet { phases[phase, default: Phase()].started = CACurrentMediaTime() }
    }
    private var phases: [String: Phase] = [:]
    private var link: CADisplayLink?
    private weak var scroller: UIScrollView?
    private var lastOffset: CGFloat?

    func start() {
        phases = [:]
        phases[phase, default: Phase()].started = CACurrentMediaTime()
        lastOffset = nil
        sentShownMs = nil
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    var summary: String {
        "sentShownMs=\(sentShownMs.map(String.init) ?? "-") | " + ["keyboard", "send", "stream"].map { name in
            let p = phases[name] ?? Phase()
            return "\(name): frames=\(p.frames) jumps=\(p.jumps) biggestJump=\(Int(p.biggestJump)) "
                + "biggestStep=\(Int(p.biggestStep)) behind=\(Int(p.farthestBehind)) "
                + "firstMoveMs=\(p.firstMoveMs.map(String.init) ?? "-") atEndMs=\(p.atEndMs.map(String.init) ?? "-") "
                + "worstGapMs=\(p.worstGapMs) longGaps=\(p.longGaps) "
                + "seenJumps=\(p.seenJumps) biggestSeenJump=\(Int(p.biggestSeenJump))"
        }.joined(separator: " | ")
    }

    @objc private func frame() {
        guard let sv = findScroller() else { return }
        let end = max(-sv.adjustedContentInset.top, sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height)
        // Where the chat is drawn, not where UIKit's model says it is: an animated
        // offset change holds its final value in the model from the start.
        let offset = sv.layer.presentation()?.bounds.origin.y ?? sv.contentOffset.y
        var p = phases[phase] ?? Phase()
        p.frames += 1
        let now = CACurrentMediaTime()
        if p.lastFrameAt > 0 {
            let gap = Int((now - p.lastFrameAt) * 1000)
            p.worstGapMs = max(p.worstGapMs, gap)
            if gap > 25 { p.longGaps += 1 }
        }
        p.lastFrameAt = now
        let sinceStart = Int((now - p.started) * 1000)
        if phase == "send" { noteSentRowShown(sinceSend: sinceStart) }
        if abs(end - offset) > 1 { p.wasAway = true }
        if p.wasAway, p.atEndMs == nil, abs(end - offset) <= 1 { p.atEndMs = sinceStart }
        if let last = lastOffset {
            let step = offset - last
            if abs(step) > 0.1, p.firstMoveMs == nil { p.firstMoveMs = sinceStart }
            p.biggestStep = max(p.biggestStep, abs(step))
            // At the end now, and more than 24 pt from it a frame ago, short of it
            // or past it (an end that moved up, as the keyboard goes down).
            if abs(end - offset) <= 1, abs(end - last) > 24 {
                p.jumps += 1
                p.biggestJump = max(p.biggestJump, abs(end - last))
            }
        }
        p.farthestBehind = max(p.farthestBehind, abs(end - offset))
        if let y = trackedRowScreenY() {
            if let last = lastRowY, abs(y - last) > 24 {
                p.seenJumps += 1
                p.biggestSeenJump = max(p.biggestSeenJump, abs(y - last))
            }
            lastRowY = y
        }
        phases[phase] = p
        lastOffset = offset
    }

    /// The history's last row, found by its position marker (the chat's own
    /// `NativeChatRowMarker` view, whose `rowId` names the row).
    var trackedRowId = ""
    private weak var trackedRow: UIView?
    private var lastRowY: CGFloat?
    /// The sent message, and when it was first drawn after the send.
    var sentRowId = ""
    private var sentShownMs: Int?

    private func noteSentRowShown(sinceSend: Int) {
        guard sentShownMs == nil, !sentRowId.isEmpty, marker(for: sentRowId) != nil else { return }
        sentShownMs = sinceSend
    }

    private func marker(for id: String) -> UIView? {
        var found: UIView?
        func visit(_ view: UIView) {
            guard found == nil else { return }
            if String(describing: type(of: view)).contains("MarkerView"),
               Mirror(reflecting: view).children.first(where: { $0.label == "rowId" })?.value as? String == id,
               view.window != nil {
                found = view
                return
            }
            view.subviews.forEach(visit)
        }
        for scene in UIApplication.shared.connectedScenes {
            (scene as? UIWindowScene)?.windows.forEach(visit)
        }
        return found
    }

    /// Where the tracked row's top is drawn, in the window: its layer's presentation,
    /// through every ancestor's presentation, so an animated scroll counts as drawn.
    private func trackedRowScreenY() -> CGFloat? {
        if trackedRow?.window == nil {
            trackedRow = nil
            func visit(_ view: UIView) {
                guard trackedRow == nil else { return }
                if String(describing: type(of: view)).contains("MarkerView"),
                   Mirror(reflecting: view).children.first(where: { $0.label == "rowId" })?.value as? String == trackedRowId {
                    trackedRow = view
                    return
                }
                view.subviews.forEach(visit)
            }
            for scene in UIApplication.shared.connectedScenes {
                (scene as? UIWindowScene)?.windows.forEach(visit)
            }
        }
        guard let row = trackedRow, let window = row.window else { return nil }
        let layer = row.layer.presentation() ?? row.layer
        let windowLayer = window.layer.presentation() ?? window.layer
        return layer.convert(CGPoint.zero, to: windowLayer).y
    }

    /// The chat's scroll view: the tallest in the window that is not a text view's,
    /// a list's or the page's.
    private func findScroller() -> UIScrollView? {
        if let scroller, scroller.window != nil { return scroller }
        var found: UIScrollView?
        func visit(_ view: UIView) {
            if let candidate = view as? UIScrollView, !(candidate is UITextView), !(candidate is UICollectionView),
               !String(describing: type(of: candidate)).hasPrefix("WK"),
               candidate.contentSize.height > (found?.contentSize.height ?? 0) {
                found = candidate
            }
            view.subviews.forEach(visit)
        }
        for scene in UIApplication.shared.connectedScenes {
            (scene as? UIWindowScene)?.windows.forEach(visit)
        }
        scroller = found
        return found
    }
}
