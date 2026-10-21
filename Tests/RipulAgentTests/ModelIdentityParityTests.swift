import XCTest
@testable import RipulAgent

/// Model-identity parity with the web app's
/// `chrome-extension/src/LLM/multiParticipant/modelIdentity.ts` — test cases
/// mirrored from `modelIdentity.test.ts`. The Swift port feeds the native
/// session row's leading icon; if you change one side's family table,
/// colours or label construction, change both.
final class ModelIdentityParityTests: XCTestCase {
    func testReturnsNilForEmptyOrUnknownIds() {
        XCTAssertNil(ModelIdentity.resolve(modelId: nil))
        XCTAssertNil(ModelIdentity.resolve(modelId: ""))
        XCTAssertNil(ModelIdentity.resolve(modelId: "default"))
        XCTAssertNil(ModelIdentity.resolve(modelId: "anthropic"))
    }

    func testResolvesKimiFromConcreteStreamId() {
        // The env-swap case: k3[1m] is the concrete stream id for Kimi K3.
        let id = ModelIdentity.resolve(modelId: "k3[1m]")
        XCTAssertEqual(id?.label, "Kimi K3")
        XCTAssertEqual(id?.colorHex, "#14B8A6")
        XCTAssertEqual(id?.glyph, "☾")
    }

    func testResolvesKimiTiersDespiteHarnessPrefix() {
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-cli-raw-kimi-k3")?.label, "Kimi K3")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-cli-raw-kimi-coding")?.label, "Kimi for Coding")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-cli-raw-kimi-highspeed")?.label, "Kimi HighSpeed")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "kimi-for-coding")?.label, "Kimi for Coding")
    }

    func testResolvesClaudeTiersFromCatalogIds() {
        // Just the model, never the CLI name.
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-cli-raw-opus")?.label, "Opus")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-cli-sonnet")?.label, "Sonnet")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-cli-raw-haiku")?.label, "Haiku")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-cli-raw-fable")?.label, "Fable")
    }

    func testAppendsVersionNumbersSkippingDateStamps() {
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-opus-4-8")?.label, "Opus 4.8")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-sonnet-4.6")?.label, "Sonnet 4.6")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-haiku-4-5-20251001")?.label, "Haiku 4.5")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "claude-fable-5")?.label, "Fable 5")
    }

    func testClaudeTiersHaveDistinctIdentities() {
        let identities = ["opus", "sonnet", "haiku", "fable"].compactMap { ModelIdentity.resolve(modelId: $0) }
        XCTAssertEqual(identities.count, 4)
        XCTAssertEqual(Set(identities.map(\.colorHex)).count, 4)
        XCTAssertEqual(Set(identities.map(\.glyph)).count, 4)
    }

    func testResolvesOpenAIAndGeminiIdsWithVersionsAndTierWords() {
        XCTAssertEqual(ModelIdentity.resolve(modelId: "gpt-5.5")?.label, "GPT 5.5")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "codex-cli-raw-gpt-5.4-mini")?.label, "GPT 5.4 Mini")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "gemini-2.5-pro")?.label, "Gemini 2.5 Pro")
        XCTAssertEqual(ModelIdentity.resolve(modelId: "antigravity-cli-raw-gemini-3.5-flash")?.label, "Gemini 3.5 Flash")
    }

    func testUnmergedAntigravitySessionResolvesProviderAndModelInUnifiedSessionBuild() {
        let now = Date()
        let remote = RemoteSessionInfo(
            id: "chat_agy",
            sourceChatId: "chat_agy",
            displayName: "Antigravity task",
            createdAt: now,
            lastModified: nil,
            isRunning: false,
            projectName: nil,
            cwd: nil,
            gitBranch: nil,
            messageCount: nil,
            provider: nil,
            providerLabel: nil,
            model: nil,
            hostChatId: "chat_agy",
            machineId: "mac-1",
            teamVisibility: nil,
            creatorUserId: nil,
            startedBy: nil
        )
        let localTab = ChatSession(
            id: "chat_agy",
            sourceChatId: "chat_agy",
            displayName: "Antigravity task",
            createdAt: now,
            provider: "antigravity-cli",
            providerLabel: "Antigravity",
            model: "antigravity-cli-raw-gemini-4-argon",
            hostChatId: "chat_agy"
        )
        let built = UnifiedSession.build(
            from: [remote],
            localSessions: [localTab],
            machineNames: ["chat_agy": "Mac"]
        )
        XCTAssertEqual(built.first?.provider, "antigravity-cli")
        XCTAssertEqual(built.first?.providerLabel, "Antigravity")
        XCTAssertEqual(built.first?.model, "antigravity-cli-raw-gemini-4-argon")
        XCTAssertEqual(built.first?.resolvedProvider?.id, "antigravity")

        // When only the generic CLI default model id is set, modelDisplayName returns nil
        // so the row falls back to the provider label ("Antigravity") instead of raw id.
        let genericRow = built.first?.withModel("antigravity-cli-raw-default")
        XCTAssertNil(genericRow?.modelDisplayName)

        // When a scanned row has nil provider/model and its matched tab later supplies them,
        // tabFactsDiffer and adoptingTabFacts fill in the missing fields without overruling host values.
        let bareScanned = UnifiedSession.build(
            from: [remote],
            localSessions: [],
            machineNames: ["chat_agy": "Mac"]
        )[0]
        XCTAssertTrue(bareScanned.tabFactsDiffer(from: localTab))
        let adopted = bareScanned.adoptingTabFacts(localTab)
        XCTAssertEqual(adopted.provider, "antigravity-cli")
        XCTAssertEqual(adopted.providerLabel, "Antigravity")
        XCTAssertEqual(adopted.model, "antigravity-cli-raw-gemini-4-argon")
        XCTAssertFalse(adopted.tabFactsDiffer(from: localTab))
    }
}
