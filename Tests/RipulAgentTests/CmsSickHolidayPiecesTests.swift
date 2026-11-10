import XCTest
@testable import RipulAgent

/// The three general pieces WAC's sick days and holidays are built from
/// (docs/plans/cms-sick-holiday.md), against the tables the web tests too:
/// computed values with text, comparisons and `if` (`cmsFormExpr.cases.json`),
/// a set of days (`cmsDateSets.cases.json`) and a row form by the row
/// (`cmsFormSteps.cases.json`, `rowFormFor`).
final class CmsSickHolidayPiecesTests: XCTestCase {
    private static func table(_ file: String) -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/\(file)")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func json(_ any: Any?) -> CmsJSON? {
        guard let any else { return nil }
        if any is NSNull { return .null }
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try! JSONDecoder().decode(CmsJSON.self, from: data)
    }

    private func cases(_ table: [String: Any], _ key: String) -> [[String: Any]] {
        let list = table[key] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty, "the table has \(key) cases")
        return list
    }

    // MARK: Computed values

    /// A scope over plain values, as the web's evaluator reads them.
    private func scope(_ values: [String: CmsJSON], rows: [String: [String: CmsJSON]]) -> CmsFormScope {
        func items(_ v: CmsJSON?) -> [[String: CmsJSON]] {
            switch v {
            case .array(let list)?: return list.compactMap { $0 == .null ? nil : ($0.objectValue ?? ["value": $0]) }
            case .string(let s)? where s.hasPrefix("["):
                return items(try? JSONDecoder().decode(CmsJSON.self, from: Data(s.utf8)))
            default: return []
            }
        }
        func lookup(_ name: String) -> CmsJSON? {
            if let v = values[name] { return v }
            if let dot = name.firstIndex(of: ".") { return rows[String(name[..<dot])]?[String(name[name.index(after: dot)...])] }
            return nil
        }
        return CmsFormScope(
            number: { CmsFormScope.number(lookup($0)) },
            moment: { name in if case .string(let t)? = lookup(name) { return CmsActionForm.parseTime(t) } else { return nil } },
            items: { items(values[$0]) },
            value: { name in
                switch lookup(name) {
                case .number(let n)?: return .number(n)
                case .bool(let b)?: return .number(b ? 1 : 0)
                case .string(let s)?: return s.isEmpty ? .blank : (Double(s.trimmingCharacters(in: .whitespaces)).map(CmsFormValue.number) ?? .text(s))
                default: return .blank
                }
            })
    }

    func testComputedValuesFromTheSharedTable() {
        let t = Self.table("cmsFormExpr.cases.json")
        for c in cases(t, "eval") {
            let name = c["name"] as! String
            let values = json(c["values"])?.objectValue ?? [:]
            let rows = (json(c["rows"])?.objectValue ?? [:]).compactMapValues(\.objectValue)
            guard let expr = CmsFormExpr.parse(c["expr"] as! String) else { XCTFail("parses: \(name)"); continue }
            let got = scope(values, rows: rows).value(expr)
            switch c["expect"] {
            case let n as NSNumber where !(c["expect"] is String): XCTAssertEqual(got, .number(n.doubleValue), name)
            case let s as String: XCTAssertEqual(got, .text(s), name)
            default: XCTAssertEqual(got, .blank, name)
            }
        }
        for c in cases(t, "invalid") {
            XCTAssertNil(CmsFormExpr.parse(c["expr"] as! String), "refuses: \(c["name"] as! String)")
        }
    }

    func testFunctionsWhoseResultVaries() {
        let t = Self.table("cmsFormExpr.cases.json")
        for c in cases(t, "patterns") {
            let name = c["name"] as! String
            let values = json(c["values"])?.objectValue ?? [:]
            guard let expr = CmsFormExpr.parse(c["expr"] as! String) else { XCTFail("parses: \(name)"); continue }
            let got = scope(values, rows: [:]).value(expr).text ?? ""
            XCTAssertNotNil(got.range(of: c["pattern"] as! String, options: .regularExpression), "\(name): \(got)")
        }
    }

    func testATimeOfDay() {
        let inputs = try! JSONDecoder().decode([CmsActionInputDef].self, from: Data("""
        [{ "name": "starts", "type": "time", "required": true },
         { "name": "ends", "type": "time", "required": true, "after": "starts" }]
        """.utf8))
        XCTAssertEqual(CmsActionForm.control(for: inputs[0]), .time)
        let draft = CmsActionForm.draft(inputs, values: ["starts": .string("09:00"), "ends": .string("17:30")])
        let check = CmsActionForm.validate(inputs, draft: draft)
        XCTAssertTrue(check.ready, "\(check.errors)")
        XCTAssertEqual(check.values["starts"], .string("09:00"))
        XCTAssertEqual(check.values["ends"], .string("17:30"))
        // An end before its start is refused, as the web's `after`.
        let wrong = CmsActionForm.validate(inputs, draft: CmsActionForm.draft(inputs, values: ["starts": .string("18:00"), "ends": .string("09:00")]))
        XCTAssertEqual(wrong.errors.map(\.field), ["ends"])
        XCTAssertFalse(CmsActionForm.check(inputs, supplied: ["starts": .string("9am"), "ends": .string("17:00")]).errors.isEmpty)
    }

    func testASetOfDaysWithNoRangeTakesAnyDay() {
        let inputs = [CmsActionInputDef(name: "days", type: "dates")]
        let check = CmsActionForm.validate(inputs, draft: ["days": .text("2026-10-20,2026-12-01")])
        XCTAssertEqual(check.values["days"], .array([.string("2026-10-20"), .string("2026-12-01")]))
    }

    func testATextComputedValueIsSentAsText() {
        let inputs = [
            CmsActionInputDef(name: "days", type: "dates"),
            CmsActionInputDef(name: "kind", type: "string"),
        ]
        let values = CmsFormValues(inputs: inputs,
                                   computed: [CmsComputedDef(name: "sent", expr: "if(count(days) == 0, 'unpaid', kind)", format: nil)],
                                   draft: ["days": .text(""), "kind": .text("fixed")])
        XCTAssertEqual(values.value("sent").text, "unpaid")
        let paid = CmsFormValues(inputs: inputs,
                                 computed: [CmsComputedDef(name: "sent", expr: "if(count(days) == 0, 'unpaid', kind)", format: nil)],
                                 draft: ["days": .text("2026-10-20,2026-10-21"), "kind": .text("fixed")])
        XCTAssertEqual(paid.value("sent").text, "fixed")
        XCTAssertEqual(paid.text("sent", format: nil), "fixed")
    }

    // MARK: A set of days

    func testDateSetsFromTheSharedTable() {
        let t = Self.table("cmsDateSets.cases.json")
        for c in cases(t, "between") {
            XCTAssertEqual(CmsDateSets.daysBetween(json(c["from"]), json(c["to"])), c["days"] as! [String], "between: \(c["name"] as! String)")
        }
        for c in cases(t, "value") {
            let input = c["input"] as? [String: Any] ?? [:]
            XCTAssertEqual(CmsDateSets.value(itemField: input["itemField"] as? String, json(c["raw"])), c["days"] as! [String], "value: \(c["name"] as! String)")
        }
        for c in cases(t, "forRange") {
            let input = c["input"] as? [String: Any] ?? [:]
            XCTAssertEqual(CmsDateSets.forRange(defaultSelection: input["defaultSelection"] as? String, json(c["from"]), json(c["to"])),
                           c["days"] as! [String], "forRange: \(c["name"] as! String)")
        }
        for c in cases(t, "wire") {
            let input = c["input"] as? [String: Any] ?? [:]
            XCTAssertEqual(CmsDateSets.wire(itemField: input["itemField"] as? String, c["days"] as! [String]), json(c["sent"]), "wire: \(c["name"] as! String)")
        }
        for c in cases(t, "issue") {
            let data = try! JSONSerialization.data(withJSONObject: (c["input"] as! [String: Any]).merging(["type": "dates"]) { a, _ in a })
            let input = try! JSONDecoder().decode(CmsActionInputDef.self, from: data)
            let refused = CmsDateSets.issue(input, json(c["raw"]) ?? .null, values: json(c["values"])?.objectValue ?? [:]) != nil
            XCTAssertEqual(refused, c["refused"] as! Bool, "issue: \(c["name"] as! String)")
        }
    }

    func testADateSetInAForm() {
        let decoded = try! JSONDecoder().decode([CmsActionInputDef].self, from: Data("""
        [{ "name": "start", "type": "date", "required": true },
         { "name": "end", "type": "date", "required": true },
         { "name": "paid", "type": "dates", "range": { "from": "start", "to": "end" }, "defaultSelection": "all", "itemField": "paid_day" }]
        """.utf8))
        XCTAssertEqual(decoded[2].range, CmsDateRange(from: "start", to: "end"))
        XCTAssertEqual(CmsActionForm.control(for: decoded[2]), .dates)
        // A row's records fill the draft as days; the form sends plain days (the worker makes the records).
        let draft = CmsActionForm.draft(decoded, values: [
            "start": .string("2026-10-20"), "end": .string("2026-10-21"),
            "paid": .array([.object(["id": .number(7), "paid_day": .string("2026-10-21")])]),
        ])
        XCTAssertEqual(draft["paid"], .text("2026-10-21"))
        let check = CmsActionForm.validate(decoded, draft: draft)
        XCTAssertTrue(check.ready, "\(check.errors)")
        XCTAssertEqual(check.values["paid"], .array([.string("2026-10-21")]))
        XCTAssertEqual(CmsDateSets.readingRange(decoded, changed: "end").map(\.name), ["paid"])
    }

    func testASetOpensWithItsDefaultSelectionWhenItsRangeOpensFilled() {
        let inputs = try! JSONDecoder().decode([CmsActionInputDef].self, from: Data("""
        [{ "name": "start", "type": "date", "required": true },
         { "name": "end", "type": "date", "required": true },
         { "name": "all", "type": "dates", "range": { "from": "start", "to": "end" }, "defaultSelection": "all" },
         { "name": "none", "type": "dates", "range": { "from": "start", "to": "end" } }]
        """.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z")!
        let draft = CmsActionForm.initialDraft(inputs, now: now, calendar: calendar)
        XCTAssertEqual(draft["all"], .text("2026-10-30"))
        XCTAssertEqual(draft["none"], .text(""))
    }

    func testPickerComponentsRoundTrip() {
        let c = CmsDateSets.components("2026-10-15")!
        XCTAssertEqual(CmsDateSets.day(c), "2026-10-15")
        // The picker's own components for that day read back the same.
        let own = Calendar.current.dateComponents([.calendar, .era, .year, .month, .day], from: CmsDateSets.date("2026-10-15")!)
        XCTAssertEqual(own, c)
    }

    // MARK: A row form by the row

    func testRowFormForFromTheSharedTable() {
        let t = Self.table("cmsFormSteps.cases.json")
        for c in cases(t, "rowFormFor") {
            let spec = CmsRowFormSpec(json(c["rowForm"]))!
            let row = json(c["row"])?.objectValue ?? [:]
            XCTAssertEqual(spec.form(for: row).mutationSlug, c["mutationSlug"] as! String, c["name"] as! String)
            XCTAssertEqual(CmsRecordFormRequest(spec: spec, row: row).spec.mutationSlug, c["mutationSlug"] as! String, c["name"] as! String)
        }
    }
}
