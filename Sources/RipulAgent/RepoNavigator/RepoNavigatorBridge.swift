import Foundation
import WebKit

/// `AgentBridge` access to the repo navigator callables — the git
/// queries and branch actions behind the iPhone's GitKraken-style graph.
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

    /// Repos the host's `gh` login can see, most recently pushed first. The
    /// error, when gh is missing or signed out, is worded for the screen.
    public func repoGithubList(machineId: String) async -> Result<GitHubRepoList, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoGithubList?.(machineId) ?? { repos: [], error: 'GitHub listing is not available in this build.' };",
            ["machineId": machineId])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value):
            switch decodeRepoPayload([GitHubRepo].self, from: value, key: "repos") {
            case .failure(let error): return .failure(error)
            case .success(let repos):
                let root = (value as? [String: Any])?["cloneRoot"] as? String
                return .success(GitHubRepoList(repos: repos, cloneRoot: root))
            }
        }
    }

    /// Start cloning `source` (owner/repo or a git URL) into the host's
    /// ~/Documents/repos. Returns as soon as the host has started; poll
    /// `repoCloneStatus` for progress.
    public func repoClone(machineId: String, source: String, name: String? = nil) async -> Result<RepoCloneJob, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoClone?.(machineId, source, name) ?? { success: false, error: 'Cloning is not available in this build.' };",
            ["machineId": machineId, "source": source, "name": name.map { $0 as Any } ?? NSNull()])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decodeRepoPayload(RepoCloneJob.self, from: value, key: "job")
        }
    }

    public func repoCloneStatus(machineId: String, jobId: String) async -> Result<RepoCloneJob, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoCloneStatus?.(machineId, jobId) ?? { error: 'Cloning is not available in this build.' };",
            ["machineId": machineId, "jobId": jobId])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decodeRepoPayload(RepoCloneJob.self, from: value, key: "job")
        }
    }

    /// Who the host's `gh` CLI is signed in to GitHub as, or the code of a
    /// sign-in waiting for approval.
    public func repoGithubAuthStatus(machineId: String) async -> Result<GitHubAuthStatus, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoGithubAuthStatus?.(machineId) ?? { error: 'GitHub sign-in is not available in this build.' };",
            ["machineId": machineId])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decodeRepoPayload(GitHubAuthStatus.self, from: value, key: "status")
        }
    }

    /// Start GitHub's device flow on the host (`gh auth login --web`). Returns
    /// the one-time code to enter at the returned URL; gh finishes by itself
    /// once it is approved, so poll `repoGithubAuthStatus`.
    public func repoGithubAuthBegin(machineId: String) async -> Result<GitHubAuthPending, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoGithubAuthBegin?.(machineId) ?? { success: false, error: 'GitHub sign-in is not available in this build.' };",
            ["machineId": machineId])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value): return decodeRepoPayload(GitHubAuthPending.self, from: value, key: "pending")
        }
    }

    public func repoGithubAuthCancel(machineId: String) async -> Result<Void, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoGithubAuthCancel?.(machineId) ?? { success: false, error: 'GitHub sign-in is not available in this build.' };",
            ["machineId": machineId])
        switch result {
        case .failure(let message): return .failure(message)
        case .success(let value):
            if let error = (value as? [String: Any])?["error"] as? String, !error.isEmpty {
                return .failure(RepoNavigatorError(error))
            }
            return .success(())
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
    /// the host). Returns git's stderr text
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

    /// Switch on the selected host, preserving Git's working-tree protections.
    public func repoSwitchBranch(machineId: String, repoPath: String, branch: String, isRemote: Bool) async -> Result<String, RepoNavigatorError> {
        let result = await callRepoNavigator(
            "return await window.__ripulRepoSwitchBranch?.(machineId, repoPath, branch, isRemote) ?? { success: false, error: 'Branch switching requires the latest app and host build.' };",
            ["machineId": machineId, "repoPath": repoPath, "branch": branch, "isRemote": isRemote])
        switch result {
        case .failure(let error): return .failure(error)
        case .success(let value):
            guard let dict = value as? [String: Any] else {
                return .failure(RepoNavigatorError("The web layer returned no switch result."))
            }
            if let error = dict["error"] as? String, !error.isEmpty {
                return .failure(RepoNavigatorError(error))
            }
            guard dict["success"] as? Bool == true,
                  let currentBranch = dict["branch"] as? String, !currentBranch.isEmpty else {
                return .failure(RepoNavigatorError("The host did not confirm the branch switch. Refresh to check the current branch."))
            }
            return .success(currentBranch)
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
