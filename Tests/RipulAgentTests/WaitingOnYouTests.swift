import XCTest
@testable import RipulAgent

/// The Waiting on You screen: which items it can answer, in what order, what each answer
/// sends, and when it comes forward by itself.
/// Peter, 30 October 2026: "a unified question-answer center that pulls together everything
/// that is waiting on me", answered "without having to drill into all the chats".
@MainActor
final class WaitingOnYouTests: XCTestCase {
    /// As the server lists them for the owner of the chats: a permission request, a question
    /// with several choices, one with values and typed words, one with a date, one with only
    /// its words (a table to choose from), a mention and a macOS question on a Mac.
    private let listed = """
    [{"chatId":"cli_review","questionId":"owner_browser_access_1","title":"Review","question":"George asked to read files.",
      "blocking":1,"createdAt":5,"expiresAt":null,"kind":"question","answerPolicy":"owner","header":"Folder access",
      "machineId":"studio","threadId":"owner-approval-owner_browser_access_1","actionId":"owner-approval-action-owner_browser_access_1",
      "options":[{"label":"Allow once"},{"label":"Don't allow"}]},
     {"chatId":"cli_release","questionId":"cli_ask_user_t_0","title":"Release","question":"Which checks?","blocking":1,"createdAt":2,
      "expiresAt":null,"kind":"question","threadId":"cli-question-t-0","actionId":"cli-action-t-0","machineId":"studio",
      "multiSelect":true,"options":[{"label":"Unit tests"},{"label":"Phone/install","value":"phone"}]},
     {"chatId":"cli_site","questionId":"ask_colour","title":"Site","question":"Which colour?","blocking":1,"createdAt":3,
      "expiresAt":null,"kind":"question","threadId":"t","actionId":"a","machineId":"studio","allowsText":true,
      "options":[{"label":"Navy","value":"navy-1"},{"label":"Teal"}]},
     {"chatId":"cli_rota","questionId":"ask_date","title":"Rota","question":"Start?","blocking":1,"createdAt":4,
      "expiresAt":null,"kind":"question","threadId":"t2","actionId":"a2","dateInput":{"includeTime":true,"minDate":"2026-10-30"}},
     {"chatId":"cli_clean","questionId":"ask_table","title":"Clean-up","question":"Which rows?","blocking":1,"createdAt":1,
      "expiresAt":null,"kind":"question"},
     {"chatId":"cli_design","questionId":"msg_1","title":"Design","question":"Look at this?","blocking":0,"createdAt":0,
      "expiresAt":null,"kind":"mention","fromName":"Sam"},
     {"chatId":"mac-dialog:studio","questionId":"tcc_1","title":"Studio","question":"Allow access to Documents?","blocking":1,
      "createdAt":6,"expiresAt":null,"kind":"question"}]
    """

    private func items() throws -> [PendingAgentQuestion] {
        try JSONDecoder().decode([PendingAgentQuestion].self, from: Data(listed.utf8))
    }

    func testWhatCanBeAnsweredOnTheScreen() throws {
        let byId = Dictionary(uniqueKeysWithValues: try items().map { ($0.questionId, $0) })
        XCTAssertTrue(byId["owner_browser_access_1"]!.isAnswerableHere)
        XCTAssertTrue(byId["cli_ask_user_t_0"]!.isAnswerableHere)
        XCTAssertTrue(byId["ask_colour"]!.isAnswerableHere)
        XCTAssertTrue(byId["ask_date"]!.isAnswerableHere, "A date alone is enough")
        XCTAssertFalse(byId["ask_table"]!.isAnswerableHere, "Only its words came: it is answered in its chat")
        XCTAssertFalse(byId["msg_1"]!.isAnswerableHere, "A mention is read, not answered")
        XCTAssertTrue(byId["tcc_1"]!.isMacDialog)
        XCTAssertFalse(byId["tcc_1"]!.isAnswerableHere, "macOS's own question is pressed on the Mac's screen")
        // A question with a form but no ids to route the answer is answered in its chat.
        var stray = byId["ask_colour"]!
        stray.threadId = nil
        XCTAssertFalse(stray.isAnswerableHere)
    }

