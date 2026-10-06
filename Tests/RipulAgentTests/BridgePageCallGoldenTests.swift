#if os(macOS)
import WebKit
import XCTest
@testable import RipulAgent

/// Pins what every AgentBridge call into the page sends and hands back.
///
/// Each probe is one bridge call with fixed arguments, run against a page that
/// answers in each of the ways a page can: not attached, callable not defined,
/// null, a bare number, a refusal, a full answer, a throw. What the page saw,
/// what the bridge returned, what it logged and which of its properties moved
/// are written out and compared with `Tests/Golden/bridge-page-calls.txt`.
///
/// The record describes today's behaviour; it is not a specification. When a
/// change to a call is intended, re-record and read the diff before committing:
///
///     RIPUL_RECORD_GOLDEN=1 swift test --filter BridgePageCallGoldenTests
///
/// `RIPUL_BRIDGE_PROBES=mirror,archive` runs only the probes whose name
/// contains one of those words. macOS only: it reads NSLog off stderr.
@MainActor
final class BridgePageCallGoldenTests: XCTestCase {

    // MARK: - The ways a page can answer

    enum PageState: String, CaseIterable {
        case detached, missing, null, scalar, refused, answered, throwing

        /// What every callable does in this state. `name` is in scope.
        var behaviour: String {
            switch self {
            case .detached, .missing: return ""
            case .null: return "return null;"
            case .scalar: return "return 7;"
            case .refused: return "return {success:false, ok:false, error:'refused'};"
            case .answered: return "return name in answers ? answers[name] : {success:true, ok:true};"
            case .throwing: return "throw new Error('kaboom');"
            }
        }
    }

    struct Probe {
        let name: String
        var states: [PageState] = PageState.allCases
        /// Extra page script, run after the callables are defined.
        var page = ""
        var prepare: @MainActor (AgentBridge) -> Void = { _ in }
        let run: @MainActor (AgentBridge) async -> Any?
    }

    /// States for calls that go on to probe and reload the page when the
    /// answer is unusable: those paths carry timings and are not pinned here.
    private static let settled: [PageState] = [.detached, .missing, .refused, .answered]

    // MARK: - What the page answers when it answers in full

