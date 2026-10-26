import XCTest
@testable import RipulAgent

/// The machine panel draws only listed actions (`RemoteActionDescriptor.listed`).
/// These pin the flag's default, its trip over the wire and through the cache,
/// and what an app makes of a host built before the flag.
final class RemoteActionDescriptorTests: XCTestCase {
    private func wire(category: String, listed: Bool? = nil) -> [String: Any] {
        var dict: [String: Any] = ["id": "\(category):x", "displayName": "X", "description": "", "category": category]
        if let listed { dict["listed"] = listed }
        return dict
    }

    func testAnActionIsUnlistedUnlessItsProviderSaysSo() {
        let action = RemoteActionDescriptor(id: "dock:list", displayName: "List Dock Apps", description: "", category: "dock")
        XCTAssertFalse(action.listed)
        XCTAssertEqual(action.toDict["listed"] as? Bool, false, "sent when false too, so an app can tell it from an older host")
    }

    func testTheHostsFlagDecides() {
        XCTAssertEqual(RemoteActionDescriptor(from: wire(category: "dock", listed: true))?.listed, true)
        XCTAssertEqual(RemoteActionDescriptor(from: wire(category: "script", listed: false))?.listed, false)
    }

    func testAnOlderHostListsOnlyItsScriptsAndSystemInfo() {
        XCTAssertEqual(RemoteActionDescriptor(from: wire(category: "script"))?.listed, true)
        XCTAssertEqual(RemoteActionDescriptor(from: wire(category: "intrinsic"))?.listed, true)
        for category in ["dock", "processes", "trainyard", "alerts", "bridge", "liveview", "screen"] {
            XCTAssertEqual(RemoteActionDescriptor(from: wire(category: category))?.listed, false, category)
        }
    }

    func testTheCacheKeepsTheFlag() {
        let listed = RemoteActionDescriptor(id: "script:a", displayName: "A", description: "", category: "script", listed: true)
        let unlisted = RemoteActionDescriptor(id: "script:b", displayName: "B", description: "", category: "script")
        XCTAssertEqual(RemoteActionDescriptor(from: listed.toDict)?.listed, true)
        XCTAssertEqual(RemoteActionDescriptor(from: unlisted.toDict)?.listed, false)
    }
}
