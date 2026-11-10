import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import RipulAgent

/// The nav icon table: every key a site uses draws a symbol that exists.
final class CmsNavIconTests: XCTestCase {
    func testEverySymbolInTheTableExists() {
        #if canImport(AppKit)
        for (key, symbol) in CmsNavIcon.symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(key) → \(symbol)")
        }
        #endif
    }

    /// Every icon name the live sandsend site uses (pages, sidebars, tabs; 3 November 2026).
    func testTheSandsendSitesIconsAllMap() {
        for key in ["business", "calendar", "calendar_month", "contacts", "dashboard", "document", "event", "favorite",
                    "forum", "group", "holiday", "home", "hotel", "info", "institution", "key", "lock", "login",
                    "loyalty", "mail", "map", "menu", "place", "receipt", "sparkles", "store"] {
            XCTAssertNotNil(CmsNavIcon.symbols[key], key)
        }
        XCTAssertEqual(CmsNavIcon.symbol(for: "calendar_month"), "calendar")
        XCTAssertNil(CmsNavIcon.symbol(for: ""))
    }
}
