import XCTest
@testable import RipulAgent

/// The record form (docs/plans/cms-record-form.md): its layout and computed
/// values decoded, the expression language, formats and templates, list
/// inputs, a draft filled from a row, and what is sent.
final class CmsRecordFormTests: XCTestCase {
    private func json<T: Decodable>(_ type: T.Type, _ s: String) -> T {
        try! JSONDecoder().decode(type, from: Data(s.utf8))
    }

    /// A shift: job (with a rate), start, end, breaks (seconds, paid), notes.
    private var shift: CmsActionConfigDef {
        json(CmsActionConfigDef.self, #"""
        { "inputs": [
            { "name": "id", "type": "integer", "hidden": true },
            { "name": "job", "type": "string", "required": true,
              "optionsQuery": { "querySlug": "my_jobs", "valueColumn": "id", "labelColumn": "name", "imageColumn": "logo",
                                "image": { "chain": [ { "source": "logo", "from": "name" } ] } } },
            { "name": "start", "type": "timestamp", "required": true, "look": "tile" },
            { "name": "end", "type": "timestamp", "required": true, "look": "tile", "after": "start" },
            { "name": "breaks", "type": "list", "addLabel": "Add break", "removedItems": { "flag": "_destroy" },
              "fields": [
                { "name": "total_break_time", "type": "integer", "unit": "seconds" },
                { "name": "is_paid_break", "type": "boolean" },
                { "name": "break_type", "type": "string", "hidden": true, "defaultValue": "quick_break" } ] },
            { "name": "notes", "type": "string", "multiline": true } ],
          "form": { "title": "{worked|duration}",
            "computed": {
              "worked": "minutes(start, end) - sum(breaks, total_break_time * (1 - is_paid_break)) / 60",
              "pay": "round(worked / 60 * job.rate, 2)" },
            "sections": [
              { "items": [ "job", { "row": ["start", "breaks", "end"] } ] },
              { "heading": "Notes", "collapsible": true, "items": ["notes"] },
              { "heading": "Earnings", "items": [],
                "summary": { "lines": [ { "label": "Base pay", "detail": "{worked|duration} × {job.rate|0.00}", "amount": "{pay|0.00}", "input": "job" } ],
                             "total": { "label": "Total", "amount": "{pay|0.00}" } } } ] } }
        """#)
    }

    // MARK: Decoding

    func testTheFormAndComputedDecode() {
        let config = shift
        XCTAssertEqual(config.form?.title, "{worked|duration}")
        XCTAssertEqual(config.form?.sections.count, 3)
        XCTAssertEqual(config.form?.sections[0].items, [.input("job"), .row(["start", "breaks", "end"])])
        XCTAssertEqual(config.form?.sections[1].collapsible, true)
        XCTAssertEqual(config.form?.sections[1].collapsed, true, "collapsible starts closed")
        XCTAssertEqual(config.inputs?.first { $0.name == "job" }?.optionsQuery?.imageColumn, "logo", "a choice's picture on its optionsQuery")
        if case .summary(let lines, let total)? = config.form?.sections[2].items.first {
            XCTAssertEqual(lines.first?.input, "job", "a line can be an input in disguise")
            XCTAssertEqual(total?.label, "Total")
        } else { XCTFail("a summary") }
        XCTAssertEqual(config.form?.computed.map(\.name), ["pay", "worked"], "form.computed: { name: expression }")
        let breaks = config.inputs?.first { $0.name == "breaks" }
        XCTAssertEqual(breaks?.fields?.map(\.name), ["total_break_time", "is_paid_break", "break_type"])
        XCTAssertEqual(breaks?.removedItems?.flag, "_destroy")
        XCTAssertEqual(breaks?.fields?.first?.unit, "seconds")
        XCTAssertEqual(config.form?.namesUsed, ["job", "start", "breaks", "end", "notes", "job"])
        XCTAssertEqual(CmsActionForm.control(for: breaks!), .list)
        XCTAssertEqual(CmsActionForm.control(for: breaks!.fields![0]), .duration)
        XCTAssertEqual(CmsActionForm.control(for: config.inputs!.first { $0.name == "notes" }!), .multiline)
    }

    // MARK: Expressions

    func testTheExpressionLanguage() {
        let scope = CmsFormScope(
            number: { ["a": 6, "b": 4, "rate": 11][$0] },
            moment: { ["s": Date(timeIntervalSince1970: 0), "e": Date(timeIntervalSince1970: 8 * 3600)][$0] },
            items: { $0 == "breaks" ? [["m": .number(30), "paid": .bool(false)], ["m": .number(15), "paid": .bool(true)]] : [] })
        func eval(_ s: String) -> Double? { scope.evaluate(CmsFormExpr.parse(s)!) }
        XCTAssertEqual(eval("a + b * 2"), 14, "× before +")
        XCTAssertEqual(eval("(a + b) * 2"), 20)
        XCTAssertNil(eval("a / 0"), "division by 0 is blank")
        XCTAssertNil(eval("-a + missing"), "a blank name makes the arithmetic blank, as on the web")
        XCTAssertEqual(eval("a + coalesce(missing, 0)"), 6, "coalesce: the first that isn't blank")
        XCTAssertEqual(eval("coalesce(missing, b, a)"), 4)
        XCTAssertNil(eval("coalesce(missing, nothing)"), "blank only if all are")
        XCTAssertEqual(eval("a + true"), 7, "a truth counts as 1")
        XCTAssertEqual(eval("sum(breaks, m * (1 - paid))"), 30, "sum(list, expr): per item, the item's field first")
        XCTAssertEqual(eval("sum(breaks, m * rate / 15)"), 33, "then the form's own names")
        XCTAssertEqual(eval("minutes(s, e)"), 480)
        XCTAssertNil(eval("minutes(s, nowhere)"))
        XCTAssertEqual(eval("sum(breaks.m)"), 45)
        XCTAssertEqual(eval("count(breaks)"), 2)
        XCTAssertEqual(eval("round(10 / 3, 2)"), 3.33)
        XCTAssertEqual(eval("max(a, b) - min(a, b)"), 2)
        XCTAssertEqual(eval("a × b ÷ 2"), 12, "the plan's signs read too")
        XCTAssertNil(CmsFormExpr.parse("a +"), "an expression that doesn't read")
        XCTAssertEqual(CmsFormExpr.parse("round(job.rate * hours)")?.names, ["job.rate", "hours"])
    }

    func testFormatsAndTemplates() {
        XCTAssertEqual(CmsFormText.duration(480), "8h")
        XCTAssertEqual(CmsFormText.duration(450), "7h 30m")
        XCTAssertEqual(CmsFormText.duration(0), "0m")
        XCTAssertEqual(CmsFormText.show(number: 88, format: "0.00"), "88.00")
        XCTAssertEqual(CmsFormText.show(number: nil, truth: false, format: "Paid;Unpaid"), "Unpaid")
        XCTAssertEqual(CmsFormText.fill("{a} and {b|x}") { name, format in name + (format ?? "") }, "a and bx")
    }

    // MARK: The live values

    func testComputedValuesReadInputsTheChosenRowAndLists() {
        let config = shift
        let inputs = config.inputs!
        var draft = CmsActionForm.initialDraft(inputs)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        draft["start"] = .date(start)
        draft["end"] = .date(start.addingTimeInterval(8 * 3600 + 30 * 60))
        draft["job"] = .text("7")
        draft["breaks"] = .list([["total_break_time": .number(1800), "is_paid_break": .bool(false)],
                                 ["total_break_time": .number(900), "is_paid_break": .bool(true)]], removed: [])
        let values = CmsFormValues(inputs: inputs, computed: config.form!.computed, draft: draft,
                                   chosenRow: { $0 == "job" ? ["id": .number(7), "rate": .number(11)] : nil })
        XCTAssertEqual(values.number("worked"), 480, "8h 30m less the 30m unpaid break")
        XCTAssertEqual(values.fill(config.form!.title!), "8h", "the title")
        XCTAssertEqual(values.number("pay"), 88)
        XCTAssertEqual(values.fill("{worked|duration} × {job.rate|0.00}"), "8h × 11.00", "a chosen option's column")
        XCTAssertEqual(values.fill("{pay|0.00}"), "88.00", "a format in the slot")
        XCTAssertEqual(values.fillComplete("{worked|duration} × {job.rate|0.00}"), "8h × 11.00")
        let noJob = CmsFormValues(inputs: inputs, computed: config.form!.computed, draft: draft, chosenRow: { _ in nil })
        XCTAssertNil(noJob.fillComplete("{worked|duration} × {job.rate|0.00}"),
                     "a summary detail with a blank slot is hidden (no job chosen yet)")
        XCTAssertEqual(values.fill("{pay}"), "88", "unformatted: at most 2 decimal places")
        let breaks = inputs.first { $0.name == "breaks" }!
        XCTAssertEqual(CmsFormValues.itemText(nil, item: ["total_break_time": .number(1800), "is_paid_break": .bool(false),
                                                          "break_type": .string("quick_break")], fields: breaks.fields!), "30 min",
                       "the web's reading: visible fields joined, a duration in words, a false truth left out")
        XCTAssertEqual(CmsFormValues.itemText(nil, item: ["total_break_time": .number(4500), "is_paid_break": .bool(true)],
                                              fields: breaks.fields!), "1 h 15 min · is_paid_break", "a true truth reads as its label")
    }

    // MARK: Filled from a row, and sent

    func testADraftFilledFromARowAndWhatIsSent() {
        let config = shift
        let inputs = config.inputs!
        let row: [String: CmsJSON] = [
            "id": .string("42"),
            "job": .string("7"),
            "start": .string("2026-10-29T09:00:00Z"),
            "end": .string("2026-10-29 17:00:00"),
            // An endpoint read's nested array arrives as JSON text.
            "breaks": .string(#"[{"id":5,"break_type":"quick_break","total_break_time":1800,"is_paid_break":false}]"#),
            "notes": .null,
        ]
        let draft = CmsActionForm.draft(inputs, values: row)
        XCTAssertEqual(CmsActionForm.listItems(draft["breaks"]).first?["id"], .number(5), "an item keeps its own key")
        if case .date(let d)? = draft["end"] { XCTAssertNotNil(d, "a zoneless timestamp reads on the viewer's clock") }
        XCTAssertEqual(draft["job"], .text("7"))

        // A break removed: sent as { id, _destroy: true }.
        var edited = draft
        edited["breaks"] = .list([], removed: CmsActionForm.listItems(draft["breaks"]))
        let check = CmsActionForm.validate(inputs, draft: edited)
        XCTAssertEqual(check.values["breaks"], .array([.object(["id": .number(5), "_destroy": .bool(true)])]))
        XCTAssertEqual(check.values["notes"], .null)
        let params = CmsActionForm.typedParams(inputs, values: check.values)
        XCTAssertEqual(params["breaks"]?.objectValue?["value"], .string(#"[{"_destroy":true,"id":5}]"#),
                       "a list goes as its JSON text, as a json input does")
        // Without removedItems a removed item is left out.
        var plain = inputs.first { $0.name == "breaks" }!
        plain.removedItems = nil
        XCTAssertEqual(CmsActionForm.listWire(plain, items: [], removed: [["id": .number(5)]]), .array([]))
    }

    @MainActor
    func testARunsWarningShowsBesideTheSuccessMessage() {
        let runtime = CmsRuntime(cmsId: "cms_test", client: CmsClient(config: CmsClientConfig(getToken: { nil })))
        runtime.showWarning("Step 1 (PUT /api/v1/track_hours/42.json) wasn't saved: 422")
        runtime.showNotice("Entry added")
        let shown = expectation(description: "both")
        DispatchQueue.main.async {
            XCTAssertEqual(runtime.notice?.message, "Entry added")
            XCTAssertEqual(runtime.notice?.warning, "Step 1 (PUT /api/v1/track_hours/42.json) wasn't saved: 422",
                           "the warning stays beside the success message")
            shown.fulfill()
        }
        wait(for: [shown], timeout: 1)
    }

    func testARowFormSpec() {
        let spec = CmsRowFormSpec(.object([
            "mutationSlug": .string("edit_shift"), "deleteMutationSlug": .string("delete_shift"),
            "values": .object(["id": .string("{id}"), "start": .string("{starts_at}")]),
            "load": .object(["querySlug": .string("shift_detail"), "params": .object(["id": .string("{id}")])]),
        ]))
        XCTAssertEqual(spec?.mutationSlug, "edit_shift")
        XCTAssertEqual(spec?.deleteMutationSlug, "delete_shift")
        XCTAssertEqual(spec?.values["start"], "{starts_at}")
        XCTAssertEqual(spec?.load?.querySlug, "shift_detail")
        XCTAssertNil(CmsRowFormSpec(.object(["values": .object([:])])), "no mutation, no form")
    }

    /// `picker` (item 9): the input's own, else `form.picker`, else a sheet; an unknown value counts as unset.
    func testADatePickersStyle() {
        let config = json(CmsActionConfigDef.self, #"""
        { "inputs": [
            { "name": "start", "type": "timestamp" },
            { "name": "end", "type": "timestamp", "picker": "inline" },
            { "name": "day", "type": "date", "picker": "wobbly" } ],
          "form": { "picker": "floating", "sections": [ { "items": [ { "row": ["start", "end"] } ] } ] } }
        """#)
        let form = config.form
        XCTAssertEqual(form?.picker, "floating")
        let inputs = Dictionary(uniqueKeysWithValues: (config.inputs ?? []).map { ($0.name, $0) })
        XCTAssertEqual(CmsDatePickerStyle.resolve(inputs["start"]!, form: form), .floating)
        XCTAssertEqual(CmsDatePickerStyle.resolve(inputs["end"]!, form: form), .inline)
        XCTAssertEqual(CmsDatePickerStyle.resolve(inputs["day"]!, form: form), .floating)
        XCTAssertEqual(CmsDatePickerStyle.resolve(inputs["start"]!, form: nil), .sheet)
        XCTAssertEqual(CmsDatePickerStyle.resolve(inputs["end"]!, form: nil), .inline)
        // Kept when stored.
        let again = try! JSONDecoder().decode(CmsFormDef.self, from: JSONEncoder().encode(form!))
        XCTAssertEqual(again.picker, "floating")
        XCTAssertEqual(inputs["end"]!.picker, "inline")
    }
}
