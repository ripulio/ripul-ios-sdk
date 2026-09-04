import Foundation
import WebKit

/// `AgentBridge` access to the plan review callables.
///
/// Three calls, all thin: the web layer owns the load/fold/append/render cycle
/// and hands back a finished view model. Nothing here interprets plan state —
/// see PlanReviewModels for why that split matters.
///
/// Errors are returned rather than thrown so the store can put them straight on
/// screen. A plan the working directory does not contain, a machine that is not
/// reachable, and an illegal status transition all arrive the same way: a
/// message the user can read.
@available(iOS 17.0, macOS 14.0, *)
extension AgentBridge {

    /// Decode a callable's `[String: Any]` reply into a Codable payload.
    ///
    /// `callAsyncJavaScript` hands back Foundation collections, so this
    /// round-trips through JSONSerialization rather than reaching for a bespoke
    /// dictionary decoder.
    private func decode<T: Decodable>(_ type: T.Type, from value: Any?, key: String) -> Result<T, PlanReviewError> {
        guard let dict = value as? [String: Any] else {
            return .failure(PlanReviewError("The web layer returned no plan data."))
        }
        if let error = dict["error"] as? String, !error.isEmpty {
            return .failure(PlanReviewError(error))
        }
        guard let payload = dict[key] else {
            return .failure(PlanReviewError("The web layer returned no \"\(key)\"."))
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .failure(PlanReviewError("Could not read the plan: \(error.localizedDescription)"))
        }
    }

    private func callPlanReview(_ script: String, _ arguments: [String: Any]) async -> Result<Any?, PlanReviewError> {
        do {
            guard let value = try await callPageFunction(script, arguments: arguments) else {
                return .failure(PlanReviewError("The app is still starting up."))
            }
            return .success(value)
        } catch {
            return .failure(PlanReviewError(error.localizedDescription))
        }
    }

