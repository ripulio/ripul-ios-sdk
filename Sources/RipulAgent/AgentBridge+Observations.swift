import Foundation

/// Observations: what agents noticed and someone should act on later
/// (tangents), and what they left unfinished (loose ends), kept per repository
/// for the account. The page reads and writes them (`nativeCallables/
/// observations.ts`); every change made from here is a person's.
///
/// Plan: docs/plans/observations.md.
extension AgentBridge {

    public struct RepoObservation: Identifiable, Equatable {
        public struct RepositoryMove: Equatable {
            public let fromRepoKey: String
            public let toRepoKey: String
            public let chatTitle: String
            public let note: String
            public let at: Date?
        }

        public struct Sighting: Equatable {
            public let chatId: String
            public let chatTitle: String?
            public let note: String?
        }

        public let id: String
        public let repoKey: String
        public let title: String
        public let detail: String
        /// `tangent` or `loose-end`.
        public let kind: String
        /// `low`, `medium`, `high`, `critical`.
        public let severity: String
        public let category: String
        public let files: [String]
        /// `open`, `doing`, `done`, `dropped`.
        public let status: String
        public let resolution: String?
        public let raisedByChatId: String
        public let raisedByTitle: String?
        public let raisedOn: String?
        public let branch: String?
        public let claimedByChatId: String?
        public let claimedByTitle: String?
        public let personEdited: Bool
        public let sightings: [Sighting]
        public let repositoryMoves: [RepositoryMove]
        public let createdAt: Date?
        public let updatedAt: Date?

        public var isClosed: Bool { status == "done" || status == "dropped" }
        public var kindLabel: String { kind == "loose-end" ? "loose end" : "tangent" }
        public var statusLabel: String {
            switch status {
            case "doing": return "In hand"
            case "done": return "Done"
            case "dropped": return "Dropped"
            default: return "Open"
            }
        }
        public var severityRank: Int {
            switch severity {
            case "critical": return 3
            case "high": return 2
            case "medium": return 1
            default: return 0
            }
        }
    }

    public struct ChatObservations: Equatable {
        public let repoKey: String?
        public let repoName: String?
        public let reason: String?
        public let chat: [RepoObservation]
        public let open: [RepoObservation]
    }

    public static let observationSeverities = ["low", "medium", "high", "critical"]
    public static let observationCategories = ["bug", "performance", "security", "enhancement", "tech-debt", "ux", "docs", "tests"]

    /// A chat's section: its repository, what it raised or saw, and the
    /// repository's open list. Nil when the page could not answer.
    public func getChatObservations(chatId: String) async -> ChatObservations? {
        let reply = await callPage("__ripulGetChatObservations", [chatId], .ifMissing("{ error: 'not ready' }"))
        guard let dict = reply.dictionary, dict["error"] == nil else { return nil }
        return ChatObservations(
            repoKey: dict["repoKey"] as? String,
            repoName: dict["repoName"] as? String,
            reason: dict["reason"] as? String,
            chat: Self.parseObservations(dict["chat"]),
            open: Self.parseObservations(dict["open"])
        )
    }

    /// A repository's observations. `repo` is its key or its origin URL.
    /// `status` is nil for open and in hand, `"all"`, or a comma list.
    public func listObservations(repo: String, status: String? = nil) async -> (repoKey: String?, observations: [RepoObservation])? {
        var filter: [String: Any] = ["repo": repo, "limit": 300]
        if let status { filter["status"] = status == "all" ? "all" : status.split(separator: ",").map(String.init) }
        let reply = await callPage("__ripulListObservations", [filter], .ifMissing("{ error: 'not ready' }"))
        guard let dict = reply.dictionary, dict["error"] == nil else { return nil }
        return (dict["repoKey"] as? String, Self.parseObservations(dict["observations"]))
    }

    public struct ObservationRepoCount: Identifiable, Equatable {
        public var id: String { repoKey }
        public let repoKey: String
        public let open: Int
        public let doing: Int
        public let critical: Int
        public let high: Int
        /// `ripul` for `github.com/ripulio/ripul`.
        public var name: String { repoKey.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? repoKey }
    }

