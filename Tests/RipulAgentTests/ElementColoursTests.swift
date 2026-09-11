#if os(iOS)
import XCTest
@testable import RipulAgent

@MainActor
final class ElementColoursTests: XCTestCase {
    private func prepare() {
        RipulThemeEngine.persistMutation = nil
        RipulThemeEngine.exportThemeDocument = nil
        RipulThemeEngine.configure(.init(bundleResource: "MissingColourFixture", overrideDefaultsKey: "ElementColoursTests",
            vocabulary: .init(primitives: [.init(name: "green", label: "Green", path: [], defaultReference: "00AA00")],
                roles: [.init(name: "accent", label: "Accent", path: [], defaultReference: "green")],
                components: [.init(name: "fieldLabel", label: "Field label", path: [], defaultReference: "accent")]), styleKinds: []))
        var doc = RipulThemeDocument(); doc.primitives = ["green": "00AA00"]
        RipulThemeEngine.adopt(doc)
    }
    func testIndividualOverrideSharedChangeAndResetCascade() {
        prepare()
        let start = RipulColourAssignment(element: "screen.start", property: "foreground", defaultToken: "fieldLabel")
        let finish = RipulColourAssignment(element: "screen.finish", property: "foreground", defaultToken: "fieldLabel")
        start.setReference("#112233")
        XCTAssertEqual(start.colour.ripulHexString.uppercased(), "#112233")
        XCTAssertEqual(finish.colour.ripulHexString.uppercased(), "#00AA00")
        RipulThemeEngine.setPrimitive("green", hex: "445566")
        XCTAssertEqual(start.colour.ripulHexString.uppercased(), "#112233")
        XCTAssertEqual(finish.colour.ripulHexString.uppercased(), "#445566")
        start.setReference(nil)
        XCTAssertEqual(start.colour.ripulHexString.uppercased(), "#445566")
        XCTAssertTrue(RipulThemeEngine.current.elementColors.isEmpty)
    }
    func testAssignmentRoundTripAndPublicationPreserveHostFields() throws {
        prepare()
        let assignment = RipulColourAssignment(element: "unrelated.invoice.total", property: "foreground", defaultToken: "fieldLabel")
        assignment.setReference("accent")
        let encoded = try RipulThemeEngine.themeDocumentForPublishing(over: Data(#"{"hostExtra":{"keep":true}}"#.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["hostExtra"])
        let decoded = try JSONDecoder().decode(RipulThemeDocument.self, from: encoded)
        RipulThemeEngine.adopt(RipulThemeDocument()); RipulThemeEngine.adopt(decoded)
        XCTAssertEqual(assignment.override, "accent")
        XCTAssertEqual(assignment.colour.ripulHexString.uppercased(), "#00AA00")
    }
    func testUIKitStateRefreshKeepsAuthorTokenAndOpacity() {
        prepare(); RipulThemeInstrumentation.install()
        let label = UILabel(); label.accessibilityIdentifier = "screen.subtitle"
        let assignment = RipulColourAssignment(element: "screen.subtitle", property: "foreground", defaultToken: "fieldLabel")
        assignment.setReference("#112233")
        label.textColor = RipulThemeEngine.color(component: "fieldLabel").ripulAlpha(0.5)
        XCTAssertEqual(label.textColor.ripulToken, "fieldLabel")
        XCTAssertEqual(label.textColor.ripulColourAssignment, assignment)
        XCTAssertEqual(label.textColor.cgColor.alpha, 0.5, accuracy: 0.01)
        XCTAssertEqual(label.textColor.ripulHexString.uppercased(), "#112233")
        assignment.setReference(nil); RipulElementColours.reapply(label)
        XCTAssertEqual(label.textColor.ripulHexString.uppercased(), "#00AA00")
        XCTAssertEqual(label.textColor.cgColor.alpha, 0.5, accuracy: 0.01)
    }
    func testSourceNavigationDistinguishesSemanticFromSameNamedPrimitive() {
        prepare()
        var doc = RipulThemeEngine.current; doc.primitives["accent"] = "123456"; doc.semantic["accent"] = "accent"
        RipulThemeEngine.adopt(doc)
        XCTAssertEqual(ColourTokenAddress.component("fieldLabel").source, .role("accent"))
        XCTAssertEqual(ColourTokenAddress.role("accent").source, .primitive("accent"))
        XCTAssertNil(ColourTokenAddress.primitive("accent").source)
    }

    func testExplicitPaletteAndSemanticReferencesRemainDistinct() {
        prepare()
        var doc = RipulThemeEngine.current
        doc.primitives["accent"] = "123456"; doc.semantic["accent"] = "green"
        doc.semantic["alias"] = "semantic:accent"
        doc.components["fieldLabel"] = "palette:accent"
        RipulThemeEngine.adopt(doc)
        XCTAssertEqual(RipulThemeEngine.color(component: "fieldLabel").ripulHexString.uppercased(), "#123456")
        XCTAssertEqual(RipulThemeEngine.colourReference("semantic:accent").ripulHexString.uppercased(), "#00AA00")
        XCTAssertEqual(RipulThemeEngine.color(label: "alias").ripulHexString.uppercased(), "#00AA00")
        XCTAssertTrue(RipulThemeEngine.aliasWouldCycle(label: "accent", to: "semantic:alias"))
        XCTAssertEqual(ColourTokenAddress.component("fieldLabel").source, .primitive("accent"))
    }

    func testNativeLayerBindingRepaintsAndCanBeRemoved() {
        prepare(); RipulThemeInstrumentation.install()
        let view = UIView(); view.accessibilityIdentifier = "screen.card"
        view.backgroundColor = RipulThemeEngine.color(component: "fieldLabel").ripulAlpha(0.4)
        RipulElementColours.bind(view, tokens: ["border": "fieldLabel"]) { view, colours in
            view.layer.borderColor = colours["border"]?.cgColor
        }
        let border = RipulColourAssignment(element: "screen.card", property: "border", defaultToken: "fieldLabel")
        border.setReference("#112233"); RipulElementColours.reapply(view)
        XCTAssertEqual(UIColor(cgColor: view.layer.borderColor!).ripulHexString.uppercased(), "#112233")
        XCTAssertEqual(view.backgroundColor!.cgColor.alpha, 0.4, accuracy: 0.01)
        XCTAssertEqual(view.ripulDeclaredTokenColors.first?.color.ripulColourAssignment, border)
        RipulElementColours.unbind(view)
        view.layer.borderColor = nil
        border.setReference(nil); RipulElementColours.reapply(view)
        XCTAssertNil(view.layer.borderColor)
        XCTAssertTrue(view.ripulDeclaredTokenColors.isEmpty)
    }
}
#endif
