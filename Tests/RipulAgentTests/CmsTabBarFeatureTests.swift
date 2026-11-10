import XCTest
@testable import RipulAgent

/// The tab bar's feature button against the table both renderers share:
/// `chrome-extension/packages/shared-types/src/cmsTabBarFeature.cases.json`
/// (the web runs the same file in cmsTabBarFeature.test.ts).
final class CmsTabBarFeatureTests: XCTestCase {
    private static let table: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/packages/shared-types/src/cmsTabBarFeature.cases.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func json(_ any: Any?) -> CmsJSON? {
        guard let any, !(any is NSNull) else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try? JSONDecoder().decode(CmsJSON.self, from: data)
    }

    private func cases(_ key: String) -> [[String: Any]] {
        let list = Self.table[key] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty, "the table has \(key) cases")
        return list
    }

    func testResolve() {
        for c in cases("resolve") {
            let name = c["name"] as! String
            let button = CmsTabBarFeature(json(c["button"]))!
            let data = c["data"] as? [String: Any] ?? [:]
            let row = json(data["row"])?.objectValue
            let counts = data["rowCounts"] as? [String: Int] ?? [:]
            let failed = data["failed"] as? String
            let previous: String?? = data.keys.contains("previous") ? .some(data["previous"] as? String) : nil
            let got = button.resolve(row: row, rowCount: { counts[$0] }, failed: failed, previous: previous)
            let expect = c["expect"] as! [String: Any]
            if let status = expect["status"] as? String { XCTAssertEqual(got.status.rawValue, status, name) }
            if expect.keys.contains("variant") { XCTAssertEqual(got.variant, expect["variant"] as? String, name) }
            if expect.keys.contains("kind") { XCTAssertEqual(got.act?.kind, expect["kind"] as? String, name) }
            if let act = expect["act"] as? [String: Any] {
                if let run = act["run"] as? String {
                    guard case .card(.run(let slug, let inputs, _))? = got.act else { return XCTFail("\(name): not a run") }
                    XCTAssertEqual(slug, run, name)
                    if let i = act["inputs"] { XCTAssertEqual(inputs, json(i)?.objectValue, name) }
                }
            }
            if expect.keys.contains("hold") {
                if let hold = expect["hold"] as? [String: Any] {
                    guard let got = got.hold else { XCTFail("\(name): no hold"); continue }
                    if let v = hold["seconds"] as? Double { XCTAssertEqual(got.seconds, v, name) }
                    if let v = hold["ring"] as? String { XCTAssertEqual(got.ring.rawValue, v, name) }
                    if let v = hold["label"] as? String { XCTAssertEqual(got.label, v, name) }
                    if let v = hold["kind"] as? String { XCTAssertEqual(got.kind, v, name) }
                    if let act = hold["act"] as? [String: Any], let run = act["run"] as? String {
                        guard case .run(let slug, let inputs, _) = got.act else { XCTFail("\(name): hold not a run"); continue }
                        XCTAssertEqual(slug, run, name)
                        if let i = act["inputs"] { XCTAssertEqual(inputs, json(i)?.objectValue, name) }
                    }
                } else {
                    XCTAssertNil(got.hold, name)
                }
            }
            if let look = expect["look"] as? [String: Any] {
                if let v = look["label"] as? String { XCTAssertEqual(got.label, v, name) }
                if let v = look["showLabel"] as? Bool { XCTAssertEqual(got.showLabel, v, name) }
                if let v = look["icon"] as? String { XCTAssertEqual(got.icon, v, name) }
                if let v = look["image"] as? String { XCTAssertEqual(got.image, v, name) }
                if let v = look["fill"] as? String { XCTAssertEqual(got.fill?.rawValue ?? "gradient", v, name) }
                if let v = look["size"] as? Double { XCTAssertEqual(got.size, v, name) }
                if let v = look["lift"] as? Double { XCTAssertEqual(got.lift, v, name) }
            }
        }
    }

    func testSlots() {
        for c in cases("slots") {
            let slot = (c["slot"] as? Double).flatMap { $0 == $0.rounded() ? Int($0) : nil }
            let button = CmsTabBarFeature(.object(["label": .string("X"), "slot": c["slot"].flatMap(json) ?? .null]))!
            XCTAssertEqual(button.slot, slot, c["name"] as! String)
            XCTAssertEqual(CmsTabBarFeature.slotIndex(button.slot, tabCount: c["tabs"] as! Int), c["expect"] as! Int, c["name"] as! String)
        }
    }

    func testInputs() {
        for c in cases("inputs") {
            let got = CmsCards.inputs(json(c["inputs"])?.objectValue ?? [:], row: json(c["row"])?.objectValue)
            let expect = json(c["expect"])?.objectValue ?? [:]
            for (k, v) in expect {
                // The cards' inputs come typed, `{ value, type }`: a lone slot keeps its
                // column's value, text around slots is text.
                let value = got[k]?.objectValue?["value"] ?? got[k]
                XCTAssertEqual(CmsCards.text(value), CmsCards.text(v), "\(c["name"] as! String): \(k)")
            }
        }
    }

    private func bar(_ props: String) throws -> CmsTabBarConfig {
        let block = try JSONDecoder().decode(CmsBlock.self, from: Data(#"{"id":"b","slug":"tabs","type":"tabBar","props":\#(props)}"#.utf8))
        return CmsTabBarConfig(block: block)
    }

    func testDecodingAndPlatforms() throws {
        let wac = try bar(#"{"items":[],"featureButton":{"label":"WAC in","run":"wac_in","query":"current_shift","variants":[{"name":"out","when":{"rows":"current_shift","empty":false}}]}}"#)
        XCTAssertEqual(wac.featureButton?.queries, ["current_shift"])
        let web = try bar(#"{"featureButton":{"label":"X","run":"a","platforms":["web"]}}"#)
        XCTAssertNil(web.featureButton, "left off the iPhone with platforms: web")
        XCTAssertNil(try bar(#"{"items":[]}"#).featureButton)
        XCTAssertEqual(CmsTabBarFeature.lift(12, hasAccessory: true), 0)
    }
}

/// What a card, the tab bar's hold and its tap send: typed values as text, as
/// the worker binds only a string or null (`coerceQueryParam`).
final class CmsCardsTypedParamTests: XCTestCase {
    func testTypedValuesAreText() {
        XCTAssertEqual(CmsCards.typed(.number(42)), .object(["value": .string("42"), "type": .string("integer")]))
        XCTAssertEqual(CmsCards.typed(.number(2.5)), .object(["value": .string("2.5"), "type": .string("float")]))
        XCTAssertEqual(CmsCards.typed(.bool(true)), .object(["value": .string("true"), "type": .string("boolean")]))
        XCTAssertEqual(CmsCards.typed(.null), .object(["value": .null, "type": .string("string")]))
        let filled = CmsCards.inputs(["id": .string("{id}")], row: ["id": .number(7)])
        XCTAssertEqual(filled["id"], .object(["value": .string("7"), "type": .string("integer")]))
    }
}
