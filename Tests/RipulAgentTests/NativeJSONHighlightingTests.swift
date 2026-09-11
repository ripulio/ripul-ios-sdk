import XCTest
import SwiftUI
@testable import RipulAgent

final class NativeJSONHighlightingTests: XCTestCase {
    func testEscapesUnicodeAndNumbersRetainExactSource() {
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
            let highlighted = NativeJSONHighlighting.attributed(source, colorScheme: scheme)
            XCTAssertEqual(String(highlighted.characters), source)
            let runs = highlighted.runs.map { (String(highlighted[$0.range].characters), $0.foregroundColor) }
            XCTAssertTrue(runs.contains { $0.0 == "-1.25e+10" && $0.1 != nil })
            XCTAssertTrue(runs.contains { $0.0 == "9007199254740993" && $0.1 != nil })
            XCTAssertTrue(runs.contains { $0.0.contains("true: 42") && $0.0.hasPrefix("\"") && $0.1 != nil }, "JSON-looking content inside a string stays one string token")
            let key = runs.first { $0.0 == "\"number\"" }?.1
            let number = runs.first { $0.0 == "-1.25e+10" }?.1
            let literal = runs.first { $0.0 == "true" }?.1
            XCTAssertNotEqual(key, number)
            XCTAssertNotEqual(number, literal)
        }
    }

    func testPartialDiagnosticsRemainReadableAndThemeChangesColours() {
        let source = "{\"status\": false,\n  \"output\": \"unfinished"
        let light = NativeJSONHighlighting.attributed(source, colorScheme: .light)
        let dark = NativeJSONHighlighting.attributed(source, colorScheme: .dark)
        XCTAssertEqual(String(light.characters), source)
        XCTAssertEqual(String(dark.characters), source)
        XCTAssertNotEqual(light, dark)
        XCTAssertEqual(String(NativeJSONHighlighting.attributed("", colorScheme: .dark).characters), "")
    }
}
