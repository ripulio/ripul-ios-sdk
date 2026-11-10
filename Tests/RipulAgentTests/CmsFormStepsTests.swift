import XCTest
@testable import RipulAgent

/// Form steps, `showWhen`, waiting and creatable choices against the table
/// both renderers share: `chrome-extension/packages/shared-types/src/cmsFormSteps.cases.json`
/// (the web runs the same file in cmsFormSteps.test.ts). The `body` cases are
/// the worker's and are left out here.
final class CmsFormStepsTests: XCTestCase {
    typealias S = CmsFormSteps

    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsFormSteps.cases.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func json(_ any: Any?) -> CmsJSON? {
        guard let any, !(any is NSNull) else { return any is NSNull ? .null : nil }
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try! JSONDecoder().decode(CmsJSON.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ any: Any?) -> T? {
        guard let any, !(any is NSNull) else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func cases(_ key: String) -> [[String: Any]] {
        let list = Self.table[key] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty, "the table has \(key) cases")
        return list
    }

    private func inputs(_ c: [String: Any]) -> [CmsActionInputDef] { decode([CmsActionInputDef].self, c["inputs"]) ?? [] }
    private func values(_ c: [String: Any], _ key: String = "values") -> [String: CmsJSON] { json(c[key])?.objectValue ?? [:] }

    func testWhenOne() {
        for c in cases("whenOne") {
            let name = c["name"] as! String
            let query = decode(CmsActionOptionsQuery.self, (c["options"] as! [String: Any]).merging(["querySlug": "q"]) { a, _ in a })
            let st = c["state"] as! [String: Any]
            let rows: S.ChoiceRows
            switch st["state"] as! String {
            case "ok": rows = .rows(json(st["rows"])?.arrayValue?.compactMap(\.objectValue) ?? [])
            case "error": rows = .error
            default: rows = .loading
            }
            let got = S.whenOne(query, rows)
            let expect = c["expect"] as! [String: Any]
            XCTAssertEqual(got.hide, expect["hide"] as! Bool, name)
            if expect.keys.contains("value") {
                let want = expect["value"] as? String
                XCTAssertEqual(got.value, .some(want), name)
            } else {
                XCTAssertNil(got.value, name)
            }
        }
    }

    func testChoiceStyle() {
        for c in cases("choiceStyle") {
            let name = c["name"] as! String
            let input = decode(CmsActionInputDef.self, (c["input"] as? [String: Any]).map { $0.merging(["name": "x", "type": "string"]) { a, _ in a } })
            guard let input else { return XCTFail("\(name): input") }
            XCTAssertEqual(CmsActionForm.choiceStyle(input, themeInputs: json(c["themeInputs"])), c["expect"] as? String, name)
        }
    }

    func testEmptyChoice() {
        for c in cases("emptyChoice") {
            let name = c["name"] as! String
            let input = decode(CmsActionInputDef.self, (c["input"] as? [String: Any]).map { $0.merging(["name": "x", "type": "string"]) { a, _ in a } })
            guard let input else { return XCTFail("\(name): input") }
            let want = decode(CmsActionOptionsQuery.EmptyChoice.self, c["expect"])
            XCTAssertEqual(CmsActionForm.emptyChoice(input), want, name)
        }
    }

    func testChoiceTile() {
        for c in cases("choiceTile") {
            let name = c["name"] as! String
            let expect = c["expect"] as! [String: String]
            let key = c["key"] as! String
            XCTAssertEqual(CmsDropdownChoice.initials(label: c["label"] as! String, key: key), expect["initials"], name)
            XCTAssertEqual(CmsCalendarDecorations.paletteColor(key), expect["color"], name)
        }
    }

    func testShowWhen() {
        for c in cases("showWhen") {
            let name = c["name"] as! String
            XCTAssertEqual(S.holds(decode(CmsShowWhen.self, c["rule"]), json(c["value"])), c["holds"] as? Bool, name)
        }
    }

    func testHiddenFollowsTheChain() {
        for c in cases("hidden") {
            let name = c["name"] as! String
            XCTAssertEqual(S.hidden(inputs(c), values: values(c)), Set(c["hidden"] as! [String]), name)
        }
    }

    func testVisibleSteps() {
        for c in cases("steps") {
            let name = c["name"] as! String
            let form = decode(CmsFormDef.self, c["form"])
            let got = S.visible(inputs(c), form: form, values: values(c), fixed: Set(c["fixed"] as? [String] ?? []))
            let want = (c["steps"] as! [[String: Any]]).map { ($0["index"] as! Int, $0["inputs"] as! [String]) }
            XCTAssertEqual(got.map(\.index), want.map(\.0), name)
            XCTAssertEqual(got.map(\.inputs), want.map(\.1), name)
        }
    }

    func testValidateSkipsWhatShowWhenKeepsOut() {
        for c in cases("validate") {
            let name = c["name"] as! String
            let check = CmsActionForm.check(inputs(c), supplied: values(c, "supplied"))
            XCTAssertEqual(check.missing, c["missing"] as! [String], name)
            XCTAssertEqual(check.values, values(c), name)
        }
    }

    func testOptionsParams() {
        for c in cases("optionsParams") {
            let name = c["name"] as! String
            let params = c["params"] as? [String: String]
            let result = c["result"] as! [String: Any]
            switch S.optionsParams(params, values: values(c)) {
            case .ready(let got):
                XCTAssertEqual(result["ready"] as? Bool, true, name)
                XCTAssertEqual(got, json(result["params"])?.objectValue ?? [:], name)
            case .waiting(let on):
                XCTAssertEqual(result["ready"] as? Bool, false, name)
                XCTAssertEqual(on, result["waitingOn"] as? [String], name)
            }
        }
    }

    func testDependsOn() {
        for c in cases("dependsOn") {
            XCTAssertEqual(S.dependsOn(c["params"] as? [String: String]), c["names"] as! [String], c["name"] as! String)
        }
    }

    func testCreate() {
        for c in cases("create") {
            let name = c["name"] as! String
            let create = decode(CmsOptionsCreate.self, c["create"])!
            let text = c["text"] as! String
            XCTAssertEqual(S.offersCreate(text, labels: c["labels"] as! [String]), c["offers"] as? Bool, name)
            XCTAssertEqual(S.createLabel(create, text: text), c["label"] as? String, name)
            XCTAssertEqual(S.createParams(create, listParams: values(c, "listParams"), text: text), values(c, "params"), name)
            let chosen = S.createdChoice(create, result: json(c["result"]), text: text)
            if let want = c["choice"] as? [String: String] {
                XCTAssertEqual(chosen?.value, want["value"], name)
                XCTAssertEqual(chosen?.label, want["label"], name)
            } else {
                XCTAssertNil(chosen?.value, name)
            }
        }
    }

    func testProgress() {
        XCTAssertEqual(S.progress(2, of: 4).text, "Step 2 of 4")
        XCTAssertEqual(S.progress(2, of: 4).fraction, 0.5)
        XCTAssertEqual(S.progress(9, of: 4).text, "Step 4 of 4", "held to the count")
    }

    func testTheNewFieldsDecode() {
        let input = decode(CmsActionInputDef.self, [
            "name": "industry_id", "type": "string", "choiceStyle": "list", "searchable": true,
            "showWhen": ["input": "freq", "in": [4, "3"]],
            "optionsQuery": ["querySlug": "industries", "valueColumn": "id", "labelColumn": "name", "descriptionColumn": "blurb",
                             "params": ["q": "{name}"],
                             "create": ["mutationSlug": "create_industry", "input": "name", "valuePath": "industry.id"]],
        ] as [String: Any])
        XCTAssertEqual(input?.choiceStyle, "list")
        XCTAssertEqual(input?.searchable, true)
        XCTAssertEqual(input?.showWhen?.in ?? [], ["4", "3"], "listed numbers compare as text")
        XCTAssertEqual(input?.optionsQuery?.descriptionColumn, "blurb")
        XCTAssertEqual(input?.optionsQuery?.params, ["q": "{name}"])
        XCTAssertEqual(input?.optionsQuery?.create?.mutationSlug, "create_industry")
        let form = decode(CmsFormDef.self, ["progress": "count", "submitLabel": "Add job", "steps": [
            ["title": "Job details", "question": "What's the name?", "nextLabel": "Next",
             "showWhen": ["input": "a", "filled": true], "sections": [["items": ["name"]]]]]] as [String: Any])
        XCTAssertEqual(form?.steps.first?.question, "What's the name?")
        XCTAssertEqual(form?.steps.first?.showWhen?.filled, true)
        XCTAssertEqual(form?.progress, "count")
        XCTAssertEqual(form?.submitLabel, "Add job")
        // Kept when stored.
        let again = try! JSONDecoder().decode(CmsFormDef.self, from: JSONEncoder().encode(form!))
        XCTAssertEqual(again.steps, form?.steps)
    }

    func testChoiceRoles() {
        let t = Self.table["choiceRoles"] as! [String: Any]
        let rows = (json(t["rows"])?.arrayValue ?? []).compactMap(\.objectValue)
        let fills = (t["fills"] as! [[String: Any]])[0]["fills"] as! [String: String]
        var q = CmsActionOptionsQuery(querySlug: "q", valueColumn: "key")
        q.fills = fills
        for c in t["fills"] as! [[String: Any]] {
            let got = q.fillValues(json(c["row"])?.objectValue)
            let expect = c["expect"] as! [String: Any]
            for (k, v) in expect { XCTAssertEqual(got[k] ?? nil, v as? String, "\(c["name"]!): \(k)") }
        }
        for c in t["forFills"] as! [[String: Any]] {
            let values = (c["values"] as! [String: Any]).mapValues { "\($0)" }
            XCTAssertEqual(q.choice(forValues: values, rows: rows), c["expect"] as? String, c["name"] as? String ?? "")
        }
        for c in t["description"] as! [[String: Any]] {
            let query = decode(CmsActionOptionsQuery.self, (c["query"] as! [String: Any]).merging(["querySlug": "q", "valueColumn": "key"]) { a, _ in a })!
            XCTAssertEqual(query.describe(json(c["row"])!.objectValue!), c["expect"] as? String, c["name"] as? String ?? "")
        }
    }

    func testRowFormActions() {
        for c in cases("rowFormActions") {
            let name = c["name"] as! String
            let a = c["action"] as! [String: Any]
            let action = CmsRowFormSpec.Action(label: "x", mutationSlug: "m", values: (a["values"] as? [String: String]) ?? [:])
            let record = json(c["record"])?.objectValue ?? [:]
            let got = CmsRowFormSpec.actionParams(action, inputNames: c["inputs"] as! [String], record: record)
            XCTAssertEqual(got, json(c["expect"])?.objectValue ?? [:], name)
        }
    }
}

