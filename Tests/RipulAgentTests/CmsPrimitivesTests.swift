import XCTest
@testable import RipulAgent

/// Primitives against the table every renderer shares:
/// `chrome-extension/packages/shared-types/src/cmsPrimitives.cases.json` (the web runs it in cmsPrimitives.test.ts).
final class CmsPrimitivesTests: XCTestCase {
    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsPrimitives.cases.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func json(_ any: Any?) -> CmsJSON? {
        guard let any, !(any is NSNull) else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try? JSONDecoder().decode(CmsJSON.self, from: data)
    }

    func testSharedTable() {
        let cases = Self.table["cases"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as! String
            let given = (c["rows"] as? [String: Any]) ?? [:]
            let rows: (String) -> CmsPrimitiveRows = { slug in
                switch given[slug] {
                case let s as String where s == "error": return .error
                case let list as [Any]: return .ready(list.compactMap { self.json($0)?.objectValue })
                default: return .loading
                }
            }
            let caps = c["capabilities"] as? [String]
            let got = CmsPrimitives.resolve(json(c["tree"]), row: json(c["row"])?.objectValue, rows: rows,
                                            supports: caps.map { list in { list.contains($0) } })
            if let expect = c["expect"] as? [String: Any] {
                guard let root = got.root else { XCTFail("\(name): nothing resolved"); continue }
                XCTAssertEqual(NSDictionary(dictionary: root.caseJSON), NSDictionary(dictionary: expect), name)
            } else {
                XCTAssertNil(got.root, name)
            }
        }
    }

    func testCutsPastTheDepthLimit() {
        var tree: CmsJSON = .object(["kind": .string("text"), "text": .string("deep")])
        for _ in 0..<(CmsPrimitives.maxDepth + 2) { tree = .object(["kind": .string("stack"), "children": .array([tree])]) }
        XCTAssertEqual(CmsPrimitives.resolve(tree).cut, 1)
    }

    func testCutsPastTheNodeLimit() {
        let rows = (0..<50).map { ["id": CmsJSON.number(Double($0))] }
        let tree = CmsJSON.object(["kind": .string("stack"), "children": .array((1...5).map { n in
            .object(["kind": .string("repeat"), "rows": .string("r"), "max": .number(50),
                     "child": .object(["kind": .string("text"), "text": .string("\(n):{id}")])])
        })])
        let got = CmsPrimitives.resolve(tree, rows: { _ in .ready(rows) })
        XCTAssertEqual(got.root?.children?.count, 199)
        XCTAssertEqual(got.cut, 51)
    }

    func testCapabilitiesNameEveryKind() {
        XCTAssertEqual(CmsPrimitives.capabilities.first, "layout@1")
        XCTAssertTrue(CmsPrimitives.capabilities.contains("node.repeat"))
        XCTAssertEqual(CmsPrimitives.capabilities.count, 14)
    }

    /// The web's flex row: content-sized children are laid out before spacers
    /// and `fill` children, so text keeps one line while a spacer has room.
    @MainActor
    func testRowGivesContentItsWidthBeforeSpacers() {
        let tree = json([
            "kind": "row", "children": [
                ["kind": "text", "text": "£32.00"],
                ["kind": "spacer"],
                ["kind": "text", "text": "40 in stock", "width": "fill"],
                ["kind": "badge", "text": "New"],
            ],
        ])
        let kids = CmsPrimitives.resolve(tree).root?.children ?? []
        XCTAssertEqual(kids.map(CmsPrimitiveView.rowPriority), [1, 0, 0, 1])
    }

    func testQuerySlugsIncludeFallbacks() {
        let tree = json([
            "kind": "stack", "children": [
                ["kind": "repeat", "rows": "offers", "child": ["kind": "text", "text": "{name}"]],
                ["kind": "gauge", "fallback": ["kind": "text", "text": "x", "when": ["rows": "gone"]]],
            ],
        ])
        XCTAssertEqual(CmsPrimitives.querySlugs(tree).sorted(), ["gone", "offers"])
    }
}
