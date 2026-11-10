import XCTest
@testable import RipulAgent

/// Signing in with a site's own identity provider through the system's sheet
/// (CmsPortalSignIn.swift, the worker's siteKeys/nativeHandoff.ts).
final class CmsPortalSignInTests: XCTestCase {
    private let handoff = CmsPortalHandoff(
        siteURL: URL(string: "https://business.wac.rocks")!,
        providerKey: "pk_live_Y2xlcmsud2FjLnJvY2tzJA",
        siteKey: "pk_live_2qbx8m0vxxkqnr8i14mpri8s",
        redirect: URL(string: "wacbusiness://portal-signed-in")!,
        apiBase: "https://llm-proxy.ripul.io"
    )

    /// RFC 7636 Appendix B, the vector the worker and Android pass too.
    func testS256MatchesTheRFCVector() {
        XCTAssertEqual(CmsPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    /// 43 unreserved characters, as the worker's check wants, and never the same twice.
    func testVerifiersAreUnreservedAndFresh() {
        let first = CmsPKCE.verifier(), second = CmsPKCE.verifier()
        XCTAssertEqual(first.count, 43)
        XCTAssertNotNil(first.range(of: "^[A-Za-z0-9._~-]{43,128}$", options: .regularExpression))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(CmsPKCE.challenge(for: first).count, 43)
    }

    func testSignInAddress() throws {
        let url = handoff.signInURL(challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", promptLogin: false)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "business.wac.rocks")
        XCTAssertEqual(parts.path, "/portal-session")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["pk"], "pk_live_Y2xlcmsud2FjLnJvY2tzJA")
        XCTAssertEqual(query["siteKey"], "pk_live_2qbx8m0vxxkqnr8i14mpri8s")
        XCTAssertEqual(query["redirect"], "wacbusiness://portal-signed-in")
        XCTAssertEqual(query["challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertNil(query["prompt"])
        XCTAssertTrue(handoff.signInURL(challenge: "x", promptLogin: true).absoluteString.hasSuffix("&prompt=login"),
                      "after a sign-out the provider asks for an account again")
    }

    func testCodeOnlyFromTheAppsOwnRedirect() {
        let code = "rnc_" + String(repeating: "a1", count: 32)
        XCTAssertEqual(handoff.code(in: URL(string: "wacbusiness://portal-signed-in?code=\(code)")!), code)
        XCTAssertNil(handoff.code(in: URL(string: "otherapp://portal-signed-in?code=\(code)")!), "another scheme")
        XCTAssertNil(handoff.code(in: URL(string: "wacbusiness://portal-signed-in")!), "no code")
        XCTAssertNil(handoff.code(in: URL(string: "wacbusiness://portal-signed-in?code=nope")!), "not a handoff code")
    }

    func testExchangeAndSignOutRequests() throws {
        let exchange = handoff.exchangeRequest(code: "rnc_x", verifier: "v")
        XCTAssertEqual(exchange.url?.absoluteString, "https://llm-proxy.ripul.io/v1/site-key/native-handoff/exchange")
        XCTAssertEqual(exchange.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exchange.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["siteKey": "pk_live_2qbx8m0vxxkqnr8i14mpri8s", "code": "rnc_x", "verifier": "v",
                              "redirect": "wacbusiness://portal-signed-in"])

        let signOut = handoff.signOutRequest(token: "rns_t")
        XCTAssertEqual(signOut.url?.absoluteString, "https://llm-proxy.ripul.io/v1/site-key/native-handoff/session")
        XCTAssertEqual(signOut.httpMethod, "DELETE")
        XCTAssertEqual(signOut.value(forHTTPHeaderField: "Authorization"), "Bearer rns_t")
    }

    /// The worker's `toISOString()` (fractional seconds), and the same without them.
    func testExpiryDates() throws {
        let date = try XCTUnwrap(CmsPortalHandoff.expiry("2026-12-03T10:15:30.123Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_796_292_930.123, accuracy: 0.001)
        XCTAssertNotNil(CmsPortalHandoff.expiry("2026-12-03T10:15:30Z"))
        XCTAssertNil(CmsPortalHandoff.expiry("soon"))
    }

    func testExchangedAnswerDecodes() throws {
        let json = #"{"token":"rns_abc","expiresAt":"2026-12-03T10:15:30.123Z","member":{"id":"user_1","email":"a@b.c"}}"#
        let exchanged = try JSONDecoder().decode(CmsPortalHandoff.Exchanged.self, from: Data(json.utf8))
        XCTAssertEqual(exchanged.token, "rns_abc")
        XCTAssertEqual(exchanged.member.id, "user_1")
        XCTAssertEqual(exchanged.member.email, "a@b.c")
    }
}
