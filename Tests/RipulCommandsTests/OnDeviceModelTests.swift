import XCTest
@testable import RipulCommands

/// The 26.0 betas carry an older FoundationModels API than the SDK's 26.0,
/// so the gate must refuse them and nothing else (see OnDeviceModel).
final class OnDeviceModelTests: XCTestCase {
    private func v(_ major: Int, _ minor: Int, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    func testRefusesThe26Point0Beta() {
        // The build in the 2026-10-06 crash: no GeneratedContent.jsonString,
        // no respond(to:generating:includeSchemaInPrompt:options:).
        XCTAssertTrue(OnDeviceModel.isEarlyBeta(version: v(26, 0), build: "25A5306g"))
        XCTAssertTrue(OnDeviceModel.isEarlyBeta(version: v(26, 0), build: "23A5276f"))   // an iOS 26.0 beta
    }

    func testAllowsReleasesAndLaterBetas() {
        XCTAssertFalse(OnDeviceModel.isEarlyBeta(version: v(26, 0), build: "25A354"))
        XCTAssertFalse(OnDeviceModel.isEarlyBeta(version: v(26, 0, 1), build: "25A362"))
        XCTAssertFalse(OnDeviceModel.isEarlyBeta(version: v(26, 1), build: "25B5042k"))
        XCTAssertFalse(OnDeviceModel.isEarlyBeta(version: v(27, 0), build: "26A5289f"))
        XCTAssertFalse(OnDeviceModel.isEarlyBeta(version: v(26, 0), build: ""))
    }
}
