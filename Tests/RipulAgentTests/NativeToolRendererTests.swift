import XCTest
@testable import RipulAgent

final class NativeToolRendererTests: XCTestCase {
    func testNarrativePolicyPreservesLiteralFieldsAndRejectsUnsafeLinks() throws {
        XCTAssertTrue(NativeToolNarrative.isProse("## Done\n**All checks passed**"))
        XCTAssertFalse(NativeToolNarrative.isProse("# shell comment", hasSyntax: true))
        XCTAssertFalse(NativeToolNarrative.isProse("a_b_c", enabled: false))
        XCTAssertFalse(NativeToolNarrative.isProse("\u{001B}[31merror"))
        for field in ["guide", "unexpectedField", "details", "payload"] {
            XCTAssertTrue(NativeToolNarrative.isProse("# Trains\n\n**Ready**", field: field))
        }
        for field in ["path", "stdout", "code", "command"] {
            XCTAssertFalse(NativeToolNarrative.isProse("# literal", field: field))
        }
        for value in ["cli_a_b_c", "/tmp/a file.md", "https://example.com/a_b_c"] {
            XCTAssertFalse(NativeToolNarrative.isProse(value))
        }
        for link in ["https://example.com", "ripul://file/a", "file:///tmp/test.swift", "/tmp/test.swift"] {
            XCTAssertTrue(NativeToolNarrative.allowsLink(try XCTUnwrap(URL(string: link))))
        }
        for link in ["javascript:alert(1)", "data:text/html,hello", "vbscript:hello"] {
            XCTAssertFalse(NativeToolNarrative.allowsLink(try XCTUnwrap(URL(string: link))))
        }
    }

