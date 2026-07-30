import XCTest
@testable import RipulAgent

/// Phase-0 (automation-macros): `RipulMacro`/`MacroStep`/`MacroSelector` are
/// plain `Codable` structs with no UIKit dependency, so — unlike almost
/// everything else screen-actuation-related — they're testable directly, no
/// resolver seam needed. Pins the round-trip contract the `/v1/macros`
/// backend (phase 3) and the recording UI (phase 2) both rely on.
final class MacroModelsTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func testMacroSelectorRoundTripsIncludingAnchor() throws {
        let selector = MacroSelector(id: nil, text: "Clock In", role: "button", className: nil, nth: nil,
                                     within: MacroAnchorSelector(text: "Alice"))
        let data = try encoder.encode(selector)
        let decoded = try decoder.decode(MacroSelector.self, from: data)
        XCTAssertEqual(decoded, selector)
    }

    func testMacroSelectorRoundTripsWithNoAnchor() throws {
        let selector = MacroSelector(id: "records.clockIn")
        let data = try encoder.encode(selector)
        let decoded = try decoder.decode(MacroSelector.self, from: data)
        XCTAssertEqual(decoded, selector)
        XCTAssertNil(decoded.within)
    }

    func testMacroStepRoundTrips() throws {
        let step = MacroStep(kind: .type,
                             selector: MacroSelector(role: "field"),
                             text: "{{note}}",
                             append: false,
                             recordedLabel: "Type into 'Note'")
        let data = try encoder.encode(step)
        let decoded = try decoder.decode(MacroStep.self, from: data)
        XCTAssertEqual(decoded, step)
    }

    func testRipulMacroRoundTripsWithStepsAndParameters() throws {
        let now = ISO8601DateFormatter().date(from: "2026-07-30T12:00:00Z")!
        let macro = RipulMacro(
            id: "macro_abc123_clock_in",
            name: "clock_in",
            description: "Clocks in with an optional note.",
            steps: [
                MacroStep(kind: .tap, selector: MacroSelector(text: "Clock In"), recordedLabel: "Tap 'Clock In' (button)"),
                MacroStep(kind: .wait, selector: MacroSelector(text: "Confirm"), state: "visible", timeout: 5,
                         recordedLabel: "Wait for 'Confirm'"),
                MacroStep(kind: .type, selector: MacroSelector(role: "field"), text: "{{note}}",
                         recordedLabel: "Type into note field"),
            ],
            parameters: [MacroParameter(name: "note", description: "Optional shift note")],
            published: false,
            siteKeyId: "sk_test",
            createdAt: now,
            updatedAt: now
        )
        let data = try encoder.encode(macro)
        let decoded = try decoder.decode(RipulMacro.self, from: data)
        XCTAssertEqual(decoded, macro)
    }

    func testMacroIsNeverBornPublished() {
        // Guards the default-value contract phase 3's handlers.ts relies on:
        // a macro created without an explicit `published` argument is a draft.
        let now = Date()
        let macro = RipulMacro(id: "id", name: "name", description: "d", steps: [], createdAt: now, updatedAt: now)
        XCTAssertFalse(macro.published)
    }

    func testMacroSelectorHasAnyPredicate() {
        XCTAssertFalse(MacroSelector().hasAnyPredicate)
        XCTAssertTrue(MacroSelector(text: "x").hasAnyPredicate)
        // nth alone is a positional predicate, not a matching predicate —
        // mirrors ScreenElementFinder.Query.hasAnyPredicate exactly.
        XCTAssertFalse(MacroSelector(nth: 2).hasAnyPredicate)
    }
}
