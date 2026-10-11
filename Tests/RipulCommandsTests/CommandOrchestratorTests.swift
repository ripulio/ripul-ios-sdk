import XCTest
@testable import RipulCommands

/// The orchestrator, with its replies scripted: what it is sent, how its answer
/// is checked, and what stands in when it cannot answer. No network and no
/// model — the transport is a closure, which is the whole point of it.
final class CommandOrchestratorTests: XCTestCase {
    typealias Fixtures = RipulCommandsTests

    let snapshot = CommandSnapshot(entities: ["chats": Fixtures.chats, "machines": Fixtures.machines])

    func resolver(_ calls: [OrchestratorReply.Call], registry: CommandRegistry = Fixtures.registry) -> CommandResolver {
        CommandResolver(registry: registry, orchestrator: CommandOrchestrator { _ in OrchestratorReply(calls: calls) })
    }

    func resolve(_ sentence: String, _ calls: [OrchestratorReply.Call]) async -> CommandResolution {
        await resolver(calls).resolve(sentence, map: Fixtures.map(), mode: .orchestrator, snapshot: snapshot)
    }

    // MARK: What it is sent

    func testActionsBecomeToolsAndEntitiesBecomeNumbers() {
        let tools = OrchestratorPrompt.tools(registry: Fixtures.registry)
        XCTAssertEqual(tools.map(\.name), Fixtures.registry.actions.map(\.id))

        let send = tools.first { $0.name == "send_to_agent" }!
        XCTAssertEqual(send.inputs.map(\.name), ["text", "machine"])
        XCTAssertEqual(send.inputs.map(\.kind), [.text, .number])
        XCTAssertEqual(send.inputs.map(\.isRequired), [true, false])
        // No description of its own: the title, and the list it picks from.
        XCTAssertEqual(send.description, "Send to the agent")
        XCTAssertTrue(send.inputs[1].description.contains("Machines"))
    }

    func testAnActionsOwnDescriptionIsWhatTheModelIsTold() {
        let registry = CommandRegistry(actions: [
            CommandAction(id: "stop", title: "Stop", description: "Stop the agent working in the current chat.",
                          parameters: [.init(name: "why", kind: .text, isRequired: false, description: "The reason, if one was given.")]) { _ in },
        ], sources: [])
        let tool = OrchestratorPrompt.tools(registry: registry)[0]
        XCTAssertEqual(tool.description, "Stop the agent working in the current chat.")
        XCTAssertEqual(tool.inputs[0].description, "The reason, if one was given.")
    }

    func testRequestNumbersTheListsAndNamesTheFallbackTool() {
        let request = OrchestratorPrompt.request(sentence: "four", map: Fixtures.map(), registry: Fixtures.registry,
                                                 snapshot: snapshot, limit: 150)
        XCTAssertTrue(request.lists.contains("Chats:\n1. Deploy lock contention\n2. Same title"))
        XCTAssertTrue(request.lists.contains("Machines:\n1. Peter's MacBook Pro"))
        XCTAssertEqual(request.fallbackTool, "send_to_agent")
        XCTAssertEqual(request.addressWords, ["Ripul", "Ripple"])
    }

    func testOnlyWhatWasListedCanBeChosen() async {
        // Three chats listed of four: number 4 is a row the model never saw.
        let listed = OrchestratorPrompt.lists(registry: Fixtures.registry, snapshot: snapshot, limit: 3)
        XCTAssertFalse(listed.contains("Native slot attachment flicker"))

        let short = CommandResolver(registry: Fixtures.registry, orchestrator: CommandOrchestrator(maxListed: 3) { _ in
            OrchestratorReply(calls: [.init(name: "open_chat", numbers: ["chat": 4])])
        })
        let resolution = await short.resolve("the flicker one", map: Fixtures.map(), mode: .orchestrator, snapshot: snapshot)
        XCTAssertTrue(resolution.fellBack)
    }

