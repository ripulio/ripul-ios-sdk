import Foundation

/// Choosing the model, effort and raw mode for the app and for one chat, and
/// editing the model list.
extension AgentBridge {
    /// Set the user's model override. Pass nil to revert to the default model.
    @discardableResult
    public func setModel(_ modelId: String?) async -> Bool {
        handleConsoleLog("LOG: [MODELSW] native.setModel (global) modelId=\(modelId ?? "default")")
        let reply = await callPage("__ripulSetModel", [modelId], .orElse("{success:false}"), log: .none)
        if reply.isDetached {
            handleConsoleLog("LOG: [MODELSW] native.setModel ABORT webView=nil")
            return false
        }
        if let error = reply.error {
            handleConsoleLog("LOG: [MODELSW] native.setModel ERROR \(error.localizedDescription)")
            return false
        }
        guard reply.succeeded, let dict = reply.dictionary else {
            handleConsoleLog("LOG: [MODELSW] native.setModel FAILED modelId=\(modelId ?? "default") result=\(String(describing: reply.value))")
            return false
        }
        self.selectedModelId = modelId
        // Picking from the global model menu IS the user expressing a
        // preference — the primary way the sticky default is set.
        rememberModelPick(modelId)
        handleConsoleLog("LOG: [MODELSW] native.setModel OK modelId=\(modelId ?? "default") readBack=\(dict["readBack"] as? String ?? "none")")
        return true
    }

    /// Load the current reasoning-effort override from the web app.
    public func fetchEffort() async {
        let reply = await callPage("__ripulGetEffort", [], .orElse("{effort:null}"))
        if let dict = reply.dictionary {
            setIfChanged(\.selectedEffort, dict["effort"] as? String)
        }
    }

    /// Set the reasoning-effort override. Pass nil for the CLI default.
    @discardableResult
    public func setEffort(_ effort: String?) async -> Bool {
        let reply = await callPage("__ripulSetEffort", [effort], .orElse("{success:false}"))
        guard reply.succeeded else { return false }
        self.selectedEffort = effort
        NSLog("[AgentBridge] setEffort: %@", effort ?? "default")
        return true
    }

    /// Whether the current principal may edit CLI models (owner/admin, not a
    /// site-key portal visitor). The backend also enforces admin on /admin/models*.
    public func canEditModels() async -> Bool {
        await callPage("__ripulCanEditModels", [], .orElse("{canEdit:false}")).dictionary?["canEdit"] as? Bool ?? false
    }

    /// Create or update a CLI model in the catalog. `bodyJSON` is a JSON
    /// UpsertModelRequest. Refreshes `availableModels` on success.
    /// Returns (success, errorMessage?).
    public func saveModel(id: String, bodyJSON: String) async -> (Bool, String?) {
        await editModel("__ripulSaveModel", [id, bodyJSON], otherwise: "Save failed")
    }

    /// Save or delete a model, then reload the list so the change shows.
    private func editModel(
        _ function: String, _ arguments: [Any?], otherwise: String, caller: String = #function
    ) async -> (Bool, String?) {
        let reply = await callPage(function, arguments, .orElse("{success:false, error:'\(function) unavailable'}"), caller: caller)
        if let reason = reply.failure(detached: "No web view") { return (false, reason) }
        guard let dict = reply.dictionary else { return (false, "Unexpected response") }
        guard (dict["success"] as? Bool) == true else { return (false, (dict["error"] as? String) ?? otherwise) }
        await fetchModels()
        return (true, nil)
    }

    /// Delete a CLI model from the catalog. Refreshes `availableModels` on success.
    /// Returns (success, errorMessage?).
    public func deleteModel(id: String) async -> (Bool, String?) {
        await editModel("__ripulDeleteModel", [id], otherwise: "Delete failed")
    }

    /// Set the model override for a specific chat tab (used for CLI raw sessions).
    /// Unlike setModel() which sets a global override, this targets a single chat.
    @discardableResult
    public func setChatModel(chatId: String, modelId: String) async -> Bool {
        handleConsoleLog("LOG: [MODELSW] native.setChatModel enter chatId=\(chatId.suffix(12)) modelId=\(modelId)")
        let reply = await callPage("__ripulSetChatModel", [chatId, modelId], .orElse("{success:false}"), log: .none)
        if reply.isDetached {
            handleConsoleLog("LOG: [MODELSW] native.setChatModel ABORT webView=nil")
            return false
        }
        if let error = reply.error {
            handleConsoleLog("LOG: [MODELSW] native.setChatModel ERROR \(error.localizedDescription)")
            return false
        }
        guard reply.succeeded, let dict = reply.dictionary else {
            handleConsoleLog("LOG: [MODELSW] native.setChatModel FAILED chatId=\(chatId.suffix(12)) modelId=\(modelId) result=\(String(describing: reply.value))")
            return false
        }
        let reason = dict["reason"] as? String ?? "unknown"
        let applied = dict["descriptorModelOverride"] as? String ?? "none"
        handleConsoleLog("LOG: [MODELSW] native.setChatModel OK chatId=\(chatId.suffix(12)) modelId=\(modelId) reason=\(reason) descriptorNowHas=\(applied)")
        return true
    }

    /// Toggle raw mode for a CLI session. In raw mode, prompts are passed verbatim
    /// to Claude with no system prompt wrapping and all tools available.
    /// Returns `(success, errorMessage)`. When success is false and errorMessage is
    /// non-nil, the caller should display it to the user.
    @discardableResult
    public func setRawMode(sessionId: String, enabled: Bool) async -> (Bool, String?) {
        let reply = await callPage("__ripulSetRawMode", [sessionId, enabled], .orElse("{success:false}"))
        if let error = reply.error { return (false, error.localizedDescription) }
        // The web app's own message, when it gave one.
        guard reply.succeeded else { return (false, reply.dictionary?["error"] as? String) }
        NSLog("[AgentBridge] setRawMode: session=%@, enabled=%@", sessionId, enabled ? "true" : "false")
        return (true, nil)
    }

    /// Check if a session is in raw mode by reading from the web app's localStorage.
    public func isRawMode(sessionId: String) async -> Bool {
        await runPage(
            """
            try {
                var map = JSON.parse(localStorage.getItem('cliRawModeSessions') || '{}');
                return !!map[sessionId];
            } catch(e) { return false; }
            """,
            arguments: ["sessionId": sessionId], log: .none).value as? Bool ?? false
    }

    /// Discover Codex raw models available on a specific host machine.
    /// Returns `ModelInfo` rows generated from that machine's installed Codex CLI catalog.
    public func discoverCodexModels(machineId: String) async -> [ModelInfo] {
        let reply = await callPage("__ripulDiscoverCodexModels", [machineId], .orElse("{models:[]}"), log: .console)
        guard let dict = reply.dictionary, let modelsArray = dict["models"] as? [[String: Any]] else { return [] }
        if let error = dict["error"] as? String, !error.isEmpty {
            handleConsoleLog("[AgentBridge] discoverCodexModels warning: \(error)")
        }
        return modelsArray.compactMap { item in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let modelId = item["modelId"] as? String else { return nil }
            return ModelInfo(
                id: id,
                name: name,
                modelId: modelId,
                provider: (item["provider"] as? String) ?? "codex-cli",
                group: (item["group"] as? String) ?? "Codex",
                description: item["description"] as? String,
                supportsThinking: (item["supportsThinking"] as? Bool) ?? true,
                cliSupportedEfforts: item["cliSupportedEfforts"] as? [String],
                cliDefaultEffort: item["cliDefaultEffort"] as? String
            )
        }
    }
}
