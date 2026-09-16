import XCTest
@testable import RipulAgent

final class NativeToolRendererTests: XCTestCase {
    func testConsoleNamesRouteWithoutCanonicalRendererMetadata() {
        for name in ["host_console_logs", "device_console_logs", "console_logs",
                     "mcp_ripul_tools_host_console_logs", "mcp__ripul_tools_host_console_logs",
                     "mcp__ripul_tools__host_console_logs", "functions.mcp_ripul_tools_device_console_logs"] {
            XCTAssertEqual(NativeToolRendererKind.resolve(name), .logs, name)
        }
        XCTAssertEqual(NativeToolRendererKind.resolve("another_console_logs_tool"), .fields)
    }

    func testConsoleSearchKeepsCaptureCountsRepeatBoundariesAndCopiesEveryEntry() throws {
        let logs = try XCTUnwrap(NativeConsoleLogs(ToolValue.parse("""
        {"total":120,"logs":[
          {"level":"info","message":"Connected","ts":1789120000000},
          {"level":"info","message":"Connected","ts":1789120001000},
          {"level":"warning","message":"Retrying","ts":1789120002000},
          {"level":"info","message":"Connected","ts":1789120003000},
          {"level":"error","message":"Failed","stack":"fetchData (app.ts:12)","ts":1789120004000}
        ]}
        """)))
        XCTAssertEqual(logs.total, 120)
        XCTAssertEqual(logs.levels, ["ERROR", "WARN", "INFO"])
        let groups = logs.matching(query: " connected ", level: "INFO")
        XCTAssertEqual(groups.map(\.count), [2, 1], "Filtering must not coalesce non-consecutive repeats")
        XCTAssertEqual(groups.map(\.id), [0, 3], "Filtering and ordering must retain original row identities")
        XCTAssertEqual(groups.first?.lastEntry.timestamp, .number(1789120001000))
        XCTAssertEqual(logs.matching(query: "FETCHDATA", level: nil).map(\.id), [4])
        XCTAssertTrue(logs.matching(query: "fetchData", level: "INFO").isEmpty)
        let copy = logs.copyText(query: "Connected", level: nil, newestFirst: false)
        XCTAssertEqual(copy.components(separatedBy: "\n").count, 3, "Copy includes folded and unrevealed entries")
        XCTAssertTrue(copy.contains("[INFO] Connected"))
        XCTAssertEqual(logs.copyText(query: "Connected", level: nil, newestFirst: true).components(separatedBy: "\n"), copy.components(separatedBy: "\n").reversed())
        XCTAssertTrue(logs.copyText(query: "fetchData", level: nil, newestFirst: true).contains("\nfetchData (app.ts:12)"))
    }

    func testConsoleCurrentDeviceWebRecordsAndEmptyResults() throws {
        let output = ToolValue.parse("""
        {"logs":[{"level":"debug","text":"Web console","timestamp":"2026-09-16T10:00:00.123Z"}]}
        """)
        let logs = try XCTUnwrap(NativeConsoleLogs(output))
        XCTAssertEqual(logs.entries.first?.message, "Web console")
        XCTAssertNotNil(logs.entries.first?.date)
        XCTAssertTrue(logs.entries.first!.copyText.hasPrefix("2026-09-16T10:00:00.123Z"))
        XCTAssertEqual(NativeConsoleLogs(ToolValue.parse("{\"logs\":[]}"))?.entries, [])
        XCTAssertNil(NativeConsoleLogs(ToolValue.parse("{\"error\":\"Connection failed\"}")))
        XCTAssertNil(NativeConsoleLogs(.string("unavailable")))
    }

    func testSharedWebNativeFixtures() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("shared/tool-call-renderers.json"))) as? [[String: Any]])
        for fixture in fixtures {
            let name = fixture["name"] as! String
            func text(_ value: Any) throws -> String {
                if let value = value as? String { return value }
                return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
            }
            var wire: [String: Any] = ["id": name, "toolName": fixture["toolName"]!, "status": "success", "timestamp": 1,
                "arguments": try text(fixture["args"]!), "result": try text(fixture["result"]!), "diagnostics": "{}",
                "rendererName": fixture["rendererName"]!, "renderArguments": fixture["renderArguments"]!]
            wire["commandPresentation"] = fixture["commandPresentation"]
            let call = try JSONDecoder().decode(ToolCallDetail.self, from: JSONSerialization.data(withJSONObject: wire))
            let content = NativeToolContent(call)
            XCTAssertEqual(content.kind.rawValue, fixture["expectedKind"] as? String, name)
            XCTAssertNotNil(content.output, name)
            if name == "provider-read" { XCTAssertEqual(content.args.double("offset"), 4); XCTAssertEqual(content.args.double("limit"), 3) }
            if name == "grep" { XCTAssertEqual(content.args.string("output_mode"), "content") }
            if name == "logs" { XCTAssertEqual(content.output?.objectValue?["logs"]?.toolArray?.count, 4) }
            if name == "wrapped-python" {
                let summary = NativeToolSummary(call)
                XCTAssertEqual(summary.title, "Python")
                XCTAssertEqual(summary.subtitle, "Verify iPhone installation")
                XCTAssertFalse(summary.isCode)
                XCTAssertEqual(call.commandPresentation?.language, "python")
                XCTAssertEqual(call.commandPresentation?.executionContext, "zsh")
                XCTAssertTrue(call.commandPresentation!.source!.contains("assert a['bundleVersion']==v"))
                XCTAssertTrue(call.recordedCommand!.hasPrefix("'/bin/zsh'"))
                XCTAssertEqual(NativeToolCodeSyntax.language("python").language, "python")
            }
            if name == "package-script" {
                let summary = NativeToolSummary(call)
                XCTAssertEqual(summary.title, "Build: typecheck")
                XCTAssertNil(summary.subtitle, "The command belongs in the expanded body")
                XCTAssertEqual(call.commandPresentation?.executionContext, "npm · zsh")
                XCTAssertEqual(call.commandPresentation?.command, "npm run build:typecheck")
                XCTAssertEqual(call.recordedCommand, "npm run build:typecheck")
            }
            if name == "compound-command" {
                XCTAssertEqual(NativeToolSummary(call).title, "Python + Status")
                XCTAssertNil(call.commandPresentation?.source)
                XCTAssertTrue(call.commandPresentation!.command.contains("&&"))
                XCTAssertEqual(call.commandPresentation?.commandBreakLines, [1])
                XCTAssertEqual(call.commandPresentation?.command, "python3 check.py &&\ngit status --short")
            }
            if name == "pipeline-command" {
                XCTAssertEqual(call.commandPresentation?.commandBreakLines, [1, 2])
                XCTAssertEqual(call.commandPresentation?.commandPipeLines, [1])
                XCTAssertEqual(NativeToolSummary(call).title, "Grep + Head + Sed")
            }
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
