import XCTest
@testable import RipulAgent

/// Request-body field names for context-scoped validation.
///
/// The worker reads `contextId` and `surface` (handleSiteKeyValidate). A
/// mismatch here doesn't fail — the server ignores unknown fields and resolves
/// the key's default context, so the app boots the wrong toolset while looking
/// healthy. The names are pinned on both sides: here, and in
/// scripts/selftest-api.mjs which sends this exact shape to the live worker.
final class SiteKeyValidatorBodyTests: XCTestCase {
    /// Mirrors the body assembly in SiteKeyValidator.validate.
    private func body(siteKey: String, contextId: String?, surface: String?) -> [String: Any] {
        var body: [String: Any] = ["siteKey": siteKey]
        if let contextId { body["contextId"] = contextId }
        if let surface { body["surface"] = surface }
        return body
    }

    func testOmitsOptionalFieldsWhenUnset() {
        let json = body(siteKey: "pk_test_x", contextId: nil, surface: nil)
        XCTAssertEqual(Set(json.keys), ["siteKey"])
    }

    func testUsesContextIdFieldName() {
        let json = body(siteKey: "pk_test_x", contextId: "sc_a", surface: nil)
        XCTAssertEqual(json["contextId"] as? String, "sc_a")
        XCTAssertNil(json["solutionContextId"], "the worker reads contextId, not solutionContextId")
    }

    func testUsesSurfaceFieldName() {
        let json = body(siteKey: "pk_test_x", contextId: nil, surface: "beta")
        XCTAssertEqual(json["surface"] as? String, "beta")
    }

    func testBodySerializesToJSON() {
        let json = body(siteKey: "pk_test_x", contextId: "sc_a", surface: "beta")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
        let data = try? JSONSerialization.data(withJSONObject: json)
        XCTAssertNotNil(data)
    }
}
