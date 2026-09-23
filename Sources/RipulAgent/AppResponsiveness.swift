import Foundation
#if canImport(UIKit)
import UIKit

/// Why the app didn't answer a device tool.
///
/// Every device tool runs on the main thread, and the relay reports a slow answer as a
/// bare "operation aborted" / "no device responded within 15s" — identical whether the
/// phone was locked, the app was in the background, or the main thread was busy (a
/// full theme apply). The three need different responses: wait, ask for the phone, or
/// fix a stall. This records the evidence so `get_app_diagnostics`, called right after
/// the failure, can say which it was.
///
/// - Main-thread stalls: a background timer asks the main queue to answer every 250ms
///   and records any answer that took longer than 400ms (the last 12, plus the worst).
/// - Lifecycle: when the app last went to the background / came back, and when
///   protected data (the lock screen) last became unavailable / available.
///
/// Started by the dev-tool registry, so apps without dev tools never pay for it.
final class AppResponsiveness: @unchecked Sendable {
    static let shared = AppResponsiveness()

    struct Stall { let at: Date; let ms: Int }

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var stalls: [Stall] = []
    private var worst: Stall?
    private var events: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []

    private let interval: TimeInterval = 0.25
    private let threshold: TimeInterval = 0.4
    private let keep = 12

    /// Idempotent; safe from any thread.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let queue = DispatchQueue(label: "ripul.responsiveness", qos: .utility)
        let source = DispatchSource.makeTimerSource(queue: queue)
        var pending = false
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in
            guard !pending else { return }   // the last ping hasn't been answered yet — that IS the stall
            pending = true
            let sent = Date()
            DispatchQueue.main.async {
                let waited = Date().timeIntervalSince(sent)
                queue.async { pending = false }
                self?.recordLatency(waited, at: sent)
            }
        }
        source.resume()
        timer = source
        DispatchQueue.main.async { self.observeLifecycle() }
    }

    private func recordLatency(_ seconds: TimeInterval, at: Date) {
        guard seconds > threshold else { return }
        let stall = Stall(at: at, ms: Int(seconds * 1000))
        lock.lock(); defer { lock.unlock() }
        stalls.append(stall)
        if stalls.count > keep { stalls.removeFirst(stalls.count - keep) }
        if stall.ms > (worst?.ms ?? 0) { worst = stall }
    }

    @MainActor
    private func observeLifecycle() {
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "enteredBackground"),
            (UIApplication.willEnterForegroundNotification, "enteredForeground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "unlocked"),
        ]
        for (name, key) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.events[key] = Date(); self.lock.unlock()
            })
        }
    }

    /// The diagnostics section. Main actor: it reads the application state.
    @MainActor
    func report() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let now = Date()
        func ago(_ date: Date) -> String { "\(Int(now.timeIntervalSince(date)))s ago (\(iso.string(from: date)))" }
        lock.lock()
        let recent = stalls, worstStall = worst, lifecycle = events
        lock.unlock()
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        var out: [String: Any] = [
            "appState": state,
            "screenLocked": !UIApplication.shared.isProtectedDataAvailable,
            "monitoring": timer != nil,
            "stallThresholdMs": Int(threshold * 1000),
            "recentStalls": recent.reversed().map { ["ms": $0.ms, "at": ago($0.at)] },
        ]
        if let worstStall { out["worstStall"] = ["ms": worstStall.ms, "at": ago(worstStall.at)] }
        out["lifecycle"] = lifecycle.mapValues { ago($0) }
        return out
    }
}
#endif
