import Foundation
import WebKit

/// Sending a message when the page is not there to answer.
///
/// A send is a call into the page that waits for its answer. The answer is lost
/// when the page goes away under the call: it reloads onto a new build after a
/// deploy, its web process dies, or WebKit cannot hand the answer back ("JavaScript
/// execution returned a result of an unsupported type", which is also what a
/// dead or half-started page gives). None of those says whether the message was
/// sent, so this neither reports a failure at once nor sends again blind:
///
///   1. the page is probed, and reloaded when it is dead (`classifyJsCallFailure`);
///   2. once it answers again it is asked what became of the send, by the id the
///      send carried (`__ripulSubmissionOutcome`, nativeSubmissionLedger.ts);
///   3. the message is sent again only when the page never took it.
///
/// A page that had not started yet, or that says it is reloading onto a new
/// build, never took the message, so that send is simply repeated when the page
/// is back.
extension AgentBridge {
    /// What one attempt at a send came to.
    enum SubmissionAnswer: Equatable {
        case accepted
        /// The page answered no. The reason is its own words, when it gave one.
        case refused(String?)
        /// The page has not installed its callables: nothing was sent.
        case pageStarting
        /// The page cannot send on its build and is reloading: nothing was sent.
        case pageReloading(String?)
        /// The call threw or never came back. Whether it was sent is not known.
        case noAnswer(String)
    }

    /// What the page's record says of a send.
    enum SubmissionRecord: Equatable {
        case accepted
        case refused(String?)
        /// The page never took it.
        case unknown
        /// A page that is gone started sending it.
        case interrupted
        /// The page keeps no record (an older build), or would not say.
        case unavailable
    }

    /// How long a page that went away is given to answer again.
    static var submissionPagePatience: TimeInterval = 20
    /// How long one send may go without an answer before the page is asked
    /// what became of it. A send still under way is waited for after that.
    static var submissionAnswerPatience: TimeInterval = 20
    /// How long a send the page says is still under way is waited for.
    static var submissionPendingPatience: TimeInterval = 120
    /// The id a send carries. A test fixes it.
    static var makeSubmissionId: () -> String = { UUID().uuidString }

    static let submissionUnconfirmed = "The chat did not confirm your message. Check the conversation before sending it again."
    static let submissionInterrupted = "The chat reloaded while your message was being sent. Check the conversation before sending it again."
    static let submissionPageAway = "The chat is not responding. Try again in a moment."
    static let submissionPageStarting = "The chat is still loading. Try again in a moment."

    /// One call to `__ripulSubmitMessage`. The script answers a flat object of
    /// a boolean and strings whatever the page returned, so the answer can
    /// always be handed back.
    func attemptSubmission(_ arguments: [Any?]) async -> SubmissionAnswer {
        let call = Self.pageCallScript("__ripulSubmitMessage", arguments, .nothing)
        let script = """
        if (typeof window.__ripulSubmitMessage !== 'function') return { missing: true };
        const reply = await (async () => { \(call.script) })();
        return {
            success: reply?.success === true,
            error: reply?.error == null ? null : String(reply.error),
            retry: reply?.retry === true,
        };
        """
        let reply = await withPageTimeout(Self.submissionAnswerPatience) {
            await self.runPage(script, arguments: call.arguments, log: .none)
        }
        if let error = reply.error { return .noAnswer(Self.describeEvalError(error)) }
        guard let answer = reply.dictionary else {
            return reply.isDetached ? .refused(nil) : .noAnswer("the page answered nothing")
        }
        if answer["missing"] as? Bool == true { return .pageStarting }
        if answer["success"] as? Bool == true { return .accepted }
        let reason = answer["error"] as? String
        return answer["retry"] as? Bool == true ? .pageReloading(reason) : .refused(reason)
    }

