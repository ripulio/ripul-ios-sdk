import Foundation

/// Tab and window mirroring: what a paired Mac's browser and apps look like
/// from here, and driving them.
extension AgentBridge {
    /// List the open browser tabs on a host machine (tab mirror).
    /// Returns `{success, tabs?: [{id, url, title, active, favIconUrl?, contextId?, contextName?}],
    /// contexts?: [{id, name, colorIndex, isEphemeral, tabCount?}], error?}`. `contexts` is
    /// absent when the host has none to offer (Chrome, an older Mac).
    public func mirrorListTabs(machineId: String) async -> [String: Any] {
        await mirrorCall("__ripulMirrorListTabs", [machineId])
    }

    /// List the Mac app windows on a host machine (window pixel mirror).
    /// Returns `{success, windows?: [{id, title, app, onScreen, frontmost, isSelf, width, height}], error?}`.
    /// One level of a mirrored app's menu bar, read through Accessibility on
    /// the Mac. An empty path is the menu bar itself.
    ///
    /// Reading needs no activation, so browsing a background app's menus costs
    /// the user nothing. Pressing is what needs the app forward, and the Mac
    /// side does that itself.
    /// Any allow-listed capability call on the mirrored machine.
    ///
    /// The generic door. Every mirror feature before this one needed its own
    /// method here, its own callable, its own relay command and its own entry
    /// in five more lists; behind this, a new capability is a line in the Mac's
    /// allowlist and nothing else. The Mac holds that allowlist, because a gate
    /// the caller could edit would not be a gate.
    public func mirrorInvoke(
        machineId: String, capability: String, method: String, args: [Any], chatId: String? = nil
    ) async -> [String: Any] {
        await mirrorCall("__ripulMirrorInvoke", [machineId, capability, method, args, chatId])
    }

    /// A mirrored app's whole menu tree, children nested under their parent.
    ///
    /// One call rather than one per level, because a real menu needs its
    /// children the moment it opens.
    public func mirrorMenuTree(
        machineId: String, pid: Int, maxDepth: Int = 3, budget: Int = 1200
    ) async -> [String: Any] {
        await mirrorCall("__ripulMirrorMenuTree", [machineId, pid, maxDepth, budget])
    }

    /// Invoke a menu item on a mirrored app.
    public func mirrorMenuPress(machineId: String, pid: Int, path: [Int]) async -> [String: Any] {
        await mirrorCall("__ripulMirrorMenuPress", [machineId, pid, path])
    }

    public func mirrorListWindows(machineId: String) async -> [String: Any] {
        await mirrorCall("__ripulMirrorListWindows", [machineId])
    }

    /// Collect switcher thumbnails for Mac app windows (window pixel mirror).
    /// Returns `{success, thumbs: {"<windowId>": {w, h, jpegB64}}, error?}` —
    /// the web side gathers them off the ephemeral stream channel, so this
    /// can take a few seconds for a long window list.
    public func mirrorWindowThumbs(machineId: String, windowIds: [Int]) async -> [String: Any] {
        await mirrorCall("__ripulMirrorWindowThumbs", [machineId, windowIds])
    }

    /// Open a new browser tab on a host machine (tab mirror). Bare hosts are
    /// upgraded to https:// web-side. Returns `{success, tab?, error?}` where
    /// tab carries {id, url, title, ...} for jumping straight into a mirror.
    ///
    /// Contexts are the host's. `contextId` names one of them (from
    /// `mirrorListTabs`' `contexts`); `newContextName` / `newContextEphemeral`
    /// have the host make one first. Neither: the host's own choice, which is
    /// the context of its active tab.
    public func mirrorOpenTab(
        machineId: String,
        url: String,
        contextId: String? = nil,
        newContextName: String? = nil,
        newContextEphemeral: Bool = false
    ) async -> [String: Any] {
        var options: [String: Any] = [:]
        if let contextId { options["contextId"] = contextId }
        if newContextName != nil || newContextEphemeral {
            options["newContext"] = ["name": newContextName ?? "", "ephemeral": newContextEphemeral] as [String: Any]
        }
        return await mirrorCall("__ripulMirrorOpenTab", [machineId, url, options])
    }

    /// Delete one of a host machine's browsing contexts (tab mirror): its tabs
    /// close and its cookies and storage go. Returns `{success, contexts?, error?}`
    /// with the contexts that are left.
    public func mirrorRemoveContext(machineId: String, contextId: String) async -> [String: Any] {
        await mirrorCall("__ripulMirrorRemoveContext", [machineId, contextId])
    }

    /// Open the full-screen live tab-mirror overlay in the web layer. The
    /// caller must first put the UI in a state where the webview is visible
    /// (agent tab, chat state) — the overlay paints inside the webview and
    /// hides the native chat chrome itself via page:context.
    public func openTabMirror(machineId: String, tabId: Int, title: String) async {
        _ = await callPage("__ripulOpenTabMirror", [machineId, tabId, title], .orElse("{success:false}"), log: .none)
    }

    /// Drive browser navigation on a host tab (remote browser chrome).
    /// action: "back" | "forward" | "reload" | "navigate" | "close";
    /// url is required for "navigate". Returns `{success, tab?, error?}`.
    public func mirrorTabControl(machineId: String, tabId: Int, action: String, url: String? = nil, width: Int? = nil, height: Int? = nil) async -> [String: Any] {
        await mirrorCall("__ripulMirrorTabControl", [machineId, tabId, action, url ?? "", width ?? 0, height ?? 0])
    }

    /// Set the mirror's reticule pointer mode: "off" | "pointer" | "inspect".
    public func setMirrorPointerMode(_ mode: String) async {
        _ = await callPage("__ripulSetMirrorPointerMode", [mode], .orElse("{success:false}"), log: .none)
    }

    /// Close the tab-mirror overlay if open (safe no-op otherwise).
    public func closeTabMirror() async {
        _ = await callPage("__ripulCloseTabMirror", [], .orElse("{success:false}"), log: .none)
    }

    /// One mirror callable. They all answer `{success, error?, …}`, and the
    /// caller gets that dictionary whether it came from the Mac or from here.
    private func mirrorCall(_ function: String, _ arguments: [Any?], caller: String = #function) async -> [String: Any] {
        let reply = await callPage(function, arguments, .orElse("{success:false, error:'not ready'}"), log: .console, caller: caller)
        if let reason = reply.failure() { return ["success": false, "error": reason] }
        return reply.dictionary ?? ["success": false, "error": "Unexpected result type"]
    }
}
