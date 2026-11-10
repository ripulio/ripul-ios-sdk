import XCTest
@testable import RipulAgent

/// The offers grid's benefits, picture and lock, read as the web reads them
/// (offerGrid.ts `offerBenefits`, `offerUnlocked`, `offerFromRow`; the same
/// cases as offerGrid.test.ts).
final class CmsOfferGridSectionsTests: XCTestCase {
    func testBenefitsFromJSONTextAListOrLines() {
        XCTAssertEqual(CmsOfferGridBlockView.benefits(.string("[\"15% off tickets\", \" Free delivery \"]")), ["15% off tickets", "Free delivery"])
        XCTAssertEqual(CmsOfferGridBlockView.benefits(.array([.string("A"), .string(""), .string("B")])), ["A", "B"])
        XCTAssertEqual(CmsOfferGridBlockView.benefits(.string("• One\n- Two\n")), ["One", "Two"])
        XCTAssertEqual(CmsOfferGridBlockView.benefits(.null), [])
        XCTAssertEqual(CmsOfferGridBlockView.benefits(nil), [])
        XCTAssertEqual(CmsOfferGridBlockView.benefits(.string("[not json")), ["[not json"])
    }

    func testPictureIsHttpOnlyAndLockedIsCarried() {
        XCTAssertEqual(CmsOfferGridBlockView.offer(["name": .string("A"), "image_url": .string("https://x.test/a.png")])?.picture?.absoluteString, "https://x.test/a.png")
        XCTAssertNil(CmsOfferGridBlockView.offer(["name": .string("A"), "image_url": .string("data:x")])?.picture)
        XCTAssertEqual(CmsOfferGridBlockView.offer(["name": .string("A")], locked: true)?.locked, true)
        XCTAssertEqual(CmsOfferGridBlockView.offer(["name": .string("A")])?.locked, false)
    }

    func testUnlockOnATrueValueOrAnEqualOne() {
        let unlock: [String: CmsJSON] = ["querySlug": .string("me"), "column": .string("is_subscribed")]
        XCTAssertTrue(CmsOfferGridBlockView.unlocked([["is_subscribed": .bool(true)]], unlock: unlock))
        XCTAssertTrue(CmsOfferGridBlockView.unlocked([["is_subscribed": .string("yes")]], unlock: unlock))
        XCTAssertFalse(CmsOfferGridBlockView.unlocked([["is_subscribed": .bool(false)]], unlock: unlock))
        XCTAssertFalse(CmsOfferGridBlockView.unlocked([], unlock: unlock))
        XCTAssertFalse(CmsOfferGridBlockView.unlocked(nil, unlock: unlock))
        let plan: [String: CmsJSON] = ["querySlug": .string("me"), "column": .string("plan"), "equals": .string("gold")]
        XCTAssertTrue(CmsOfferGridBlockView.unlocked([["plan": .string("gold")]], unlock: plan))
        XCTAssertFalse(CmsOfferGridBlockView.unlocked([["plan": .string("free")]], unlock: plan))
        XCTAssertFalse(CmsOfferGridBlockView.unlocked([["is_subscribed": .bool(true)]], unlock: nil))
    }

    func testTheSearchReadsTheBenefits() throws {
        let offer = try XCTUnwrap(CmsOfferGridBlockView.offer(["name": .string("Iceland"), "benefits": .string("[\"£7 off a £55 shop\"]")]))
        XCTAssertEqual(CmsOfferGridBlockView.filter([offer], query: "£55", category: "").map(\.name), ["Iceland"])
    }
}
