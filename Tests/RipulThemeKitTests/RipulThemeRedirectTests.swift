import XCTest
import SwiftUI
@testable import RipulThemeKit

/// The redirect a host's unedited source goes through (the `RipulThemeRedirect` plug-in):
/// with no theme every function returns the value SwiftUI's own would have, itself, and a
/// document changes it.
final class RipulThemeRedirectTests: XCTestCase {
    override func setUp() { RipulTheme.resetToDefaults() }
    override func tearDown() { RipulTheme.resetToDefaults() }

    private func adopt(_ json: String) throws { try RipulTheme.adopt(documentData: Data(json.utf8)) }

    private let styles: [(Font.TextStyle, Font)] = [
        (.largeTitle, .largeTitle), (.title, .title), (.title2, .title2), (.title3, .title3),
        (.headline, .headline), (.body, .body), (.callout, .callout), (.subheadline, .subheadline),
        (.footnote, .footnote), (.caption, .caption), (.caption2, .caption2),
    ]

    func testWithNoThemeEveryTextStyleIsSwiftUIsOwn() {
        for (style, system) in styles {
            XCTAssertEqual(RipulThemeRedirect.font(style), system, "\(style)")
            XCTAssertEqual(RipulThemeRedirect.weight(RipulThemeRedirect.font(style), .semibold), system.weight(.semibold), "\(style)")
        }
    }

    func testWithNoThemeEverySystemFontIsTheCallSitesOwnValue() {
        for design in [nil, Font.Design.default, .serif, .rounded, .monospaced] as [Font.Design?] {
            for weight in [nil, Font.Weight.semibold] as [Font.Weight?] {
                XCTAssertEqual(RipulThemeRedirect.systemFont(size: 22, weight: weight, design: design),
                               Font.system(size: 22, weight: weight, design: design))
                XCTAssertEqual(RipulThemeRedirect.systemFont(.title2, design: design, weight: weight),
                               Font.system(.title2, design: design, weight: weight))
            }
        }
    }

    func testWithNoThemeTheNamedColoursAreSwiftUIsOwn() {
        XCTAssertEqual(RipulThemeRedirect.color(.danger), Color.red)
        XCTAssertEqual(RipulThemeRedirect.color(.warning), Color.orange)
        XCTAssertEqual(RipulThemeRedirect.color(.success), Color.green)
        XCTAssertEqual(RipulThemeRedirect.color(.info), Color.blue)
        XCTAssertEqual(RipulThemeRedirect.color(.neutral), Color.gray)
        XCTAssertEqual(RipulThemeRedirect.color(.text), Color.primary)
        XCTAssertEqual(RipulThemeRedirect.color(.textSecondary), Color.secondary)
    }

    #if canImport(UIKit)
    func testWithNoThemeAWrappedSystemColourIsItself() {
        for colour in [UIColor.systemBackground, .systemGroupedBackground, .secondarySystemGroupedBackground, .label, .separator, .systemGray5] {
            XCTAssertEqual(RipulThemeRedirect.color(colour), Color(uiColor: colour))
        }
    }

    func testAThemedSurfaceReachesAWrappedSystemColour() throws {
        try adopt(##"{"schema":1,"roles":{"ripul.surfaceSunken":"#f7f3ec"}}"##)
        XCTAssertEqual(RipulThemeRedirect.color(.systemGroupedBackground), Color.ripul(.surfaceSunken))
        XCTAssertNotEqual(RipulThemeRedirect.color(.systemGroupedBackground), Color(uiColor: .systemGroupedBackground))
        // A role the document does not name, and a colour that is no role's default.
        XCTAssertEqual(RipulThemeRedirect.color(.systemBackground), Color(uiColor: .systemBackground))
        XCTAssertEqual(RipulThemeRedirect.color(.systemGray5), Color(uiColor: .systemGray5))
    }
    #endif

    func testAThemedFamilyReachesTextStylesAndFixedSizes() throws {
        try adopt(#"{"schema":1,"typography":{"families":{"text":"Georgia"}}}"#)
        XCTAssertEqual(RipulThemeRedirect.font(.body), Font.ripul(.body))
        XCTAssertNotEqual(RipulThemeRedirect.font(.body), Font.body)
        XCTAssertEqual(RipulThemeRedirect.systemFont(size: 14, weight: .medium, design: nil), Font.ripul(size: 14, weight: .medium))
        XCTAssertEqual(RipulThemeRedirect.systemFont(.title, design: nil, weight: .bold), Font.ripul(.title, weight: .bold))
        // No display family named: a serif stays the system's serif, and rounded is never touched.
        XCTAssertEqual(RipulThemeRedirect.systemFont(.title, design: .serif, weight: .bold), Font.system(.title, design: .serif, weight: .bold))
        XCTAssertEqual(RipulThemeRedirect.systemFont(size: 12, weight: nil, design: .rounded), Font.system(size: 12, weight: nil, design: .rounded))
    }

    func testASerifIsTheDisplayFamilyOnceAThemeNamesOne() throws {
        try adopt(#"{"schema":1,"typography":{"families":{"display":"Georgia"}}}"#)
        XCTAssertEqual(RipulThemeRedirect.systemFont(.title, design: .serif, weight: .semibold),
                       Font.ripul(.title, weight: .semibold, family: .display))
        XCTAssertEqual(RipulThemeRedirect.systemFont(size: 22, weight: .medium, design: .serif),
                       Font.ripul(size: 22, weight: .medium, family: .display))
        // The text family is not named, so plain text styles are still SwiftUI's own.
        XCTAssertEqual(RipulThemeRedirect.font(.body), Font.body)
    }
}

// MARK: - Text with no colour of its own

final class RipulThemeRedirectTextTests: XCTestCase {
    override func tearDown() {
        RipulTheme.resetToDefaults()
        super.tearDown()
    }

    func testWithNoThemeATextIsItselfAndTheTableIsNotRead() {
        var asked = false
        XCTAssertEqual(RipulThemeRedirect.text("Hello") { asked = true; return true }, Text("Hello"))
        XCTAssertEqual(RipulThemeRedirect.text(verbatim: "Hello") { asked = true; return true }, Text(verbatim: "Hello"))
        XCTAssertFalse(asked)
    }

    func testUnderAThemedTextColourOnlyABareTextTakesIt() throws {
        try RipulTheme.adopt(documentData: Data(##"{"roles":{"text":"#1C2540"}}"##.utf8))
        XCTAssertEqual(RipulThemeRedirect.text("Hello") { false }, Text("Hello"))
        XCTAssertNotEqual(RipulThemeRedirect.text("Hello") { true }, Text("Hello"))
        XCTAssertNotEqual(RipulThemeRedirect.text(verbatim: "Hello") { true }, Text(verbatim: "Hello"))
    }

    func testAThemeThatNamesNoTextColourLeavesTextAlone() throws {
        try RipulTheme.adopt(documentData: Data(##"{"roles":{"accent":"#24386B"}}"##.utf8))
        XCTAssertEqual(RipulThemeRedirect.text("Hello") { true }, Text("Hello"))
    }
}
