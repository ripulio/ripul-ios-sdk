#if os(iOS)
import XCTest
import SwiftUI
@testable import RipulAgent

@MainActor
final class ElementTextTests: XCTestCase {
    private func prepare() {
        RipulElementText.configure(defaults: ["action.save": .text("Save"), "form.submit": .token("action.save"),
            "items.summary": .text("{count} items for {name}")])
        NativeTextRuntime.adopt(NativeTextTheme())
        RipulThemeInstrumentation.install()
    }
    private func assignment(_ id: String) -> RipulTextAssignment {
        .init(element: id, token: "form.submit", fallback: "Save")
    }
    func testSharedAliasIndividualExceptionAndResetToCurrentDefault() throws {
        prepare()
        let first = assignment("invoice.save"), second = assignment("profile.save")
        XCTAssertEqual(first.text, "Save")
        try first.setReference(.text("Keep invoice"))
        try RipulElementText.setToken("action.save", reference: .text("Save changes"))
        XCTAssertEqual(first.text, "Keep invoice"); XCTAssertEqual(second.text, "Save changes")
        try first.setReference(nil)
        XCTAssertEqual(first.text, "Save changes"); XCTAssertTrue(NativeTextRuntime.current.elements.isEmpty)
        try first.setReference(.text("")); XCTAssertEqual(first.text, "")
    }
    func testReferencesAreTypedAndCyclesAreRejectedWithoutMutation() throws {
        prepare()
        let before = NativeTextRuntime.current
        XCTAssertThrowsError(try RipulElementText.setToken("action.save", reference: .token("form.submit")))
        XCTAssertEqual(NativeTextRuntime.current, before)
        XCTAssertThrowsError(try assignment("save").setReference(.token("missing")))
        try assignment("save").setReference(.text("form.submit"))
        XCTAssertEqual(assignment("save").text, "form.submit")
        XCTAssertThrowsError(try JSONDecoder().decode(RipulTextReference.self, from: Data(#"{"text":"a","token":"b"}"#.utf8)))
    }
    func testDataRemainsLiveAndTemplatesNeverReinterpretArguments() throws {
        prepare()
        let data = RipulTextAssignment(element: "invoice.amount", fallback: "£12.00", dataSource: "Invoice total")
        XCTAssertThrowsError(try data.setReference(.text("£100")))
        var doc = NativeTextRuntime.current; doc.elements[data.element] = ["text": .text("£100")]
        NativeTextRuntime.adopt(doc)
        XCTAssertEqual(data.text, "£12.00")
        let template = RipulTextAssignment(element: "summary", token: "items.summary", fallback: "",
            arguments: ["count": "2", "name": "{count} 🐬"])
        XCTAssertEqual(template.text, "2 items for {count} 🐬")
    }
    func testTextToolRejectsEmptyPropertyAndExposesRestorableTokenOverrides() async throws {
        prepare()
        do {
            _ = try await RipulSetThemeKnobTool().execute(args: ["scope": "save", "knob": "text.", "value": "Bad"])
            XCTFail("An empty property must be rejected")
        } catch { XCTAssertTrue(error is TextReferenceError) }
        try RipulElementText.setToken("action.save", reference: .text("Confirm"))
        let result = try await RipulListThemeScopesTool().execute(args: [:]) as? [String: Any]
        let tokens = try XCTUnwrap(result?["textTokens"] as? [[String: Any]])
        let saved = try XCTUnwrap(tokens.first { $0["name"] as? String == "action.save" })
        XCTAssertEqual(saved["override"] as? [String: String], ["text": "Confirm"])
        let alias = try XCTUnwrap(tokens.first { $0["name"] as? String == "form.submit" })
        XCTAssertTrue(alias["override"] is NSNull)
        XCTAssertEqual(alias["definition"] as? [String: String], ["token": "action.save"])
    }
    func testPublicationRoundTripPreservesExistingTextAndHostFields() throws {
        prepare()
        let original = Data(#"{"nativeTextOverrides":{"tabBarItemTitles":{"help":"Help centre"},"future":{"keep":true}},"host":{"keep":42},"elementColors":{"save":{"foreground":"accent"}}}"#.utf8)
        var doc = try NativeTextTheme.decode(document: original)
        doc.tokens["action.save"] = .text("Save changes")
        doc.elements["invoice.save"] = ["text": .token("action.save")]
        let encoded = try doc.merging(into: original)
        let decoded = try NativeTextTheme.decode(document: encoded)
        XCTAssertEqual(doc, decoded)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(root["host"]); XCTAssertNotNil(root["elementColors"])
        XCTAssertNotNil((root["nativeTextOverrides"] as? [String: Any])?["future"])
        NativeTextRuntime.adopt(decoded)
        XCTAssertEqual(assignment("invoice.save").text, "Save changes")
        XCTAssertEqual(decoded.tabBarItemTitles["help"], "Help centre")
    }
    func testExistingNativeLabelAndTabCanJoinASharedToken() throws {
        prepare()
        let controller = UIViewController(), window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; NativeTextRuntime.adopt(NativeTextTheme()) }
        let label = UILabel(); label.text = "Original"; label.accessibilityIdentifier = "greeting"
        controller.view.addSubview(label)
        let selector = try XCTUnwrap(NativeLabelTheme.capture(label).selector)
        NativeLabelTheme.setOverride(selector, text: "Existing wording")
        XCTAssertEqual(TextEditingTarget.native(.label(selector)).reference, .text("Existing wording"))
        try TextEditingTarget.native(.label(selector)).set(.token("action.save"))
        XCTAssertEqual(label.text, "Save")
        let bar = UITabBar(), item = UITabBarItem(title: "Original tab", image: nil, tag: 0)
        item.accessibilityIdentifier = "tabs.save"; bar.items = [item]; controller.view.addSubview(bar)
        try TextEditingTarget.native(.tabTitle("tabs.save")).set(.token("action.save"))
        try RipulElementText.setToken("action.save", reference: .text("Confirm"))
        XCTAssertEqual(label.text, "Confirm"); XCTAssertEqual(item.title, "Confirm")
        label.text = "Latest app wording"
        try TextEditingTarget.native(.label(selector)).set(nil)
        XCTAssertEqual(label.text, "Latest app wording")
        try TextEditingTarget.native(.tabTitle("tabs.save")).set(nil)
        XCTAssertEqual(item.title, "Original tab")
    }
    func testNativeComponentAdapterPreservesExistingOverrideAndUsesNewDefaultAfterReset() throws {
        prepare()
        let controller = UIViewController(), window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; NativeTextRuntime.adopt(NativeTextTheme()) }
        let label = UILabel(); label.accessibilityIdentifier = "form.save"; label.text = "Save"
        controller.view.addSubview(label)
        let selector = try XCTUnwrap(NativeLabelTheme.capture(label).selector)
        NativeLabelTheme.setOverride(selector, text: "Existing wording")
        let value = assignment("form.save")
        RipulElementText.bindLabel(label, assignment: value)
        XCTAssertEqual(label.text, "Existing wording")
        try value.setReference(nil)
        XCTAssertEqual(label.text, "Save")
        try RipulElementText.setToken("action.save", reference: .text("Confirm"))
        XCTAssertEqual(label.text, "Confirm")
        RipulElementText.unbind(label)
    }
    func testReviewTreatsReferenceChangesAtomicallyAndCanDiscardOne() throws {
        prepare()
        let before = Data(#"{"nativeTextOverrides":{"elements":{"save":{"text":{"text":"Save"}}},"tokens":{"save":{"text":"Save"}}}}"#.utf8)
        let after = Data(#"{"nativeTextOverrides":{"elements":{"save":{"text":{"token":"save"}}},"tokens":{"save":{"text":"Confirm"}}}}"#.utf8)
        let changes = ThemeDocumentChanges.compare(before, after)
        XCTAssertEqual(changes.count, 2)
        let assignment = try XCTUnwrap(changes.first { $0.keys.contains("elements") })
        XCTAssertEqual(assignment.new?.display, "Token: save")
        let reverted = try ThemeDocumentChanges.reverting(assignment, baseline: before, draft: after)
        let doc = try NativeTextTheme.decode(document: reverted)
        XCTAssertEqual(doc.elements["save"]?["text"], .text("Save"))
        XCTAssertEqual(doc.tokens["save"], .text("Confirm"))
    }
}
#endif