    /// Every repository with observations, most recently changed first.
    public func observationRepos() async -> [ObservationRepoCount]? {
        let reply = await callPage("__ripulObservationRepos", [], .ifMissing("{ error: 'not ready' }"))
        guard let dict = reply.dictionary, dict["error"] == nil else { return nil }
        return (dict["repos"] as? [Any] ?? []).compactMap { entry in
            guard let r = entry as? [String: Any], let key = r["repoKey"] as? String else { return nil }
            return ObservationRepoCount(repoKey: key, open: r["open"] as? Int ?? 0, doing: r["doing"] as? Int ?? 0,
                                        critical: r["critical"] as? Int ?? 0, high: r["high"] as? Int ?? 0)
        }
    }

    /// A person records one, for the chat's repository or `repoKey`.
    @discardableResult
    public func createObservation(chatId: String?, repoKey: String? = nil, title: String, detail: String? = nil,
                                  severity: String, category: String) async -> RepoObservation? {
        var input: [String: Any] = ["title": title, "severity": severity, "category": category]
        if let repoKey { input["repoKey"] = repoKey }
        if let detail, !detail.isEmpty { input["detail"] = detail }
        let reply = await callPage("__ripulCreateObservation", [chatId, input], .ifMissing("{ error: 'not ready' }"))
        return Self.parseObservation(reply.dictionary?["observation"])
    }

    /// A person moves or edits one: `["status": "done", "resolution": "…"]`.
    @discardableResult
    public func patchObservation(chatId: String?, id: String, patch: [String: Any]) async -> RepoObservation? {
        let reply = await callPage("__ripulPatchObservation", [chatId, id, patch], .ifMissing("{ error: 'not ready' }"))
        return Self.parseObservation(reply.dictionary?["observation"])
    }

    @discardableResult
    public func deleteObservation(id: String) async -> Bool {
        let reply = await callPage("__ripulDeleteObservation", [id], .ifMissing("{ error: 'not ready' }"))
        return reply.dictionary?["deleted"] as? Bool == true
    }

    // MARK: - Parsing

    static func parseObservations(_ raw: Any?) -> [RepoObservation] {
        (raw as? [Any] ?? []).compactMap(parseObservation)
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseObservation(_ raw: Any?) -> RepoObservation? {
        guard let d = raw as? [String: Any],
              let id = d["id"] as? String,
              let title = d["title"] as? String else { return nil }
        let raised = d["raisedBy"] as? [String: Any] ?? [:]
        let claimed = d["claimedBy"] as? [String: Any]
        let files = (d["files"] as? [Any] ?? []).compactMap { entry -> String? in
            guard let f = entry as? [String: Any], let path = f["path"] as? String else { return nil }
            if let line = f["line"] as? Int { return "\(path):\(line)" }
            return path
        }
        let sightings = (d["sightings"] as? [Any] ?? []).compactMap { entry -> RepoObservation.Sighting? in
            guard let s = entry as? [String: Any], let chatId = s["chatId"] as? String else { return nil }
            return RepoObservation.Sighting(chatId: chatId, chatTitle: s["chatTitle"] as? String, note: s["note"] as? String)
        }
        return RepoObservation(
            id: id,
            repoKey: d["repoKey"] as? String ?? "",
            title: title,
            detail: d["detail"] as? String ?? "",
            kind: d["kind"] as? String ?? "tangent",
            severity: d["severity"] as? String ?? "low",
            category: d["category"] as? String ?? "",
            files: files,
            status: d["status"] as? String ?? "open",
            resolution: d["resolution"] as? String,
            raisedByChatId: raised["chatId"] as? String ?? "",
            raisedByTitle: raised["chatTitle"] as? String,
            raisedOn: raised["machine"] as? String,
            branch: raised["branch"] as? String,
            claimedByChatId: claimed?["chatId"] as? String,
            claimedByTitle: claimed?["chatTitle"] as? String,
            personEdited: d["personEdited"] as? Bool ?? false,
            sightings: sightings,
            repositoryMoves: (d["repositoryMoves"] as? [[String: Any]] ?? []).compactMap { move in
                guard let from = move["fromRepoKey"] as? String, let to = move["toRepoKey"] as? String else { return nil }
                let by = move["by"] as? [String: Any] ?? [:]
                return RepoObservation.RepositoryMove(fromRepoKey: from, toRepoKey: to,
                    chatTitle: by["chatTitle"] as? String ?? by["chatId"] as? String ?? "another chat",
                    note: move["note"] as? String ?? "", at: (move["at"] as? String).flatMap(isoParser.date(from:)))
            },
            createdAt: (d["createdAt"] as? String).flatMap(isoParser.date(from:)),
            updatedAt: (d["updatedAt"] as? String).flatMap(isoParser.date(from:))
        )
    }
}