    private static let answers: [String: String] = [
        "__ripulArchiveRemoteSession": "{success:true}",
        "__ripulCanEditModels": "{canEdit:true}",
        "__ripulClearCommsLog": "{success:true}",
        "__ripulClearReplyTarget": "{success:true}",
        "__ripulCloseSession": "{success:true}",
        "__ripulCloseTabMirror": "{success:true}",
        "__ripulConnectToMachine": "{success:true, tabId:'tab-c', chatId:'chat-c', machineName:'Studio', hostChatId:'host-c'}",
        "__ripulConnectToMachineWithProvider": "{success:true, tabId:'tab-p', chatId:'chat-p', machineName:'Studio', hostChatId:'host-p'}",
        "__ripulConsoleExec": "{exitCode:0, stdout:'out'}",
        "__ripulConsoleJobControl": "{jobs:[{id:'j1'}]}",
        "__ripulCreateChat": "{success:true, chatId:'chat-new', tabId:'tab-new'}",
        "__ripulDeleteArchivedSession": "{success:true}",
        "__ripulDeleteModel": "{success:true}",
        "__ripulDeleteSession": "{success:true, results:['local'], errors:[]}",
        "__ripulDiagnostics": "{relay:'connected', machines:1}",
        "__ripulDiscoverCodexModels": "{models:[{id:'c1', name:'Codex One', modelId:'gpt-x', cliSupportedEfforts:['low','high'], cliDefaultEffort:'low'},{id:'bad'}], error:'partial'}",
        "__ripulDiscoverRemoteActions": "{actions:[{id:'a1', title:'Action'}], error:'partial'}",
        "__ripulEvictSessionChannel": "{success:true}",
        "__ripulExecuteRemoteAction": "{success:true, output:{status:'ok', fields:[1,2]}}",
        "__ripulFileViewerFind": "{total:3, current:1}",
        "__ripulFileViewerFindNext": "{total:3, current:2}",
        "__ripulFileViewerFindPrev": "{total:3, current:3}",
        "__ripulFilesDirectory": "{entries:[{path:'/m/a', isDirectory:true},{nope:1}]}",
        "__ripulFilesRead": "{content:'machine file body'}",
        "__ripulFocusSession": "{success:true}",
        "__ripulForkSession": "{success:true, newChatId:'chat-fork'}",
        "__ripulGetAgentLifecycleSnapshot": "{chatId:'chat-1', phase:'running', sequence:3, timestamp:1700000000000}",
        "__ripulGetAgentStatus": "{isRunning:true, isPaused:false, chatId:'chat-1'}",
        "__ripulGetChatToolCategories": "{categories:[{name:'files', label:'Files', description:'d', toolCount:3, enabled:false},{name:'x'},{}]}",
        "__ripulGetChatToolInventory": "{categories:[]}",
        "__ripulGetCommsLog": "{available:true, entries:[]}",
        "__ripulGetComposerState": "{actions:[{id:'queue', label:'Queue', description:'Send after this turn', sfSymbol:'clock'}], runningSendLabel:'Queue'}",
        "__ripulGetConversationMode": "{mode:'chat', showModeSwitcher:true}",
        "__ripulGetEffort": "{effort:'high'}",
        "__ripulGetFavoriteDirectories": "{directories:['/a','/b'], current:'/a', sessionDirectory:'/s'}",
        "__ripulGetGroupChatIds": "['g1','g2',3]",
        "__ripulGetHostSettings": "{success:true, settings:[]}",
        "__ripulGetHostStatus": "{available:true, enabled:true}",
        "__ripulGetLastAssistantText": "{text:'reply'}",
        "__ripulGetMachines": "{machines:[{machineId:'m1', displayName:'Studio', roomId:'room-1', lastSeenAt:'2026-10-01T00:00:00Z', meta:{os:'mac'}, shared:true},{machineId:'broken'}], error:'stale'}",
        "__ripulGetModels": "{models:[{id:'m1', name:'Model One', modelId:'model-1', provider:'anthropic', supportsThinking:true, sortOrder:1, perMInput:3, perMOutput:15},{id:'bad'}], selectedModelId:'m1', modelSelectionEnabled:true}",
        "__ripulGetRelayDiagnostics": "{available:true, rooms:[]}",
        "__ripulGetRemoteCliAccount": "{account:{email:'a@b.c', plan:'max'}, error:null}",
        "__ripulGetResolvedToolsForSession": "{tools:[{name:'t1', description:'d'},{name:'t2'},{}]}",
        "__ripulGetSessionMetadata": "{metadata:{id:'s1', description:'d', notes:[{id:'n1', text:'note'}], filesEdited:[], deployments:[], contributors:[], participants:[], model:'m', modelHistory:['m'], createdAt:'c', updatedAt:'u'}}",
        "__ripulGetSessionStorageBreakdown": "{breakdown:{totalBytes:100, count:2, buckets:[{name:'actions', bytes:60, count:1},{bytes:1}]}}",
        "__ripulGetSessionTags": "{'tab-1':['a','b'], 'tab-2':['c', 5], 'tab-3':'no'}",
        "__ripulGetSessions": "{sessions:[{id:'tab-1', sourceChatId:'chat-1', displayName:'One', createdAt:1700000000000, provider:'claude-cli', displayNameSource:'user'},{id:'tab-2', sourceChatId:'chat-2', displayName:'Two', createdAt:1700000001000},{id:'bad'}], activeId:'tab-2'}",
        "__ripulGetShowThinking": "{success:true, mode:'full'}",
        "__ripulGetSlashCommands": "[{command:'/review', description:'Review', icon:'eye', type:'action', hasVariables:true, options:[{value:'v', label:'L', description:'D'},{value:'x'}]},{command:'/broken'}]",
        "__ripulGrepRemoteFiles": "[{path:'/a', line:3, snippet:'s'},{path:'/b', line:4.5},{nope:1}]",
        "__ripulImportCliSession": "{success:true}",
        "__ripulInjectFileContent": "{success:true}",
        "__ripulInjectFileError": "{success:true}",
        "__ripulInterruptAgent": "{success:true}",
        "__ripulInviteToSession": "{success:true}",
        "__ripulJoinShareLink": "{ok:true, tabId:'tab-shared', label:'Shared'}",
        "__ripulKillMachine": "{success:true}",
        "__ripulLeaveSharedChat": "{success:true}",
        "__ripulListArchivedSessions": "{sessions:[{id:'a1', displayName:'Old', projectName:'p', archivedAt:1700000000000, provider:'claude-cli'},{id:'a2'},{nope:1}]}",
        "__ripulListCommitsWithSessions": "{repoPath:'/repo', commits:[{sha:'abc', shortSha:'ab', subject:'s', authorName:'n', timestamp:1700000000, branch:'main', sessionId:'s1', sessionTitle:'t', filesEditedCount:2, description:'d', deploymentTargets:['web'], filesEdited:[{fileName:'f', filePath:'/f', editCount:2, lastSeenAt:'x'},{}], notes:[{id:'n1', text:'note', createdAt:'c', timestamp:'t'}], deployments:[{id:'d1', target:'web', timestamp:'t'}]},{sha:'bad'}], error:null}",
        "__ripulListDirectory": "{entries:[{path:'/a', isDirectory:true},{path:'/b'},{nope:1}], error:null}",
        "__ripulListRemoteSessions": "{sessions:[{id:'s1', sourceChatId:'c1', displayName:'Remote', createdAt:1700000000000, lastModified:1700000005000, isRunning:true, projectName:'p', cwd:'/w', gitBranch:'main', messageCount:3, provider:'claude-cli', providerLabel:'Claude', model:'m', hostChatId:'h1'},{id:'bad'}], timeline:['a','b'], error:''}",
        "__ripulListTodoItems": "{items:[{id:'t1', text:'do', chatId:'chat-1', chatName:'One', completed:true},{id:'bad'}], currentChatId:'chat-1'}",
        "__ripulMirrorInvoke": "{success:true, result:{ok:1}}",
        "__ripulMirrorListTabs": "{success:true, tabs:[{id:1, url:'https://x', title:'X', active:true}]}",
        "__ripulMirrorListWindows": "{success:true, windows:[{id:9, title:'W'}]}",
        "__ripulMirrorMenuPress": "{success:true}",
        "__ripulMirrorMenuTree": "{success:true, items:[]}",
        "__ripulMirrorOpenTab": "{success:true, tabId:4}",
        "__ripulMirrorRemoveContext": "{success:true}",
        "__ripulMirrorTabControl": "{success:true}",
        "__ripulMirrorWindowThumbs": "{success:true, thumbs:{}}",
        "__ripulMoveSession": "{success:true, newChatId:'chat-moved', effectiveCwd:'/w', cwdFallback:true, targetMachineName:'Studio', sourceRemoved:true, sourceRemoveError:null}",
        "__ripulOpenRemoteSession": "{success:true, tabId:'tab-o', provider:'claude-cli', providerLabel:'Claude'}",
        "__ripulOpenTabMirror": "{success:true}",
        "__ripulPatchSessionMetadata": "{metadata:{id:'s1', description:'patched', notes:[], filesEdited:[], deployments:[], contributors:[], participants:[], modelHistory:[]}}",
        "__ripulPrewarmNewChat": "true",
        "__ripulQueryAutocomplete": "{suggestions:[{label:'s'}]}",
        "__ripulQueryPageElements": "['#a','#b']",
        "__ripulQueryParticipants": "{participants:[{id:'p1'}]}",
        "__ripulQueryRemoteFiles": "{files:[{path:'/a.txt'}]}",
        "__ripulReadRemoteFile": "{content:'file body'}",
        "__ripulRemoteClaudeAccountCreate": "{ok:true, slug:'work', name:'Work'}",
        "__ripulRemoteClaudeAccountDelete": "{ok:true, active:'default'}",
        "__ripulRemoteClaudeAccountSwitch": "{ok:true, active:'work', recycledSessions:['s1'], deferredBusySessions:['s2']}",
        "__ripulRemoteClaudeAccountsList": "{accounts:[{slug:'default', name:'Default'},{slug:'work', name:'Work', email:'w@b.c'}], active:'work'}",
        "__ripulRemoteHostAuthBegin": "{sessionId:'auth-1', authUrl:'https://auth'}",
        "__ripulRemoteHostAuthCancel": "{ok:true}",
        "__ripulRemoteHostAuthStatus": "{loggedIn:true, email:'a@b.c'}",
        "__ripulRemoteHostAuthSubmitCode": "{ok:true}",
        "__ripulRenameSession": "{success:true, displayName:'Confirmed', renamedAt:1700000000000}",
        "__ripulRepairConnection": "{success:true}",
        "__ripulRescueSession": "{success:true, localTabId:'tab-r', newChatId:'chat-r', cwdFallback:true, targetMachineName:'Studio'}",
        "__ripulResetHostPeaks": "{ok:true}",
        "__ripulRestoreArchivedSession": "{success:true}",
        "__ripulRestoreRemoteSession": "{success:true}",
        "__ripulResumeAgent": "{success:true}",
        "__ripulResumeFromCommit": "{success:true, sessionId:'s-res'}",
        "__ripulSaveModel": "{success:true}",
        "__ripulSearchFiles": "[{path:'/a', isDirectory:true},{path:'/b'},{nope:1}]",
        "__ripulSetChatModel": "{success:true, reason:'applied', descriptorModelOverride:'m1'}",
        "__ripulSetChatToolCategories": "{success:true}",
        "__ripulSetConversationMode": "{success:true}",
        "__ripulSetEffort": "{success:true}",
        "__ripulSetHostEnabled": "{success:true}",
        "__ripulSetHostSetting": "{success:true}",
        "__ripulSetMirrorPointerMode": "{success:true}",
        "__ripulSetModel": "{success:true, readBack:'m1'}",
        "__ripulSetRawMode": "{success:true}",
        "__ripulSetSessionTags": "{ok:true}",
        "__ripulSetShowThinking": "{success:true}",
        "__ripulSetWorkingDirectory": "{success:true}",
        "__ripulStartNewChatWithPrompt": "{success:true, chatId:'chat-p', tabId:'tab-p', machineId:'m1'}",
        "__ripulSubmitComposerAction": "{success:true}",
        "__ripulSubmitMessage": "{success:true}",
        "__ripulSubmitNote": "{success:true}",
        "__ripulTruncateSession": "{success:true, removed:4}",
    ]

