import XCTest
@testable import RipulAgent

/// Pictures from image sources in more blocks (plan cms-image-sources-woven-in):
/// a link list row's `image.chain` and the offers grid's `logoImage.chain`,
/// read as the web reads them (offerGrid.ts `offerLogoCandidates`).
final class CmsImageChainBlocksTests: XCTestCase {
    private func json(_ text: String) throws -> CmsJSON {
        try JSONDecoder().decode(CmsJSON.self, from: Data(text.utf8))
    }

    // MARK: Link list rows

    func testNavItemReadsItsImageChainFromItsOwnFields() throws {
        let item = try XCTUnwrap(CmsNavItem.decode(try json("""
        {"label": "KFC", "icon": "store", "targetPageSlug": "kfc", "logoUrl": "https://img.example/kfc.png",
         "image": {"chain": [{"source": "logos", "column": "label"}, {"column": "logoUrl"}]}}
        """)))
        XCTAssertEqual(item.imageChain, [
            .init(column: "label", source: "logos"),
            .init(column: "logoUrl", source: nil),
        ])
        XCTAssertEqual(item.pictureCandidates, [
            .source("logos", value: "KFC"),
            .url("https://img.example/kfc.png"),
        ], "the source asked by the label, then an https address from the item's field")
    }

    func testNavItemWithoutAChainKeepsItsIcon() throws {
        let item = try XCTUnwrap(CmsNavItem.decode(try json(#"{"label": "Home", "icon": "home", "targetPageSlug": "home"}"#)))
        XCTAssertTrue(item.imageChain.isEmpty)
        XCTAssertTrue(item.pictureCandidates.isEmpty, "no chain: the row draws its icon as before")
    }

    func testNavItemChainSkipsEmptyAndNonHttpsValues() throws {
        let item = try XCTUnwrap(CmsNavItem.decode(try json("""
        {"label": "", "logoUrl": "http://plain.example/x.png",
         "image": {"chain": [{"source": "logos", "column": "label"}, {"column": "logoUrl"}, {"column": "missing"}]}}
        """)))
        XCTAssertEqual(item.pictureCandidates, [], "an empty label, a plain-http address and a missing field offer nothing")
    }

    // MARK: Offers grid

    func testOfferLogoTriesTheChainThenLogoUrl() throws {
        let row: [String: CmsJSON] = [
            "name": .string("Pizza Hut"),
            "logo_url": .string("https://cdn.example/ph.png"),
            "brand_logo": .string("https://cdn.example/ph.png"),
        ]
        let offer = try XCTUnwrap(CmsOfferGridBlockView.offer(row))
        XCTAssertEqual(offer.row, row)

        let chain = CmsCalendarDecorations.imageChain(try json(#"[{"source": "logos", "column": "name"}]"#))
        XCTAssertEqual(CmsOfferGridBlockView.logoCandidates(offer, chain: chain), [
            .source("logos", value: "Pizza Hut"),
            .url("https://cdn.example/ph.png"),
        ], "the image source by name first, logo_url as the fallback")

        let sameUrl = CmsCalendarDecorations.imageChain(try json(#"[{"column": "brand_logo"}]"#))
        XCTAssertEqual(CmsOfferGridBlockView.logoCandidates(offer, chain: sameUrl), [.url("https://cdn.example/ph.png")],
                       "logo_url isn't tried twice")
    }

    func testOfferWithoutAChainUsesLogoUrlAlone() throws {
        let offer = try XCTUnwrap(CmsOfferGridBlockView.offer(["name": .string("Tesco"), "logo_url": .string("https://cdn.example/t.png")]))
        XCTAssertEqual(CmsOfferGridBlockView.logoCandidates(offer, chain: []), [.url("https://cdn.example/t.png")])
        let bare = try XCTUnwrap(CmsOfferGridBlockView.offer(["name": .string("Aldi")]))
        XCTAssertEqual(CmsOfferGridBlockView.logoCandidates(bare, chain: []), [], "no logo: the initials show")
    }
}
