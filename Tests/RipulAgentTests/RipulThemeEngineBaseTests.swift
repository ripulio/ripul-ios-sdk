#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import RipulAgent
@testable import RipulThemeKit

// The engine (RipulThemeEngine, RipulThemeDocument, NativeTextTheme) is
// RipulAgent's, so these live with its tests; RipulThemeKitTests links only
// the theme layer.

/// The UIKit accessors, and the host engine beside the base vocabulary.
final class RipulThemeEngineBaseTests: XCTestCase {
    private let conditions: [(String, UITraitCollection)] = [
        ("light", UITraitCollection(userInterfaceStyle: .light)),
        ("dark", UITraitCollection(userInterfaceStyle: .dark)),
        ("increased contrast", UITraitCollection(traitsFrom: [.init(userInterfaceStyle: .light), .init(accessibilityContrast: .high)])),
        ("dark, increased contrast", UITraitCollection(traitsFrom: [.init(userInterfaceStyle: .dark), .init(accessibilityContrast: .high)])),
        ("elevated", UITraitCollection(traitsFrom: [.init(userInterfaceStyle: .dark), .init(userInterfaceLevel: .elevated)])),
    ]
    private var light: UITraitCollection { conditions[0].1 }
    private var dark: UITraitCollection { conditions[1].1 }

    override func setUp() {
        RipulTheme.resetToDefaults()
        UserDefaults.standard.removeObject(forKey: "RipulThemeCoreTests")
        RipulThemeEngine.persistMutation = nil
    }
    override func tearDown() { RipulTheme.resetToDefaults() }

    func testEveryUIColorRoleIsTheSystemColourItself() {
        let pairs: [(RipulColorRole, UIColor)] = [
            (.accent, .tintColor), (.canvas, .systemBackground), (.surface, .secondarySystemGroupedBackground),
            (.surfaceSunken, .systemGroupedBackground), (.text, .label), (.textSecondary, .secondaryLabel),
            (.textTertiary, .tertiaryLabel), (.textQuaternary, .quaternaryLabel), (.separator, .separator),
            (.success, .systemGreen), (.warning, .systemOrange), (.danger, .systemRed), (.info, .systemBlue),
            (.neutral, .systemGray),
        ]
        XCTAssertEqual(pairs.count + 1, RipulColorRole.allCases.count, "every role is in this test")
        for (role, system) in pairs {
            XCTAssertTrue(UIColor.ripul(role) === system, "\(role)")
            XCTAssertNil(UIColor.ripul(role).ripulToken, "a system colour is shared and must not be tagged")
            // The same object, so this cannot fail; it is here as the statement of what
            // "exactly" means: the live colour under every condition, never a resolved one.
            for (name, traits) in conditions {
                XCTAssertEqual(UIColor.ripul(role).resolvedColor(with: traits), system.resolvedColor(with: traits), "\(role), \(name)")
            }
        }
        XCTAssertEqual(UIColor.ripul(.onAccent), UIColor(red: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertEqual(Color.ripul(.canvas), Color(UIColor.systemBackground))
        XCTAssertEqual(Color.ripul(.surface), Color(UIColor.secondarySystemGroupedBackground))
        XCTAssertEqual(Color.ripul(.textTertiary), Color(UIColor.tertiaryLabel))
        XCTAssertEqual(Color.ripul(.separator), Color(UIColor.separator))
    }

    func testTheSystemFormIsTheSystemColour() {
        XCTAssertTrue(UIColor.ripul(system: .secondarySystemBackground) === UIColor.secondarySystemBackground)
        XCTAssertTrue(UIColor.ripul(system: .tertiarySystemFill) === UIColor.tertiarySystemFill)
        XCTAssertEqual(Color.ripul(system: .secondarySystemBackground), Color(UIColor.secondarySystemBackground))
        XCTAssertEqual(Color.ripul(system: .secondaryLabel), Color(UIColor.secondaryLabel), "a fixed label colour, not the hierarchical style")
        XCTAssertEqual(Color.ripul(system: .white), Color.white)
        XCTAssertEqual(Color.ripul(system: .black), Color.black)
        XCTAssertEqual(Color.ripul(system: .systemPink), Color.pink)
        for name in RipulSystemColor.allCases where name != .white && name != .black {
            XCTAssertTrue(RipulTheme.systemColorNames.contains(name.rawValue), "\(name)")
        }
    }

    func testUIFontRolesAreTheSystemFonts() {
        XCTAssertEqual(UIFont.ripul(.body), UIFont.preferredFont(forTextStyle: .body))
        XCTAssertEqual(UIFont.ripul(.caption), UIFont.preferredFont(forTextStyle: .caption1))
        XCTAssertEqual(UIFont.ripul(.title), UIFont.preferredFont(forTextStyle: .title1))
        XCTAssertEqual(UIFont.ripul(size: 14, weight: .medium), UIFont.systemFont(ofSize: 14, weight: .medium))
        XCTAssertEqual(UIFont.ripul(size: 12), UIFont.systemFont(ofSize: 12))
        XCTAssertEqual(UIFont.ripul(size: 12, weight: .semibold, family: .code), UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold))
        XCTAssertEqual(UIFont.ripul(.footnote, weight: .semibold),
                       UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .semibold))
    }