    // MARK: - The calls

    /// Text that breaks a script built by pasting it in: quotes, a backslash, a newline.
    private static let awkward = "it's \"quoted\" \\ and\nsplit"

    private static func twoSessions(_ bridge: AgentBridge) {
        bridge.sessions = [
            ChatSession(id: "tab-1", sourceChatId: "chat-1", displayName: "One", createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ChatSession(id: "tab-2", sourceChatId: "chat-2", displayName: "Two", createdAt: Date(timeIntervalSince1970: 1_700_000_001)),
        ]
        bridge.activeSessionId = "tab-1"
    }

    private static let probes: [Probe] = [
        // Conversation
        Probe(name: "clearReplyTarget") { await $0.clearReplyTarget(chatId: "chat-1") },
        Probe(name: "refreshConversationMode") { await $0.refreshConversationMode(chatId: "chat-1") },
        Probe(name: "setConversationMode") { await $0.setConversationMode(chatId: "chat-1", mode: "plan") },
        Probe(name: "fetchWebDiagnostics") { await $0.fetchWebDiagnostics() },
        Probe(name: "fetchWebDiagnostics.focused") { await $0.fetchWebDiagnostics(focusChatId: "chat-1", action: "open") },
        Probe(name: "fetchWebDiagnostics.focusedNoAction") { await $0.fetchWebDiagnostics(focusChatId: "chat-1") },
        Probe(name: "startNewChat") { await $0.startNewChat() },
        Probe(name: "startNewChat.prompt") { await $0.startNewChat(prompt: awkward) },
        Probe(name: "submitMessage") { await $0.submitMessage(awkward) },
        Probe(name: "submitMessage.images") {
            await $0.submitMessage("hi", imageAttachments: [["id": "i1", "mediaType": "image/png", "data": "AAAA"]])
        },
        Probe(name: "submitMessage.addressed") { await $0.submitMessage("hi", addressedTo: ["@a"], modality: "voice") },
        Probe(name: "submitMessage.all") {
            await $0.submitMessage("hi", imageAttachments: [["id": "i1", "mediaType": "image/png", "data": "AAAA"]],
                                   addressedTo: ["@a", "@b"], modality: "voice")
        },
        Probe(name: "refreshComposerActions") { await $0.refreshComposerActions(chatId: "chat-1") },
        Probe(name: "submitComposerAction", prepare: twoSessions) {
            await $0.submitComposerAction(chatId: "chat-1", action: "queue", text: awkward, imageAttachments: nil)
        },
        Probe(name: "submitComposerAction.otherChat", prepare: twoSessions) {
            await $0.submitComposerAction(chatId: "chat-9", action: "queue", text: "t", imageAttachments: nil)
        },
        Probe(name: "submitNote") { await $0.submitNote(awkward) },
        Probe(name: "interruptAgent") { await $0.interruptAgent() },
        Probe(name: "interruptAgent.active", prepare: twoSessions) { await $0.interruptAgent() },
        Probe(name: "syncShowThinking") { await $0.syncShowThinking() },
        Probe(name: "setShowThinking") { await $0.setShowThinking("full") },
        Probe(name: "resumeAgent") { await $0.resumeAgent() },
        Probe(name: "resumeAgent.context", prepare: twoSessions) { await $0.resumeAgent(context: "more") },
        Probe(name: "resumeAgent.blankContext") { await $0.resumeAgent(context: "  ") },
        Probe(name: "syncAgentStatus") { describe(await $0.syncAgentStatus()) },
        Probe(name: "syncAgentStatus.chat", prepare: twoSessions) { describe(await $0.syncAgentStatus(chatId: "chat-1")) },
        Probe(name: "syncAgentStatus.legacy", page: "delete window.__ripulGetAgentLifecycleSnapshot;", prepare: twoSessions) {
            describe(await $0.syncAgentStatus(chatId: "chat-1"))
        },

        // Sessions
        Probe(name: "fetchSessions") { await $0.fetchSessions() },
        Probe(name: "focusSession", prepare: twoSessions) { await $0.focusSession(id: "tab-2") },
        Probe(name: "getSlashCommands") { await $0.getSlashCommands() },
        Probe(name: "getSlashCommands.hidden") { await $0.getSlashCommands(showHidden: true) },
        Probe(name: "closeSession", prepare: twoSessions) { await $0.closeSession(id: "tab-1") },
        Probe(name: "leaveSharedChat", prepare: twoSessions) { describe(await $0.leaveSharedChat(id: "tab-1")) },
        Probe(name: "joinShareLink") { await $0.joinShareLink(token: "tok") },
        Probe(name: "truncateSession") { describe(await $0.truncateSession(chatId: "chat-1", keepCount: 5)) },
        Probe(name: "evictSessionChannel") { describe(await $0.evictSessionChannel(chatId: "chat-1")) },
        Probe(name: "importCliSession") {
            await $0.importCliSession(messages: [["role": "user", "text": awkward]], sessionId: "s1", title: "T")
        },
        Probe(name: "importCliSession.subAgents") {
            await $0.importCliSession(messages: [], sessionId: "s1", title: "T",
                                      subAgentSessions: [(agentId: "a1", messages: [["role": "assistant"]])])
        },
        Probe(name: "getSessionTags") { await $0.getSessionTags() },
        Probe(name: "getGroupChatIds") { await $0.getGroupChatIds() },
        Probe(name: "setSessionTags") { await $0.setSessionTags(sessionId: "s1", tags: ["a", "b"]) },
        Probe(name: "deleteSession", prepare: twoSessions) {
            describe(await $0.deleteSession(tabId: "tab-1", machineId: "m1", remoteSessionId: "s1"))
        },
        Probe(name: "deleteSession.local", prepare: twoSessions) {
            describe(await $0.deleteSession(tabId: "tab-1", machineId: nil, remoteSessionId: nil, keepRemote: true))
        },
        Probe(name: "createNewChat") { await $0.createNewChat() },
        Probe(name: "createNewChat.explicit") {
            await $0.createNewChat(modelOverride: "m1", machineId: "mac-1", workingDirectory: "/w")
        },
        Probe(name: "renameSession", prepare: twoSessions) {
            $0.renameSession(id: "tab-1", sourceChatId: "chat-1", displayName: "New name"); return nil
        },
        Probe(name: "renameSession.backtick", prepare: twoSessions) {
            $0.renameSession(id: "tab-1", sourceChatId: "chat-1", displayName: "tick ` and \\ slash"); return nil
        },
        // A title is text, not a script: `${…}` must reach the page as typed.
        Probe(name: "renameSession.template", prepare: twoSessions) {
            $0.renameSession(id: "tab-1", sourceChatId: "chat-1", displayName: "cost ${1+1} today"); return nil
        },
        Probe(name: "forgetChat") { await $0.forgetChat(tabId: "tab-1") },
        Probe(name: "startNewChatWithPrompt") { await $0.startNewChatWithPrompt(awkward) },
        Probe(name: "listTodoItems") { await $0.listTodoItems() },
        Probe(name: "prewarmNewChat") { $0.prewarmNewChat(machineId: "mac-1"); return nil },

        // Models
        Probe(name: "fetchModels", states: [.detached, .answered]) { await $0.fetchModels() },
        Probe(name: "setModel") { await $0.setModel("m1") },
        Probe(name: "setModel.default") { await $0.setModel(nil) },
        Probe(name: "fetchEffort") { await $0.fetchEffort() },
        Probe(name: "setEffort") { await $0.setEffort("high") },
        Probe(name: "setEffort.default") { await $0.setEffort(nil) },
        Probe(name: "canEditModels") { await $0.canEditModels() },
        Probe(name: "saveModel") { describe(await $0.saveModel(id: "m1", bodyJSON: "{\"name\":\"x\"}")) },
        Probe(name: "deleteModel") { describe(await $0.deleteModel(id: "m1")) },
        Probe(name: "setChatModel") { await $0.setChatModel(chatId: "chat-1", modelId: "m1") },
        Probe(name: "setRawMode") { describe(await $0.setRawMode(sessionId: "s1", enabled: true)) },
        Probe(name: "isRawMode", page: "localStorage.setItem('cliRawModeSessions', JSON.stringify({s1: true}));") {
            await $0.isRawMode(sessionId: "s1")
        },
        Probe(name: "discoverCodexModels") { await $0.discoverCodexModels(machineId: "mac-1") },

        // Machines
        Probe(name: "forkSession") { describe(await $0.forkSession(sourceChatId: "chat-1", displayName: "Fork")) },
        Probe(name: "forkSession.unnamed") { describe(await $0.forkSession(sourceChatId: "chat-1", displayName: nil)) },
        Probe(name: "moveSession") {
            describe(await $0.moveSession(sourceChatId: "chat-1", targetMachineId: "mac-2", displayName: "Moved", sourceMachineId: "mac-1"))
        },
        Probe(name: "moveSession.bare") {
            describe(await $0.moveSession(sourceChatId: "chat-1", targetMachineId: "mac-2", displayName: nil))
        },
        Probe(name: "setWorkingDirectory") { await $0.setWorkingDirectory(sessionId: "s1", directory: "/w") },
        Probe(name: "setWorkingDirectory.clear") { await $0.setWorkingDirectory(sessionId: "s1", directory: nil) },
        Probe(name: "getFavoriteDirectories") { bridge in
            do { return try await bridge.getFavoriteDirectories(sessionId: "s1") } catch { return "threw: \(error.localizedDescription)" }
        },
        Probe(name: "discoverRemoteActions", states: [.detached, .refused, .answered]) {
            await $0.discoverRemoteActions(machineId: "mac-1")
        },
        Probe(name: "executeRemoteAction") {
            await $0.executeRemoteAction(machineId: "mac-1", actionId: "a1", params: ["k": awkward, "n": 2])
        },
        Probe(name: "execRemoteCommand") { await $0.execRemoteCommand(machineId: "mac-1", command: "ls") },
        Probe(name: "execRemoteCommand.full") {
            await $0.execRemoteCommand(machineId: "mac-1", command: awkward, cwd: "/w", timeoutMs: 500, background: true)
        },
        Probe(name: "controlRemoteJob") { await $0.controlRemoteJob(machineId: "mac-1", action: "list") },
        Probe(name: "controlRemoteJob.full") {
            await $0.controlRemoteJob(machineId: "mac-1", action: "output", jobId: "j1", offset: 40)
        },
        Probe(name: "connectToMachine", states: settled) { describe(await $0.connectToMachine(machineId: "mac-1")) },
        Probe(name: "connectToMachineWithProvider", states: settled) {
            describe(await $0.connectToMachineWithProvider(machineId: "mac-1", providerKey: "claude-cli"))
        },
        Probe(name: "connectToMachineWithProvider.full", states: settled) {
            describe(await $0.connectToMachineWithProvider(machineId: "mac-1", providerKey: "codex-cli", modelId: "gpt-x", workingDirectory: "/w"))
        },
        Probe(name: "listMachines") { await $0.listMachines() },
        Probe(name: "listRemoteSessionsAnswer") { describe(await $0.listRemoteSessionsAnswer(machineId: "mac-1")) },
        Probe(name: "fetchCliAccount") { await $0.fetchCliAccount(machineId: "mac-1") },
        Probe(name: "openRemoteSession", states: settled) {
            describe(await $0.openRemoteSession(machineId: "mac-1", sessionId: "s1"))
        },
        Probe(name: "openRemoteSession.full", states: settled) {
            describe(await $0.openRemoteSession(machineId: "mac-1", sessionId: "s1", displayName: "Named", forceReimport: true, focus: false))
        },
        Probe(name: "repairConnection", states: [.detached, .answered]) { describe(await $0.repairConnection()) },
        Probe(name: "killMachine") { describe(await $0.killMachine(machineId: "mac-1")) },
        Probe(name: "killMachine.reason") { describe(await $0.killMachine(machineId: "mac-1", reason: "stuck")) },

        // Mirror
        Probe(name: "mirrorListTabs") { await $0.mirrorListTabs(machineId: "mac-1") },
        Probe(name: "mirrorInvoke") {
            await $0.mirrorInvoke(machineId: "mac-1", capability: "tabs", method: "list", args: [1, "two", ["k": true]])
        },
        Probe(name: "mirrorInvoke.chat") {
            await $0.mirrorInvoke(machineId: "mac-1", capability: "tabs", method: "list", args: [], chatId: "chat-1")
        },
        Probe(name: "mirrorMenuTree") { await $0.mirrorMenuTree(machineId: "mac-1", pid: 42) },
        Probe(name: "mirrorMenuTree.full") { await $0.mirrorMenuTree(machineId: "mac-1", pid: 42, maxDepth: 2, budget: 10) },
        Probe(name: "mirrorMenuPress") { await $0.mirrorMenuPress(machineId: "mac-1", pid: 42, path: [0, 3]) },
        Probe(name: "mirrorListWindows") { await $0.mirrorListWindows(machineId: "mac-1") },
        Probe(name: "mirrorWindowThumbs") { await $0.mirrorWindowThumbs(machineId: "mac-1", windowIds: [9, 10]) },
        Probe(name: "mirrorOpenTab") { await $0.mirrorOpenTab(machineId: "mac-1", url: "https://x") },
        Probe(name: "mirrorOpenTab.context") { await $0.mirrorOpenTab(machineId: "mac-1", url: "https://x", contextId: "ctx-1") },
        Probe(name: "mirrorOpenTab.newContext") {
            await $0.mirrorOpenTab(machineId: "mac-1", url: "https://x", newContextName: "Work", newContextEphemeral: true)
        },
        Probe(name: "mirrorRemoveContext") { await $0.mirrorRemoveContext(machineId: "mac-1", contextId: "ctx-1") },
        Probe(name: "openTabMirror") { await $0.openTabMirror(machineId: "mac-1", tabId: 4, title: awkward) },
        Probe(name: "mirrorTabControl") { await $0.mirrorTabControl(machineId: "mac-1", tabId: 4, action: "reload") },
        Probe(name: "mirrorTabControl.full") {
            await $0.mirrorTabControl(machineId: "mac-1", tabId: 4, action: "navigate", url: "https://y", width: 800, height: 600)
        },
        Probe(name: "setMirrorPointerMode") { await $0.setMirrorPointerMode("touch") },
        Probe(name: "closeTabMirror") { await $0.closeTabMirror() },

        // Composer lookups
        Probe(name: "queryRemoteFiles") { await $0.queryRemoteFiles(query: awkward) },
        Probe(name: "queryRemoteFiles.empty") { await $0.queryRemoteFiles(query: "") },
        Probe(name: "queryPageElements") { await $0.queryPageElements() },
        Probe(name: "queryParticipants") { await $0.queryParticipants() },
        Probe(name: "inviteTeammate") { await $0.inviteTeammate(email: "a@b.c") },
        Probe(name: "queryAutocomplete") { await $0.queryAutocomplete(category: "files", query: awkward) },

        // Host sign-in and accounts
        Probe(name: "fetchHostAuthStatus") { await $0.fetchHostAuthStatus(machineId: "mac-1") },
        Probe(name: "fetchHostAuthStatus.profile") { await $0.fetchHostAuthStatus(machineId: "mac-1", profile: "work") },
        Probe(name: "beginHostAuth") { await $0.beginHostAuth(machineId: "mac-1") },
        Probe(name: "beginHostAuth.profile") { await $0.beginHostAuth(machineId: "mac-1", profile: "work") },
        Probe(name: "submitHostAuthCode") {
            describe(await $0.submitHostAuthCode(machineId: "mac-1", sessionId: "auth-1", code: "123"))
        },
        Probe(name: "submitHostAuthCode.profile") {
            describe(await $0.submitHostAuthCode(machineId: "mac-1", sessionId: "auth-1", code: "123", profile: "work"))
        },
        Probe(name: "cancelHostAuth") { describe(await $0.cancelHostAuth(machineId: "mac-1")) },
        Probe(name: "fetchClaudeAccounts") { await $0.fetchClaudeAccounts(machineId: "mac-1") },
        Probe(name: "createClaudeAccount") { describe(await $0.createClaudeAccount(machineId: "mac-1", name: "Work")) },
        Probe(name: "switchClaudeAccount") { await $0.switchClaudeAccount(machineId: "mac-1", slug: "work") },
        Probe(name: "deleteClaudeAccount") { describe(await $0.deleteClaudeAccount(machineId: "mac-1", slug: "work")) },

        // Archive and commits
        Probe(name: "archiveRemoteSession") { describe(await $0.archiveRemoteSession(machineId: "mac-1", sessionId: "s1")) },
        Probe(name: "restoreRemoteSession") { describe(await $0.restoreRemoteSession(machineId: "mac-1", sessionId: "s1")) },
        Probe(name: "listArchivedSessions") { await $0.listArchivedSessions(machineId: "mac-1") },
        Probe(name: "restoreArchivedSession") { describe(await $0.restoreArchivedSession(machineId: "mac-1", sessionId: "s1")) },
        Probe(name: "deleteArchivedSession") { describe(await $0.deleteArchivedSession(machineId: "mac-1", sessionId: "s1")) },
        Probe(name: "listCommitsWithSessions") { describe(await $0.listCommitsWithSessions(machineId: "mac-1")) },
        Probe(name: "listCommitsWithSessions.repo") {
            describe(await $0.listCommitsWithSessions(machineId: "mac-1", repoPath: "/repo"))
        },
        Probe(name: "resumeFromCommit") { describe(await $0.resumeFromCommit(machineId: "mac-1", sha: "abc")) },
        Probe(name: "resumeFromCommit.repo") {
            describe(await $0.resumeFromCommit(machineId: "mac-1", sha: "abc", repoPath: "/repo"))
        },
        Probe(name: "rescueSession") {
            describe(await $0.rescueSession(machineId: "mac-1", repoPath: "/repo", sessionId: "s1", displayName: "Rescued"))
        },
        Probe(name: "rescueSession.unnamed") {
            describe(await $0.rescueSession(machineId: "mac-1", repoPath: "/repo", sessionId: "s1", displayName: nil))
        },

        // Session metadata and tools
        Probe(name: "getSessionMetadata") { await $0.getSessionMetadata(sessionId: "s1") },
        Probe(name: "patchSessionMetadata") { await $0.patchSessionMetadata(sessionId: "s1", patch: ["description": awkward]) },
        Probe(name: "getSessionStorageBreakdown") { await $0.getSessionStorageBreakdown(sessionId: "s1") },
        Probe(name: "getSessionStorageBreakdown.buckets") { await $0.getSessionStorageBreakdown(sessionId: "s1", maxBuckets: 3) },
        Probe(name: "getResolvedCliTools") { await $0.getResolvedCliTools(sessionId: "s1") },
        Probe(name: "getChatToolCategories") { await $0.getChatToolCategories(chatId: "chat-1") },
        Probe(name: "setChatToolCategories") { await $0.setChatToolCategories(chatId: "chat-1", disabled: ["files", "web"]) },
        Probe(name: "getChatToolInventory") { await $0.getChatToolInventory(chatId: "chat-1") },

        // Host
        Probe(name: "setHostEnabled") { await $0.setHostEnabled(true) },
        Probe(name: "setHostEnabled.named") { await $0.setHostEnabled(false, machineName: "Studio") },
        Probe(name: "getHostSettings") { await $0.getHostSettings() },
        Probe(name: "setHostSetting") { await $0.setHostSetting(key: "k", value: ["a", "b"]) },
        Probe(name: "getHostStatus") { await $0.getHostStatus() },
        Probe(name: "getRelayDiagnostics") { await $0.getRelayDiagnostics() },
        Probe(name: "getRelayDiagnostics.room") { await $0.getRelayDiagnostics(roomId: "room-1") },
        Probe(name: "getCommsLog") { await $0.getCommsLog() },
        Probe(name: "clearCommsLog") { await $0.clearCommsLog() },
        Probe(name: "getConnectPhase") { await $0.getConnectPhase() },
        Probe(name: "getConnectPhase.set", states: [.answered],
              page: "window.__ripulConnectPhase = {phase:'relay', elapsedMs:12, detail:'joining'};") {
            await $0.getConnectPhase()
        },
        Probe(name: "resetHostPeaks") { await $0.resetHostPeaks() },

        // Files
        Probe(name: "fileViewerFind") { await $0.fileViewerFind(query: awkward) },
        Probe(name: "fileViewerFindNext") { await $0.fileViewerFindNext() },
        Probe(name: "fileViewerFindPrev") { await $0.fileViewerFindPrev() },
        Probe(name: "searchRemoteFiles") { describe(await $0.searchRemoteFiles(query: awkward)) },
        Probe(name: "searchRemoteFiles.offset") { describe(await $0.searchRemoteFiles(query: "q", offset: 20)) },
        Probe(name: "listRemoteDirectory") { describe(await $0.listRemoteDirectory(path: awkward)) },
        Probe(name: "listRemoteDirectory.machine") { describe(await $0.listRemoteDirectory(path: "/w", machineId: "mac-1")) },
        Probe(name: "grepRemoteFiles") { await $0.grepRemoteFiles(query: awkward) },
        Probe(name: "grepRemoteFiles.max") { await $0.grepRemoteFiles(query: "q", maxResults: 5) },
        Probe(name: "readRemoteFile") { await $0.readRemoteFile(path: awkward) },
        Probe(name: "readRemoteFile.chat") { await $0.readRemoteFile(path: "/a", chatId: "chat-1") },
        Probe(name: "readRemoteFile.machine") { await $0.readRemoteFile(path: "/a", machineId: "mac-1") },
        Probe(name: "waitForFileViewerReady") { await $0.waitForFileViewerReady(timeout: 0.2) },
        Probe(name: "injectFileContent") { $0.injectFileContent(awkward); return nil },
        Probe(name: "injectFileError") { $0.injectFileError(awkward); return nil },

        // The two raw doors
        Probe(name: "callPageFunction") { bridge in
            do { return try await bridge.callPageFunction("return [a, typeof window.__ripulSubmitNote];", arguments: ["a": 1]) }
            catch { return "threw: \(error.localizedDescription)" }
        },
        Probe(name: "callAsyncJavaScript") { bridge in
            do { return try await bridge.callAsyncJavaScript("return typeof window.__ripulSubmitNote;") }
            catch { return "threw: \(error.localizedDescription)" }
        },
    ]

    // MARK: - The run

    func testEveryPageCallMatchesTheRecord() async throws {
        let environment = ProcessInfo.processInfo.environment
        let wanted = environment["RIPUL_BRIDGE_PROBES"]?.split(separator: ",").map(String.init) ?? []
        let chosen = wanted.isEmpty ? Self.probes : Self.probes.filter { probe in wanted.contains { probe.name.contains($0) } }
        XCTAssertEqual(Set(Self.probes.map(\.name)).count, Self.probes.count, "Probe names must be unique")

        var blocks: [(header: String, body: String)] = []
        for probe in chosen {
            for state in probe.states {
                blocks.append(("## \(probe.name) / \(state.rawValue)", await record(probe, state)))
            }
        }

        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Golden/bridge-page-calls.txt")
        if environment["RIPUL_RECORD_GOLDEN"] != nil {
            XCTAssertTrue(wanted.isEmpty, "Record with every probe, not a subset")
            try FileManager.default.createDirectory(at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try blocks.map { "\($0.header)\n\($0.body)\n" }.joined(separator: "\n").write(to: golden, atomically: true, encoding: .utf8)
            return
        }

        let recorded = Self.parse(try String(contentsOf: golden, encoding: .utf8))
        var differences: [String] = []
        for block in blocks where recorded[block.header] != block.body {
            differences.append("\(block.header)\n--- recorded\n\(recorded[block.header] ?? "(nothing)")\n--- now\n\(block.body)")
        }
        if wanted.isEmpty {
            for header in Set(recorded.keys).subtracting(blocks.map(\.header)).sorted() {
                differences.append("\(header)\n--- recorded, but no longer probed")
            }
        }
        guard !differences.isEmpty else { return }
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-page-calls.diff.txt")
        try differences.joined(separator: "\n\n").write(to: report, atomically: true, encoding: .utf8)
        XCTFail("""
            \(differences.count) page call(s) no longer match the record. Full list: \(report.path)
            If the change is intended, re-record with RIPUL_RECORD_GOLDEN=1 and read the diff.

            \(differences.prefix(3).joined(separator: "\n\n"))
            """)
    }

    private static func parse(_ text: String) -> [String: String] {
        var blocks: [String: String] = [:]
        for chunk in text.components(separatedBy: "\n## ") {
            let trimmed = chunk.hasPrefix("## ") ? String(chunk.dropFirst(3)) : chunk
            guard let newline = trimmed.firstIndex(of: "\n") else { continue }
            let body = trimmed[trimmed.index(after: newline)...]
            blocks["## " + trimmed[..<newline]] = body.trimmingCharacters(in: .newlines)
        }
        return blocks
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        var completion: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion?() }
    }

    private func record(_ probe: Probe, _ state: PageState) async -> String {
        // Sticky model, cached sessions and the rest outlive a bridge.
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("ripul") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let bridge = AgentBridge()
        var web: WKWebView?
        if state != .detached {
            let view = WKWebView()
            let loader = Loader()
            let loaded = expectation(description: "\(probe.name) page ready")
            loader.completion = { loaded.fulfill() }
            view.navigationDelegate = loader
            view.loadHTMLString("<script>\(Self.pageScript(state))\n\(probe.page)</script>", baseURL: URL(string: "https://bridge.test/"))
            await fulfillment(of: [loaded], timeout: 10)
            bridge.attach(to: view)
            web = view
        }
        probe.prepare(bridge)

        let before = Self.snapshot(bridge)
        let consoleBefore = bridge.consoleLogs.count
        var result: Any?
        let logs = await Self.capturingStderr {
            result = await probe.run(bridge)
            await Self.settle(web)
        }
        let after = Self.snapshot(bridge)

        var lines = ["result: \(Self.describe(result))"]
        if let web, let calls = try? await web.evaluateJavaScript("JSON.stringify(window.__stable(window.__calls))") as? String {
            lines.append("page saw: \(calls)")
        }
        for log in logs { lines.append("nslog: \(log)") }
        for entry in bridge.consoleLogs.dropFirst(consoleBefore) where !Self.isNoise(entry.message) {
            lines.append("console: \(entry.level) \(Self.scrub(entry.message))")
        }
        for (label, value) in after where before[label] != value && !Self.unpinnedState.contains(label) {
            lines.append("state: \(label) = \(value)")
        }
        withExtendedLifetime(web) {}
        return lines.joined(separator: "\n")
    }

    private static func pageScript(_ state: PageState) -> String {
        // Swift dictionaries arrive with their keys in no fixed order.
        let prelude = """
            window.__calls = [];
            window.__stable = v => Array.isArray(v) ? v.map(window.__stable)
              : (v && typeof v === 'object') ? Object.fromEntries(Object.keys(v).sort().map(k => [k, window.__stable(v[k])])) : v;
            """
        guard state != .missing else { return prelude }
        let table = answers.sorted { $0.key < $1.key }.map { "'\($0.key)': \($0.value)" }.joined(separator: ",\n")
        return """
            \(prelude)
            const answers = {\(table)};
            for (const name of Object.keys(answers)) {
              window[name] = async (...args) => {
                window.__calls.push([name, args.map(a => a === undefined ? '<undefined>' : a)]);
                \(state.behaviour)
              };
            }
            """
    }

    /// Fire-and-forget calls land after the bridge method returns: wait until
    /// the page has stopped hearing from it.
    private static func settle(_ web: WKWebView?) async {
        guard let web else {
            try? await Task.sleep(nanoseconds: 30_000_000)
            return
        }
        var last = -1
        var steady = 0
        for _ in 0..<60 {
            let count = (try? await web.evaluateJavaScript("(window.__calls ?? []).length") as? Int) ?? -2
            steady = count == last ? steady + 1 : 0
            if steady >= 2 { return }
            last = count
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    // MARK: - Reading what happened

    /// Properties that move with the clock, the machine or a background monitor.
    private static let unpinnedState: Set<String> = [
        "logs", "lastPathFingerprint", "startupBudget", "startupLoadState", "startupLastStage",
    ]

    private static func isNoise(_ message: String) -> Bool {
        message.hasPrefix("[CPU") || message.hasPrefix("[PERF")
    }

    private static func snapshot(_ bridge: AgentBridge) -> LabelledText {
        var out = LabelledText()
        for child in Mirror(reflecting: bridge).children {
            guard let label = child.label, !label.hasPrefix("_$") else { continue }
            var text = describe(child.value, state: true)
            if text.count > 600 { text = String(text.prefix(600)) + "…(\(text.count) characters)" }
            out.append(label, text)
        }
        return out
    }

    private static func capturingStderr(_ body: () async -> Void) async -> [String] {
        fflush(stderr)
        let saved = dup(STDERR_FILENO)
        let path = NSTemporaryDirectory() + "bridge-golden-\(UUID().uuidString).log"
        let file = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        dup2(file, STDERR_FILENO)
        close(file)
        await body()
        fflush(stderr)
        dup2(saved, STDERR_FILENO)
        close(saved)
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        // NSLog: "2026-10-04 14:21:52.989 xctest[56057:12991102] message"
        let prefix = try! NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+ \S+\[\d+:\d+\] "#)
        return text.components(separatedBy: "\n").compactMap { line in
            let range = NSRange(line.startIndex..., in: line)
            guard let match = prefix.firstMatch(in: line, range: range), let end = Range(match.range, in: line)?.upperBound else { return nil }
            let message = String(line[end...])
            return message.hasPrefix("[AgentBridge]") ? scrub(message) : nil
        }
    }

    private static func scrub(_ text: String) -> String {
        var out = text
        for (pattern, replacement) in [
            (#"0x[0-9a-fA-F]+"#, "0x…"),
            (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, "<uuid>"),
            (#"\(\d+ms\)"#, "(Nms)"),
            (#"\bts=\d+"#, "ts=N"),
            (#""docAgeMs":\d+"#, "\"docAgeMs\":N"),
            (#"\bage=\d+s\b"#, "age=Ns"),
        ] {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }

    /// One spelling for any value, with dictionary and set order fixed.
    /// `state` masks what a snapshot of the bridge cannot hold still.
    static func describe(_ any: Any?, state: Bool = false, depth: Int = 0) -> String {
        guard let any else { return "nil" }
        let mirror = Mirror(reflecting: any)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first else { return "nil" }
            return describe(wrapped.value, state: state, depth: depth)
        }
        if depth > 8 { return "…" }
        func each(_ value: Any) -> String { describe(value, state: state, depth: depth + 1) }
        func labelled(_ children: Mirror.Children) -> String {
            children.filter { !($0.label ?? "").hasPrefix("_$") }
                .map { child in child.label.map { "\($0): \(each(child.value))" } ?? each(child.value) }
                .joined(separator: ", ")
        }

        if let text = any as? String {
            return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        if any is NSNull { return "null" }
        if let date = any as? Date { return state ? "<date>" : "date(\(date.timeIntervalSince1970))" }
        if let data = any as? Data { return "<\(data.count) bytes>" }
        if let url = any as? URL { return "url(\(url.absoluteString))" }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            if state, abs(number.doubleValue) > 1_000_000 { return "<large number>" }
            return number.stringValue
        }
        if let dictionary = any as? [AnyHashable: Any] {
            let pairs = dictionary.map { (each($0.key.base), each($0.value)) }.sorted { $0.0 < $1.0 }
            return "[" + pairs.map { "\($0.0): \($0.1)" }.joined(separator: ", ") + "]"
        }
        switch mirror.displayStyle {
        case .set: return "{" + mirror.children.map { each($0.value) }.sorted().joined(separator: ", ") + "}"
        case .collection: return "[" + mirror.children.map { each($0.value) }.joined(separator: ", ") + "]"
        case .tuple: return "(" + labelled(mirror.children) + ")"
        case .struct: return "\(type(of: any))(" + labelled(mirror.children) + ")"
        case .enum:
            guard let payload = mirror.children.first else { return ".\(any)" }
            return ".\(payload.label ?? "?")(\(each(payload.value)))"
        case .class:
            // One level into a store; a reference further down is only named.
            return depth > 1 ? "<\(type(of: any))>" : "\(type(of: any))(" + labelled(mirror.children) + ")"
        default:
            return scrub(String(describing: any))
        }
    }
}

/// An ordered label-to-text list that can also be read by label.
private struct LabelledText: Sequence {
    private var order: [String] = []
    private var values: [String: String] = [:]
    mutating func append(_ label: String, _ value: String) {
        if values[label] == nil { order.append(label) }
        values[label] = value
    }
    subscript(label: String) -> String? { values[label] }
    func makeIterator() -> AnyIterator<(String, String)> {
        var index = 0
        return AnyIterator {
            guard index < order.count else { return nil }
            defer { index += 1 }
            return (order[index], values[order[index]]!)
        }
    }
}
#endif
