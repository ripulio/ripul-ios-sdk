import XCTest
import SwiftUI
@testable import RipulAgent

final class NativeSourceHighlightingTests: XCTestCase {
    func testAutomaticTerminalOutputRecognizesSource() async throws {
        let sdk = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let swift = try String(contentsOf: sdk.appendingPathComponent("Sources/RipulAgent/Speech/RipulVoiceModeRequest.swift"))
        let c = "#include <stdio.h>\nint main(void) {\n    printf(\"Hello world\\n\");\n    return 0;\n}\n"
        for source in [swift, c, swift + "\nSources/Example.swift:12:let pending = false\n"] {
            let result = await NativeSourceHighlighting.shared.attributed(.init(source: source, language: "auto", dark: true))
            XCTAssertEqual(String(result.characters), source)
            XCTAssertGreaterThan(Set(result.runs.compactMap { $0.foregroundColor }).count, 1)
        }
    }

    func testAutomaticTerminalOutputLeavesWeakGuessesPlain() async {
        for source in ["Tests passed\n", "Result for call 2", "Files downloaded successfully.\nNo changes needed.\n", " M app.ts\n?? notes.txt\n"] {
            let result = await NativeSourceHighlighting.shared.attributed(.init(source: source, language: "auto", dark: false))
            XCTAssertEqual(String(result.characters), source)
            XCTAssertTrue(result.runs.allSatisfy { $0.foregroundColor == nil }, source)
        }
    }

    func testSourceLanguagesAndWhitespace() async {
        let cases = [
            ("swift", "\n\tlet greeting = \"Hello 🛠️\"\n\n"),
            ("typescript", "  const count: number = 42;\n"),
            ("javascript", "const html = '<script>throw new Error(\"never execute\")</script>';\n"),
            ("bash", "#!/bin/bash\necho \"$HOME\"\n"),
            ("python", "def hello():\n    return \"world\"\n"),
            ("xml", "<div title=\"a &amp; b\">Hello</div>\n")
        ]
        for (language, source) in cases {
            let result = await NativeSourceHighlighting.shared.attributed(.init(source: source, language: language, dark: true))
            XCTAssertEqual(String(result.characters), source, language)
            XCTAssertGreaterThan(Set(result.runs.compactMap { $0.foregroundColor }).count, 1, language)
        }
    }

    func testMultilineCommentsAreHighlightedBeforeLineSplitting() async {
        let source = "/* start\nstill a comment\n*/\nconst count = 42;"
        let result = await NativeSourceHighlighting.shared.attributed(.init(source: source, language: "javascript", dark: true))
        let lines = NativeSourceHighlighting.lines(result)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].runs.first?.foregroundColor, lines[1].runs.first?.foregroundColor)
        XCTAssertNotEqual(lines[1].runs.first?.foregroundColor, lines[3].runs.first?.foregroundColor)
    }

    func testFallbackAndLineEndingFidelity() async {
        for source in ["", " \n\t", "let x = 1;\r\nlet y = 2;\r\n", String(repeating: "x", count: 100_001)] {
            let result = await NativeSourceHighlighting.shared.attributed(.init(source: source, language: "swift", dark: false))
            XCTAssertEqual(String(result.characters), source)
            XCTAssertEqual(NativeSourceHighlighting.lines(result).count, source.components(separatedBy: "\n").count)
        }
        XCTAssertEqual(NativeToolCodeSyntax.file("/src/App.tsx").language, "typescript")
        XCTAssertEqual(NativeToolCodeSyntax.file("Dockerfile").language, "dockerfile")
        XCTAssertEqual(NativeToolCodeSyntax.file("notes.unknown").language, "plaintext")
    }

    func testDiffKeepsMarkersAndSeparateSyntaxState() async {
        let patch = "*** Begin Patch\n*** Update File: app.ts\n@@\n-/* removed open comment\n+const count: number = 42;\n*** End Patch"
        let rows = NativeToolDiffLine.unified(patch)
        let result = await NativeSourceHighlighting.shared.diff(.init(lines: rows, path: "", includesPrefix: true, dark: true))
        XCTAssertEqual(result.map { String($0.characters) }, rows.map(\.text))
        XCTAssertGreaterThan(Set(result[4].runs.compactMap { $0.foregroundColor }).count, 1)
    }

    func testReadLineNumbersDoNotBecomePartOfTheGrammar() async {
        let source = "  10→/* comment\n  11→continued */\n  12→const value = 42;"
        let result = await NativeSourceHighlighting.shared.attributed(.init(source: source, language: "typescript", dark: true, readLineNumbers: true))
        XCTAssertEqual(String(result.characters), source)
        XCTAssertGreaterThan(Set(result.runs.compactMap { $0.foregroundColor }).count, 2)
    }

    func testEscapesUnicodeAndNumbersRetainExactSource() async {
        let source = #"""
        {
          "emoji 🛠️": "a \"quote\", a \\slash, a \n newline, true: 42",
          "key \"with escapes\"": "https://ripul.io",
          "number": -1.25e+10,
          "precise": 9007199254740993,
          "enabled": true,
          "empty": null
        }
        """#
        for scheme: ColorScheme in [.light, .dark] {
            let highlighted = await NativeSourceHighlighting.shared.attributed(.init(source: source, language: "json", dark: scheme == .dark))
            XCTAssertEqual(String(highlighted.characters), source)
            let runs = highlighted.runs.map { (String(highlighted[$0.range].characters), $0.foregroundColor) }
            XCTAssertTrue(runs.contains { $0.0 == "-1.25e+10" && $0.1 != nil })
            XCTAssertTrue(runs.contains { $0.0 == "9007199254740993" && $0.1 != nil })
            XCTAssertTrue(runs.contains { $0.0.contains("true: 42") && $0.0.hasPrefix("\"") && $0.1 != nil }, "JSON-looking content inside a string stays one string token")
            let key = runs.first { $0.0 == "\"number\"" }?.1
            let string = runs.first { $0.0 == "\"https://ripul.io\"" }?.1
            let literal = runs.first { $0.0 == "true" }?.1
            XCTAssertNotEqual(key, string)
            XCTAssertNotNil(literal) // GitHub shares colours across some token categories.
        }
    }

    func testPartialDiagnosticsRemainReadableAndThemeChangesColours() async {
        let source = "{\"status\": false,\n  \"output\": \"unfinished"
        let light = await NativeSourceHighlighting.shared.attributed(.init(source: source, language: "json", dark: false))
        let dark = await NativeSourceHighlighting.shared.attributed(.init(source: source, language: "json", dark: true))
        XCTAssertEqual(String(light.characters), source)
        XCTAssertEqual(String(dark.characters), source)
        XCTAssertNotEqual(light, dark)
        let empty = await NativeSourceHighlighting.shared.attributed(.init(source: "", language: "json", dark: true))
        XCTAssertEqual(String(empty.characters), "")
    }
}
