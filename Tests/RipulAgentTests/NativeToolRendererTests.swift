import XCTest
@testable import RipulAgent

final class NativeToolRendererTests: XCTestCase {
    func testSharedWebNativeFixtures() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("shared/tool-call-renderers.json"))) as? [[String: Any]])
        for fixture in fixtures {
            let name = fixture["name"] as! String
            func text(_ value: Any) throws -> String {
                if let value = value as? String { return value }
                return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
            }
            let wire: [String: Any] = ["id": name, "toolName": fixture["toolName"]!, "status": "success", "timestamp": 1,
                "arguments": try text(fixture["args"]!), "result": try text(fixture["result"]!), "diagnostics": "{}",
                "rendererName": fixture["rendererName"]!, "renderArguments": fixture["renderArguments"]!]
            let call = try JSONDecoder().decode(ToolCallDetail.self, from: JSONSerialization.data(withJSONObject: wire))
            let content = NativeToolContent(call)
            XCTAssertEqual(content.kind.rawValue, fixture["expectedKind"] as? String, name)
            XCTAssertNotNil(content.output, name)
            if name == "provider-read" { XCTAssertEqual(content.args.double("offset"), 4); XCTAssertEqual(content.args.double("limit"), 3) }
            if name == "grep" { XCTAssertEqual(content.args.string("output_mode"), "content") }
            if name == "logs" { XCTAssertEqual(content.output?.objectValue?["logs"]?.toolArray?.count, 4) }
        }
    }

    func testDiffReconstructsBothSourcesWithoutInventingChanges() {
        for (before, after) in [("one\ntwo\nthree", "one\nchanged\nthree"), ("", "new"), ("old", ""), ("same", "same")] {
            let rows = NativeToolDiffLine.compare(old: before, new: after)
            XCTAssertEqual(rows.filter { $0.kind != .added }.map(\.text).joined(separator: "\n"), before)
            XCTAssertEqual(rows.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n"), after)
        }
    }

    func testLogGroupingPreservesSeverityAndStackDifferences() {
        let logs = ToolValue.parse("""
        [{"level":"info","message":"ready"},{"level":"info","message":"ready"},
         {"level":"error","message":"ready","stack":"first"},{"level":"error","message":"ready","stack":"second"}]
        """).toolArray!
        let groups = NativeToolLogGroup.collect(logs)
        XCTAssertEqual(groups.map(\.count), [2, 1, 1])
        XCTAssertEqual(groups.map(\.level), ["INFO", "ERROR", "ERROR"])
    }

    func testCodexFileChangeMapAndLiveArray() {
        let stored = ToolValue.parse(#"""
        {"a.swift":{"type":"update","unified_diff":"-old\n+new"},"b.swift":{"type":"add","content":"created"}}
        """#)
        let files = NativeToolFileChange.collect(stored)
        XCTAssertEqual(files.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(files.first?.lines?.map(\.kind), [.removed, .added])
        XCTAssertEqual(files.last?.lines?.first?.text, "+created")
        let live = ToolValue.parse("""
        [{"path":"renamed.swift","kind":{"type":"update","move_path":"old.swift"},"diff":"+new"}]
        """)
        let file = NativeToolFileChange.collect(live).first
        XCTAssertEqual(file?.path, "renamed.swift")
        XCTAssertEqual(file?.lines?.first?.kind, .added)
        XCTAssertNotNil(file?.fields["kind"], "Preserve move metadata alongside the diff")
    }

    func testTransportUnwrapAndTerminalControls() {
        XCTAssertEqual(ToolValue.unwrap(ToolValue.parse("{\"content\":[{\"type\":\"text\",\"text\":\"false\"}]}")), .bool(false))
        XCTAssertEqual(ToolValue.unwrap(.string("null")), .null)
        XCTAssertEqual(ToolValue.cleanTerminal("\u{001B}[32mPassed\u{001B}[0m"), "Passed")
        let mixed = ToolValue.parse("{\"status\":200,\"result\":\"keep\",\"headers\":{\"ETag\":\"123\"}}")
        XCTAssertEqual(ToolValue.unwrap(mixed), mixed, "An HTTP result with other fields is not a transport envelope")
    }
}
