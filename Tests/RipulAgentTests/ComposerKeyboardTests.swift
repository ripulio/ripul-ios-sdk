#if os(iOS)
import SwiftUI
import XCTest
@testable import RipulAgent

@MainActor
final class ComposerKeyboardTests: XCTestCase {
    @MainActor private final class Model: ObservableObject {
        @Published var text = "A message"
        var sent: [String] = []
        let contexts = RipulComposerContextStore()
    }

    private struct Composer: View {
        @ObservedObject var model: Model
        var body: some View {
            NativeChatInput(text: $model.text, imageAttachments: .constant([]),
                selectedPhotos: .constant([]), isAgentRunning: false,
                onSubmit: { model.sent.append(model.text); model.text = "" },
                contextStore: model.contexts)
                .frame(width: 370)
        }
    }

    private func editor(in view: UIView) -> ChatTextView? {
        if let editor = view as? ChatTextView { return editor }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }

    private func withComposer(_ check: (Model, ChatTextView) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = Model()
        let host = UIHostingController(rootView: Composer(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(250))
        let input = try XCTUnwrap(editor(in: host.view))
        XCTAssertTrue(input.becomeFirstResponder())
        try await check(model, input)
    }

    private func command(_ flags: UIKeyModifierFlags, in input: ChatTextView) throws -> UIKeyCommand {
        try XCTUnwrap(input.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == flags })
    }

    func testHardwareReturnSendsOnceAndKeepsFocusForTheNextMessage() async throws {
        try await withComposer { model, input in
            let send = try command([], in: input)
            XCTAssertTrue(send.wantsPriorityOverSystemBehavior)
            XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(send.action), to: input, from: send, for: nil))
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(model.sent, ["A message"])
            XCTAssertEqual(input.text, "")
            XCTAssertTrue(input.isFirstResponder)
            input.insertText("Next message")
            XCTAssertEqual(model.text, "Next message")
            XCTAssertEqual(model.sent.count, 1)
        }
    }

    func testShiftReturnReplacesSelectionWithNewlineWithoutSending() async throws {
        try await withComposer { model, input in
            input.selectedRange = NSRange(location: 1, length: 1)
            let newline = try command(.shift, in: input)
            XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(newline.action), to: input, from: newline, for: nil))
            XCTAssertEqual(model.text, "A\nmessage")
            XCTAssertEqual(input.selectedRange, NSRange(location: 2, length: 0))
            XCTAssertTrue(model.sent.isEmpty)
            XCTAssertTrue(input.isFirstResponder)
        }
    }

    func testSoftwareReturnAndMultilineInsertionNeverSend() async throws {
        try await withComposer { model, input in
            input.selectedRange = NSRange(location: input.text.utf16.count, length: 0)
            // UITextInput insertion is the onscreen keyboard's path. It must
            // remain separate from the hardware UIKeyCommand action.
            input.insertText("\n")
            input.insertText("Second line\nThird line")
            XCTAssertEqual(model.text, "A message\nSecond line\nThird line")
            XCTAssertTrue(model.sent.isEmpty)
            XCTAssertTrue(input.isFirstResponder)
            XCTAssertEqual(input.returnKeyType, .default)
        }
    }

    func testMarkedTextCannotTriggerSendEvenWithAnAlreadyResolvedCommand() async throws {
        try await withComposer { model, input in
            let send = try command([], in: input)
            input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertNotNil(input.markedTextRange)
            XCTAssertFalse(input.keyCommands?.contains { $0.action == send.action } ?? false)
            _ = UIApplication.shared.sendAction(try XCTUnwrap(send.action), to: input, from: send, for: nil)
            XCTAssertTrue(model.sent.isEmpty)
            input.unmarkText()
            XCTAssertNotNil(try command([], in: input))
        }
    }
}
#endif
