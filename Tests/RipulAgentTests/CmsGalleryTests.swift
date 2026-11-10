import XCTest
@testable import RipulAgent

/// The `gallery` block's rules, held to the web's GalleryBlock.tsx.
final class CmsGalleryTests: XCTestCase {
    private func props(_ any: [String: Any]) -> [String: CmsJSON] {
        let data = try! JSONSerialization.data(withJSONObject: any)
        return try! JSONDecoder().decode(CmsJSON.self, from: data).objectValue!
    }

    private func items(_ n: Int) -> [[String: Any]] {
        (0..<n).map { ["src": "https://example.com/\($0).jpg"] }
    }

    func testDefaultsAreTheWebs() {
        let g = CmsGallery(props(["items": items(1)]))
        XCTAssertEqual(g.layout, .grid)
        XCTAssertTrue(g.fill)
        XCTAssertEqual(g.gap, 8)
        XCTAssertEqual(g.radius, .number(4))
        XCTAssertEqual(g.maxHeight, 0)
        XCTAssertEqual(g.columns, 3)
    }

    func testItemsWithoutAnAddressAreLeftOut() {
        let g = CmsGallery(props(["items": [["src": ""], ["src": "  "], ["src": "https://a/b.jpg", "alt": "Beach"]]]))
        XCTAssertEqual(g.items.map(\.src), ["https://a/b.jpg"])
        XCTAssertEqual(g.items.first?.alt, "Beach")
    }

    func testVideosByExtension() {
        XCTAssertTrue(CmsGallery.isVideo("https://a/clip.mp4"))
        XCTAssertTrue(CmsGallery.isVideo("https://a/clip.MOV?v=2"))
        XCTAssertTrue(CmsGallery.isVideo("https://a/clip.webm#t=1"))
        XCTAssertFalse(CmsGallery.isVideo("https://a/clip.mp4.jpg"))
        XCTAssertFalse(CmsGallery.isVideo("https://a/photo.jpg"))
        let g = CmsGallery(props(["items": [["src": "https://a/c.mp4"]]]))
        XCTAssertTrue(g.items[0].controls, "controls default on")
        XCTAssertFalse(g.items[0].autoPlay)
    }

    func testGridShapesFollowTheCount() {
        XCTAssertEqual(CmsGallery(props(["items": items(1)])).gridShape, .single)
        XCTAssertEqual(CmsGallery(props(["items": items(2)])).gridShape, .pair)
        XCTAssertEqual(CmsGallery(props(["items": items(3)])).gridShape, .trio)
        XCTAssertEqual(CmsGallery(props(["items": items(9)])).gridShape, .tiles(shown: 9, more: 0))
        // Three rows at most: 3 columns show 9, the last saying +3.
        XCTAssertEqual(CmsGallery(props(["items": items(12)])).gridShape, .tiles(shown: 9, more: 3))
        XCTAssertEqual(CmsGallery(props(["items": items(12), "columns": 2])).gridShape, .tiles(shown: 6, more: 6))
    }

    func testRowShowsThree() {
        XCTAssertEqual(CmsGallery(props(["items": items(5), "layoutMode": "row"])).rowItems.count, 3)
    }

    func testMasonryFillsColumnsInOrder() {
        let g = CmsGallery(props(["items": items(7), "layoutMode": "masonry", "columns": 3]))
        XCTAssertEqual(g.masonryColumns, [[0, 1, 2], [3, 4, 5], [6]])
        XCTAssertEqual(CmsGallery(props(["items": items(2), "layoutMode": "masonry"])).masonryColumns, [[0], [1]])
    }

    func testHeights() {
        let g = CmsGallery(props(["items": items(2), "layoutMode": "carousel"]))
        XCTAssertEqual(g.carouselHeight(width: 400), 300)
        XCTAssertEqual(g.carouselHeight(width: 100), 200, "at least 200")
        XCTAssertEqual(g.carouselHeight(width: 2000), 500, "at most 500")
        XCTAssertEqual(CmsGallery(props(["items": items(2), "maxHeight": 240])).carouselHeight(width: 400), 240)
        // The shown picture's own shape: a 3:2 photo at 400 wide is 266.67 tall; at 294 it holds 200.
        XCTAssertEqual(g.carouselHeight(width: 400, aspect: 2.0 / 3.0), 266.67, accuracy: 0.01)
        XCTAssertEqual(g.carouselHeight(width: 294, aspect: 2.0 / 3.0), 200)
        XCTAssertEqual(g.rowHeight, 300)
        XCTAssertEqual(g.trioHeight, 400)
    }

    func testColumnsAndFit() {
        XCTAssertEqual(CmsGallery(props(["items": items(1), "columns": 9])).columns, 6)
        XCTAssertEqual(CmsGallery(props(["items": items(1), "columns": 0])).columns, 1)
        XCTAssertFalse(CmsGallery(props(["items": items(1), "objectFit": "contain"])).fill)
        XCTAssertEqual(CmsGallery(props(["items": items(1), "itemRadius": "radius.card"])).radius, .string("radius.card"))
    }
}
