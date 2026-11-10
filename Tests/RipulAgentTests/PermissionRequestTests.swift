import XCTest
@testable import RipulAgent

/// The permission requests the Waiting on You screen brings forward as they arrive:
/// which open questions they are, and that only an answer clears one.
/// Peter, 29 October 2026: a permission request "shoukd come to the front of the app
/// and not allow me to proceed without making a decision"; on 30 October it became one
/// card of the Waiting on You screen, which can be put away.
@MainActor
final class PermissionRequestTests: XCTestCase {
    private func store() -> PendingQuestionStore {
        let store = PendingQuestionStore(defaults: UserDefaults(suiteName: "io.ripul.tests.permission.\(UUID().uuidString)")!)
        store.configure(accountId: "owner", tokenProvider: { nil })
        return store
    }

    /// As the server lists them: an owner approval with its choices, and an ordinary question.
    private let listed = """
    [{"chatId":"cli_review","questionId":"owner_browser_access_1","title":"wac 3.0.0 review","question":"George asked to read files.",
      "blocking":1,"createdAt":1,"expiresAt":null,"kind":"question","fromName":null,"answerPolicy":"owner","header":"Folder access",
      "machineId":"studio","threadId":"owner-approval-owner_browser_access_1","actionId":"owner-approval-action-owner_browser_access_1",
      "options":[{"label":"Allow once","description":"For the one action that is waiting."},{"label":"Don't allow"}]},
     {"chatId":"cli_other","questionId":"ask_1","title":"Website","question":"Which colour?","blocking":1,"createdAt":2,
      "expiresAt":null,"kind":"question","fromName":null}]
    """

    func testAnOwnerApprovalIsAPermissionRequestWithItsChoices() throws {
        let items = try JSONDecoder().decode([PendingAgentQuestion].self, from: Data(listed.utf8))
        XCTAssertTrue(items[0].isPermission)
        XCTAssertEqual(items[0].options?.map(\.label), ["Allow once", "Don't allow"])
        XCTAssertEqual(items[0].machineId, "studio")
        XCTAssertFalse(items[1].isPermission, "An agent's ordinary question is not brought forward as a permission")
        // An item an older server or the cache wrote, with none of the new fields, still reads.
        let old = try JSONDecoder().decode(PendingAgentQuestion.self, from: Data("""
        {"chatId":"c","questionId":"owner_browser_access_2","title":"t","question":"q","blocking":1,"createdAt":1,"expiresAt":null}
        """.utf8))
        XCTAssertTrue(old.isPermission, "Known by its key from an older server")
        XCTAssertNil(old.options)
        XCTAssertTrue(items[0].isAnswerableHere)
        XCTAssertFalse(old.isAnswerableHere)
    }

    /// Peter, 29 October 2026: "permissions need to be surfaced outside the chat, not just a link to it inside the chat".
    func testARequestWithoutItsChoicesIsNotHeldInFrontAsALink() throws {
        let store = store()
        var items = try JSONDecoder().decode([PendingAgentQuestion].self, from: Data(listed.utf8))
        items.append(try JSONDecoder().decode(PendingAgentQuestion.self, from: Data("""
        {"chatId":"cli_adversarial","questionId":"owner_browser_access_old","title":"Adversarial code review","question":"Eden asked to change files.",
         "blocking":1,"createdAt":3,"expiresAt":null,"kind":"question","fromName":null,"answerPolicy":"owner"}
        """.utf8)))
        store.replace(items)
        XCTAssertEqual(store.permissionRequests.map(\.questionId), ["owner_browser_access_1"])
        // It is still an open question of the account's, shown with the others.
        XCTAssertTrue(store.questions.contains { $0.questionId == "owner_browser_access_old" })
    }

    /// Peter, 1 November 2026: Gatekeeper's "Open ipsw?" on the Studio waited unseen on the list.
    func testAMacOSQuestionComesForwardAsItArrives() throws {
        let store = store()
        var items = try JSONDecoder().decode([PendingAgentQuestion].self, from: Data(listed.utf8))
        items.append(try JSONDecoder().decode(PendingAgentQuestion.self, from: Data("""
        {"chatId":"mac-dialog:machine-studio","questionId":"dialog-936-1793548331","title":"Studio",
         "question":"macOS is asking on this Mac: Open ipsw?","blocking":1,"createdAt":4,"expiresAt":null}
        """.utf8)))
        store.replace(items)
        XCTAssertEqual(Set(store.broughtForward.map(\.questionId)), ["owner_browser_access_1", "dialog-936-1793548331"])
        XCTAssertEqual(store.permissionRequests.map(\.questionId), ["owner_browser_access_1"],
                       "still not answerable on its card: Show the Question opens the live dialog")
    }

    func testOnlyAnAnswerClearsAPermissionRequest() throws {
        let store = store()
        store.replace(try JSONDecoder().decode([PendingAgentQuestion].self, from: Data(listed.utf8)))
        XCTAssertEqual(store.permissionRequests.map(\.questionId), ["owner_browser_access_1"])
        // Clearing a chat's attention in the list leaves its permission request standing.
        store.dismiss(anyOf: ["cli_review", "cli_other"])
        XCTAssertEqual(store.permissionRequests.map(\.questionId), ["owner_browser_access_1"])
        XCTAssertFalse(store.questions.contains { $0.questionId == "ask_1" })
        // An answer lets it go.
        store.settle(store.permissionRequests[0])
        XCTAssertTrue(store.permissionRequests.isEmpty)
    }

    func testAPushKeepsTheChoicesTheListGave() throws {
        let store = store()
        store.replace(try JSONDecoder().decode([PendingAgentQuestion].self, from: Data(listed.utf8)))
        let pushed = store.receivePush([
            "userId": "owner", "type": "agentQuestion", "chatId": "cli_review", "questionId": "owner_browser_access_1",
            "title": "wac 3.0.0 review", "answerPolicy": "owner", "createdAt": 1.0,
            "expiresAt": Date().timeIntervalSince1970 * 1000 + 60_000,
            "aps": ["alert": ["title": "wac 3.0.0 review · Needs your permission", "body": "George asked to read files."]],
        ])
        XCTAssertTrue(pushed)
        XCTAssertEqual(store.permissionRequests.first?.options?.count, 2)
        XCTAssertEqual(store.permissionRequests.first?.machineId, "studio")
    }
}
