import XCTest
import SwiftUI
@testable import RipulThemeKit

/// The base theme: the proof that the default theme is today's look exactly (each
/// accessor IS the system value it replaces), and that a document changes it.
final class RipulThemeCoreTests: XCTestCase {
    override func setUp() { RipulTheme.resetToDefaults() }
    override func tearDown() { RipulTheme.resetToDefaults() }

    private func adopt(_ json: String) throws { try RipulTheme.adopt(documentData: Data(json.utf8)) }

    // MARK: decision 1: with no theme, every accessor is the system value

    func testEveryTextStyleRoleIsTheSystemTextStyle() {
        let pairs: [(RipulTextRole, Font)] = [
            (.largeTitle, .largeTitle), (.title, .title), (.title2, .title2), (.title3, .title3),
            (.headline, .headline), (.body, .body), (.callout, .callout), (.subheadline, .subheadline),
            (.footnote, .footnote), (.caption, .caption), (.caption2, .caption2),
        ]
        for (role, system) in pairs {
            XCTAssertEqual(Font.ripul(role), system, "\(role)")
            XCTAssertEqual(Font.ripul(role, weight: .semibold), system.weight(.semibold), "\(role) semibold")
            XCTAssertEqual(Font.ripul(role).monospacedDigit(), system.monospacedDigit(), "\(role) chained")
            XCTAssertEqual(Font.ripul(role).bold(), system.bold(), "\(role) bold")
            XCTAssertEqual(Font.ripulIcon(role.textStyle), system, "\(role) icon")
        }
    }

    func testTheThreeNamedRolesAreTheirSystemEquivalents() {
        XCTAssertEqual(Font.ripul(.display), Font.title)
        XCTAssertEqual(Font.ripul(.eyebrow), Font.subheadline.weight(.semibold))
        XCTAssertEqual(Font.ripul(.code), Font.system(.body, design: .monospaced))
    }

    func testCodeFamilyIsTheSystemMonospacedDesign() {
        XCTAssertEqual(Font.ripul(.caption, family: .code), Font.system(.caption, design: .monospaced))
        XCTAssertEqual(Font.ripul(.caption, weight: .medium, family: .code),
                       Font.system(.caption, design: .monospaced).weight(.medium))
        XCTAssertEqual(Font.ripul(size: 12, family: .code), Font.system(size: 12, design: .monospaced))
        XCTAssertEqual(Font.ripul(size: 12, weight: .semibold, family: .code),
                       Font.system(size: 12, weight: .semibold, design: .monospaced))
    }

    func testFixedSizesAndIconsAreSystemFonts() {
        XCTAssertEqual(Font.ripul(size: 14), Font.system(size: 14))
        XCTAssertEqual(Font.ripul(size: 14, weight: .medium), Font.system(size: 14, weight: .medium))
        XCTAssertEqual(Font.ripulIcon(size: 18), Font.system(size: 18))
        XCTAssertEqual(Font.ripulIcon(size: 18, weight: .bold), Font.system(size: 18, weight: .bold))
    }

    func testColourRolesAreSwiftUIsOwnColours() {
        XCTAssertEqual(Color.ripul(.accent), Color.accentColor)
        XCTAssertEqual(Color.ripul(.text), Color.primary)
        XCTAssertEqual(Color.ripul(.textSecondary), Color.secondary)
        XCTAssertEqual(Color.ripul(.success), Color.green)
        XCTAssertEqual(Color.ripul(.warning), Color.orange)
        XCTAssertEqual(Color.ripul(.danger), Color.red)
        XCTAssertEqual(Color.ripul(.info), Color.blue)
        XCTAssertEqual(Color.ripul(.neutral), Color.gray)
        XCTAssertEqual(Color.ripul(.onAccent), Color(RipulPlatformColor(red: 1, green: 1, blue: 1, alpha: 1)))
    }

    func testTheRootAppliesNothingWithNoTheme() {
        XCTAssertNil(RipulTheme.accentOverride)
        XCTAssertNil(RipulTheme.defaultFontOverride)
        for role in RipulColorRole.allCases { XCTAssertTrue(RipulTheme.isDefault(role), "\(role)") }
    }