    func testEachAnswerIsWhatTheCardInTheChatSends() throws {
        let byId = Dictionary(uniqueKeysWithValues: try items().map { ($0.questionId, $0) })
        XCTAssertEqual(WaitingOnYouRules.answer(choosing: [0], of: byId["ask_colour"]!), "navy-1", "A choice's value, when it has one")
        XCTAssertEqual(WaitingOnYouRules.answer(choosing: [1], of: byId["ask_colour"]!), "Teal")
        XCTAssertEqual(WaitingOnYouRules.answer(choosing: [1, 0], of: byId["cli_ask_user_t_0"]!), #"["Unit tests","phone"]"#)
        XCTAssertNil(WaitingOnYouRules.answer(choosing: [], of: byId["cli_ask_user_t_0"]!))
        XCTAssertNil(WaitingOnYouRules.answer(choosing: [7], of: byId["ask_colour"]!))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 5))!
        XCTAssertEqual(WaitingOnYouRules.dateAnswer(date, includeTime: true, calendar: calendar), "2026-10-30T14:05")
        XCTAssertEqual(WaitingOnYouRules.dateAnswer(date, includeTime: false, calendar: calendar), "2026-10-30")
        XCTAssertEqual(WaitingOnYouRules.date("2026-10-30T14:05", calendar: calendar), date)
        XCTAssertNil(WaitingOnYouRules.date("soon", calendar: calendar))
    }

    /// Peter, 30 October 2026: "The cards should start with newest to oldest, newest first".
    func testTheNewestComesFirstWhateverItsKind() throws {
        let order = WaitingOnYouRules.ordered(try items()).map(\.questionId)
        XCTAssertEqual(order, ["tcc_1", "owner_browser_access_1", "ask_date", "ask_colour", "cli_ask_user_t_0", "ask_table", "msg_1"])
    }

    /// Peter, 30 October 2026: "What about questions that have timed out and the agent has moved on then?"
    func testACardSaysWhenTheAgentHasMovedOn() throws {
        let now = Date()
        let byId = Dictionary(uniqueKeysWithValues: try items().map { ($0.questionId, $0) })
        func asked(_ id: String, minutesAgo: Double, blocking: Int = 1) -> PendingAgentQuestion {
            var item = byId[id]!
            item = PendingAgentQuestion(chatId: item.chatId, questionId: item.questionId, title: item.title, question: item.question,
                blocking: blocking, createdAt: now.timeIntervalSince1970 * 1000 - minutesAgo * 60_000, expiresAt: nil)
            item.answerPolicy = byId[id]!.answerPolicy
            item.kind = byId[id]!.kind
            return item
        }
        // Claude hands its call back after about four minutes; the card stays open for a late answer.
        XCTAssertFalse(asked("cli_ask_user_t_0", minutesAgo: 1).agentMovedOn(now: now))
        XCTAssertTrue(asked("cli_ask_user_t_0", minutesAgo: 10).agentMovedOn(now: now))
        XCTAssertTrue(asked("owner_browser_access_1", minutesAgo: 10).agentMovedOn(now: now))
        // A question the agent never stopped for; one an agent in a page still waits on; a person's mention.
        XCTAssertTrue(asked("ask_colour", minutesAgo: 1, blocking: 0).agentMovedOn(now: now))
        XCTAssertFalse(asked("ask_colour", minutesAgo: 600).agentMovedOn(now: now))
        XCTAssertFalse(asked("msg_1", minutesAgo: 600, blocking: 0).agentMovedOn(now: now))
    }

    func testItComesForwardOnOpeningAndAfterAWhileAway() {
        let now = Date()
        XCTAssertTrue(WaitingOnYouRules.comesForward(launch: true, awaySince: nil, now: now, showOnOpen: true, awayMinutes: 5))
        XCTAssertFalse(WaitingOnYouRules.comesForward(launch: true, awaySince: nil, now: now, showOnOpen: false, awayMinutes: 5))
        XCTAssertFalse(WaitingOnYouRules.comesForward(launch: false, awaySince: now.addingTimeInterval(-120), now: now, showOnOpen: true, awayMinutes: 5),
                       "Two minutes away is not a gap")
        XCTAssertTrue(WaitingOnYouRules.comesForward(launch: false, awaySince: now.addingTimeInterval(-301), now: now, showOnOpen: true, awayMinutes: 5))
        XCTAssertTrue(WaitingOnYouRules.comesForward(launch: false, awaySince: now.addingTimeInterval(-2), now: now, showOnOpen: true, awayMinutes: 0),
                      "Any Time: every return")
        XCTAssertFalse(WaitingOnYouRules.comesForward(launch: false, awaySince: nil, now: now, showOnOpen: true, awayMinutes: 0),
                       "Never away: nothing to come back from")
    }

    func testAutomaticButtonDoesNotOpenCardsUntilTappedAndReturnsAfterClosing() {
        let centre = WaitingOnYouCentre()
        centre.offer(focusing: "first", asButton: true)
        XCTAssertTrue(centre.offersButton)
        XCTAssertFalse(centre.isPresented, "A new question must not interrupt the current screen")
        XCTAssertEqual(centre.openings, 0)

        centre.offer(focusing: "newest", asButton: true)
        XCTAssertEqual(centre.focusId, "newest")
        XCTAssertEqual(centre.openings, 0, "Several arrivals update the button without opening cards")

        // The FAB uses the offered focus, including when another question arrived meanwhile.
        centre.open(focusing: centre.focusId)
        XCTAssertTrue(centre.isPresented)
        XCTAssertEqual(centre.focusId, "newest")
        XCTAssertEqual(centre.openings, 1)
        centre.close()
        XCTAssertFalse(centre.isPresented)
        XCTAssertTrue(centre.offersButton, "Putting cards away must leave the unanswered items reachable")

        centre.clearButton()
        XCTAssertFalse(centre.offersButton, "Nothing waiting, signing out or disabling the setting removes the button")
        XCTAssertFalse(centre.isPresented, "Removing the button never opens a card")
    }

    func testFullCardPreferenceAndExplicitNotificationTapsStillOpenImmediately() {
        let centre = WaitingOnYouCentre()
        centre.offer(focusing: "question", asButton: false)
        XCTAssertTrue(centre.isPresented)
        XCTAssertFalse(centre.offersButton)
        XCTAssertEqual(centre.focusId, "question")
        centre.close()

        centre.offer(focusing: "deferred", asButton: true)
        // A notification or the Agents question chip calls open, never offer.
        centre.open(focusing: "notification")
        XCTAssertTrue(centre.isPresented)
        XCTAssertEqual(centre.focusId, "notification")
        XCTAssertEqual(centre.openings, 2)
    }

    /// Peter, 4 November 2026: "if I'm in another chat and there's a pending question, I'm not gonna see it".
    func testAQuestionArrivingFromAnotherChatComesForward() throws {
        let listed = try items()
        func asked(_ id: String, in chat: String, at createdAt: Double) -> PendingAgentQuestion {
            var item = PendingAgentQuestion(chatId: chat, questionId: id, title: "New", question: "Which one?",
                blocking: 1, createdAt: createdAt, expiresAt: nil)
            item.kind = "question"
            return item
        }
        var arrivals = QuestionArrivals()
        XCTAssertNil(arrivals.take(listed, isViewing: { _ in false }), "What waits at opening is the opening rule's")
        XCTAssertNil(arrivals.take(listed, isViewing: { _ in false }), "Nothing new")
        // Two arrive at once: the newest comes first. One answered only in its chat comes forward too.
        let site = asked("ask_new_site", in: "cli_site", at: 10)
        let clean = asked("ask_new_clean", in: "cli_clean", at: 11)
        XCTAssertEqual(arrivals.take(listed + [site, clean], isViewing: { _ in false })?.questionId, "ask_new_clean")
        XCTAssertNil(arrivals.take(listed + [site, clean], isViewing: { _ in false }), "Each comes forward once")
        // Asked in the chat on screen: seen there, and not brought forward when the person leaves that chat.
        let release = asked("ask_new_release", in: "cli_release", at: 12)
        XCTAssertNil(arrivals.take(listed + [release], isViewing: { $0 == "cli_release" }))
        XCTAssertNil(arrivals.take(listed + [release], isViewing: { _ in false }))
        // A mention, a permission request and a macOS question are not this rule's.
        var mention = asked("msg_new", in: "cli_design", at: 13)
        mention.kind = "mention"
        var permission = asked("owner_browser_access_new", in: "cli_review", at: 14)
        permission.answerPolicy = "owner"
        let dialog = asked("tcc_new", in: "mac-dialog:studio", at: 15)
        XCTAssertNil(arrivals.take(listed + [mention, permission, dialog], isViewing: { _ in false }))
    }

    func testAnAnsweredQuestionGoesAndAClearedOneStaysAnsweredNowhere() throws {
        let store = PendingQuestionStore(defaults: UserDefaults(suiteName: "io.ripul.tests.waiting.\(UUID().uuidString)")!)
        store.configure(accountId: "owner", tokenProvider: { nil })
        store.replace(try items())
        let colour = store.waiting.first { $0.questionId == "ask_colour" }!
        store.settle(colour)
        XCTAssertFalse(store.waiting.contains(colour))
        // Clearing a question from the list never answers it, and a permission request is cleared only by an answer.
        let permission = store.waiting.first(where: \.isPermission)!
        store.dismiss(permission)
        XCTAssertTrue(store.waiting.contains(permission))
        let table = store.waiting.first { $0.questionId == "ask_table" }!
        store.dismiss(table)
        XCTAssertFalse(store.waiting.contains(table))
        // A macOS dialog question can also be dismissed permanently from its card.
        let macDialog = store.waiting.first { $0.questionId == "tcc_1" }!
        store.dismiss(macDialog)
        XCTAssertFalse(store.waiting.contains(macDialog))
    }

    func testAPushKeepsHowTheListSaidToAnswer() throws {
        let store = PendingQuestionStore(defaults: UserDefaults(suiteName: "io.ripul.tests.waiting.\(UUID().uuidString)")!)
        store.configure(accountId: "owner", tokenProvider: { nil })
        store.replace(try items())
        XCTAssertTrue(store.receivePush([
            "userId": "owner", "type": "agentQuestion", "chatId": "cli_release", "questionId": "cli_ask_user_t_0",
            "title": "Release", "createdAt": 2.0, "expiresAt": Date().timeIntervalSince1970 * 1000 + 60_000,
            "aps": ["alert": ["title": "Release · Waiting for your answer", "body": "Which checks?"]],
        ]))
        let pushed = store.waiting.first { $0.questionId == "cli_ask_user_t_0" }!
        XCTAssertEqual(pushed.multiSelect, true)
        XCTAssertEqual(pushed.options?.last?.answer, "phone")
        XCTAssertTrue(pushed.isAnswerableHere)
    }
}
