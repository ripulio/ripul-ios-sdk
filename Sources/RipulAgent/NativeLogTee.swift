import Foundation

// MARK: - NSLog tee → consoleLogs buffer
//
// A module-level shadow of `NSLog`. Because it lives at file scope in the
// RipulAgent module, every UNQUALIFIED `NSLog(...)` call in the SDK resolves to
// THIS instead of Foundation's — so all native SDK logging ALSO lands in the
// `consoleLogs` buffer that `device_console_logs` / `host_console_logs` read,
// without editing ~200 call sites. The real OS logger is still invoked (via
// `Foundation.NSLog`), so Xcode / Console output is unchanged.
//
// Anything that must NOT be tee'd (to avoid double-append / recursion) calls
// `Foundation.NSLog(...)` explicitly — see `AgentBridge.handleConsoleLog` and the
// `nlog/nwarn/nerror` helpers.
//
// Safeguards:
//  - `args.isEmpty` path skips `String(format:)`, so a pre-interpolated message
//    containing a literal `%` (the dominant `NSLog("x \(y)")` form) isn't
//    misparsed. The format path runs only for genuine `NSLog("%@", x)` calls,
//    which is exactly what Foundation would do anyway.
//  - reentrancy guard: the tee's own `handleConsoleLog` path must never re-enter
//    the tee (it uses Foundation.NSLog, but the guard is belt-and-suspenders).
//  - rate limit: native poll loops can flood; cap tee'd entries/sec so a burst
//    can't thrash the main actor or buffer. The real NSLog is NEVER dropped.
//  - tee is best-effort: if no bridge exists yet, only the OS log fires.

private let logTeeLock = NSLock()
private var logTeeReentrant = false
private var logTeeWindowStart = Date(timeIntervalSince1970: 0)
private var logTeeWindowCount = 0
private let logTeeMaxPerSecond = 40

func NSLog(_ format: String, _ args: CVarArg...) {
    // Avoid String(format:) for the no-args case: a bare interpolated message may
    // legitimately contain '%' and must not be treated as a format string.
    let message = args.isEmpty ? format : String(format: format, arguments: args)

    // Always emit to the real OS logger (qualified → bypasses this shadow).
    Foundation.NSLog("%@", message)

    // Decide whether to also tee into the buffer (reentrancy + rate limit).
    logTeeLock.lock()
    let drop: Bool
    if logTeeReentrant {
        drop = true
    } else {
        let now = Date()
        if now.timeIntervalSince(logTeeWindowStart) >= 1 {
            logTeeWindowStart = now
            logTeeWindowCount = 0
        }
        logTeeWindowCount += 1
        drop = logTeeWindowCount > logTeeMaxPerSecond
    }
    logTeeLock.unlock()
    if drop { return }

    Task { @MainActor in
        logTeeLock.lock(); logTeeReentrant = true; logTeeLock.unlock()
        AgentBridge.current?.handleConsoleLog("LOG: [native] \(message)")
        logTeeLock.lock(); logTeeReentrant = false; logTeeLock.unlock()
    }
}
