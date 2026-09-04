import Foundation
import WebKit

/// `AgentBridge` access to the repo navigator callables — the read-only git
/// queries behind the iPhone's GitKraken-style graph.
///
/// Same shape as PlanReviewBridge: the web layer owns the relay round-trip to
/// the paired Mac and hands back the host's payload untouched; nothing here
/// interprets git state. Errors arrive as `RepoNavigatorError` with a sentence
/// the screen can show — an unreachable machine, a stale repo path, and a git
/// failure all read the same way from the user's side.
@available(iOS 17.0, macOS 14.0, *)
extension AgentBridge {

    private func decodeRepoPayload<T: Decodable>(_ type: T.Type, from value: Any?, key: String) -> Result<T, RepoNavigatorError> {
        guard let dict = value as? [String: Any] else {
            return .failure(RepoNavigatorError("The web layer returned no repository data."))
        }
        if let error = dict["error"] as? String, !error.isEmpty {
            return .failure(RepoNavigatorError(error))
        }
        guard let payload = dict[key] else {
            return .failure(RepoNavigatorError("The web layer returned no \"\(key)\"."))
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .failure(RepoNavigatorError("Could not read the repository data: \(error.localizedDescription)"))
        }
    }

    /// Whole-dictionary variant for single-object replies (commit detail).
    private func decodeRepoObject<T: Decodable>(_ type: T.Type, from value: Any?) -> Result<T, RepoNavigatorError> {
        guard let dict = value as? [String: Any] else {
            return .failure(RepoNavigatorError("The web layer returned no repository data."))
        }
        if let error = dict["error"] as? String, !error.isEmpty {
            return .failure(RepoNavigatorError(error))
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .failure(RepoNavigatorError("Could not read the repository data: \(error.localizedDescription)"))
        }
    }

    private func callRepoNavigator(_ script: String, _ arguments: [String: Any]) async -> Result<Any?, RepoNavigatorError> {
        do {
            guard let value = try await callPageFunction(script, arguments: arguments) else {
                return .failure(RepoNavigatorError("The app is still starting up."))
            }
            return .success(value)
        } catch {
            return .failure(RepoNavigatorError(error.localizedDescription))
        }
    }

    /// Git repos discovered on the paired Mac. `roots` nil lets the host use
    /// its favorites + working directory + ~/Documents/repos.
    public func repoList(machineId: String, roots: [String]? = nil) async -> Result<[RepoSummary], RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoList?.(machineId, roots) ?? { roots: [], repos: [], error: 'Repo navigator is not available in this build.' };",
            ["machineId": machineId, "roots": roots.map { $0 as Any } ?? NSNull()])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decodeRepoPayload([RepoSummary].self, from: value, key: "repos")
        }
    }

    /// Commits across every ref, date-ordered, with parents and decorations —
    /// the full input the lane-assignment engine needs.
    public func repoGraph(machineId: String, repoPath: String, limit: Int = 300) async -> Result<RepoGraph, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoGraph?.(machineId, repoPath, limit) ?? { repoPath: '', commits: [], hasMore: false, error: 'Repo navigator is not available in this build.' };",
            ["machineId": machineId, "repoPath": repoPath, "limit": limit])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decodeRepoObject(RepoGraph.self, from: value)
        }
    }

    /// Local + remote branches with ahead/behind, most-recent first.
    public func repoBranches(machineId: String, repoPath: String) async -> Result<[BranchInfo], RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoBranches?.(machineId, repoPath) ?? { repoPath: '', branches: [], error: 'Repo navigator is not available in this build.' };",
            ["machineId": machineId, "repoPath": repoPath])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decodeRepoPayload([BranchInfo].self, from: value, key: "branches")
        }
    }

    /// One commit's full message, per-file stats, and unified diff (capped
    /// host-side; check `patchTruncated`).
    public func repoCommitDetail(machineId: String, repoPath: String, sha: String) async -> Result<CommitDetail, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoCommitDetail?.(machineId, repoPath, sha) ?? { error: 'Repo navigator is not available in this build.' };",
            ["machineId": machineId, "repoPath": repoPath, "sha": sha])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decodeRepoObject(CommitDetail.self, from: value)
        }
    }

    /// Push a branch with no upstream yet (`git push -u origin <branch>` on
    /// the host) — the navigator's one mutation. Returns git's stderr text
    /// on rejection so the row can show why.
    public func repoPushBranch(machineId: String, repoPath: String, branch: String) async -> Result<String, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoPushBranch?.(machineId, repoPath, branch) ?? { success: false, error: 'Repo navigator is not available in this build.' };",
            ["machineId": machineId, "repoPath": repoPath, "branch": branch])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value):
            guard let dict = value as? [String: Any] else {
                return .failure(RepoNavigatorError("The web layer returned no push result."))
            }
            if let error = dict["error"] as? String, !error.isEmpty {
                return .failure(RepoNavigatorError(error))
            }
            guard dict["success"] as? Bool == true else {
                return .failure(RepoNavigatorError("The push did not complete."))
            }
            return .success(branch)
        }
    }

    /// Working-tree status: branch, ahead/behind, dirty counts.
    public func repoStatus(machineId: String, repoPath: String) async -> Result<RepoStatus, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoStatus?.(machineId, repoPath) ?? { error: 'Repo navigator is not available in this build.' };",
            ["machineId": machineId, "repoPath": repoPath])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decodeRepoPayload(RepoStatus.self, from: value, key: "status")
        }
    }
}
