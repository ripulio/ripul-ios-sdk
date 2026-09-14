import Foundation

public struct FilesSearchResult: Decodable, Sendable {
    public struct File: Decodable, Sendable {
        public let path: String
        public let isDirectory: Bool
    }
    public struct Hit: Decodable, Sendable {
        public let path: String
        public let line: Int
        public let snippet: String
    }
    public let files: [File]
    public let hits: [Hit]
    public let hasMore: Bool
}

public struct FilesRepositories: Decodable, Sendable {
    public let repos: [RepoSummary]
    public let current: String?
}

@available(iOS 17.0, macOS 14.0, *)
extension AgentBridge {
    private func filesPayload<T: Decodable>(_ type: T.Type, script: String, arguments: [String: Any]) async throws -> T {
        guard let value = try await callPageFunction(script, arguments: arguments) as? [String: Any] else {
            throw RepoNavigatorError("Files is still connecting. Try again.")
        }
        if let error = value["error"] as? String { throw RepoNavigatorError(error) }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    public func filesRepositories(machineId: String) async throws -> FilesRepositories {
        try await filesPayload(FilesRepositories.self,
            script: "return await window.__ripulFilesRepos?.(machineId) ?? {error:'Files is still connecting. Try again.'};",
            arguments: ["machineId": machineId])
    }

    public func searchRepositoryFiles(machineId: String, cwd: String, query: String, contents: Bool, offset: Int = 0) async throws -> FilesSearchResult {
        try await filesPayload(FilesSearchResult.self,
            script: "return await window.__ripulFilesSearch?.(machineId, cwd, query, contents, offset) ?? {error:'Files is still connecting. Try again.'};",
            arguments: ["machineId": machineId, "cwd": cwd, "query": query, "contents": contents, "offset": offset])
    }
}