    /// Plans across every candidate root, with enough state for a list row.
    ///
    /// `roots` makes the list span projects; empty falls back to the work scope
    /// alone, which is the original single-directory behaviour.
    public func planReviewList(chatId: String, roots: [String] = []) async -> Result<[PlanListEntry], PlanReviewError> {
        let result = await callPlanReview(
            "return await window.__ripulPlanReviewList?.(chatId, roots?.length ? roots : undefined) ?? { error: 'Plan review is not available in this build.' };",
            ["chatId": chatId, "roots": roots])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decode([PlanListEntry].self, from: value, key: "plans")
        }
    }

    /// One plan's full review state.
    public func planReviewGet(chatId: String, plan: String, root: String? = nil) async -> Result<PlanDetail, PlanReviewError> {
        let result = await callPlanReview(
            "return await window.__ripulPlanReviewGet?.(chatId, plan, root) ?? { error: 'Plan review is not available in this build.' };",
            ["chatId": chatId, "plan": plan, "root": root.map { $0 as Any } ?? NSNull()])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decode(PlanDetail.self, from: value, key: "plan")
        }
    }

    /// Apply one action and get the refreshed plan back.
    public func planReviewAct(
        chatId: String,
        plan: String,
        action: PlanAction,
        author: String,
        root: String? = nil
    ) async -> Result<PlanDetail, PlanReviewError> {
        let result = await callPlanReview(
            "return await window.__ripulPlanReviewAct?.(chatId, plan, action, root) ?? { error: 'Plan review is not available in this build.' };",
            ["chatId": chatId, "plan": plan, "action": action.payload(author: author),
             "root": root.map { $0 as Any } ?? NSNull()])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decode(PlanDetail.self, from: value, key: "plan")
        }
    }

    /// Create a new plan body and return its review state.
    ///
    /// A slug collision returns the existing plan rather than replacing it —
    /// the web layer never overwrites, and this path has no undo.
    public func planReviewCreate(chatId: String, title: String, problem: String? = nil, root: String? = nil) async -> Result<PlanDetail, PlanReviewError> {
        let result = await callPlanReview(
            "return await window.__ripulPlanReviewCreate?.(chatId, title, problem, root) ?? { error: 'Plan review is not available in this build.' };",
            ["chatId": chatId, "title": title, "problem": problem.map { $0 as Any } ?? NSNull(),
             "root": root.map { $0 as Any } ?? NSNull()])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decode(PlanDetail.self, from: value, key: "plan")
        }
    }

    /// The WORK SCOPE picker's state: effective directory, provenance, and
    /// the machine's directory options. Nil when the web layer cannot say.
    ///
    /// Shared with the sessions list — this is no longer Plans-private state,
    /// which is why the callable is named for the concept and not the screen.
    /// `chatId` may be empty; the machine falls back to the stored default.
    public func workScope(chatId: String) async -> WorkScopeState? {
        let result = await callPlanReview(
            "return await window.__ripulWorkScope?.(chatId) ?? { error: 'Work scope is not available in this build.' };",
            ["chatId": chatId])
        guard case .success(let value) = result,
              let dict = value as? [String: Any],
              dict["error"] == nil,
              let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return nil }
        return try? JSONDecoder().decode(WorkScopeState.self, from: data)
    }

    /// Wake an existing session with a message — the plan checkpoint's kick.
    /// The drafting session keeps its context; addressing resumes it rather
    /// than spawning a fresh addresser. `machineId` lets the web layer reopen
    /// the session's tab when it is not currently open (controller restart).
    /// Returns nil on success, else the reason — the checkpoint shows it
    /// verbatim, because "could not wake the author" with the cause swallowed
    /// is undiagnosable from the phone.
    public func planResumeSession(chatId: String, message: String, machineId: String?) async -> String? {
        let result = await callPlanReview(
            "return await window.__ripulPlanResumeSession?.(chatId, message, machineId) ?? { ok: false, error: 'Plans are not available in this build.' };",
            ["chatId": chatId, "message": message, "machineId": machineId.map { $0 as Any } ?? NSNull()])
        switch result {
        case .failure(let failure):
            return failure.message
        case .success(let value):
            guard let dict = value as? [String: Any] else { return "The web layer returned nothing." }
            if dict["ok"] as? Bool == true { return nil }
            let reason = dict["error"] as? String
            return (reason?.isEmpty == false ? reason : nil) ?? "Could not wake the author."
        }
    }

    /// Link (or unlink) an existing session to a plan via its link tag.
    public func planLinkSession(sessionId: String, planKey: String, linked: Bool) async -> Bool {
        let result = await callPlanReview(
            "return await window.__ripulPlanLinkSession?.(sessionId, planKey, linked) ?? { ok: false };",
            ["sessionId": sessionId, "planKey": planKey, "linked": linked])
        if case .success(let value) = result, let dict = value as? [String: Any] {
            return dict["ok"] as? Bool == true
        }
        return false
    }

    /// Set (nil clears) the shared work scope. The web layer announces the
    /// change to every surface, including back to native — see
    /// `.ripulWorkScopeChanged`.
    public func setWorkScope(path: String?) async -> Bool {
        let result = await callPlanReview(
            "return await window.__ripulSetWorkScope?.(path) ?? { ok: false };",
            ["path": path.map { $0 as Any } ?? NSNull()])
        if case .success(let value) = result, let dict = value as? [String: Any] {
            return dict["ok"] as? Bool == true
        }
        return false
    }

    /// Delete a plan's three files. Returns nil on success, else the reason.
    public func planReviewDelete(chatId: String, plan: String, root: String? = nil) async -> String? {
        let result = await callPlanReview(
            "return await window.__ripulPlanDelete?.(chatId, plan, root) ?? { ok: false, error: 'Plan delete is not available in this build.' };",
            ["chatId": chatId, "plan": plan, "root": root.map { $0 as Any } ?? NSNull()])
        switch result {
        case .failure(let failure):
            return failure.message
        case .success(let value):
            guard let dict = value as? [String: Any] else { return "No response from the web layer." }
            if let error = dict["error"] as? String, !error.isEmpty { return error }
            return dict["ok"] as? Bool == true ? nil : "The plan was not deleted."
        }
    }

    /// The prompt a run would start from, for display before it is sent.
    public func planRunPrompt(chatId: String, plan: String, intent: String) async -> String {
        let result = await callPlanReview(
            "return await window.__ripulPlanRunPrompt?.(chatId, plan, intent) ?? {};",
            ["chatId": chatId, "plan": plan, "intent": intent])
        if case .success(let value) = result,
           let dict = value as? [String: Any],
           let prompt = dict["prompt"] as? String {
            return prompt
        }
        return ""
    }

    /// Start an agent run. Returns nil on success, or the reason it did not start.
    /// `planKey` tags the new session onto the plan at creation (nil = no tag);
    /// `title` names it after its job (nil keeps the default auto-title).
    public func planStartRun(sourceChatId: String, modelId: String, prompt: String, planKey: String?, title: String?) async -> PlanRunStartResult {
        let result = await callPlanReview(
            "return await window.__ripulPlanStartRun?.(chatId, modelId, prompt, planKey, title) ?? { error: 'Plan runs are not available in this build.' };",
            ["chatId": sourceChatId, "modelId": modelId, "prompt": prompt,
             "planKey": planKey.map { $0 as Any } ?? NSNull(),
             "title": title.map { $0 as Any } ?? NSNull()])
        switch result {
        case .failure(let failure):
            return PlanRunStartResult(error: failure.message, chatId: nil)
        case .success(let value):
            guard let dict = value as? [String: Any] else {
                return PlanRunStartResult(error: "No response from the web layer.", chatId: nil)
            }
            // The chat may exist even on failure paths (created-but-not-
            // active) — surface it either way so callers can record it.
            let chatId = dict["chatId"] as? String
            if let error = dict["error"] as? String, !error.isEmpty {
                return PlanRunStartResult(error: error, chatId: chatId)
            }
            return PlanRunStartResult(
                error: dict["started"] as? Bool == true ? nil : "The run did not start.",
                chatId: chatId
            )
        }
    }

    /// The store's injected bridge, wired to this AgentBridge.
    @MainActor
    public func planReviewBridge() -> PlanReviewStore.Bridge {
        PlanReviewStore.Bridge(
            list: { [weak self] chatId, roots in
                guard let self else { return .failure(PlanReviewError("The app is still starting up.")) }
                return await self.planReviewList(chatId: chatId, roots: roots)
            },
            get: { [weak self] chatId, plan, root in
                guard let self else { return .failure(PlanReviewError("The app is still starting up.")) }
                return await self.planReviewGet(chatId: chatId, plan: plan, root: root)
            },
            act: { [weak self] chatId, plan, action, author, root in
                guard let self else { return .failure(PlanReviewError("The app is still starting up.")) }
                return await self.planReviewAct(chatId: chatId, plan: plan, action: action, author: author, root: root)
            },
            create: { [weak self] chatId, title, problem, root in
                guard let self else { return .failure(PlanReviewError("The app is still starting up.")) }
                return await self.planReviewCreate(chatId: chatId, title: title, problem: problem, root: root)
            },
            runPrompt: { [weak self] chatId, plan, intent in
                guard let self else { return "" }
                return await self.planRunPrompt(chatId: chatId, plan: plan, intent: intent)
            },
            startRun: { [weak self] chatId, modelId, prompt, planKey, title in
                guard let self else {
                    return PlanRunStartResult(error: "The app is still starting up.", chatId: nil)
                }
                return await self.planStartRun(sourceChatId: chatId, modelId: modelId, prompt: prompt, planKey: planKey, title: title)
            },
            // availableModels is main-actor state on AgentBridge, so hop there
            // rather than reaching across from the Sendable closure.
            models: { [weak self] in
                guard let self else { return [] }
                if await MainActor.run(body: { self.availableModels.isEmpty }) {
                    await self.fetchModels()
                }
                return await MainActor.run { self.availableModels }
            },
            workDir: { [weak self] chatId in
                await self?.workScope(chatId: chatId)
            },
            setWorkDir: { [weak self] path in
                await self?.setWorkScope(path: path) ?? false
            },
            delete: { [weak self] chatId, plan, root in
                guard let self else { return "The app is still starting up." }
                return await self.planReviewDelete(chatId: chatId, plan: plan, root: root)
            },
            // The SAME bulk map the session list joins against — one account
            // tag store, one fetch, two lists. Plan rows are keyed by
            // `tagsId`, sessions by `metadataKey`; the map holds both.
            allTags: { [weak self] in
                guard let self else { return [:] }
                return await self.getSessionTags()
            }
        )
    }
}
