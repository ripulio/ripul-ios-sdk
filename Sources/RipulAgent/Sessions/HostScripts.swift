import Foundation

// MARK: - Models

/// One declared input to a host script. Mirrors the host's `ScriptParameter`,
/// minus its UUID — that only exists for the Mac editor's ForEach and never
/// crosses the relay.
public struct HostScriptParameter: Codable, Equatable, Identifiable {
    /// Local identity for list editing; not sent to the host.
    public var id = UUID()
    public var name: String
    public var type: String
    public var description: String
    public var required: Bool

    public static let types = ["string", "number", "boolean"]

    public init(name: String = "", type: String = "string", description: String = "", required: Bool = false) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }

    private enum CodingKeys: String, CodingKey { case name, type, description, required }
}

/// A host script as it crosses the relay. `id` is nil until the host stores it.
public struct HostScript: Codable, Equatable, Identifiable {
    public var id: String?
    public var name: String
    public var description: String
    public var source: String
    public var scriptType: String
    public var parameters: [HostScriptParameter]
    public var createdAt: Double?
    public var updatedAt: Double?

    public init(
        id: String? = nil,
        name: String = "",
        description: String = "",
        source: String = "",
        scriptType: String = "bash",
        parameters: [HostScriptParameter] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.source = source
        self.scriptType = scriptType
        self.parameters = parameters
    }

    /// The remote-action id ScriptActionProvider advertises this script under.
    public var actionId: String? { id.map { "script:\($0)" } }

    /// What the editor actually sends: trimmed, with unnamed parameter rows
    /// dropped — those are scaffolding the user never filled in.
    var forSaving: HostScript {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.parameters = parameters
            .map { var p = $0; p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines); return p }
            .filter { !$0.name.isEmpty }
        return copy
    }

    /// Content equality, ignoring the editor-only parameter ids and timestamps.
    func sameContent(as other: HostScript) -> Bool {
        let a = forSaving, b = other.forSaving
        return a.id == b.id && a.name == b.name && a.description == b.description
            && a.source == b.source && a.scriptType == b.scriptType
            && a.parameters.map { [$0.name, $0.type, $0.description, "\($0.required)"] }
                == b.parameters.map { [$0.name, $0.type, $0.description, "\($0.required)"] }
    }
}

/// Result of listing a host's scripts. `supported` false = the host has no
/// script store at all (anything but a relay-connected Mac host).
public struct HostScriptsList {
    public var supported: Bool
    public var scripts: [HostScript]
    public var error: String?
}

// MARK: - Bridge

/// `AgentBridge` access to a host's script store — the scripts
/// ScriptActionProvider turns into the tiles in that machine's panel.
///
/// Same shape as RepoNavigatorBridge: the web layer owns the relay round-trip
/// (`__ripulRemoteScript*` in FrameMCPBridge) and hands back the host's
/// payload; this only decodes it.
extension AgentBridge {

    public func fetchHostScripts(machineId: String) async -> HostScriptsList {
        do {
            let value = try await callPageFunction(
                "return await window.__ripulRemoteScriptList?.(machineId) ?? { supported: false, scripts: [], error: 'Script editing is not available in this build.' };",
                arguments: ["machineId": machineId])
            guard let dict = value as? [String: Any] else {
                return HostScriptsList(supported: false, scripts: [], error: "The app is still starting up.")
            }
            let scripts = (dict["scripts"] as? [[String: Any]] ?? []).compactMap(Self.decodeScript)
            return HostScriptsList(
                supported: dict["supported"] as? Bool ?? false,
                scripts: scripts,
                error: dict["error"] as? String)
        } catch {
            handleConsoleLog("[AgentBridge] fetchHostScripts error: \(error.localizedDescription)")
            return HostScriptsList(supported: true, scripts: [], error: error.localizedDescription)
        }
    }

    /// Create (nil id) or update one script. Returns the host's stored copy,
    /// which carries the id assigned on create.
    public func saveHostScript(machineId: String, script: HostScript) async -> Result<HostScript, HostScriptError> {
        do {
            let data = try JSONEncoder().encode(script.forSaving)
            let payload = try JSONSerialization.jsonObject(with: data)
            let value = try await callPageFunction(
                "return await window.__ripulRemoteScriptSave?.(machineId, script) ?? { success: false, error: 'Script editing is not available in this build.' };",
                arguments: ["machineId": machineId, "script": payload])
            guard let dict = value as? [String: Any] else {
                return .failure(HostScriptError("The app is still starting up."))
            }
            guard dict["success"] as? Bool == true,
                  let raw = dict["script"] as? [String: Any],
                  let stored = Self.decodeScript(raw) else {
                return .failure(HostScriptError(dict["error"] as? String ?? "Save failed"))
            }
            return .success(stored)
        } catch {
            handleConsoleLog("[AgentBridge] saveHostScript error: \(error.localizedDescription)")
            return .failure(HostScriptError(error.localizedDescription))
        }
    }

    public func deleteHostScript(machineId: String, scriptId: String) async -> Result<Void, HostScriptError> {
        do {
            let value = try await callPageFunction(
                "return await window.__ripulRemoteScriptDelete?.(machineId, scriptId) ?? { success: false, error: 'Script editing is not available in this build.' };",
                arguments: ["machineId": machineId, "scriptId": scriptId])
            guard let dict = value as? [String: Any] else {
                return .failure(HostScriptError("The app is still starting up."))
            }
            guard dict["success"] as? Bool == true else {
                return .failure(HostScriptError(dict["error"] as? String ?? "Delete failed"))
            }
            return .success(())
        } catch {
            handleConsoleLog("[AgentBridge] deleteHostScript error: \(error.localizedDescription)")
            return .failure(HostScriptError(error.localizedDescription))
        }
    }

    private static func decodeScript(_ raw: [String: Any]) -> HostScript? {
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(HostScript.self, from: data)
    }
}

public struct HostScriptError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