    func testNarrativeExpandsUnknownNestedFieldsWithoutReinterpretingSource() throws {
        let value = ToolValue.parse(##"{"embeddedToolResult":{"status":"success","result":"{\"guide\":\"# Trains\\n\\n**Ready**\"}"},"source":"{\"unexpected\":\"# Literal code\"}","items":["cli_a_b_c",{"unfamiliar":"**Formatted**"}]}"##)
        let object = try XCTUnwrap(NativeToolNarrative.expanded(value).objectValue)
        let result = try XCTUnwrap(object["embeddedToolResult"]?.objectValue?["result"]?.objectValue)
        XCTAssertEqual(result["guide"]?.stringValue, "# Trains\n\n**Ready**")
        XCTAssertNotNil(object["source"]?.stringValue, "Explicit source must not be parsed into prose fields")
        XCTAssertEqual(object["items"]?.toolArray?.first, .string("cli_a_b_c"))
        XCTAssertEqual(object["items"]?.toolArray?.last?.objectValue?["unfamiliar"], .string("**Formatted**"))
    }

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
            wire["agentComms"] = fixture["agentComms"]
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
            if name == "agent-spawn" {
                let summary = NativeToolSummary(call)
                XCTAssertEqual(summary.title, "Started Check the upload retry")
                XCTAssertEqual(summary.subtitle, "Review how the upload queue retries a failed part. Read UploadQueue.swift and say whether a part that fails three times is dropped or kept. Do not change any code.", "The task as plain text, not the ids")
                XCTAssertEqual(call.agentComms?.target.harness, "Claude Code")
                XCTAssertEqual(call.agentComms?.details?.first, .init(label: "Agent ID", value: "cli_3f9a2c1b-77aa-4e0c-9d54-1f2b6c0a9e11"))
            }
            if name == "agent-await" {
                let summary = NativeToolSummary(call)
                XCTAssertEqual(summary.title, "Reply from Check the upload retry", "Named from the chat's earlier start, not its handle")
                XCTAssertEqual(summary.subtitle, "A part that fails three times is kept, not dropped. UploadQueue.retry moves it to parked. Parked parts are retried when the network path changes.", "Markdown marks are left out of a one-line preview")
                XCTAssertFalse((summary.title + summary.subtitle!).contains("agentmsg_"))
            }
            if name == "agent-list" {
                XCTAssertNil(call.agentComms)
                let summary = NativeToolSummary(call)
                XCTAssertEqual(summary.title, "Recent agents")
                XCTAssertNil(summary.subtitle)
                let list = try XCTUnwrap(NativeAgentList(content.output))
                XCTAssertEqual(list.summary, "3 agents · 1 working · 1 needs input")
                XCTAssertEqual(list.agents.map(\.harness), ["Claude Code", "Codex", "Claude Code"])
                XCTAssertEqual(list.agents.map(\.activity), ["Review how the upload queue retries a failed part.", "Two pass. May I delete the stale snapshot?", nil])
                XCTAssertEqual(list.agents.map(\.folder), ["ripul", "chrome-extension", "website"])
                XCTAssertEqual(list.agents[1].device, "iPhone 16 Pro")
                XCTAssertEqual(list.agents.map(\.startedByCaller), [true, false, false])
                XCTAssertEqual(list.inFlight, [.init(summary: "Task to Check the upload retry", state: "Running")])
                XCTAssertEqual(list.otherMachines, ["MacBook Pro"])
                XCTAssertEqual(list.ids.first, .init(label: "Check the upload retry", value: "cli_3f9a2c1b-77aa-4e0c-9d54-1f2b6c0a9e11"))
                XCTAssertNil(list.rest["agents"])
                let taken = try Date.ISO8601FormatStyle().parse("2026-09-11T05:53:20Z")
                // The wording is the system's and follows the locale ("5 min ago", "5 min. ago").
                XCTAssertTrue(NativeAgentList.ago(list.agents[0].lastActive!, asOf: taken).contains("5"), "Told as of the call, not as of now")
                XCTAssertEqual(NativeAgentList.ago(taken, asOf: taken), "just now")
            }
            if name == "pipeline-command" {
                XCTAssertEqual(call.commandPresentation?.commandBreakLines, [1, 2])
                XCTAssertEqual(call.commandPresentation?.commandPipeLines, [1])
                XCTAssertEqual(NativeToolSummary(call).title, "Grep + Head + Sed")
            }
        }
    }

    func testAgentCallsRouteToTheirOwnPanelsAndIcons() {
        for name in ["send_to_agent", "spawn_agent", "await_agent", "archive_agent"] {
            XCTAssertEqual(NativeToolRendererKind.resolve("mcp__ripul_tools__\(name)"), .agentComms, name)
            XCTAssertEqual(ToolIconMap.symbol(for: "mcp__ripul_tools__\(name)"), "bubble.left.and.bubble.right", name)
        }
        XCTAssertEqual(NativeToolRendererKind.resolve("functions.mcp__ripul_tools__list_agents"), .agentList)
        XCTAssertEqual(ToolIconMap.symbol(for: "list_agents"), "bubble.left.and.bubble.right")
        XCTAssertEqual(NativeToolRendererKind.resolve("Agent"), .agent, "Claude's own sub-agent tool keeps its panel")
        XCTAssertEqual(NativeAgentRuntime.text(harness: "Claude Code", model: "claude-cli-raw-opus", "on MacBook Pro"), "Claude Code · Opus · on MacBook Pro")
        XCTAssertEqual(NativeAgentRuntime.text(harness: "Codex", model: "codex-shared-cli-raw-default", nil), "Codex", "A default model named after its CLI is not said twice")
        XCTAssertEqual(NativeAgentRuntime.text(harness: nil, model: "claude-cli-raw-haiku"), "Haiku")
        XCTAssertEqual(NativeAgentRuntime.text(harness: nil, model: nil), "")
    }

    func testAgentCallWithoutThePresentationLeadsWithWhatWasAsked() throws {
        // A web build from before the card: no ids in the heading or the subtitle.
        let wire: [String: Any] = ["id": "old", "toolName": "mcp__ripul_tools__await_agent", "status": "success", "timestamp": 1,
            "arguments": #"{"handle":"agentmsg_1791624528515_7ix9q2u14","timeoutSec":120}"#, "result": "{}", "diagnostics": "{}"]
        let call = try JSONDecoder().decode(ToolCallDetail.self, from: JSONSerialization.data(withJSONObject: wire))
        let summary = NativeToolSummary(call)
        XCTAssertEqual(summary.title, "Await agent")
        XCTAssertNil(summary.subtitle)
        XCTAssertNil(NativeAgentList(ToolValue.parse(#"{"error":"Connection failed"}"#)))
        // A reply on its way back to the caller, as a live list showed it on 10 October 2026.
        let live = NativeAgentList(ToolValue.parse(#"{"self":{"agentId":"me"},"agents":[{"agentId":"a","title":"Panel test: ready","status":"idle"}],"pending":[{"from":"a","to":"me","kind":"reply","status":"running"}]}"#))
        XCTAssertEqual(live?.inFlight, [.init(summary: "Reply from Panel test: ready", state: "Running")])
        XCTAssertNil(NativeAgentList(.string("unavailable")))
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

    func testFieldFlowLayoutPacksShortFieldsInOneRowAndIsolatesWideOrBlockFields() {
        let rows = NativeToolFieldFlowLayout.packRows(idealWidths: [76, 82, 88, 280], availableWidth: 340, spacing: 8, maxPerRow: 3)
        XCTAssertEqual(rows.count, 2, "Three narrow fields share the first row while the wide path takes the second row")
        XCTAssertEqual(rows[0].map(\.index), [0, 1, 2])
        XCTAssertEqual(rows[0].reduce(0) { $0 + $1.width } + 16, 340, accuracy: 0.01)
        XCTAssertEqual(rows[1].map(\.index), [3])
        XCTAssertEqual(rows[1][0].width, 340, accuracy: 0.01)

        XCTAssertTrue(NativeToolValueView.isCompactFieldControl(key: "offset", item: .number(1)))
        XCTAssertTrue(NativeToolValueView.isCompactFieldControl(key: "followSymlinks", item: .bool(true)))
        XCTAssertTrue(NativeToolValueView.isCompactFieldControl(key: "path", item: .string("Sources/App.swift")))
        XCTAssertFalse(NativeToolValueView.isCompactFieldControl(key: "script", item: .string("echo 1\necho 2")))
        XCTAssertFalse(NativeToolValueView.isCompactFieldControl(key: "nested", item: .object(["a": .number(1)])))
        XCTAssertFalse(NativeToolValueView.isCompactFieldControl(key: "summary", item: .string("## Heading\n\nA multi-sentence markdown explanation.")))
    }
}
