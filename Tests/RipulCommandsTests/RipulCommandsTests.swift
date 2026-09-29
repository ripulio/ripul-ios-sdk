import XCTest
@testable import RipulCommands

/// Fixtures for the engine. Every guard here is pinned to the measurement that
/// produced it — the model-behaviour cases replay what the on-device model
/// actually returned on a real iPhone (iOS 27, contextSize 8192), as scripted
/// decisions, so the corrections are tested without the model.
final class RipulCommandsTests: XCTestCase {

    // MARK: A registry shaped like a real app's

    static let chats = [
        CommandEntity(id: "s1", title: "Deploy lock contention"),
        CommandEntity(id: "s2", title: "Same title"),
        CommandEntity(id: "s3", title: "Same title"),
        CommandEntity(id: "s4", title: "Native slot attachment flicker"),
    ]
    static let machines = [
        CommandEntity(id: "m1", title: "Peter's MacBook Pro", aliases: ["my Mac", "Mac", "MacBook", "laptop"]),
        CommandEntity(id: "m2", title: "Peter's iPhone", aliases: ["my iPhone", "iPhone", "my phone", "phone"]),
    ]

    static let registry = CommandRegistry(
        actions: [
            CommandAction(id: "open_chat", title: "Open a chat",
                          parameters: [.init(name: "chat", kind: .entity(sourceId: "chats"))]) { _ in },
            CommandAction(id: "new_chat", title: "New chat",
                          parameters: [.init(name: "machine", kind: .entity(sourceId: "machines"), isRequired: false)]) { _ in },
            CommandAction(id: "voice_mode", title: "Voice mode") { _ in },
            CommandAction(id: "chat_list", title: "Chat list") { _ in },
            CommandAction(id: "unread", title: "Read unread") { _ in },
            CommandAction(id: "send_to_agent", title: "Send to the agent", parameters: [
                .init(name: "text", kind: .text),
                .init(name: "machine", kind: .entity(sourceId: "machines"), isRequired: false),
            ]) { _ in },
            CommandAction(id: "nothing", title: "Do nothing") { _ in },
        ],
        sources: [
            EntitySource(id: "chats", title: "Chats") { RipulCommandsTests.chats },
            EntitySource(id: "machines", title: "Machines") { RipulCommandsTests.machines },
        ]
    )

    static func map(agentText: ParameterBinding = .utterance) -> CommandMap {
        CommandMap(
            name: "Test",
            commands: [
                SoftCommand(id: "open_chat", description: "Open a chat that already exists, by its number.",
                            examples: ["open the chat", "the one about"], actionId: "open_chat",
                            bindings: ["chat": .modelPicks]),
                SoftCommand(id: "new_chat", description: "Start a new chat.",
                            examples: ["new session", "new chat", "start a session"], actionId: "new_chat",
                            bindings: ["machine": .rulesMatch]),
                SoftCommand(id: "voice_mode", description: "Talk hands-free.",
                            examples: ["voice mode", "hands free", "let's talk"], actionId: "voice_mode"),
                SoftCommand(id: "chat_list", description: "Show the list of chats.",
                            examples: ["go back", "my chats", "session list"], actionId: "chat_list"),
                SoftCommand(id: "unread", description: "Report what is waiting.",
                            examples: ["anything waiting", "unread"], actionId: "unread"),
                SoftCommand(id: "send_to_agent", description: "Anything the person wants an agent to do.",
                            actionId: "send_to_agent", bindings: ["text": agentText, "machine": .rulesMatch]),
                SoftCommand(id: "nothing", description: "Nothing was asked.",
                            examples: ["thanks", "that's all"], actionId: "nothing"),
            ],
            fallbackCommandId: "send_to_agent",
            addressWords: ["Ripul", "Ripple"]
        )
    }

    let resolver = CommandResolver(registry: RipulCommandsTests.registry)
    let snapshot = CommandSnapshot(entities: ["chats": RipulCommandsTests.chats, "machines": RipulCommandsTests.machines])

    func rules(_ sentence: String, map: CommandMap = RipulCommandsTests.map()) -> CommandResolution {
        resolver.resolveWithRules(sentence, map: map, snapshot: snapshot)
    }

    func bind(_ decision: CommandDecision, _ sentence: String,
              map: CommandMap = RipulCommandsTests.map()) -> CommandResolution {
        var resolution = CommandResolution(engine: .model, sentence: sentence)
        CommandBinder.bind(decision, into: &resolution, map: map, registry: Self.registry, snapshot: snapshot)
        return resolution
    }