    // MARK: Checking the answer

    func testOneActionWithItsEntity() async {
        let resolution = await resolve("open the one where attachments flash",
                                       [.init(name: "open_chat", numbers: ["chat": 4])])
        XCTAssertEqual(resolution.engine, .orchestrator)
        XCTAssertEqual(resolution.commandId, "open_chat")
        XCTAssertEqual(resolution.values.entities["chat"]?.id, "s4")
        XCTAssertFalse(resolution.fellBack)
        XCTAssertTrue(resolution.laterSteps.isEmpty)
    }

    func testSeveralActionsKeepTheirOrder() async {
        let resolution = await resolve("open the deploy chat and go hands free", [
            .init(name: "open_chat", numbers: ["chat": 1]),
            .init(name: "voice_mode"),
        ])
        XCTAssertEqual(resolution.actionId, "open_chat")
        XCTAssertEqual(resolution.values.entities["chat"]?.id, "s1")
        XCTAssertEqual(resolution.laterSteps, [CommandStep(actionId: "voice_mode")])
    }

    func testEveryStepRunsInOrder() async throws {
        let ran = Recorder()
        let registry = CommandRegistry(actions: [
            CommandAction(id: "first", title: "First") { _ in await ran.add("first") },
            CommandAction(id: "second", title: "Second", parameters: [.init(name: "text", kind: .text)]) { values in
                await ran.add("second \(values.texts["text"] ?? "")")
            },
        ], sources: [])
        let resolver = resolver([.init(name: "first"), .init(name: "second", texts: ["text": "carry on"])], registry: registry)
        let map = CommandMap(name: "Test", commands: [])
        let resolution = await resolver.resolve("do both", map: map, mode: .orchestrator, snapshot: CommandSnapshot())
        try await resolver.perform(resolution)
        let order = await ran.entries
        XCTAssertEqual(order, ["first", "second carry on"])
    }

    func testAModelsTextIsKeptAsWritten() async {
        // Unlike the on-device model, whose text is discarded unless it shares
        // a word with the sentence: relaying a message means rephrasing it.
        let resolution = await resolve("ask my Mac where it got to",
                                       [.init(name: "send_to_agent", numbers: ["machine": 1], texts: ["text": "Where did you get to?"])])
        XCTAssertEqual(resolution.values.texts["text"], "Where did you get to?")
        XCTAssertEqual(resolution.values.entities["machine"]?.id, "m1")
    }

    func testZeroMeansNoneForAnOptionalNumber() async {
        let resolution = await resolve("start a new chat", [.init(name: "new_chat", numbers: ["machine": 0])])
        XCTAssertEqual(resolution.commandId, "new_chat")
        XCTAssertNil(resolution.values.entities["machine"])
        XCTAssertFalse(resolution.fellBack)
    }

    // MARK: A plan runs completely or not at all

    func testOutOfRangeNumberAbandonsTheWholePlan() async {
        let resolution = await resolve("open the ninth one and go hands free", [
            .init(name: "open_chat", numbers: ["chat": 9]),
            .init(name: "voice_mode"),
        ])
        XCTAssertTrue(resolution.fellBack)
        XCTAssertEqual(resolution.commandId, "send_to_agent")
        XCTAssertTrue(resolution.laterSteps.isEmpty, "voice mode must not run on its own")
        XCTAssertTrue(resolution.notes.contains { $0.contains("out of range") })
    }

    func testAnOptionalNumberOutOfRangeIsNotQuietlyDropped() async {
        // Dropping it would start the chat on the default machine instead of
        // the one that was named.
        let resolution = await resolve("new chat on the server", [.init(name: "new_chat", numbers: ["machine": 7])])
        XCTAssertTrue(resolution.fellBack)
    }

    func testUnknownToolFallsBack() async {
        let resolution = await resolve("delete everything", [.init(name: "delete_all")])
        XCTAssertTrue(resolution.fellBack)
        XCTAssertEqual(resolution.commandId, "send_to_agent")
        XCTAssertEqual(resolution.values.texts["text"], "delete everything")
    }

