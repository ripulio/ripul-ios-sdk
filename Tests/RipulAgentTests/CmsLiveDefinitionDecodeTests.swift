import XCTest
@testable import RipulAgent

/// Decodes real site definitions (exported from D1 into a folder named by
/// `CMS_DEFINITIONS_DIR`, one `<id>.json` per site) with the renderer's
/// models. Skipped when the variable is unset. A strict model that fails on
/// one site's odd field empties the whole test-bed list, so this names the
/// exact coding path.
final class CmsLiveDefinitionDecodeTests: XCTestCase {
    func testLiveDefinitionsDecode() throws {
        guard let dir = ProcessInfo.processInfo.environment["CMS_DEFINITIONS_DIR"] else {
            throw XCTSkip("CMS_DEFINITIONS_DIR not set")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(file))
            do {
                _ = try JSONDecoder().decode(CmsRenderDefinition.self, from: data)
            } catch let DecodingError.typeMismatch(type, context) {
                XCTFail("\(file): type mismatch \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")) — \(context.debugDescription)")
            } catch let DecodingError.keyNotFound(key, context) {
                XCTFail("\(file): missing \(key.stringValue) at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
            } catch let DecodingError.valueNotFound(type, context) {
                XCTFail("\(file): null \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
            } catch let DecodingError.dataCorrupted(context) {
                XCTFail("\(file): corrupted at \(context.codingPath.map(\.stringValue).joined(separator: ".")) — \(context.debugDescription)")
            }
        }
    }
}
