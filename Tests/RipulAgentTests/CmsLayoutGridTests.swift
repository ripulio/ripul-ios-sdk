import XCTest
@testable import RipulAgent

final class CmsLayoutGridTests: XCTestCase {
    private let fixture = """
    {"layout":"list","items":[{"id":"layout","slug":"layout","type":"fieldGrid","props":{
      "bindQuerySlug":"","layoutMode":"grid","gridLayout":{"cols":3,"rows":1,
        "placements":{"__slot:left":{"row":1,"col":1,"colSpan":2}},
        "slots":{"left":{"layout":"list","items":[{"id":"child","slug":"child","type":"text",
          "props":{"content":"Static content"},"bindings":{"content":{"querySlug":"independent","column":"name"}}}]}}
      }}}
    ]}
    """

    func testUnboundGridIncludesNestedBlocksAndTheirOwnBindings() throws {
        let container = try JSONDecoder().decode(CmsPageBlocks.self, from: Data(fixture.utf8))
        let blocks = container.allBlocks()
        XCTAssertEqual(blocks.map(\.id), ["layout", "child"])
        XCTAssertEqual(blocks[1].bindings?["content"]?.querySlug, "independent")
        let roundTrip = try JSONDecoder().decode(CmsPageBlocks.self, from: JSONEncoder().encode(container))
        XCTAssertEqual(roundTrip, container)
    }

    @MainActor
    func testInspectorEditsCellContentWithoutChangingPlacementOrBinding() async throws {
        let raw = try JSONDecoder().decode(CmsJSON.self, from: Data(fixture.utf8))
        let updated = try XCTUnwrap(CmsDesignController.updatingBlock(in: raw, blockId: "child") { block in
            var props = block["props"]?.objectValue ?? [:]
            props["content"] = .string("Edited content")
            block["props"] = .object(props)
        })
        let container = try XCTUnwrap(CmsDesignController.decode(CmsPageBlocks.self, from: updated))
        let child = try XCTUnwrap(CmsDesignController.findBlock(id: "child", in: container))
        XCTAssertEqual(child.props.string("content"), "Edited content")
        XCTAssertEqual(child.bindings?["content"]?.querySlug, "independent")
        XCTAssertNotNil(CmsDesignController.findRawBlock(id: "child", in: updated))
        let parent = try XCTUnwrap(CmsDesignController.findBlock(id: "layout", in: container))
        XCTAssertEqual(parent.props.object("gridLayout")?.object("placements")?.object("__slot:left")?.double("colSpan"), 2)
    }
}