    // MARK: Positions — what the shipped Siri menu matcher cannot do

    func testPositionsAnywhereInTheSentence() {
        for said in ["four", "the fourth one", "number 4", "option four", "the last one"] {
            let r = rules(said)
            XCTAssertEqual(r.commandId, "open_chat", said)
            XCTAssertEqual(r.values.entities["chat"]?.id, "s4", said)
        }
    }

    func testOneIsFillerUnlessMadeNumeric() {
        XCTAssertEqual(rules("the one about the deploy lock").values.entities["chat"]?.id, "s1")
        XCTAssertEqual(rules("number one").values.entities["chat"]?.id, "s1")
    }

    // MARK: Titles

    /// Measured: the old rules missed this; the model got it 5/5 on the phone.
    func testSuffixesMatch() {
        let r = rules("Open the chat about flickering")
        XCTAssertEqual(r.commandId, "open_chat")
        XCTAssertEqual(r.values.entities["chat"]?.id, "s4")
    }

    func testSameWordNeedsFourLetters() {
        XCTAssertTrue(EntityMatcher.sameWord("flicker", "flickering"))
        XCTAssertFalse(EntityMatcher.sameWord("in", "into"))
    }

    // MARK: Machines and instructions — the clause Apple's schema would eat

    func testInstructionKeepsItsMachineAndLosesTheAddress() {
        let r = rules("tell Ripul on my Mac to run the tests")
        XCTAssertEqual(r.commandId, "send_to_agent")
        XCTAssertEqual(r.values.texts["text"], "run the tests")
        XCTAssertEqual(r.values.entities["machine"]?.id, "m1")
    }

    func testMisheardAppNameAndPhoneAreStripped() {
        let r = rules("ask Ripple on my iPhone what is failing")
        XCTAssertEqual(r.values.texts["text"], "what is failing")
        XCTAssertEqual(r.values.entities["machine"]?.id, "m2")
    }

    func testNewChatOnANamedMachine() {
        let r = rules("start a new session on my Mac")
        XCTAssertEqual(r.commandId, "new_chat")
        XCTAssertEqual(r.values.entities["machine"]?.id, "m1")
    }

    func testPlainCommands() {
        XCTAssertEqual(rules("voice mode").commandId, "voice_mode")
        XCTAssertEqual(rules("go back to my chats").commandId, "chat_list")
        XCTAssertEqual(rules("anything waiting for me").commandId, "unread")
        XCTAssertEqual(rules("thanks that's all").commandId, "nothing")
    }

    func testNothingSaidRunsNothing() {
        let r = rules("   ")
        XCTAssertNil(r.commandId)
    }

    // MARK: Checking the model's answer — replays of what it actually did

    func testOutOfRangeRowFallsBackInsteadOfOpeningAnything() {
        let r = bind(CommandDecision(commandId: "open_chat", picks: ["chats": 99]), "open the deploy one")
        XCTAssertEqual(r.commandId, "send_to_agent")
        XCTAssertTrue(r.fellBack)
        XCTAssertEqual(r.values.texts["text"], "open the deploy one")
        XCTAssertTrue(r.notes.contains { $0.contains("out of range") }, "\(r.notes)")
    }

    func testDuplicateTitlesStayDistinctByNumber() {
        XCTAssertEqual(bind(CommandDecision(commandId: "open_chat", picks: ["chats": 3]), "same title")
            .values.entities["chat"]?.id, "s3")
    }

    func testUnknownCommandFallsBack() {
        let r = bind(CommandDecision(commandId: "newSession"), "start a new session on my Mac")
        XCTAssertEqual(r.commandId, "send_to_agent")
        XCTAssertTrue(r.fellBack)
    }

    /// iOS 27 model: dropped "my Mac" 5/5. Machines are never the model's call.
    func testNamedMachineAttachedEvenWhenTheModelLeftItOut() {
        XCTAssertEqual(bind(CommandDecision(commandId: "new_chat"), "start a new session on my Mac")
            .values.entities["machine"]?.id, "m1")
    }

    /// iOS 26 model: addressed "run the tests" to the Mac 1 in 5.
    func testMachineNeverNamedIsNeverAttached() {
        let r = bind(CommandDecision(commandId: "send_to_agent", picks: ["machines": 1]), "run the tests")
        XCTAssertNil(r.values.entities["machine"])
    }

