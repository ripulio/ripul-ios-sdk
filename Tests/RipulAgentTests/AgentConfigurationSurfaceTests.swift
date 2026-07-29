import XCTest
@testable import RipulAgent

/// Hash-param assembly for the per-surface solution-context binding.
///
/// The web boot reads these params and forwards them to validate, so a wrong
/// name or a missed encoding doesn't error — it silently boots the key's
/// default context, which looks exactly like success. Hence assertions on the
/// literal param names.
final class AgentConfigurationSurfaceTests: XCTestCase {
    private func makeConfig() -> AgentConfiguration {
        AgentConfiguration(
            baseURL: URL(string: "https://demo.ripul.io")!,
            siteKey: "pk_test_selftest_multictx"
        )
    }

    /// The RAW url string, not `URLComponents.fragment` — that accessor
    /// percent-DECODES, so reading through it would hide exactly the encoding
    /// bug these tests exist to catch.
    private func fragment(_ config: AgentConfiguration) -> String {
        config.embeddedURL.absoluteString
    }

    func testOmitsBothParamsWhenUnset() {
        let hash = fragment(makeConfig())
        XCTAssertFalse(hash.contains("solutionContext="))
        XCTAssertFalse(hash.contains("surface="))
    }

    func testEmitsSurface() {
        var config = makeConfig()
        config.surface = "beta"
        XCTAssertTrue(fragment(config).contains("surface=beta"))
    }

    func testEmitsSolutionContextId() {
        var config = makeConfig()
        config.solutionContextId = "sc_selftest_beta"
        // The web side reads `solutionContext`, not `solutionContextId`.
        XCTAssertTrue(fragment(config).contains("solutionContext=sc_selftest_beta"))
    }

    func testEmitsBothWhenBothSet() {
        var config = makeConfig()
        config.solutionContextId = "sc_selftest_beta"
        config.surface = "beta"
        let hash = fragment(config)
        XCTAssertTrue(hash.contains("solutionContext=sc_selftest_beta"))
        XCTAssertTrue(hash.contains("surface=beta"))
    }

    func testPercentEncodesValues() {
        var config = makeConfig()
        // A surface name with a separator would otherwise split the hash param
        // and truncate everything after it.
        config.surface = "settings&admin one"
        let hash = fragment(config)
        XCTAssertTrue(hash.contains("surface=settings%26admin%20one"), hash)
        XCTAssertFalse(hash.contains("settings&admin"))
    }

    func testInitializerCarriesTheParams() {
        let config = AgentConfiguration(
            baseURL: URL(string: "https://demo.ripul.io")!,
            siteKey: "pk_test_selftest_multictx",
            solutionContextId: "sc_selftest_alpha",
            surface: "alpha"
        )
        XCTAssertEqual(config.solutionContextId, "sc_selftest_alpha")
        XCTAssertEqual(config.surface, "alpha")
    }
}
