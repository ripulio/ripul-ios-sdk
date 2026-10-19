import XCTest
import CoreText
@testable import RipulThemeKit

/// A theme by name: what a host gets for naming one document in its bundle.
final class RipulThemeLibraryTests: XCTestCase {
    private var folder: URL!
    private var bundle: Bundle!

    private let brand = ##"{ "schema": 1, "name": "Brand", "roles": { "ripul.accent": "#112233" } }"##
    private let loud = ##"{ "schema": 1, "name": "Loud", "roles": { "accent": "#FF00FF" } }"##

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: RipulTheme.choiceKey)
        RipulTheme.resetLibraryForTests()
        RipulTheme.resetToDefaults()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ripul-theme-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Themes"), withIntermediateDirectories: true)
        try brand.write(to: folder.appendingPathComponent("brand.json"), atomically: true, encoding: .utf8)
        try loud.write(to: folder.appendingPathComponent("Themes/loud.json"), atomically: true, encoding: .utf8)
        // A bundle holds other JSON, and a document from a newer SDK.
        try ##"{ "providers": [] }"##.write(to: folder.appendingPathComponent("providers.json"), atomically: true, encoding: .utf8)
        try ##"{ "schema": 99, "roles": { "accent": "#000000" } }"##.write(to: folder.appendingPathComponent("newer.json"), atomically: true, encoding: .utf8)
        bundle = try XCTUnwrap(Bundle(url: folder))
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: RipulTheme.choiceKey)
        RipulTheme.resetLibraryForTests()
        RipulTheme.resetToDefaults()
        try? FileManager.default.removeItem(at: folder)
    }

    private var accent: RipulColorValue { RipulTheme.color(.accent) }
    private func rgb(_ hex: String) -> RipulColorValue { RipulColorValue(light: RipulColorLiteral(hex)!) }

    func testNamingADocumentPutsItInUse() {
        RipulTheme.install(theme: "brand", bundle: bundle)
        XCTAssertEqual(accent, rgb("#112233"))
        XCTAssertEqual(RipulTheme.selectedTheme, "brand")
    }

    func testInfoPlistCanChooseDifferentPlatformDocumentsAndHandsTheChoiceToThePage() throws {
        // Two app builds can point at different documents without different loaders.
        // A shipping build must use that choice even if a debug look was saved before.
        UserDefaults.standard.set("loud", forKey: RipulTheme.choiceKey)
        for (name, document, expected) in [("brand", brand, "#112233"), ("loud", loud, "#FF00FF")] {
            RipulTheme.resetLibraryForTests()
            let app = folder.appendingPathComponent("\(name).bundle")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try document.write(to: app.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
            let info = try PropertyListSerialization.data(fromPropertyList: [RipulTheme.infoPlistKey: name],
                                                         format: .xml, options: 0)
            try info.write(to: app.appendingPathComponent("Info.plist"))
            RipulTheme.install(bundle: try XCTUnwrap(Bundle(url: app)), keepsChoice: false)
            XCTAssertEqual(RipulTheme.selectedTheme, name)
            XCTAssertEqual(accent, rgb(expected))
            let handedOff = try XCTUnwrap(RipulTheme.adoptedDocumentData)
            let actual = try JSONSerialization.jsonObject(with: handedOff) as? NSDictionary
            let supplied = try JSONSerialization.jsonObject(with: Data(document.utf8)) as? NSDictionary
            XCTAssertEqual(actual, supplied, "the web chat receives the selected platform's document")
        }
    }

    func testAHostThatNamesNothingIsLeftAsItIs() throws {
        try RipulTheme.adopt(documentData: Data(loud.utf8))
        RipulTheme.install(bundle: bundle)
        XCTAssertEqual(accent, rgb("#FF00FF"), "a document the host adopted itself stays")
        XCTAssertEqual(RipulTheme.selectedTheme, RipulTheme.systemThemeName)
    }

    func testAMissingDocumentKeepsTheSystemLook() {
        RipulTheme.install(theme: "not-there", bundle: bundle)
        XCTAssertTrue(RipulTheme.isDefault(.accent))
    }

    func testAChoiceIsKeptAcrossLaunches() {
        RipulTheme.install(theme: "brand", bundle: bundle)
        XCTAssertTrue(RipulTheme.select("loud"), "found in the Themes folder")
        XCTAssertEqual(accent, rgb("#FF00FF"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: RipulTheme.choiceKey), "loud")

        // The next launch.
        RipulTheme.resetLibraryForTests()
        RipulTheme.resetToDefaults()
        RipulTheme.install(theme: "brand", bundle: bundle)
        XCTAssertEqual(accent, rgb("#FF00FF"))
        XCTAssertEqual(RipulTheme.selectedTheme, "loud")
    }

    func testAChoiceMadeBeforeTheSDKKeptItIsCarried() {
        // Ripul's own app kept its choice under this key before the SDK did.
        UserDefaults.standard.set("loud", forKey: "ripul.theme.document")
        RipulTheme.install(theme: "brand", bundle: bundle)
        XCTAssertEqual(RipulTheme.selectedTheme, "loud")
    }

    func testAKeptChoiceThatIsGoneFallsBackToTheHostsTheme() {
        UserDefaults.standard.set("deleted-since", forKey: RipulTheme.choiceKey)
        RipulTheme.install(theme: "brand", bundle: bundle)
        XCTAssertEqual(accent, rgb("#112233"))
    }

    func testABuildWithOneThemeReadsNoChoice() {
        UserDefaults.standard.set("loud", forKey: RipulTheme.choiceKey)
        RipulTheme.install(theme: "brand", bundle: bundle, keepsChoice: false)
        XCTAssertEqual(accent, rgb("#112233"))
    }

    func testSelectingWhatIsMissingOrRefusedChangesNothing() {
        RipulTheme.install(theme: "brand", bundle: bundle)
        XCTAssertFalse(RipulTheme.select("not-there"))
        XCTAssertFalse(RipulTheme.select("providers"), "JSON that is not a theme document")
        XCTAssertFalse(RipulTheme.select("newer"), "a document for a newer SDK")
        XCTAssertEqual(accent, rgb("#112233"))
        XCTAssertEqual(RipulTheme.selectedTheme, "brand")
        XCTAssertNil(UserDefaults.standard.string(forKey: RipulTheme.choiceKey))
    }

    func testTheSystemLookIsAChoiceAndNilForgetsIt() {
        RipulTheme.install(theme: "brand", bundle: bundle)
        XCTAssertTrue(RipulTheme.select(RipulTheme.systemThemeName))
        XCTAssertTrue(RipulTheme.isDefault(.accent))
        XCTAssertEqual(RipulTheme.selectedTheme, "system")
        XCTAssertEqual(UserDefaults.standard.string(forKey: RipulTheme.choiceKey), "system")

        XCTAssertTrue(RipulTheme.select(nil))
        XCTAssertEqual(accent, rgb("#112233"))
        XCTAssertNil(UserDefaults.standard.string(forKey: RipulTheme.choiceKey))
    }

    func testAThemeLinkSwitchesInAnyScheme() throws {
        RipulTheme.install(theme: "brand", bundle: bundle)
        XCTAssertTrue(RipulTheme.handleThemeLink(try XCTUnwrap(URL(string: "sandsend://theme?name=loud"))))
        XCTAssertEqual(RipulTheme.selectedTheme, "loud")
        XCTAssertTrue(RipulTheme.handleThemeLink(try XCTUnwrap(URL(string: "ripul://theme?name=system"))))
        XCTAssertTrue(RipulTheme.isDefault(.accent))
        XCTAssertFalse(RipulTheme.handleThemeLink(try XCTUnwrap(URL(string: "sandsend://agents"))))
        XCTAssertFalse(RipulTheme.handleThemeLink(try XCTUnwrap(URL(string: "sandsend://theme"))))
    }

    func testTheBundledThemesAreListedByTheirOwnNames() {
        RipulTheme.install(theme: "brand", bundle: bundle)
        XCTAssertEqual(RipulTheme.bundledThemes.map(\.name), ["brand", "loud", "newer"])
        XCTAssertEqual(RipulTheme.bundledThemes.map(\.title), ["Brand", "Loud", "newer"])
    }

    func testAFontFileOfANamedFamilyIsRegistered() throws {
        // theme/fonts is outside the SDK: not present in a standalone package checkout.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let font = root.appendingPathComponent("theme/fonts/InstrumentSerif-Regular.ttf")
        guard FileManager.default.fileExists(atPath: font.path) else {
            throw XCTSkip("theme/fonts is outside the SDK; not present in a standalone package checkout")
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Fonts"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: font, to: folder.appendingPathComponent("Fonts/InstrumentSerif-Regular.ttf"))
        try ##"{ "schema": 1, "typography": { "families": { "display": "Instrument Serif" } } }"##
            .write(to: folder.appendingPathComponent("serif.json"), atomically: true, encoding: .utf8)

        func family() -> String { CTFontCopyFamilyName(CTFontCreateWithName("InstrumentSerif-Regular" as CFString, 12, nil)) as String }
        XCTAssertNotEqual(family(), "Instrument Serif", "not known to the system before a document names it")
        RipulTheme.install(theme: "brand", bundle: bundle)
        XCTAssertNotEqual(family(), "Instrument Serif", "a document that names no family registers nothing")
        XCTAssertTrue(RipulTheme.select("serif"))
        XCTAssertEqual(family(), "Instrument Serif")
        XCTAssertEqual(RipulTheme.face(.display), "Instrument Serif")
    }
}