    /// iOS 27 model: returned the instructions' example "what is failing" as
    /// the text for this sentence 5/5.
    func testCopiedModelTextIsReplacedByTheSentence() {
        let map = Self.map(agentText: .modelWrites)
        let said = "open the conversation about builds stepping on each other"
        let r = bind(CommandDecision(commandId: "send_to_agent", text: "what is failing"), said, map: map)
        XCTAssertEqual(r.values.texts["text"], said)
        XCTAssertTrue(r.notes.contains { $0.contains("not about what was said") }, "\(r.notes)")
    }

    func testGenuineRephrasingSurvives() {
        let map = Self.map(agentText: .modelWrites)
        let r = bind(CommandDecision(commandId: "send_to_agent", text: "tell me what is failing on my iPhone"),
                     "ask my phone what is failing", map: map)
        XCTAssertEqual(r.values.texts["text"], "tell me what is failing on my iPhone")
    }

    func testNoFallbackMeansNothingRuns() {
        var map = Self.map()
        map.fallbackCommandId = nil
        let r = bind(CommandDecision(commandId: "open_chat", picks: ["chats": 99]), "open it", map: map)
        XCTAssertNil(r.commandId)
    }

    // MARK: What the model is sent

    func testInstructionsListCommandsWithWhatPeopleSay() {
        let text = CommandPrompt.instructions(map: Self.map())
        XCTAssertTrue(text.contains("- open_chat: Open a chat that already exists, by its number. People say things like \"open the chat\", \"the one about\"."))
        XCTAssertTrue(text.contains("Prefer send_to_agent over guessing"))
        XCTAssertFalse(text.contains("{{"))
    }

    func testPromptNumbersPickedSourcesAndNamesMatchedOnes() {
        let prompt = CommandPrompt.prompt(sentence: "four", map: Self.map(), registry: Self.registry, snapshot: snapshot)
        XCTAssertEqual(prompt, """
        Chats:
        1. Deploy lock contention
        2. Same title
        3. Same title
        4. Native slot attachment flicker
        Machines, named rather than chosen: Peter's MacBook Pro, Peter's iPhone.
        Sentence: four
        """)
    }

    // MARK: Portable JSON

    func testRoundTrip() throws {
        let map = Self.map(agentText: .constant("hello"))
        XCTAssertEqual(try CommandMapStore.decode(CommandMapStore.encode(map)), map)
    }

    func testNewerVersionIsRefusedNotHalfRead() {
        let data = Data(#"{"version": 99}"#.utf8)
        XCTAssertThrowsError(try CommandMapStore.decode(data)) { error in
            XCTAssertEqual(error as? CommandMapError, .newerVersion(found: 99, supported: CommandMap.currentVersion))
        }
    }

    // MARK: Checks

    func testSoundMapHasNoProblems() {
        XCTAssertEqual(Self.map().problems(registry: Self.registry), [])
    }

    func testBrokenMapSaysWhatIsWrong() {
        var map = Self.map()
        map.commands[0].actionId = "gone"                        // open_chat → unknown action
        map.commands[1].bindings["colour"] = .utterance          // new_chat fills a parameter it lacks
        map.commands.append(SoftCommand(id: "voice_mode", description: "again", actionId: "voice_mode"))
        map.commands[5].bindings["text"] = nil                   // send_to_agent's required text
        map.fallbackCommandId = "missing"
        map.promptTemplate = "no placeholders"
        let problems = map.problems(registry: Self.registry)
        for fragment in ["\"gone\", which this app doesn't have", "fills \"colour\"", "Two commands are called voice_mode",
                         "never fills \"text\"", "\"missing\", isn't one of the commands", "{{sentence}}"] {
            XCTAssertTrue(problems.contains { $0.contains(fragment) }, "missing \(fragment) in \(problems)")
        }
        // open_chat was the only command picking from a list, and it now runs
        // nothing — so a prompt without {{entities}} costs nothing here.
        XCTAssertFalse(problems.contains { $0.contains("{{entities}}") }, "\(problems)")
    }

    func testPromptWithoutEntitiesMattersOnlyWhenSomethingPicks() {
        var map = Self.map()
        map.promptTemplate = "Sentence: {{sentence}}"
        XCTAssertEqual(map.problems(registry: Self.registry),
                       ["The prompt doesn't include {{entities}}, so the model never sees the lists it has to choose from."])
    }

    // MARK: Maps in the Lab

    @MainActor
    func testLabCreatesDuplicatesActivatesAndDeletesMaps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lab = CommandLab(registry: Self.registry, defaultMap: Self.map(), store: CommandMapStore(directory: directory))
        let original = lab.map

        let created = lab.createMap(named: "Trial")
        XCTAssertEqual(lab.map.id, created.id)
        XCTAssertNotEqual(created.id, original.id)
        lab.duplicateActiveMap()
        XCTAssertEqual(lab.map.name, "Trial copy")
        XCTAssertEqual(lab.maps.count, 3)

        lab.activate(original.id)
        XCTAssertEqual(lab.map.id, original.id)
        XCTAssertEqual(CommandMapStore(directory: directory).activeMapId, original.id, "activation persists")

        lab.deleteMap(original.id)
        XCTAssertNotEqual(lab.map.id, original.id, "deleting the active map switches to another")
        XCTAssertEqual(lab.maps.count, 2)
        XCTAssertEqual(CommandMapStore(directory: directory).loadAll().count, 2)
    }

