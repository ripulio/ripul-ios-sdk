import XCTest
@testable import RipulAgent

/// The native action-input form against the web's (`actionInputForm.test.ts`):
/// the same inputs asked, the same value formats, the same verdicts.
final class CmsActionFormTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!

    private var mutation: CmsMutationDef {
        let json = """
        {"slug":"add_shift","name":"Add shift","sql":"INSERT …","connectionId":"db",
         "paramSources":{"workplace":{"sourceQuerySlug":"workplaces","column":"id"}},
         "action":{"enabled":true,"operation":"custom","inputs":[
           {"name":"job","label":"Job","type":"string","required":true,"optionsQuery":{"querySlug":"my_jobs","valueColumn":"id","labelColumn":"name"}},
           {"name":"day","label":"Day","type":"date","required":true},
           {"name":"starts","label":"Starts","type":"timestamp","required":true},
           {"name":"hours","label":"Hours","type":"float","required":true,"validation":{"min":0}},
           {"name":"breaks","label":"Breaks","type":"integer"},
           {"name":"paid","label":"Paid","type":"boolean"},
           {"name":"kind","label":"Kind","type":"string","options":{"strict":true,"choices":[{"value":"day"},{"value":"night"}]}},
           {"name":"workplace","type":"string"},
           {"name":"broken","type":7}
         ]}}
        """
        return try! JSONDecoder().decode(CmsMutationDef.self, from: Data(json.utf8))
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = london
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testDecodesTheContractAndDropsABadInput() {
        let inputs = mutation.action?.inputs ?? []
        XCTAssertEqual(inputs.map(\.name), ["job", "day", "starts", "hours", "breaks", "paid", "kind", "workplace"])
        XCTAssertEqual(inputs.first?.optionsQuery, CmsActionOptionsQuery(querySlug: "my_jobs", valueColumn: "id", labelColumn: "name"))
    }

    /// Choices that don't say `strict` (most forms' own) are kept: the input
    /// used to fail to decode and leave the form.
    func testChoicesWithoutStrictKeepTheirInput() throws {
        let json = """
        {"enabled":true,"operation":"custom","inputs":[
          {"name":"status","type":"string","choiceStyle":"menu","options":{"choices":[{"value":"confirmed","label":"Confirmed"},{"value":"checked out"}]}}
        ]}
        """
        let action = try JSONDecoder().decode(CmsActionConfigDef.self, from: Data(json.utf8))
        XCTAssertEqual(action.inputs?.map(\.name), ["status"])
        XCTAssertEqual(action.inputs?.first?.options, CmsColumnOptions(choices: [CmsColumnChoice(value: "confirmed", label: "Confirmed"), CmsColumnChoice(value: "checked out")], strict: false))
    }

    func testAsksForInputsTheButtonAndSourcesDoNotSupply() {
        let asked = CmsActionForm.askedInputs(mutation, paramMap: ["kind": .object(["source": .string("static"), "value": .string("day")])])
        XCTAssertEqual(asked.map(\.name), ["job", "day", "starts", "hours", "breaks", "paid"])
        var plain = mutation
        plain.action = nil
        XCTAssertTrue(CmsActionForm.askedInputs(plain, paramMap: nil).isEmpty)
        XCTAssertTrue(CmsActionForm.askedInputs(nil, paramMap: nil).isEmpty)
    }

    func testControls() {
        let controls = (mutation.action?.inputs ?? []).map(CmsActionForm.control(for:))
        XCTAssertEqual(controls, [.choice, .date, .dateTime, .number, .number, .toggle, .choice, .text])
    }

    func testFormats() {
        XCTAssertEqual(CmsActionForm.dateString(date(2026, 10, 27, 23, 30), timeZone: london), "2026-10-27")
        XCTAssertEqual(CmsActionForm.timestampString(date(2026, 10, 27, 9), timeZone: london), "2026-10-27T09:00:00+00:00")
        XCTAssertEqual(CmsActionForm.timestampString(date(2026, 7, 1, 9, 30), timeZone: london), "2026-07-01T09:30:00+01:00")
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        XCTAssertEqual(CmsActionForm.timestampString(date(2026, 10, 27, 9), timeZone: kolkata), "2026-10-27T14:30:00+05:30")
        XCTAssertEqual(CmsActionForm.numberString(5), "5")
        XCTAssertEqual(CmsActionForm.numberString(7.5), "7.5")
    }

    func testFilledFormBecomesTypedParams() {
        let asked = CmsActionForm.askedInputs(mutation, paramMap: nil).filter { $0.name != "kind" }
        let draft: [String: CmsActionForm.Draft] = [
            "job": .text("42"), "day": .date(date(2026, 10, 27)), "starts": .date(date(2026, 10, 27, 9)),
            "hours": .text("7,5"), "breaks": .text(""), "paid": .bool(true),
        ]
        let v = CmsActionForm.validate(asked, draft: draft, timeZone: london)
        XCTAssertEqual(v.errors, [])
        XCTAssertTrue(v.ready)
        let params = CmsActionForm.typedParams(asked, values: v.values)
        let wire = { (value: CmsJSON, type: String) in CmsJSON.object(["value": value, "type": .string(type)]) }
        XCTAssertEqual(params, [
            "job": wire(.string("42"), "string"),
            "day": wire(.string("2026-10-27"), "date"),
            "starts": wire(.string("2026-10-27T09:00:00+00:00"), "timestamp"),
            "hours": wire(.string("7.5"), "float"),
            "breaks": wire(.null, "integer"),
            "paid": wire(.string("true"), "boolean"),
        ])
    }

    func testSaveWaitsForRequiredInputs() {
        let asked = CmsActionForm.askedInputs(mutation, paramMap: nil)
        let v = CmsActionForm.validate(asked, draft: [:], timeZone: london)
        XCTAssertFalse(v.ready)
        XCTAssertEqual(v.missing, ["job", "day", "starts", "hours"])
        // A required date or time opens filled (a picker always shows one).
        let opened = CmsActionForm.initialDraft(asked, now: date(2026, 10, 27, 9, 20))
        if case .date(let d)? = opened["starts"] { XCTAssertNotNil(d) } else { XCTFail("starts") }
        if case .date(let d)? = opened["day"] { XCTAssertNotNil(d) } else { XCTFail("day") }
        XCTAssertEqual(opened["paid"], .bool(false))
    }

    func testSharedRulesRefuseBadValues() {
        let asked = CmsActionForm.askedInputs(mutation, paramMap: nil)
        let v = CmsActionForm.validate(asked, draft: [
            "job": .text("1"), "day": .date(date(2026, 1, 1)), "starts": .date(date(2026, 1, 1, 9)),
            "hours": .text("-1"), "breaks": .text("1.5"), "kind": .text("dusk"),
        ], timeZone: london)
        XCTAssertEqual(Set(v.errors.map(\.field)), ["hours", "breaks", "kind"])
        XCTAssertEqual(v.errors.first { $0.field == "hours" }?.message, "Hours must be at least 0.")
        XCTAssertEqual(v.errors.first { $0.field == "breaks" }?.message, "Breaks must be a valid integer.")
        XCTAssertEqual(v.errors.first { $0.field == "kind" }?.message, "Kind must be one of: day, night.")
    }

    func testValidatesStoredStringsLikeTheWeb() {
        let date = CmsActionInputDef(name: "d", type: "date")
        let stamp = CmsActionInputDef(name: "t", type: "timestamp")
        let json = CmsActionInputDef(name: "j", type: "json")
        let bad = CmsActionForm.validateValues([date, stamp, json], ["d": .string("2026-02-30"), "t": .string("2026-10-27T09:00"), "j": .string("{")])
        XCTAssertEqual(bad.errors.map(\.field), ["d", "t", "j"])
        let good = CmsActionForm.validateValues([date, stamp, json], ["d": .string("2026-02-28"), "t": .string("2026-10-27T09:00:00Z"), "j": .string("[1]")])
        XCTAssertEqual(good.errors, [])
    }

    func testQueryChoicesAreOfferedNotEnforced() {
        let input = CmsActionInputDef(name: "job", type: "string",
                                      options: CmsColumnOptions(choices: [CmsColumnChoice(value: "a")], strict: true),
                                      optionsQuery: CmsActionOptionsQuery(querySlug: "q", valueColumn: "id"))
        XCTAssertEqual(CmsActionForm.validateValues([input], ["job": .string("zz")]).errors, [])
        var strict = input
        strict.optionsQuery = nil
        XCTAssertEqual(CmsActionForm.validateValues([strict], ["job": .string("zz")]).errors.count, 1)
    }

    func testOptionsFromRows() {
        let rows: [[String: CmsJSON]] = [
            ["id": .number(1), "name": .string("Café")], ["id": .number(2), "name": .null],
            ["id": .number(1), "name": .string("dup")], ["id": .null, "name": .string("x")],
        ]
        let options = CmsActionForm.options(from: rows, query: CmsActionOptionsQuery(querySlug: "q", valueColumn: "id", labelColumn: "name"))
        XCTAssertEqual(options.map(\.value), ["1", "2"])
        XCTAssertEqual(options.map(\.label), ["Café", "2"])
    }

    // MARK: - after (an end after its start)

    private var ordered: [CmsActionInputDef] {
        let json = """
        [{"name":"starts_at","label":"Start","type":"timestamp","required":true},
         {"name":"ends_at","label":"End","type":"timestamp","required":true,"after":"starts_at"},
         {"name":"from","type":"date"},
         {"name":"to","type":"date","after":{"input":"from","message":"The last day is before the first."}},
         {"name":"low","type":"float"},
         {"name":"high","type":"integer","after":"low"}]
        """
        return try! JSONDecoder().decode([CmsActionInputDef].self, from: Data(json.utf8))
    }

    func testDecodesAfterAsANameOrAnObject() {
        XCTAssertEqual(ordered[1].after, CmsActionAfter(input: "starts_at"))
        XCTAssertEqual(ordered[3].after, CmsActionAfter(input: "from", message: "The last day is before the first."))
    }

    func testAnEndBeforeItsStartKeepsSaveOff() {
        let v = CmsActionForm.validate(ordered, draft: [
            "starts_at": .date(date(2026, 11, 30, 12)), "ends_at": .date(date(2026, 10, 31, 18)),
        ], timeZone: london)
        XCTAssertFalse(v.ready)
        XCTAssertEqual(v.errors, [CmsActionForm.Issue(field: "ends_at", message: "End must be after Start.")])
        let equal = CmsActionForm.validate(ordered, draft: ["starts_at": .date(date(2026, 10, 27, 9)), "ends_at": .date(date(2026, 10, 27, 9))], timeZone: london)
        XCTAssertEqual(equal.errors.map(\.field), ["ends_at"])
        let later = CmsActionForm.validate(ordered, draft: ["starts_at": .date(date(2026, 10, 27, 9)), "ends_at": .date(date(2026, 10, 27, 17))], timeZone: london)
        XCTAssertTrue(later.ready)
    }

    func testOrdersDatesAndNumbersWithAnInputsOwnMessage() {
        let issues = CmsActionForm.orderIssues(ordered, [
            "from": .string("2026-10-28"), "to": .string("2026-10-27"), "low": .number(2.5), "high": .string("2"),
        ])
        XCTAssertEqual(issues, [
            CmsActionForm.Issue(field: "to", message: "The last day is before the first."),
            CmsActionForm.Issue(field: "high", message: "high must be after low."),
        ])
        // Instants, not text, across zones; nothing until both have a value.
        XCTAssertEqual(CmsActionForm.orderIssues(ordered, ["starts_at": .string("2026-10-27T09:00:00+01:00"), "ends_at": .string("2026-10-27T08:30:00Z")]), [])
        XCTAssertEqual(CmsActionForm.orderIssues(ordered, ["starts_at": .string("2026-10-27T09:00:00+01:00"), "ends_at": .string("2026-10-27T08:00:00Z")]).count, 1)
        XCTAssertEqual(CmsActionForm.orderIssues(ordered, ["starts_at": .string("2026-10-27T09:00:00Z")]), [])
    }

    func testARequiredEndOpensAnHourAfterItsStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        let draft = CmsActionForm.initialDraft(ordered, now: date(2026, 10, 27, 9, 20), calendar: calendar)
        guard case .date(let start?)? = draft["starts_at"], case .date(let end?)? = draft["ends_at"] else { return XCTFail("dates") }
        XCTAssertEqual(start, date(2026, 10, 27, 10))
        XCTAssertEqual(end, date(2026, 10, 27, 11))
        XCTAssertTrue(CmsActionForm.validate(ordered, draft: draft, timeZone: london).ready)
    }

    func testTheEarliestALaterValueMayBe() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        XCTAssertEqual(CmsActionForm.earliest(after: date(2026, 10, 27, 9), control: .dateTime), date(2026, 10, 27, 9, 1))
        XCTAssertEqual(CmsActionForm.earliest(after: date(2026, 10, 27, 9), control: .date, calendar: calendar), date(2026, 10, 28))
    }

    /// A mutation with hidden, computed or filling inputs opens the record form even without a layout:
    /// the plain list would draw a hidden input as a field and never fill it (WAC in, 31 October 2026).
    func testOpensRecordForm() throws {
        func def(_ inputs: String, form: String = "") throws -> CmsMutationDef {
            try JSONDecoder().decode(CmsMutationDef.self, from: Data(#"{"slug":"m","action":{"enabled":true,"inputs":\#(inputs)\#(form)}}"#.utf8))
        }
        XCTAssertFalse(try def(#"[{"name":"note","type":"string"}]"#).opensRecordForm)
        XCTAssertTrue(try def(#"[{"name":"note","type":"string"}]"#, form: #","form":{"computed":{"a":"1"}}"#).opensRecordForm)
        XCTAssertTrue(try def(#"[{"name":"job_id","type":"integer","hidden":true}]"#).opensRecordForm)
        XCTAssertTrue(try def(#"[{"name":"rate","type":"string","fromComputed":"r"}]"#).opensRecordForm)
        XCTAssertTrue(try def(#"[{"name":"pick","type":"string","optionsQuery":{"querySlug":"q","valueColumn":"id","fills":{"job_id":"job_id"}}}]"#).opensRecordForm)
    }
}
