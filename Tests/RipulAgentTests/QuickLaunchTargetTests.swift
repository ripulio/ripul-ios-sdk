import XCTest
@testable import RipulAgent

/// Regression cover for CLI/API classification in the quick-launch strip and
/// picker.
///
/// The classification decides two user-visible things: whether a model can be
/// offered as a session starter at all (`offerableTargets`), and which billing
/// section it lands in inside the picker. Getting it wrong is not cosmetic — a
/// misclassified Claude Code row silently disappears, leaving only
/// platform-billed API models on the strip.
final class QuickLaunchTargetTests: XCTestCase {

    private func model(
        id: String,
        type: String? = nil,
        group: String = "Ungrouped"
    ) -> ModelInfo {
        ModelInfo(
            id: id,
            name: id,
            modelId: "",
            provider: "anthropic",
            group: group,
            description: nil,
            supportsThinking: false,
            type: type
        )
    }

    // MARK: The bug

    /// The live catalog's only Claude Code row carries **no** `type` field. It
    /// must still resolve as CLI off its id prefix — the fallback used to be
    /// gated on `ModelInfo.isCli`, which is false for precisely these rows, so
    /// it never ran.
    func testCliRowWithoutTypeResolvesFromModelIdPrefix() {
        let target = QuickLaunchTarget.resolve(
            model: model(id: "claude-cli-raw-fable", type: nil, group: "Claude Code")
        )
        XCTAssertEqual(target.providerKey, "claude-cli")
        XCTAssertTrue(target.isCli)
    }

    /// ...and therefore survives the offerable filter. Before the fix this row
    /// was dropped, so the strip could only offer API models.
    func testTypelessCliRowIsOfferable() {
        let models = [model(id: "claude-cli-raw-fable", type: nil, group: "Claude Code")]
        XCTAssertEqual(QuickLaunchPreferences.offerableTargets(models: models).count, 1)
    }

    // MARK: Incumbent behaviour — must not regress

    /// Rows that DO carry `type` keep resolving through the primary path.
    func testTypedCliRowStillResolvesFromType() {
        let target = QuickLaunchTarget.resolve(model: model(id: "anything", type: "codex-cli"))
        XCTAssertEqual(target.providerKey, "codex-cli")
    }

    /// Running `byModelId` unconditionally must not promote backend rows. The
    /// prefix table only carries CLI harness prefixes, so an API row stays API.
    func testApiRowsAreNotPromotedToCli() {
        for id in ["backend-claude-fable-5", "backend-claude-opus-5", "anthropic-claude-opus-4-6"] {
            let target = QuickLaunchTarget.resolve(model: model(id: id, group: "Anthropic API"))
            XCTAssertNil(target.providerKey, "\(id) must not resolve a CLI harness")
            XCTAssertFalse(target.isCli, "\(id) must stay an API target")
        }
    }

    /// The API group stays offerable — it is machine-free and is what the
    /// strip falls back to.
    func testApiGroupRemainsOfferable() {
        let models = [model(id: "backend-claude-fable-5", group: QuickLaunchPreferences.apiGroup)]
        XCTAssertEqual(QuickLaunchPreferences.offerableTargets(models: models).count, 1)
    }

    /// Rows that are neither CLI nor in the API group are still excluded —
    /// they are reachable from the model picker but are not session starters.
    func testUnrelatedBackendRowsStayExcluded() {
        let models = [
            model(id: "openrouter-minimax-minimax-m2-5", group: "OpenRouter"),
            model(id: "grok-grok-4-1-fast-reasoning-latest", group: "Grok"),
        ]
        XCTAssertTrue(QuickLaunchPreferences.offerableTargets(models: models).isEmpty)
    }
}