    func testMissingRequiredInputFallsBack() async {
        let resolution = await resolve("open it", [.init(name: "open_chat")])
        XCTAssertTrue(resolution.fellBack)
    }

    func testNoActionFallsBack() async {
        let resolution = await resolve("hmm", [])
        XCTAssertTrue(resolution.fellBack)
        XCTAssertTrue(resolution.notes.contains("the orchestrator chose no action"))
    }

    func testMoreStepsThanAllowedFallsBack() async {
        let resolution = await resolve("do it all", Array(repeating: .init(name: "voice_mode"), count: 4))
        XCTAssertTrue(resolution.fellBack)
        XCTAssertTrue(resolution.laterSteps.isEmpty)
    }

    func testAnInputTheActionDoesNotTakeIsIgnoredAndSaid() async {
        let resolution = await resolve("go back", [.init(name: "chat_list", numbers: ["chat": 2])])
        XCTAssertEqual(resolution.commandId, "chat_list")
        XCTAssertTrue(resolution.values.entities.isEmpty)
        XCTAssertTrue(resolution.notes.contains { $0.contains("ignored \"chat\"") })
    }

    // MARK: When it cannot answer

    struct Offline: LocalizedError { var errorDescription: String? { "offline" } }

    func testAFailingTransportStandsInWithWhatWasLiveBefore() async {
        let resolver = CommandResolver(registry: Fixtures.registry, orchestrator: CommandOrchestrator { _ in throw Offline() })
        let resolution = await resolver.resolve("go back to my chats", map: Fixtures.map(), mode: .orchestrator, snapshot: snapshot)
        XCTAssertEqual(resolution.engine, .rules)
        XCTAssertEqual(resolution.commandId, "chat_list")
        XCTAssertEqual(resolution.notes.first, "the orchestrator failed (offline); used rules, then the model")
    }

    func testNoOrchestratorSetUpStandsInToo() async {
        let resolution = await CommandResolver(registry: Fixtures.registry)
            .resolve("voice mode", map: Fixtures.map(), mode: .orchestrator, snapshot: snapshot)
        XCTAssertEqual(resolution.commandId, "voice_mode")
        XCTAssertEqual(resolution.notes.first, "no orchestrator is set up; used rules, then the model")
    }

