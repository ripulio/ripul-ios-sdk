import XCTest
@testable import RipulAgent

/// A Calendar Strip day's details against the table both renderers share:
/// `chrome-extension/packages/shared-types/src/cmsCalendarDayDetails.cases.json`
/// (the web runs it in cmsCalendarDayDetails.test.ts).
final class CmsCalendarDayDetailsTests: XCTestCase {
    typealias D = CmsCalendarDayDetails

    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsCalendarDayDetails.cases.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func json(_ any: Any?) -> CmsJSON? {
        guard let any else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try! JSONDecoder().decode(CmsJSON.self, from: data)
    }

    private func props(_ raw: Any?) -> [String: CmsJSON] {
        json(raw)?.objectValue ?? [:]
    }

    /// The parts of the resolved details the table writes.
    private func summary(_ c: D.Config?) -> NSDictionary? {
        guard let c else { return nil }
        let tap: Any
        switch c.rowTap {
        case .form?: tap = "form"
        case .page?: tap = "page"
        case nil: tap = NSNull()
        }
        return NSDictionary(dictionary: [
            "title": c.title, "max": c.max, "empty": c.empty.rawValue, "rowTap": tap,
            "addLabel": c.add?.label ?? NSNull(), "listStyle": c.listStyle ?? NSNull(),
            "querySlug": c.querySlug ?? NSNull(), "dateColumn": c.dateColumn ?? NSNull(),
            "colorColumn": c.colorColumn ?? NSNull(),
        ])
    }

    func testResolveCases() {
        let list = Self.table["resolve"] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty)
        for c in list {
            let name = c["name"] as? String ?? "?"
            let p = props(c["props"])
            let expect = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(D.tapAction(p).rawValue, expect["onDayTap"] as? String, name)
            let got = summary(D.Config(p["dayDetails"]))
            if let want = expect["details"] as? [String: Any] {
                XCTAssertEqual(got, NSDictionary(dictionary: want), name)
            } else {
                XCTAssertNil(got, name)
            }
        }
    }

    func testOutcomeCases() {
        let list = Self.table["outcomes"] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty)
        for c in list {
            let name = c["name"] as? String ?? "?"
            var raw: [String: Any] = ["row": ["title": "{x}"]]
            if let e = c["empty"] as? String { raw["empty"] = e }
            if c["add"] as? Bool == true { raw["add"] = ["form": ["mutationSlug": "add"]] }
            let details = (c["details"] as? Bool == true) ? D.Config(json(raw)) : nil
            let tap = D.TapAction(rawValue: c["onDayTap"] as? String ?? "") ?? .select
            let outcome = D.outcome(tap, details: details, rows: c["rows"] as? Int ?? 0)
            let expect = c["expect"] as? [String: Bool] ?? [:]
            XCTAssertEqual(outcome.select, expect["select"], name)
            XCTAssertEqual(outcome.open, expect["open"], name)
        }
    }

    func testTitleCases() {
        let list = Self.table["titles"] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let friday = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
        for c in list {
            let template = c["template"] as? String ?? ""
            let title = D.title(template, count: c["count"] as? Int ?? 0) { pattern in
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_GB")
                f.calendar = cal
                f.timeZone = cal.timeZone
                f.dateFormat = pattern
                return f.string(from: friday)
            }
            XCTAssertEqual(title, c["expect"] as? String, template)
        }
    }

    func testInitialCases() {
        let list = Self.table["initials"] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty)
        for c in list {
            let name = c["name"] as? String ?? "?"
            let got = D.initial(pictureText: c["pictureText"] as? String ?? "", title: c["title"] as? String ?? "",
                                ownColor: json(c["ownColor"] is NSNull ? nil : c["ownColor"]))
            if let want = c["expect"] as? [String: String] {
                XCTAssertEqual(got?.letter, want["letter"], name)
                XCTAssertEqual(got?.color, want["color"], name)
            } else {
                XCTAssertNil(got, name)
            }
        }
    }

    func testMoreCases() {
        let list = Self.table["more"] as? [[Any]] ?? []
        XCTAssertFalse(list.isEmpty)
        for c in list where c.count == 3 {
            XCTAssertEqual(D.moreText(total: c[0] as? Int ?? 0, max: c[1] as? Int ?? 0), c[2] as? String)
        }
    }
}
