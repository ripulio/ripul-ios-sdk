#if os(iOS)
import UIKit

/// Explicit, short-lived diagnostic capture. No draft text, per-frame work,
/// published state, console traffic, or attempts to restore focus.
@MainActor
final class NativeComposerFocusTrace {
    static let shared = NativeComposerFocusTrace()
    private let capacity = 96
    private var entries: [[String: Any]] = []
    private var observers: [NSObjectProtocol] = []
    private var expiry: Task<Void, Never>?
    private var deadline: TimeInterval = 0
    private var started: TimeInterval = 0
    private weak var window: UIWindow?
    private(set) var isRecording = false

    func start(in window: UIWindow?, seconds: Double = 90) {
        stop()
        entries.removeAll()
        self.window = window
        started = ProcessInfo.processInfo.systemUptime
        let duration = seconds.isFinite ? min(120, max(0.1, seconds)) : 90
        deadline = started + duration
        isRecording = true
        record("capture.start", view: firstResponder(in: window))
        for (name, kind) in [(UIResponder.keyboardWillShowNotification, "keyboard.show"),
                             (UIResponder.keyboardWillHideNotification, "keyboard.hide")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let height = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
                MainActor.assumeIsolated { self?.record(kind, values: ["height": height]) }
            })
        }
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            self?.stop()
        }
    }

    func stop() {
        expiry?.cancel()
        expiry = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        isRecording = false
    }

    func record(_ kind: String, view: UIView? = nil, values: [String: Any] = [:], stack: Bool = false) {
        guard isRecording else { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else { stop(); return }
        guard view?.window == nil || window == nil || view?.window === window else { return }
        var entry = values
        entry["event"] = kind
        entry["elapsedMs"] = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        if let view {
            entry["view"] = identity(view)
            entry["firstResponder"] = view.isFirstResponder
            entry["inWindow"] = view.window != nil
            entry["keyWindow"] = view.window?.isKeyWindow ?? false
        }
        if stack { entry["stack"] = Array(Thread.callStackSymbols.prefix(18)) }
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    func snapshot() -> [String: Any] {
        if isRecording && ProcessInfo.processInfo.systemUptime >= deadline { stop() }
        return ["recording": isRecording, "events": entries,
                "firstResponder": firstResponder(in: window).map(identity) ?? "none"]
    }

    private func identity(_ view: UIView) -> String {
        "\(type(of: view)):\(ObjectIdentifier(view))"
    }

    private func firstResponder(in view: UIView?) -> UIView? {
        guard let view else { return nil }
        if view.isFirstResponder { return view }
        return view.subviews.lazy.compactMap { self.firstResponder(in: $0) }.first
    }
}
#endif