    func testASlowAnswerIsNotWaitedFor() async {
        let resolver = CommandResolver(registry: Fixtures.registry, timeout: .milliseconds(50),
                                       orchestrator: CommandOrchestrator { _ in
            try await Task.sleep(for: .seconds(5))
            return OrchestratorReply(calls: [.init(name: "voice_mode")])
        })
        let start = ContinuousClock.now
        let resolution = await resolver.resolve("go back to my chats", map: Fixtures.map(), mode: .orchestrator, snapshot: snapshot)
        XCTAssertEqual(resolution.commandId, "chat_list")
        XCTAssertTrue(resolution.notes.first?.contains("did not answer within") == true)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testNothingSaidAsksNobody() async {
        let asked = Recorder()
        let resolver = CommandResolver(registry: Fixtures.registry, orchestrator: CommandOrchestrator { _ in
            await asked.add("asked")
            return OrchestratorReply(calls: [])
        })
        let resolution = await resolver.resolve("   ", map: Fixtures.map(), mode: .orchestrator, snapshot: snapshot)
        XCTAssertNil(resolution.commandId)
        let entries = await asked.entries
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: Live requests — what the app runs and what it passes on

    @MainActor
    func lab(_ calls: [OrchestratorReply.Call]) -> CommandLab {
        let lab = CommandLab(registry: Fixtures.registry, defaultMap: Fixtures.map(), store: nil,
                             demoEntities: ["chats": Fixtures.chats, "machines": Fixtures.machines],
                             orchestrator: CommandOrchestrator { _ in OrchestratorReply(calls: calls, model: "test-model", milliseconds: 12) })
        lab.live.mode = .orchestrator
        return lab
    }

    @MainActor
    func testAPlainMessageForTheAgentIsStillPassedOn() async {
        // Exactly what the fallback would have done, so the live entry point
        // keeps its own, proven way of delivering it.
        let lab = lab([.init(name: "send_to_agent", texts: ["text": "run the tests"])])
        let resolution = await lab.resolveLive("run the tests")
        XCTAssertEqual(resolution?.commandId, "send_to_agent")
        XCTAssertFalse(lab.isAppAction(resolution!))
    }

    @MainActor
    func testAMessageAimedAtAMachineIsTheAppsToRun() async {
        let lab = lab([.init(name: "send_to_agent", numbers: ["machine": 1], texts: ["text": "run the tests"])])
        let resolution = await lab.resolveLive("tell my Mac to run the tests")
        XCTAssertTrue(lab.isAppAction(resolution!), "passing it on would lose which machine")
    }

    @MainActor
    func testAPlanOfSeveralStepsIsTheAppsToRun() async {
        let lab = lab([.init(name: "send_to_agent", texts: ["text": "run the tests"]), .init(name: "voice_mode")])
        let resolution = await lab.resolveLive("run the tests and let's talk")
        XCTAssertTrue(lab.isAppAction(resolution!))
    }

    @MainActor
    func testAnAbandonedPlanIsPassedOn() async {
        let lab = lab([.init(name: "open_chat", numbers: ["chat": 9])])
        let resolution = await lab.resolveLive("open the ninth one")
        XCTAssertFalse(lab.isAppAction(resolution!))
    }

    @MainActor
    func testARunRecordsTheWholePlanAndWhoAnswered() async {
        let lab = lab([.init(name: "open_chat", numbers: ["chat": 1]), .init(name: "voice_mode")])
        lab.mode = .orchestrator
        lab.useDemoEntities = true
        lab.tries = 2
        lab.sentence = "open the deploy chat and go hands free"
        await lab.runSentence()

        let run = lab.run!
        XCTAssertTrue(run.isStable)
        XCTAssertEqual(run.outcomes[0].commandId, "open_chat")
        XCTAssertEqual(run.outcomes[0].thenRuns, ["voice_mode"])
        XCTAssertEqual(run.rawDecisions[0], "orchestrator: open_chat chat=1; voice_mode [test-model, 12 ms there]")
        XCTAssertTrue(run.instructions?.contains("- open_chat: Open a chat") == true)
        XCTAssertTrue(run.prompt?.contains("Sentence: open the deploy chat and go hands free") == true)
    }

    @MainActor
    func testASetOfSentencesIsRunInOrderAndRecordedTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lab = CommandLab(registry: Fixtures.registry, defaultMap: Fixtures.map(), store: CommandMapStore(directory: directory),
                             demoEntities: ["chats": Fixtures.chats, "machines": Fixtures.machines])
        let sentences = ["voice mode", "go back to my chats", "the fourth one"]
        let encoded = try JSONEncoder().encode(sentences).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        await lab.handle(URL(string: "ripul://intent-lab?mode=rules&tries=2&demo=1&suite=\(encoded)")!)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(CommandLab.SuiteRecord.self, from: Data(contentsOf: lab.lastSuiteFile!))
        XCTAssertTrue(record.finished)
        XCTAssertEqual(record.runs.map(\.sentence), sentences)
        XCTAssertEqual(record.runs.map { $0.outcomes.first?.commandId }, ["voice_mode", "chat_list", "open_chat"])
        XCTAssertEqual(record.runs.map(\.tries), [2, 2, 2])
    }

    @MainActor
    func testTheLabAsksForFreshAnswersAndALiveRequestDoesNot() async {
        let asked = Recorder()
        let lab = CommandLab(registry: Fixtures.registry, defaultMap: Fixtures.map(), store: nil,
                             orchestrator: CommandOrchestrator { request in
            await asked.add(request.fresh ? "fresh" : "cacheable")
            return OrchestratorReply(calls: [.init(name: "voice_mode")])
        })
        lab.mode = .orchestrator
        lab.tries = 2
        lab.sentence = "voice mode"
        await lab.runSentence()
        lab.live.mode = .orchestrator
        _ = await lab.resolveLive("voice mode")
        let entries = await asked.entries
        XCTAssertEqual(entries, ["fresh", "fresh", "cacheable"])
    }

    @MainActor
    func testLiveSettingsAreReachableByURL() async {
        let lab = CommandLab(registry: Fixtures.registry, defaultMap: Fixtures.map(), store: nil)
        await lab.handle(URL(string: "ripul://intent-lab?live=orchestrator")!)
        XCTAssertEqual(lab.live.mode, .orchestrator)
        XCTAssertTrue(lab.live.isEnabled)
        await lab.handle(URL(string: "ripul://intent-lab?live=off")!)
        XCTAssertFalse(lab.live.isEnabled)
        XCTAssertEqual(lab.live.mode, .orchestrator, "switching routing off keeps the chosen resolver")
        await lab.handle(URL(string: "ripul://intent-lab?live=nonsense")!)
        XCTAssertEqual(lab.live.mode, .orchestrator)
    }

    func testTheOrchestratorIsToldWhereThePersonIs() async {
        let asked = Recorder()
        let registry = CommandRegistry(actions: Fixtures.registry.actions, sources: Fixtures.registry.sources,
                                       situation: { "The person is in the chat \"Deploy lock contention\"." })
        let resolver = CommandResolver(registry: registry, orchestrator: CommandOrchestrator { request in
            await asked.add(request.situation ?? "none")
            return OrchestratorReply(calls: [.init(name: "send_to_agent", texts: ["text": "what's the status"])])
        })
        // Read with the lists, so both describe the same moment.
        let live = await resolver.snapshot(for: Fixtures.map())
        XCTAssertEqual(live.situation, "The person is in the chat \"Deploy lock contention\".")
        let resolution = await resolver.resolve("what's the status", map: Fixtures.map(), mode: .orchestrator, snapshot: live)
        XCTAssertTrue(resolution.prompt?.contains("Situation: The person is in the chat") == true)
        // A registry that says nothing sends nothing.
        _ = await CommandResolver(registry: Fixtures.registry, orchestrator: resolver.orchestrator)
            .resolve("what's the status", map: Fixtures.map(), mode: .orchestrator)
        let entries = await asked.entries
        XCTAssertEqual(entries, ["The person is in the chat \"Deploy lock contention\".", "none"])
    }

    @MainActor
    func testADemoRunCanBeGivenASituation() async {
        let asked = Recorder()
        let lab = CommandLab(registry: Fixtures.registry, defaultMap: Fixtures.map(), store: nil,
                             demoEntities: ["chats": Fixtures.chats, "machines": Fixtures.machines],
                             orchestrator: CommandOrchestrator { request in
            await asked.add(request.situation ?? "none")
            return OrchestratorReply(calls: [.init(name: "voice_mode")])
        })
        await lab.handle(URL(string: "ripul://intent-lab?mode=orchestrator&tries=1&demo=1&situation=In%20a%20chat&say=hello")!)
        await lab.handle(URL(string: "ripul://intent-lab?situation=&say=hello")!)
        let entries = await asked.entries
        XCTAssertEqual(entries, ["In a chat", "none"])
    }

    func testOrchestratorModeSurvivesBeingSaved() throws {
        var settings = CommandLab.LiveSettings()
        settings.mode = .orchestrator
        let restored = try JSONDecoder().decode(CommandLab.LiveSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.mode, .orchestrator)
    }
}

private actor Recorder {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}
