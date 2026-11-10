import XCTest
@testable import RipulAgent

@MainActor
final class NativeChatQuestionDeliveryTests: XCTestCase {
    func testQuestionRemainsUnansweredDuringDeliveryAndFailureThenCompletesOnAcknowledgement() throws {
        let store = NativeChatMessageStore()
        func row(submitting: Bool = false, error: String? = nil, answer: String? = nil) -> [String: Any] {
            var ask: [String: Any] = [
                "question": "Which colour?", "options": [["label": "Blue", "value": "Blue"]],
                "responseKey": "codex_question_request_0", "expectsResponse": true,
                "completed": answer != nil, "submitting": submitting,
            ]
            if let error { ask["submissionError"] = error }
            if let answer { ask["answer"] = answer }
            return ["messageId": "question", "chatId": "chat", "role": "assistant",
                    "content": "", "status": answer == nil ? "pending" : "complete", "askUser": ask]
        }
        store.applyBackfill([row()], chatId: "chat")
        store.applyAdd(row(submitting: true))
        var question = try XCTUnwrap(store.messages.first?.askUser)
        XCTAssertTrue(question.submitting)
        XCTAssertFalse(question.completed)
        XCTAssertNil(question.answer)
        XCTAssertTrue(question.selectedValues.isEmpty)

        store.applyAdd(row(error: "The conversation is disconnected."))
        question = try XCTUnwrap(store.messages.first?.askUser)
        XCTAssertFalse(question.submitting)
        XCTAssertFalse(question.completed)
        XCTAssertNil(question.answer)
        XCTAssertEqual(question.submissionError, "The conversation is disconnected.")
        XCTAssertEqual(question.options.first?.value, "Blue", "A failed send leaves the choices available for retry")

        store.applyAdd(row(submitting: true))
        XCTAssertNil(store.messages.first?.askUser?.submissionError)
        store.applyAdd(row(answer: "Blue"))
        question = try XCTUnwrap(store.messages.first?.askUser)
        XCTAssertTrue(question.completed)
        XCTAssertFalse(question.submitting)
        XCTAssertNil(question.submissionError)
        XCTAssertEqual(question.selectedValues, ["Blue"])
        XCTAssertEqual(store.messages.count, 1, "Delivery updates the original card")
        XCTAssertEqual(store.rows.count, 1)
    }

    func testFreeTextAnswerIsVisibleAfterLiveDeliveryAndReload() throws {
        let store = NativeChatMessageStore()
        store.applyBackfill([row()], chatId: "chat")
        XCTAssertNil(store.messages.first?.askUser?.freeTextAnswer)

        let answer = "Hot chocolate, please"
        let answeredRow = row(answer: answer)
        store.applyAdd(answeredRow)
        let question = try XCTUnwrap(store.messages.first?.askUser)
        XCTAssertEqual(question.freeTextAnswer, answer)
        XCTAssertEqual(question.selectedValues, [answer], "Transport values may contain free text, not just offered choices")
        XCTAssertEqual(store.rows.count, 1, "The reply belongs on the existing question card")

        let reopened = NativeChatMessageStore()
        reopened.applyBackfill([answeredRow], chatId: "chat")
        XCTAssertEqual(reopened.messages.first?.askUser?.freeTextAnswer, answer)
    }

    func testMatchingChoiceValuesAndLabelsDoNotRepeatAsFreeText() throws {
        for answer in ["tea", "Tea"] {
            let question = try decodedQuestion(row(answer: answer))
            XCTAssertEqual(question.answer, answer)
            XCTAssertNil(question.freeTextAnswer)
        }
    }

    func testMultipleChoicesDoNotRepeatButMixedFreeTextRemainsVisible() throws {
        let choices = try decodedQuestion(row(answer: ["tea", "Coffee"], multiSelect: true))
        XCTAssertEqual(choices.selectedValues, ["tea", "Coffee"])
        XCTAssertNil(choices.freeTextAnswer)

        let mixed = try decodedQuestion(row(answer: ["tea", "Hot chocolate"], multiSelect: true))
        XCTAssertEqual(mixed.freeTextAnswer, "tea, Hot chocolate")
    }

    func testTextOnlyQuestionShowsItsAnswer() throws {
        let question = try decodedQuestion(row(answer: "A quiet afternoon", options: []))
        XCTAssertEqual(question.freeTextAnswer, "A quiet afternoon")
    }

    func testPendingEmptyAndDateAnswersDoNotAddAReplySummary() throws {
        XCTAssertNil(try decodedQuestion(row(answer: "Still editing", completed: false)).freeTextAnswer)
        XCTAssertNil(try decodedQuestion(row(answer: "")).freeTextAnswer)
        XCTAssertNil(try decodedQuestion(row(answer: "2026-10-31", dateInput: [:])).freeTextAnswer)
    }

    func testPreviewAcknowledgementAlsoShowsFreeText() throws {
        let store = NativeChatMessageStore()
        store.applyBackfill([row()], chatId: "chat")
        store.markQuestionAnswered(messageId: "question", answer: "Hot chocolate")
        XCTAssertEqual(store.messages.first?.askUser?.freeTextAnswer, "Hot chocolate")
    }

    private func decodedQuestion(_ row: [String: Any]) throws -> NativeAskUser {
        let store = NativeChatMessageStore()
        store.applyBackfill([row], chatId: "chat")
        return try XCTUnwrap(store.messages.first?.askUser)
    }

    private func row(
        answer: Any? = nil,
        options: [[String: String]] = [["label": "Tea", "value": "tea"], ["label": "Coffee", "value": "coffee"]],
        multiSelect: Bool = false,
        completed: Bool? = nil,
        dateInput: [String: Any]? = nil
    ) -> [String: Any] {
        var ask: [String: Any] = [
            "question": "What would you like?", "options": options,
            "responseKey": "codex_question_request_0", "expectsResponse": true,
            "enableChatInput": true, "multiSelect": multiSelect,
            "completed": completed ?? (answer != nil),
        ]
        if let answer { ask["answer"] = answer }
        if let dateInput { ask["dateInput"] = dateInput }
        return ["messageId": "question", "chatId": "chat", "role": "assistant",
                "content": "", "status": answer == nil ? "pending" : "complete", "askUser": ask]
    }
}