    func testEveryDefaultReferenceParses() {
        for role in RipulColorRole.allCases {
            XCTAssertNotNil(RipulColorLiteral(role.defaultReference), "\(role)")
            XCTAssertTrue(RipulTheme.isBaseRole(role.tokenName))
        }
    }

    // MARK: the repository's document

    /// Ripul's own document is paper and navy: the brand's accent and families, the
    /// website's grounds, surfaces, separator and ink, and a faint ink one step stronger
    /// than the website's. The roles it does not name stay the system's.
    func testTheRepositoryDocumentIsPaperAndNavy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("theme/ripul-theme.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("theme/ripul-theme.json is outside the SDK; not present in a standalone package checkout")
        }
        try RipulTheme.adopt(documentData: Data(contentsOf: url))
        func pair(_ light: String, _ dark: String) -> RipulColorValue {
            RipulColorValue(light: RipulColorLiteral(light)!, dark: RipulColorLiteral(dark))
        }
        let named: [RipulColorRole: RipulColorValue] = [
            .accent: pair("#1f6f70", "#62b9b4"), .onAccent: pair("#FFFFFF", "#23253a"),
            .canvas: pair("#f8f4ec", "#1b1d2e"), .surfaceSunken: pair("#f8f4ec", "#1b1d2e"),
            .surface: pair("#fffdf9", "#262940"), .text: pair("#23253a", "#f8f4ec"),
            .textSecondary: pair("#5b5e73", "#f8f4ecbd"), .textTertiary: pair("#686a80", "#f8f4eca6"),
            .separator: pair("#23253a1f", "#f8f4ec24"),
        ]
        for role in RipulColorRole.allCases {
            if let value = named[role] {
                XCTAssertEqual(RipulTheme.color(role), value, "\(role)")
            } else {
                XCTAssertTrue(RipulTheme.isDefault(role), "\(role)")
            }
        }
        XCTAssertEqual(RipulTheme.face(.text), "Archivo")
        XCTAssertEqual(RipulTheme.face(.display), "Instrument Serif")
    }

    /// The trial brand document sets the accent, what sits on it and two families, and
    /// leaves the canvas, the surfaces and every text colour the system's.
    func testTheBrandDocumentSetsTheAccentAndFamiliesOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("theme/ripul-theme-brand.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("theme/ripul-theme-brand.json is outside the SDK; not present in a standalone package checkout")
        }
        try RipulTheme.adopt(documentData: Data(contentsOf: url))
        XCTAssertEqual(RipulTheme.color(.accent), RipulColorValue(light: RipulColorLiteral("#1f6f70")!, dark: RipulColorLiteral("#62b9b4")))
        XCTAssertEqual(RipulTheme.color(.onAccent), RipulColorValue(light: RipulColorLiteral("#FFFFFF")!, dark: RipulColorLiteral("#23253a")))
        for role in RipulColorRole.allCases where role != .accent && role != .onAccent {
            XCTAssertTrue(RipulTheme.isDefault(role), "\(role)")
        }
        XCTAssertEqual(RipulTheme.face(.text), "Archivo")
        XCTAssertEqual(RipulTheme.face(.display), "Instrument Serif")
        XCTAssertEqual(RipulTheme.face(.code), "system-monospaced")
        XCTAssertEqual(RipulTheme.text(.headline).face, "Archivo")
        XCTAssertNil(RipulTheme.text(.body).size)
        // The serif has one weight, so the display role carries by size where a bold title did.
        XCTAssertEqual(RipulTheme.text(.display).size, 36)
        let eyebrow = RipulTheme.text(.eyebrow)
        XCTAssertEqual(eyebrow.tracking, 1.8)
        XCTAssertTrue(eyebrow.uppercase)
    }

    // MARK: a document changes it

    func testALightAndDarkPairInThePaletteReachesARole() throws {
        try adopt(##"{"palette":{"teal":{"light":"#1f6f70","dark":"#62b9b4"},"ink":"1b2a41"},"roles":{"ripul.accent":"teal","ripul.text":"ink"}}"##)
        let accent = RipulTheme.color(.accent)
        XCTAssertEqual(accent.light, RipulColorLiteral("#1f6f70"))
        XCTAssertEqual(accent.dark, RipulColorLiteral("#62b9b4"))
        XCTAssertFalse(RipulTheme.isDefault(.accent))
        XCTAssertNotNil(RipulTheme.accentOverride)
        XCTAssertEqual(RipulTheme.color(.text), RipulColorValue(light: RipulColorLiteral("#1b2a41")!))
        XCTAssertTrue(RipulTheme.isDefault(.canvas))
    }

    func testALightAndDarkPairIsOneColourObjectEveryTimeItIsAskedFor() throws {
        // A body that asks again must get an equal colour. Two dynamic colours made from the
        // same pair are not equal, so SwiftUI saw a change of colour on every body and
        // animated the text separately from its row (the sidebar, 23 October 2026).
        try adopt(##"{"palette":{"ink":{"light":"#23253a","dark":"#f8f4ec"}},"roles":{"ripul.text":"ink"}}"##)
        let value = RipulTheme.color(.text)
        XCTAssertNotNil(value.dark)
        XCTAssertTrue(RipulTheme.platformColor(value) === RipulTheme.platformColor(value))
        XCTAssertEqual(Color.ripul(.text), Color.ripul(.text))
    }

    func testARoleMayPointAtAnotherRoleASystemColourOrALiteral() throws {
        try adopt(##"{"roles":{"ripul.info":"ripul.accent","ripul.accent":"system:systemPink","ripul.danger":"#FF000080"}}"##)
        XCTAssertEqual(RipulTheme.color(.info).systemName, "systemPink")
        XCTAssertEqual(Color.ripul(.info), Color.pink)
        XCTAssertEqual(RipulTheme.color(.danger).light, .rgba(red: 1, green: 0, blue: 0, alpha: 128.0 / 255))
    }

    func testACycleOrANonsenseReferenceFallsBackToTheDefault() throws {
        try adopt(##"{"roles":{"ripul.accent":"ripul.info","ripul.info":"ripul.accent","ripul.text":"no such thing","ripul.canvas":"system:notAColour"}}"##)
        XCTAssertTrue(RipulTheme.isDefault(.accent))
        XCTAssertTrue(RipulTheme.isDefault(.text))
        XCTAssertTrue(RipulTheme.isDefault(.canvas))
    }

    func testInAHostsDocumentOnlyTheReservedKeyIsRead() throws {
        // WAC's shape: its own palette, roles and fonts at the top level. None of it is ours.
        try adopt(##"{"colors":{"accent":"12CEA8"},"semantic":{"accent":"accent","ripul.accent":"accent"},"fonts":{"family":"AvenirNext"}}"##)
        XCTAssertTrue(RipulTheme.isDefault(.accent), "a host's own maps are never read")
        XCTAssertEqual(Font.ripul(.body), Font.body)
        // The same document with the SDK's part under the reserved key.
        try adopt(##"{"colors":{"accent":"12CEA8"},"semantic":{"accent":"accent"},"fonts":{"family":"AvenirNext"},"ripul":{"palette":{"teal":{"light":"#1f6f70","dark":"#62b9b4"}},"roles":{"accent":"teal","ripul.danger":"#FF0000"},"typography":{"families":{"display":"system-serif"}}}}"##)
        XCTAssertEqual(RipulTheme.color(.accent).dark, RipulColorLiteral("#62b9b4"))
        XCTAssertEqual(RipulTheme.color(.danger).light, RipulColorLiteral("#FF0000"), "a role may be written with or without the prefix")
        XCTAssertEqual(Font.ripul(.display), Font.system(.title, design: .serif))
        XCTAssertEqual(Font.ripul(.body), Font.body)
    }

    func testANewerSchemaIsRefusedAndTheLastGoodThemeStays() throws {
        try adopt(##"{"schema":1,"roles":{"ripul.accent":"#FF00FF"}}"##)
        XCTAssertThrowsError(try adopt(##"{"schema":2,"roles":{"ripul.accent":"#00FF00"}}"##)) {
            XCTAssertEqual($0 as? RipulTheme.DocumentError, .newerSchema(2))
        }
        XCTAssertThrowsError(try adopt(##"{"ripul":{"schema":7}}"##))
        XCTAssertEqual(RipulTheme.color(.accent).light, RipulColorLiteral("#FF00FF"))
    }

    func testAnAccessorMayBeCalledOffTheMainThreadWhileADocumentIsAdopted() throws {
        let done = expectation(description: "readers")
        done.expectedFulfillmentCount = 4
        for _ in 0..<4 {
            DispatchQueue.global().async {
                for _ in 0..<2_000 { _ = RipulTheme.color(.accent); _ = RipulTheme.text(.body); _ = Font.ripul(.caption) }
                done.fulfill()
            }
        }
        for index in 0..<200 {
            try adopt(index.isMultiple(of: 2) ? ##"{"roles":{"ripul.accent":"#FF00FF"}}"## : ##"{"typography":{"families":{"text":"Georgia"}}}"##)
        }
        wait(for: [done], timeout: 20)
    }

    func testFamiliesAndTypeRoles() throws {
        try adopt(##"{"typography":{"families":{"text":"Georgia","display":"system-serif"},"roles":{"eyebrow":{"size":11,"weight":"bold","tracking":1.2,"uppercase":true},"caption":{"family":"code"}}}}"##)
        XCTAssertEqual(Font.ripul(.body), Font.custom("Georgia", size: 17, relativeTo: .body))
        XCTAssertEqual(Font.ripul(.body, weight: .semibold), Font.custom("Georgia", size: 17, relativeTo: .body).weight(.semibold))
        XCTAssertEqual(Font.ripul(.display), Font.system(.title, design: .serif))
        XCTAssertEqual(Font.ripul(.headline), Font.custom("Georgia", size: 17, relativeTo: .headline).weight(.semibold),
                       "a custom face is given the semibold the system's headline carries")
        XCTAssertEqual(Font.ripul(.headline, weight: .light), Font.custom("Georgia", size: 17, relativeTo: .headline).weight(.light))
        XCTAssertEqual(Font.ripul(.eyebrow), Font.custom("Georgia", size: 11, relativeTo: .subheadline).weight(.bold))
        XCTAssertEqual(Font.ripul(.caption), Font.system(.caption, design: .monospaced))
        XCTAssertEqual(Font.ripul(size: 14, weight: .medium), Font.custom("Georgia", fixedSize: 14).weight(.medium))
        XCTAssertEqual(Font.ripul(size: 12, family: .code), Font.system(size: 12, design: .monospaced), "code family untouched")
        XCTAssertEqual(Font.ripulIcon(size: 18), Font.system(size: 18), "icons are never themed")
        let eyebrow = RipulTheme.text(.eyebrow)
        XCTAssertEqual(eyebrow.tracking, 1.2)
        XCTAssertTrue(eyebrow.uppercase)
        XCTAssertNotNil(RipulTheme.defaultFontOverride)
    }

    func testAdoptingPostsTheThemeChange() throws {
        let posted = expectation(forNotification: .ripulThemeDidChange, object: nil)
        let before = RipulTheme.version
        try adopt(##"{"roles":{"ripul.accent":"#FF00FF"}}"##)
        wait(for: [posted], timeout: 1)
        XCTAssertGreaterThan(RipulTheme.version, before)
    }

    // MARK: live repaint
    //
    // SwiftUI runs a body again when something the body read through Observation changes.
    // `withObservationTracking` is that same mechanism, so these fail if an accessor stops
    // reading the theme store when it is CALLED (for instance if the read moved back into a
    // style's `resolve`, which runs at draw time, outside any body).

    private func assertTracked(_ what: String, _ read: () -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        var invalidated = false
        withObservationTracking(read) { invalidated = true }
        XCTAssertFalse(invalidated, what, file: file, line: line)
        try adopt(##"{"roles":{"ripul.danger":"#00FF00"},"typography":{"families":{"text":"Georgia"}}}"##)
        XCTAssertTrue(invalidated, "\(what) did not register with the theme store, so a view using it would not repaint", file: file, line: line)
        RipulTheme.resetToDefaults()
    }

    func testEveryAccessorRegistersTheBodyThatCalledIt() throws {
        try assertTracked("Font.ripul(role)") { _ = Font.ripul(.body) }
        try assertTracked("Font.ripul(role, weight:)") { _ = Font.ripul(.caption, weight: .semibold) }
        try assertTracked("Font.ripul(size:)") { _ = Font.ripul(size: 13) }
        try assertTracked("Color.ripul(role)") { _ = Color.ripul(.danger) }
        try assertTracked("the style form") { _ = RipulColorStyle.ripul(.danger) }
        try assertTracked("ripulThemeRoot's overrides") { _ = RipulTheme.accentOverride; _ = RipulTheme.defaultFontOverride }
    }

    func testAStyleCarriesTheColourItHadWhenItWasMade() throws {
        // SwiftUI resolves a style again only when the style's own value changes, so the
        // value must differ after a theme change. A style that held only the role's name
        // kept its old colour on screen (measured, 10 October 2026).
        let before = RipulColorStyle.ripul(.danger)
        try adopt(##"{"roles":{"ripul.danger":"#00FF00"}}"##)
        let after = RipulColorStyle.ripul(.danger)
        XCTAssertEqual(before.role, after.role)
        XCTAssertNotEqual(before.value, after.value)
        XCTAssertEqual(after.value.light, RipulColorLiteral("#00FF00"))
    }

    func testTheAdoptedDocumentIsTheSDKsPartOnlyAndFollowsAdoptAndReset() throws {
        XCTAssertNil(RipulTheme.adoptedDocumentData)
        // Ripul's own file: the whole document, keys sorted.
        try adopt(##"{"roles":{"ripul.accent":"#FF00FF"},"name":"x"}"##)
        XCTAssertEqual(RipulTheme.adoptedDocumentData.flatMap { String(data: $0, encoding: .utf8) },
                       ##"{"name":"x","roles":{"ripul.accent":"#FF00FF"}}"##)
        // A host's document: only what is under the reserved key travels.
        try adopt(##"{"colors":{"secret":"12CEA8"},"ripul":{"roles":{"accent":"#00FF00"}}}"##)
        let part = try XCTUnwrap(RipulTheme.adoptedDocumentData.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(part, ##"{"roles":{"accent":"#00FF00"}}"##)
        // The same document written in another key order gives the same bytes.
        try adopt(##"{"ripul":{"roles":{"accent":"#00FF00"}},"colors":{"secret":"12CEA8"}}"##)
        XCTAssertEqual(RipulTheme.adoptedDocumentData.flatMap { String(data: $0, encoding: .utf8) }, part)
        // A refused document leaves it as it was.
        XCTAssertThrowsError(try adopt(##"{"schema":9}"##))
        XCTAssertEqual(RipulTheme.adoptedDocumentData.flatMap { String(data: $0, encoding: .utf8) }, part)
        RipulTheme.resetToDefaults()
        XCTAssertNil(RipulTheme.adoptedDocumentData)
    }

    func testADocumentThatIsNotAnObjectIsRefusedAndChangesNothing() {
        XCTAssertThrowsError(try adopt("[1,2]"))
        XCTAssertTrue(RipulTheme.isDefault(.accent))
    }
}


// MARK: - A host's own roles

final class RipulHostRoleTests: XCTestCase {
    override func tearDown() {
        RipulTheme.resetToDefaults()
        super.tearDown()
    }

    func testTheFifteenAreUnchangedByTheOpenType() {
        XCTAssertEqual(RipulColorRole.allCases.count, 15)
        XCTAssertEqual(RipulColorRole.allCases.map(\.rawValue).prefix(3), ["accent", "onAccent", "canvas"])
        XCTAssertEqual(RipulColorRole.accent.tokenName, "ripul.accent")
        XCTAssertEqual(RipulColorRole.text.defaultReference, "system:label")
        XCTAssertEqual(RipulColorRole(rawValue: "surface"), .surface)
        XCTAssertTrue(RipulColorRole.allCases.allSatisfy { RipulTheme.isDefault($0) && $0.isBase })
    }

    func testAHostRoleIsItsDefaultUntilADocumentNamesIt() throws {
        let cream = RipulColorRole("test.cream", default: "#F4EBDD", dark: "#2A2418")
        XCTAssertFalse(cream.isBase)
        XCTAssertEqual(cream.tokenName, "test.cream")
        XCTAssertTrue(RipulTheme.isDefault(cream))
        XCTAssertEqual(RipulTheme.color(cream), RipulColorValue(light: RipulColorLiteral("#F4EBDD")!, dark: RipulColorLiteral("#2A2418")))
        XCTAssertEqual(RipulColorRole(rawValue: "test.cream"), cream)

        try RipulTheme.adopt(documentData: Data(##"{"palette":{"sand":{"light":"#112233","dark":"#445566"}},"roles":{"test.cream":"sand"}}"##.utf8))
        XCTAssertFalse(RipulTheme.isDefault(cream))
        XCTAssertEqual(RipulTheme.color(cream), RipulColorValue(light: RipulColorLiteral("#112233")!, dark: RipulColorLiteral("#445566")))
        // The fifteen are untouched by a document that names only the host's role.
        XCTAssertTrue(RipulColorRole.allCases.allSatisfy { RipulTheme.isDefault($0) })

        RipulTheme.resetToDefaults()
        XCTAssertTrue(RipulTheme.isDefault(cream))
    }

    func testAHostRoleDeclaredAfterTheDocumentWasAdoptedStillTakesIt() throws {
        try RipulTheme.adopt(documentData: Data(##"{"roles":{"test.late":"#ABCDEF"}}"##.utf8))
        let late = RipulColorRole("test.late", default: "#000000")
        XCTAssertEqual(RipulTheme.color(late), RipulColorValue(light: RipulColorLiteral("#ABCDEF")!))
        XCTAssertFalse(RipulTheme.isDefault(late))
    }

    func testAnAssetRoleIsNamedForItsAssetAndDefaultsToIt() {
        let navy = RipulColorRole(asset: "TestBrandNavy")
        XCTAssertEqual(navy.rawValue, "TestBrandNavy")
        XCTAssertEqual(RipulTheme.color(navy).assetName, "TestBrandNavy")
        XCTAssertEqual(navy.defaultReference, "asset:TestBrandNavy")
        XCTAssertEqual(Color.ripul(navy), Color("TestBrandNavy")) // theme-mapping: a test of the accessor itself
    }

    func testARoleMayPointAtAHostRoleAndABaseRole() throws {
        let brand = RipulColorRole("test.brand", default: "#010203")
        try RipulTheme.adopt(documentData: Data(##"{"roles":{"accent":"test.brand","test.brand":"#0A0B0C","test.other":"ripul.accent"}}"##.utf8))
        XCTAssertEqual(RipulTheme.color(.accent), RipulColorValue(light: RipulColorLiteral("#0A0B0C")!))
        XCTAssertEqual(RipulTheme.color(RipulColorRole("test.other", default: "#FFFFFF")), RipulTheme.color(brand))
    }

    func testARolesValueMayBeAPairWrittenInPlace() throws {
        let navy = RipulColorRole("test.pair", default: "#000000")
        try RipulTheme.adopt(documentData: Data(##"{"roles":{"test.pair":{"light":"#24386B","dark":"#5B78C4"},"ripul.separator":{"light":"#010101"}}}"##.utf8))
        XCTAssertEqual(RipulTheme.color(navy), RipulColorValue(light: RipulColorLiteral("#24386B")!, dark: RipulColorLiteral("#5B78C4")))
        XCTAssertEqual(RipulTheme.color(.separator), RipulColorValue(light: RipulColorLiteral("#010101")!))
    }

    func testAHostRoleCannotTakeOneOfTheFifteensNames() {
        _ = RipulColorRole("accent", default: "#FF0000")
        XCTAssertTrue(RipulColorRole(rawValue: "accent")!.isBase)
        XCTAssertEqual(RipulTheme.color(.accent).systemName, "tint")
    }

    func testTheRedirectLeavesAnAssetColourAloneUntilADocumentNamesIt() throws {
        XCTAssertEqual(RipulThemeRedirect.color(named: "TestRedirectNavy", bundle: nil), Color("TestRedirectNavy"))
        try RipulTheme.adopt(documentData: Data(##"{"roles":{"TestRedirectNavy":"#123456"}}"##.utf8))
        XCTAssertNotEqual(RipulThemeRedirect.color(named: "TestRedirectNavy", bundle: nil), Color("TestRedirectNavy"))
        XCTAssertEqual(RipulThemeRedirect.color(named: "TestRedirectNavy", bundle: nil), Color.ripul(RipulColorRole(asset: "TestRedirectNavy"))) // theme-mapping: a test of the accessor itself
    }
}
