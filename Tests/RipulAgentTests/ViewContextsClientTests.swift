import XCTest
@testable import RipulAgent

final class ViewContextsClientTests: XCTestCase {
    func testEditingPreservesUnknownFeaturesAndExplicitFalse() throws {
        var context = try RipulViewContext(json: [
            "id": "phone", "name": "Phone", "tabIds": ["chat"],
            "features": ["futureSetting": ["nested": [1, 2]], "slashCommands": ["clear"],
                         "showUsage": false, "chatActionButtons": []] as [String: Any]
        ])
        context.features["welcomeTitle"] = "Hello"
        let data = try JSONSerialization.data(withJSONObject: context.payload)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try XCTUnwrap(decoded["features"] as? [String: Any])
        XCTAssertEqual(features["showUsage"] as? Bool, false)
        XCTAssertEqual(features["slashCommands"] as? [String], ["clear"])
        XCTAssertNotNil(features["futureSetting"])
        XCTAssertEqual((features["chatActionButtons"] as? [Any])?.count, 0)
        XCTAssertNil(features["modelSelection"])
        XCTAssertEqual(decoded["defaultTabId"] as? String, "")
        XCTAssertEqual(decoded["description"] as? String, "")
    }

    func testMalformedRowsFailAndSystemFlagIsReadOnlyMetadata() throws {
        XCTAssertThrowsError(try RipulViewContext(json: ["id": "bad", "name": "Bad"]))
        let context = try RipulViewContext(json: ["id": "system", "name": "System", "tabIds": ["chat"], "isSystem": true])
        XCTAssertTrue(context.isSystem)
        XCTAssertNil(context.payload["isSystem"])
    }

    func testMissingTokenRejectsBeforeNetwork() async {
        let client = RipulViewContextsClient(tokenProvider: { nil })
        do { _ = try await client.list(); XCTFail("Expected authentication failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Sign in to manage view contexts.") }
    }
}
