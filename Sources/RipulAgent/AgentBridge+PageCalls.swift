import Foundation
import WebKit

/// What came back from asking the page to run one of its callables.
///
/// The page can fail to answer in two ways that callers treat differently:
/// there is no web view yet, or the call threw. Both leave `value` nil;
/// `failure(detached:)` says which, in words a caller can hand on.
struct PageReply {
    enum Outcome {
        /// The page answered, possibly with nothing.
        case answered(Any?)
        /// No web view is attached.
        case detached
        /// The call threw.
        case failed(Error)
    }

    let outcome: Outcome

    /// The page's answer. Nil when it answered nothing, when no web view is
    /// attached and when the call threw.
    var value: Any? {
        if case .answered(let value) = outcome { return value }
        return nil
    }

    var dictionary: [String: Any]? { value as? [String: Any] }

    /// The answer carries `success: true`.
    var succeeded: Bool { dictionary?["success"] as? Bool == true }

    var isDetached: Bool {
        if case .detached = outcome { return true }
        return false
    }

    var error: Error? {
        if case .failed(let error) = outcome { return error }
        return nil
    }

    /// Why there is no answer to read: `detached` when no web view is attached,
    /// the error's own words when the call threw. Nil when the page answered.
    func failure(detached: String = "webView is nil") -> String? {
        switch outcome {
        case .answered: return nil
        case .detached: return detached
        case .failed(let error): return error.localizedDescription
        }
    }
}

extension AgentBridge {
    /// What a call answers when the page has not defined the callable.
    enum PageStandIn {
        /// `window.f?.(…) ?? literal`. The literal also replaces a null answer.
        case orElse(String)
        /// `if (!window.f) return literal`. A null answer stays null.
        case ifMissing(String)
        /// A missing callable answers nothing.
        case nothing
    }

    /// Where a thrown call is written, as "[AgentBridge] <caller> error: <why>".
    enum PageFailureLog {
        case nslog
        /// The bridge console, which the log tools read.
        case console
        /// The caller reports it, or nobody needs to hear.
        case none
    }

    /// An argument the callable should see as `undefined`. Nil arrives as `null`,
    /// and the two differ wherever the page forwards the value or defaults it.
    struct PageUndefined {}
    static let undefinedArgument = PageUndefined()

    /// Run `window.<function>(arguments…)` in the page and await its answer.
    ///
    /// Arguments are bound, never pasted into the script, so their content
    /// cannot change what the script does.
    func callPage(
        _ function: String, _ arguments: [Any?] = [], _ standIn: PageStandIn = .nothing,
        log: PageFailureLog = .nslog, detachedIsFailure: Bool = false, caller: String = #function
    ) async -> PageReply {
        let (script, bound) = Self.pageCallScript(function, arguments, standIn)
        return await runPage(script, arguments: bound, log: log, detachedIsFailure: detachedIsFailure, caller: caller)
    }

    /// Run a script in the page and await what it returns.
    ///
    /// `detachedIsFailure` reports a missing web view the way a throw is
    /// reported, log line included, for callers that have always done so.
    func runPage(
        _ script: String, arguments: [String: Any] = [:],
        log: PageFailureLog = .nslog, detachedIsFailure: Bool = false, caller: String = #function
    ) async -> PageReply {
        do {
            guard let webView = attachedWebView else {
                guard detachedIsFailure else { return PageReply(outcome: .detached) }
                throw NSError(domain: "AgentBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "webView is nil"])
            }
            let value = try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
            return PageReply(outcome: .answered(value))
        } catch {
            // #function is "name(label:)"; the log has always said just "name".
            let name = String(caller.prefix { $0 != "(" })
            switch log {
            case .nslog: NSLog("[AgentBridge] %@ error: %@", name, error.localizedDescription)
            case .console: handleConsoleLog("[AgentBridge] \(name) error: \(error.localizedDescription)")
            case .none: break
            }
            return PageReply(outcome: .failed(error))
        }
    }

    static func pageCallScript(
        _ function: String, _ arguments: [Any?], _ standIn: PageStandIn
    ) -> (script: String, arguments: [String: Any]) {
        var bound: [String: Any] = [:]
        let names: [String] = arguments.enumerated().map { index, value in
            if value is PageUndefined { return "undefined" }
            let name = "a\(index)"
            bound[name] = bridgeable(value)
            return name
        }
        let call = "(" + names.joined(separator: ", ") + ")"
        switch standIn {
        case .orElse(let literal):
            return ("return await window.\(function)?.\(call) ?? \(literal);", bound)
        case .ifMissing(let literal):
            return ("if (!window.\(function)) return \(literal);\nreturn await window.\(function)\(call);", bound)
        case .nothing:
            return ("if (window.\(function)) return await window.\(function)\(call);", bound)
        }
    }

    /// A nil has to cross as NSNull. An absent key is an undeclared name in the
    /// script, and an optional boxed in `Any` is a type WebKit refuses to send.
    private static func bridgeable(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { bridgeable($0.value) } ?? NSNull()
        }
        return value
    }
}