    /// Carry a send that did not get a plain yes or no through to one.
    func settleSubmission(
        _ first: SubmissionAnswer, id: String, resend: () async -> SubmissionAnswer
    ) async -> SubmissionAnswer {
        var answer = first
        // Two further sends at most: one after the page comes back, and one
        // more for a page that then turns out to be reloading.
        for _ in 0..<2 {
            switch answer {
            case .accepted, .refused:
                return answer
            case .pageStarting:
                handleConsoleLog("LOG: [SubmitMessage] the page has not started — waiting for it")
                guard await pageAnswers(within: Self.submissionPagePatience) else {
                    return .refused(Self.submissionPageStarting)
                }
            case .pageReloading(let reason):
                handleConsoleLog("LOG: [SubmitMessage] the page is reloading (\(reason ?? "no reason")) — sending again when it is back")
                // The page schedules its reload a moment after answering.
                try? await Task.sleep(nanoseconds: Self.submissionPagePatience > 0 ? 1_000_000_000 : 0)
                guard await pageAnswers(within: Self.submissionPagePatience) else {
                    return .refused(reason ?? Self.submissionPageAway)
                }
            case .noAnswer(let why):
                handleConsoleLog("WARN: [SubmitMessage] no answer from the page (\(why)) — finding out what became of the message")
                // Probes the page, and reloads it when it is dead or came up
                // without its callables.
                _ = await classifyJsCallFailure(why, callable: "__ripulSubmitMessage")
                guard await pageAnswers(within: Self.submissionPagePatience) else {
                    return .refused(Self.submissionPageAway)
                }
                switch await submissionRecord(id) {
                case .accepted:
                    handleConsoleLog("LOG: [SubmitMessage] the page had accepted the message; only its answer was lost")
                    return .accepted
                case .refused(let reason): return .refused(reason)
                case .interrupted: return .refused(Self.submissionInterrupted)
                case .unavailable: return .refused(Self.submissionUnconfirmed)
                case .unknown:
                    handleConsoleLog("LOG: [SubmitMessage] the page never took the message — sending it again")
                }
            }
            answer = await resend()
        }
        switch answer {
        case .accepted, .refused: return answer
        case .pageStarting: return .refused(Self.submissionPageStarting)
        case .pageReloading(let reason): return .refused(reason ?? Self.submissionPageAway)
        case .noAnswer: return .refused(Self.submissionUnconfirmed)
        }
    }

    /// Ask the page what became of a send, waiting while it is still sending.
    func submissionRecord(_ id: String) async -> SubmissionRecord {
        let script = """
        if (typeof window.__ripulSubmissionOutcome !== 'function') return { state: 'unavailable' };
        const outcome = await window.__ripulSubmissionOutcome(id);
        return { state: String(outcome?.state), error: outcome?.error == null ? null : String(outcome.error) };
        """
        let deadline = Date().addingTimeInterval(Self.submissionPendingPatience)
        while true {
            let reply = await withPageTimeout(5) {
                await self.runPage(script, arguments: ["id": id], log: .none)
            }
            let state = reply.dictionary?["state"] as? String
            switch state {
            case "accepted": return .accepted
            case "refused": return .refused(reply.dictionary?["error"] as? String)
            case "unknown": return .unknown
            case "interrupted": return .interrupted
            case "pending":
                guard Date() < deadline, !Task.isCancelled else { return .unavailable }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            default: return .unavailable
            }
        }
    }

    /// A page call that is given up on after `seconds`. WebKit does not always
    /// call back: a page that navigates away, or whose process dies, can leave
    /// the call waiting for good.
    func withPageTimeout(_ seconds: TimeInterval, _ call: @escaping @MainActor () async -> PageReply) async -> PageReply {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<PageReply, Never>) in
            let finish: @MainActor (PageReply) -> Void = { reply in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: reply)
            }
            Task { @MainActor in finish(await call()) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                finish(PageReply(outcome: .failed(NSError(domain: "AgentBridge", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "no answer after \(Int(seconds)) seconds",
                ]))))
            }
        }
    }
}
