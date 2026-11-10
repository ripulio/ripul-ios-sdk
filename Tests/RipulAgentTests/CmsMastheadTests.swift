import XCTest
@testable import RipulAgent

/// Masthead styles, a page's masthead and how a form opens, against the table
/// both renderers share: `chrome-extension/packages/shared-types/src/cmsMasthead.cases.json`
/// (the web runs the same file in cmsMasthead.test.ts).
final class CmsMastheadTests: XCTestCase {
    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsMasthead.cases.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

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

    func testStyles() {
        for c in cases("styles") {
            let name = c["name"] as! String
            let theme = decode(CmsPortalThemeConfig.self, c["theme"])
            let got = CmsMasthead.style(theme, named: c["style"] as? String)
            let expect = c["expect"] as! [String: Any]
            if let v = expect["name"] as? String { XCTAssertEqual(got.name, v, name) }
            if let v = expect["fill"] as? String { XCTAssertEqual(got.fill?.rawValue ?? "gradient", v, name) }
            if let v = expect["text"] as? String { XCTAssertEqual(got.text.rawValue, v, name) }
            if let v = expect["align"] as? String { XCTAssertEqual(got.centred ? "center" : "leading", v, name) }
            if let v = expect["scroll"] as? String { XCTAssertEqual(got.scroll, v, name) }
            if let v = expect["cut"] as? String { XCTAssertEqual(got.cut, v, name) }
            for (key, path) in [("titleSize", \CmsMasthead.Style.titleSize), ("height", \.height), ("overlap", \.overlap),
                                ("padding", \.padding), ("subtitleOpacity", \.subtitleOpacity), ("titleWeight", \.titleWeight),
                                ("subtitleSize", \.subtitleSize)] {
                if let v = expect[key] as? Double { XCTAssertEqual(got[keyPath: path], v, "\(name): \(key)") }
            }
        }
    }

    func testPages() {
        for c in cases("pages") {
            let name = c["name"] as! String
            let blocks = decode(CmsPageBlocks.self, c["blocks"])
            let masthead = decode(CmsJSON.self, c["masthead"])
            let theme = decode(CmsPortalThemeConfig.self, c["theme"])
            let out = CmsMasthead.withMasthead(blocks, masthead: masthead, title: c["title"] as? String, theme: theme)
            var list = out
            if let slot = c["expectSlot"] as? String, case .sidebar(_, let slots, _)? = out { list = slots[slot] }
            guard case .list(let items, _)? = list, let first = items.first else { return XCTFail(name) }
            XCTAssertEqual(first.id, c["expectFirst"] as? String, name)
            if let props = c["expectProps"] as? [String: String] {
                for (k, v) in props { XCTAssertEqual(first.props.string(k), v, "\(name): \(k)") }
            }
            if let frame = c["expectFrame"] as? [String: Any] {
                XCTAssertEqual(first.frame?.bleed, frame["bleed"] as? Bool, name)
                XCTAssertEqual(first.frame?.pin, frame["pin"] as? String, name)
                XCTAssertEqual(first.frame?.overlap, frame["overlap"] as? Double, name)
                XCTAssertEqual(first.frame?.pinKeep, frame["pinKeep"] as? Double, name)
                XCTAssertEqual(first.frame?.pinUnder, frame["pinUnder"] as? String, name)
            }
        }
    }

    func testPresentation() {
        for c in cases("presentation") {
            let name = c["name"] as! String
            let theme = decode(CmsPortalThemeConfig.self, c["theme"])
            let form = (c["form"] as? [String: Any])?["presentation"] as? String
            let got = CmsMasthead.presentation(form: form, theme: theme, viewer: c["viewer"] as? String)
            XCTAssertEqual(got.rawValue, c["expect"] as? String, name)
        }
    }

    func testAppliedPageHidesItsTitleAndRunsOnce() throws {
        let json = #"{"id":"p","slug":"account","title":"Account","bodyType":"blocks","masthead":true,"blocks":{"layout":"list","items":[{"id":"a","type":"cards","props":{}}]}}"#
        let page = try JSONDecoder().decode(CmsPage.self, from: Data(json.utf8))
        let once = CmsMasthead.applied(page, theme: nil)
        let twice = CmsMasthead.applied(once, theme: nil)
        XCTAssertEqual(once.titleDisplay, "hidden")
        guard case .list(let items, _)? = twice.blocks else { return XCTFail() }
        XCTAssertEqual(items.map(\.id), ["page_masthead", "a"])
    }

    func testFormDecodesPresentation() throws {
        let form = try JSONDecoder().decode(CmsFormDef.self, from: Data(#"{"presentation":"page","masthead":false,"subtitle":"{n} days"}"#.utf8))
        XCTAssertEqual(form.presentation, "page")
        XCTAssertTrue(form.mastheadOff)
        XCTAssertEqual(form.subtitle, "{n} days")
        let again = try JSONDecoder().decode(CmsFormDef.self, from: JSONEncoder().encode(form))
        XCTAssertTrue(again.mastheadOff)
    }

    func testBuiltInSlotsInTheBand() {
        CmsLevers.now = { ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z")! }
        defer { CmsLevers.now = { Date() } }
        XCTAssertEqual(CmsMastheadBand.fill("Hi {unknown}"), "Hi {unknown}")
        XCTAssertFalse(CmsMastheadBand.fill("{today|yyyy}").contains("{"))
    }
}