    @MainActor
    func testScreensAreReachableByURL() async {
        let lab = CommandLab(registry: Self.registry, defaultMap: Self.map(), store: nil)
        await lab.handle(URL(string: "ripul://intent-lab?screen=maps")!)
        XCTAssertEqual(lab.route, .maps)
        await lab.handle(URL(string: "ripul://intent-lab?screen=command:voice_mode")!)
        XCTAssertEqual(lab.route, .command("voice_mode"))
        await lab.handle(URL(string: "ripul://intent-lab?screen=root")!)
        XCTAssertNil(lab.route)
    }

    // MARK: Live requests

    @MainActor
    func testLiveActsOnlyOnConfidentCommands() async {
        let lab = CommandLab(registry: Self.registry, defaultMap: Self.map(), store: nil)
        lab.live.mode = .rules

        let open = await lab.resolveLive("go back to my chats")
        XCTAssertEqual(open?.commandId, "chat_list")
        XCTAssertTrue(lab.isAppAction(open!))

        // Lands on the fallback: a live entry point must keep its own behaviour.
        let unclear = await lab.resolveLive("run the tests")
        XCTAssertEqual(unclear?.commandId, "send_to_agent")
        XCTAssertFalse(lab.isAppAction(unclear!))
        XCTAssertEqual(lab.lastLive?.sentence, "run the tests")

        lab.live.isEnabled = false
        let off = await lab.resolveLive("go back to my chats")
        XCTAssertNil(off, "switched off, nothing is resolved")
    }

    @MainActor
    func testLiveSettingsPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lab = CommandLab(registry: Self.registry, defaultMap: Self.map(), store: CommandMapStore(directory: directory))
        lab.live.mode = .model
        lab.live.isEnabled = false
        lab.saveLive()
        let reopened = CommandLab(registry: Self.registry, defaultMap: Self.map(), store: CommandMapStore(directory: directory))
        XCTAssertEqual(reopened.live.mode, .model)
        XCTAssertFalse(reopened.live.isEnabled)
    }

    @MainActor
    func testTheLastMapCannotBeDeleted() {
        let lab = CommandLab(registry: Self.registry, defaultMap: Self.map(), store: nil)
        lab.deleteMap(lab.map.id)
        XCTAssertEqual(lab.maps.count, 1)
    }

    @MainActor
    func testImportNeverOverwritesAnExistingMap() throws {
        let lab = CommandLab(registry: Self.registry, defaultMap: Self.map(), store: nil)
        let existing = lab.map
        XCTAssertTrue(lab.importMap(try CommandMapStore.encode(existing)))
        XCTAssertNotEqual(lab.map.id, existing.id)
        XCTAssertEqual(lab.map.name, "\(existing.name) 2")
        XCTAssertEqual(lab.maps.count, 2)
        XCTAssertFalse(lab.importMap(Data("not json".utf8)))
    }

    @MainActor
    func testResetKeepsTheMapButRestoresItsCommands() {
        let lab = CommandLab(registry: Self.registry, defaultMap: Self.map(), store: nil)
        let created = lab.createMap(named: "Tuned")
        lab.map.commands.removeAll()
        lab.resetMap()
        XCTAssertEqual(lab.map.id, created.id)
        XCTAssertEqual(lab.map.name, "Tuned")
        XCTAssertEqual(lab.map.commands, Self.map().commands)
    }

    func testStoreSavesLoadsAndTracksTheActiveMap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommandMapStore(directory: directory)
        let installed = store.activeMap(orInstall: Self.map())
        XCTAssertEqual(store.activeMapId, installed.id)
        XCTAssertEqual(store.loadAll(), [installed])
    }
}