    func testAPairResolvesPerAppearanceInUIKit() throws {
        try RipulTheme.adopt(documentData: Data(##"{"palette":{"teal":{"light":"#1f6f70","dark":"#62b9b4"}},"roles":{"ripul.accent":"teal"}}"##.utf8))
        XCTAssertEqual(UIColor.ripul(.accent).resolvedColor(with: light), UIColor(ripulHexString: "#1f6f70"))
        XCTAssertEqual(UIColor.ripul(.accent).resolvedColor(with: dark), UIColor(ripulHexString: "#62b9b4"))
        RipulTheme.resetToDefaults()
        XCTAssertTrue(UIColor.ripul(.accent) === UIColor.tintColor)
    }

    // MARK: the host engine and the base vocabulary are separate

    private func configureAHost() {
        RipulThemeEngine.configure(.init(bundleResource: "NoSuchBundledTheme", overrideDefaultsKey: "RipulThemeCoreTests",
            vocabulary: .init(primitives: [.init(name: "green", label: "Green", path: [], defaultReference: "00AA00")],
                              roles: [.init(name: "accent", label: "Accent", path: [], defaultReference: "green")],
                              components: [.init(name: "fieldLabel", label: "Field label", path: [], defaultReference: "accent")]),
            styleKinds: []))
        RipulThemeEngine.adopt(RipulThemeDocument())
    }

    func testAHostsConfigureAndEditsDoNotTouchTheBaseVocabulary() throws {
        try RipulTheme.adopt(documentData: Data(##"{"roles":{"ripul.accent":"#FF00FF"}}"##.utf8))
        configureAHost()
        RipulThemeEngine.setReference(label: "accent", to: "#0000FF")
        RipulThemeEngine.setReference(label: "ripul.danger", to: "#0000FF")
        XCTAssertEqual(RipulTheme.color(.accent).light, RipulColorLiteral("#FF00FF"), "configure does not clear it")
        XCTAssertTrue(RipulTheme.isDefault(.danger), "a host's roles map is not where the base vocabulary lives")
        RipulThemeEngine.removeSemanticLabel("ripul.danger")
    }

    func testAHostTokenResolvesAsBeforeAndTheHostEditorDoesNotListBaseRoles() {
        configureAHost()
        XCTAssertEqual(RipulThemeEngine.color(component: "fieldLabel"), UIColor(ripulHexString: "00AA00"))
        XCTAssertEqual(RipulThemeEngine.color(component: "fieldLabel").ripulToken, "fieldLabel")
        XCTAssertEqual(RipulThemeEngine.color(label: "nothing"), .magenta, "the host engine's own failure colour is unchanged")
        XCTAssertFalse(RipulThemeEngine.isSemanticLabel("ripul.accent"))
        XCTAssertEqual(RipulThemeEngine.semanticLabels, ["accent"])
    }

    func testAHostColourMayNowBeASystemColourOrAPair() {
        configureAHost()
        var doc = RipulThemeDocument()
        doc.primitives = ["green": "#1f6f70"]
        doc.primitivesDark = ["green": "#62b9b4"]
        doc.semantic = ["accent": "green"]
        RipulThemeEngine.adopt(doc)
        let colour = RipulThemeEngine.color(component: "fieldLabel")
        XCTAssertEqual(colour.resolvedColor(with: light), UIColor(ripulHexString: "#1f6f70"))
        XCTAssertEqual(colour.resolvedColor(with: dark), UIColor(ripulHexString: "#62b9b4"))
        RipulThemeEngine.setReference(label: "accent", to: "system:label")
        let label = RipulThemeEngine.color(label: "accent")
        XCTAssertEqual(label.resolvedColor(with: light), UIColor.label.resolvedColor(with: light))
        XCTAssertEqual(label.resolvedColor(with: dark), UIColor.label.resolvedColor(with: dark))
        XCTAssertEqual(label.ripulToken, "accent")
        XCTAssertNil(UIColor.label.ripulToken, "tagging the engine's colour must not tag the system's")
        RipulThemeEngine.adopt(RipulThemeDocument())
    }

    // MARK: additive: what an existing host document does is unchanged

    func testAHexOnlyDocumentWithNoFontsReadsAndWritesAsBefore() throws {
        let json = ##"{"colors":{"accent":"12CEA8","black":"373635"},"components":{"rowTitle":"textPrimary"},"elementColors":{},"semantic":{"textPrimary":"black"}}"##
        let doc = try JSONDecoder().decode(RipulThemeDocument.self, from: Data(json.utf8))
        XCTAssertEqual(doc.primitives, ["accent": "12CEA8", "black": "373635"])
        XCTAssertTrue(doc.primitivesDark.isEmpty)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(data: try encoder.encode(doc), encoding: .utf8), json)
    }

    func testAPairedPaletteEntryRoundTrips() throws {
        let json = ##"{"colors":{"ink":"1b2a41","teal":{"dark":"#62b9b4","light":"#1f6f70"}},"components":{},"elementColors":{},"semantic":{}}"##
        let doc = try JSONDecoder().decode(RipulThemeDocument.self, from: Data(json.utf8))
        XCTAssertEqual(doc.primitives["teal"], "#1f6f70")
        XCTAssertEqual(doc.primitivesDark, ["teal": "#62b9b4"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(data: try encoder.encode(doc), encoding: .utf8), json)
    }

    /// WAC's real bundled theme, read from its checkout on this Mac when it is there.
    func testWACsRealThemeLoadsUnchangedWithAndWithoutARipulSection() throws {
        // In a simulator the home directory is the simulator's own; the Mac's is in the environment.
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        let url = URL(fileURLWithPath: home)
            .appendingPathComponent("Documents/WAC_ios_final-shift-rate-templates/WAC/Helper Class/Theme/Theme.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no WAC checkout at \(url.path)") }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let plain = try JSONDecoder().decode(RipulThemeDocument.self, from: data)
        XCTAssertEqual(plain.primitives, json["colors"] as? [String: String])
        XCTAssertEqual(plain.semantic, json["semantic"] as? [String: String])
        XCTAssertEqual(plain.components, json["components"] as? [String: String])
        XCTAssertTrue(plain.primitivesDark.isEmpty)

        var withSection = json
        withSection["ripul"] = ["schema": 1, "palette": ["teal": ["light": "#1f6f70", "dark": "#62b9b4"]],
                                "roles": ["accent": "teal"], "typography": ["families": ["display": "system-serif"]]]
        let extended = try JSONSerialization.data(withJSONObject: withSection)
        XCTAssertEqual(try JSONDecoder().decode(RipulThemeDocument.self, from: extended), plain,
                       "the host's slice does not see the reserved key")
        XCTAssertNoThrow(try NativeTextTheme.decode(document: extended), "the SDK's own text section still reads")
        try RipulTheme.adopt(documentData: extended)
        XCTAssertEqual(RipulTheme.color(.accent).dark, RipulColorLiteral("#62b9b4"))
        try RipulTheme.adopt(documentData: data)
        XCTAssertTrue(RipulTheme.isDefault(.accent), "WAC's own document leaves the SDK's screens at the system look")
        XCTAssertEqual(Font.ripul(.body), Font.body)
    }
}
#endif
