import XCTest
@testable import RipulAgent

final class ModelCatalogueCacheTests: XCTestCase {
    @MainActor
    func testRestoresOnlyTheCurrentAccountAndClearsOnSignOut() throws {
        let suiteName = "ModelCatalogueCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = ModelInfo(id: "fable", name: "Fable", modelId: "fable",
                              provider: "claude-cli", group: "Claude Code",
                              description: nil, supportsThinking: true)
        let data = try JSONEncoder().encode([model])
        defaults.set(data, forKey: "ripul.models.v1.alice")
        let bridge = AgentBridge()
        bridge.sessionCache = UserDefaultsSessionCache(suite: defaults)
        XCTAssertTrue(bridge.availableModels.isEmpty)
        bridge.setModelCatalogueAccount("alice")
        XCTAssertEqual(bridge.availableModels, [model])
        bridge.setModelCatalogueAccount("bob")
        XCTAssertTrue(bridge.availableModels.isEmpty)
        XCTAssertNil(defaults.data(forKey: "ripul.models.v1.alice"))
        defaults.set(data, forKey: "ripul.models.v1.bob")
        bridge.setModelCatalogueAccount(nil)
        XCTAssertTrue(bridge.availableModels.isEmpty)
        XCTAssertNil(defaults.data(forKey: "ripul.models.v1.bob"))
    }

    @MainActor
    func testCacheCanBeAttachedAfterAccountAndCorruptDataIsIgnored() throws {
        let suiteName = "ModelCatalogueCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("invalid".utf8), forKey: "ripul.models.v1.alice")
        let bridge = AgentBridge()
        bridge.setModelCatalogueAccount("alice")
        bridge.sessionCache = UserDefaultsSessionCache(suite: defaults)
        XCTAssertTrue(bridge.availableModels.isEmpty)
    }
}
