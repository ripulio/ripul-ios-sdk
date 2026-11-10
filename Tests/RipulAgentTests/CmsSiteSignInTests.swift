import XCTest
@testable import RipulAgent

/// A site's own sign-in by an emailed code (CmsSiteSignIn.swift), held to the
/// web's `siteSignIn.ts` and the worker's `emailSignIn.ts`; and the admin
/// section a page with its own shell opens under (CmsAppSection.swift).
@MainActor
final class CmsSiteSignInTests: XCTestCase {
    /// Answers each request in turn, and keeps what was sent.
    final class Server: @unchecked Sendable {
        var answers: [(Int, String)]
        var sent: [URLRequest] = []
        init(_ answers: [(Int, String)]) { self.answers = answers }
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            sent.append(request)
            let (status, body) = answers.isEmpty ? (200, "{}") : answers.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private let token = String(repeating: "ab", count: 32)
    private var later: String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(30 * 86_400))
    }

    private func make(_ server: Server, store: CmsSiteSessionStore = CmsMemorySiteSessionStore()) -> CmsSiteSignIn {
        CmsSiteSignIn(siteKey: "pk_live_site", origin: "https://beta.example.com", baseUrl: "https://api.example.com",
                      store: store, send: { try await server.send($0) })
    }

    private func body(_ request: URLRequest) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String] ?? [:]
    }

    func testSendCodeThenVerifySignsInAndKeepsTheSession() async throws {
        let server = Server([(200, #"{"sent":true}"#), (200, #"{"token":"\#(token)","email":"guest@example.com","expiresAt":"\#(later)"}"#)])
        let store = CmsMemorySiteSessionStore()
        let signIn = make(server, store: store)
        var told: [String?] = []
        signIn.onChange = { told.append($0) }

        try await signIn.sendCode(to: "  guest@example.com ")
        XCTAssertEqual(signIn.pendingEmail, "guest@example.com")
        XCTAssertEqual(server.sent[0].url?.absoluteString, "https://api.example.com/v1/site-key/sign-in/code")
        XCTAssertEqual(server.sent[0].httpMethod, "POST")
        // The routes refuse any address but the site's own.
        XCTAssertEqual(server.sent[0].value(forHTTPHeaderField: "Origin"), "https://beta.example.com")
        XCTAssertEqual(body(server.sent[0]), ["siteKey": "pk_live_site", "email": "guest@example.com"])

        try await signIn.verify(code: "123 456")
        XCTAssertEqual(server.sent[1].url?.path, "/v1/site-key/sign-in/verify")
        XCTAssertEqual(body(server.sent[1]), ["siteKey": "pk_live_site", "email": "guest@example.com", "code": "123456"])
        XCTAssertEqual(signIn.email, "guest@example.com")
        XCTAssertNil(signIn.pendingEmail)
        XCTAssertEqual(signIn.token(), token)
        XCTAssertEqual(told, ["guest@example.com"])

        // A new launch finds it in the store.
        let again = make(Server([]), store: store)
        XCTAssertEqual(again.email, "guest@example.com")
        XCTAssertEqual(again.token(), token)
    }

    func testARefusalCarriesTheServersWords() async {
        let server = Server([(200, #"{"sent":true}"#), (401, #"{"error":"That code is not right."}"#)])
        let signIn = make(server)
        try? await signIn.sendCode(to: "guest@example.com")
        do {
            try await signIn.verify(code: "000000")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That code is not right.")
        }
        XCTAssertNil(signIn.email)
        // Still waiting on a code for the same address.
        XCTAssertEqual(signIn.pendingEmail, "guest@example.com")
    }

    func testVerifyBeforeAskingForACode() async {
        let signIn = make(Server([]))
        do {
            try await signIn.verify(code: "123456")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Ask for a code first.")
        }
    }

    func testARunOutSessionIsForgotten() {
        let store = CmsMemorySiteSessionStore()
        store.save(CmsSiteSession(token: token, email: "guest@example.com", expiresAt: "2020-01-01T00:00:00.000Z"), siteKey: "pk_live_site")
        let signIn = make(Server([]), store: store)
        XCTAssertNil(signIn.email)
        XCTAssertNil(signIn.token())
        XCTAssertNil(store.load(siteKey: "pk_live_site"))
    }

    func testSignOutEndsTheSessionOnTheServer() async {
        let store = CmsMemorySiteSessionStore()
        store.save(CmsSiteSession(token: token, email: "guest@example.com", expiresAt: later), siteKey: "pk_live_site")
        let server = Server([(200, #"{"signedOut":true}"#)])
        let signIn = make(server, store: store)
        await signIn.signOut()
        XCTAssertNil(signIn.email)
        XCTAssertNil(store.load(siteKey: "pk_live_site"))
        XCTAssertEqual(server.sent.first?.httpMethod, "DELETE")
        XCTAssertEqual(server.sent.first?.url?.path, "/v1/site-key/sign-in/session")
        XCTAssertEqual(server.sent.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testSessionDatesWithAndWithoutFractions() {
        XCTAssertTrue(CmsSiteSession(token: "t", email: "e", expiresAt: "2999-01-01T00:00:00.000Z").isValid())
        XCTAssertTrue(CmsSiteSession(token: "t", email: "e", expiresAt: "2999-01-01T00:00:00Z").isValid())
        XCTAssertFalse(CmsSiteSession(token: "", email: "e", expiresAt: "2999-01-01T00:00:00Z").isValid())
        XCTAssertFalse(CmsSiteSession(token: "t", email: "e", expiresAt: "soon").isValid())
    }

    func testTheFormsRules() {
        XCTAssertTrue(CmsSiteSignInRules.isEmail(" a@b.co "))
        XCTAssertFalse(CmsSiteSignInRules.isEmail("a@b"))
        XCTAssertFalse(CmsSiteSignInRules.isEmail("a b@c.de"))
        XCTAssertEqual(CmsSiteSignInRules.codeField("12a3 4567"), "123 456")
        XCTAssertEqual(CmsSiteSignInRules.codeField("１２３"), "")
        XCTAssertTrue(CmsSiteSignInRules.isCompleteCode("123 456"))
        XCTAssertFalse(CmsSiteSignInRules.isCompleteCode("12345"))
    }

    func testAnEmailSiteIsReadFromItsConfig() {
        XCTAssertTrue(CmsSiteSignInConfig.signsInByEmail(configJSON: Data(#"{"portalAuth":{"provider":"email"}}"#.utf8)))
        XCTAssertFalse(CmsSiteSignInConfig.signsInByEmail(configJSON: Data(#"{"portalAuth":{"provider":"clerk"}}"#.utf8)))
        XCTAssertFalse(CmsSiteSignInConfig.signsInByEmail(configJSON: Data(#"{"cms":{}}"#.utf8)))
    }

    func testTheWordingOfEachForm() {
        let form = CmsSiteSignInWording.authForm(["signInHeading": .string("Sign in to Sandsend Retreats"), "emailLabel": .string("")])
        XCTAssertEqual(form.heading, "Sign in to Sandsend Retreats")
        XCTAssertEqual(form.emailLabel, "Email")
        XCTAssertEqual(form.codeIntro("a@b.co"), "We sent a code to a@b.co. Enter it to sign in.")
        XCTAssertEqual(form.emailProblem(""), "Email is required.")
        XCTAssertEqual(form.emailProblem("x"), "Enter a valid email address.")
        let guest = CmsSiteSignInWording.guestBookings(intro: " ")
        XCTAssertEqual(guest.emailIntro, "Sign in with the email you booked with, and we will email you a code.")
        XCTAssertEqual(guest.codeIntro("a@b.co"), "We have emailed a 6-digit code to a@b.co. It works for 10 minutes.")
        XCTAssertEqual(guest.codeButton, "Sign in")
    }

    // MARK: - The admin section

    private func page(_ json: String) throws -> CmsPage {
        try JSONDecoder().decode(CmsPage.self, from: Data(json.utf8))
    }

    private func sandsend() throws -> [CmsPage] {
        [
            try page(#"{"id":"p_shell","slug":"shell","title":"Shell","bodyType":"blocks","blocks":{"layout":"list","items":[]}}"#),
            try page(#"{"id":"p_home","slug":"home","title":"Home","bodyType":"blocks","blocks":{"layout":"list","items":[]}}"#),
            try page(#"""
            {"id":"p_admin","slug":"admin-shell","title":"Admin shell","bodyType":"blocks","blocks":{"layout":"sidebar","variant":"left","slots":{
              "left":{"layout":"list","items":[{"id":"nav","type":"sidebarNav","props":{"headerTitle":"Sandsend Retreats","items":[
                {"heading":true,"label":"Admin"},
                {"label":"Bookings","icon":"calendar_month","targetPageSlug":"bookings","visibility":"roles","requiredRoles":["owner","admin","manager"]},
                {"label":"Enquiries","icon":"mail","targetPageSlug":"enquiries","visibility":"roles","requiredRoles":["owner","admin","manager","employee"]},
                {"label":"Team","targetPageSlug":"team","visibility":"roles","requiredRoles":["owner","admin"]},
                {"label":"View the site","icon":"home","targetPageSlug":"home","align":"end"},
                {"align":"end","block":{"type":"userAccount","props":{}}}
              ]}}]},
              "main":{"layout":"list","items":[{"id":"out","type":"pageOutlet","props":{}}]}}}}
            """#),
            try page(#"{"id":"p_bookings","slug":"bookings","title":"Bookings","bodyType":"blocks","shellPageId":"p_admin","requiresAuth":true,"requiredRoles":["owner","admin","manager"],"blocks":{"layout":"list","items":[]}}"#),
            try page(#"{"id":"p_enquiries","slug":"enquiries","title":"Enquiries","bodyType":"blocks","shellPageId":"p_admin","blocks":{"layout":"list","items":[]}}"#),
            try page(#"{"id":"p_team","slug":"team","title":"Team","bodyType":"blocks","shellPageId":"p_admin","blocks":{"layout":"list","items":[]}}"#),
        ]
    }

    func testAnAdminPageOpensUnderItsSection() throws {
        let pages = try sandsend()
        XCTAssertEqual(CmsAppSection.shell(for: "bookings", pages: pages, siteShellId: "p_shell")?.slug, "admin-shell")
        XCTAssertNil(CmsAppSection.shell(for: "home", pages: pages, siteShellId: "p_shell"))
        let admin = try XCTUnwrap(pages.first { $0.slug == "admin-shell" })
        XCTAssertTrue(CmsAppSection.isSectionShell(admin, siteShellId: "p_shell"))
        XCTAssertFalse(CmsAppSection.isSectionShell(pages[1], siteShellId: "p_shell"))
        XCTAssertEqual(CmsAppSection.title(of: admin), "Sandsend Retreats")
    }

    func testTheSectionListsWhatThisPersonCanOpen() throws {
        let admin = try XCTUnwrap(try sandsend().first { $0.slug == "admin-shell" })
        let all: Set = ["home", "admin-shell", "bookings", "enquiries", "team"]
        let manager = CmsAppSection.groups(of: admin, membership: CmsPortalMembership(isMember: true, role: "manager"),
                                           canDesign: false, openableSlugs: all)
        XCTAssertEqual(manager, [
            .init(heading: "Admin", rows: [.init(label: "Bookings", icon: "calendar_month", pageSlug: "bookings"),
                                           .init(label: "Enquiries", icon: "mail", pageSlug: "enquiries")]),
            .init(heading: nil, rows: [.init(label: "View the site", icon: "home", pageSlug: "home")]),
        ])
        let employee = CmsAppSection.groups(of: admin, membership: CmsPortalMembership(isMember: true, role: "employee"),
                                            canDesign: false, openableSlugs: ["home", "enquiries"])
        XCTAssertEqual(employee.first?.rows.map(\.pageSlug), ["enquiries"])
    }

    func testOpeningAnAdminPagePushesTheSectionFirstOnce() {
        var state = CmsAppNavigationState(siteTabs: [(id: "site:home", rootSlug: "home"), (id: "site:app-menu", rootSlug: "app-menu")],
                                          tabIDs: ["site:home", "site:app-menu"], selected: "site:app-menu")
        let openable: Set = ["home", "app-menu", "admin-shell", "bookings", "team"]
        state.open(pageSlug: "team", openableSlugs: openable, sectionShell: "admin-shell")
        XCTAssertEqual(state.paths["site:app-menu"]?.map(\.pageSlug), ["admin-shell", "team"])
        state.open(pageSlug: "bookings", openableSlugs: openable, sectionShell: "admin-shell")
        XCTAssertEqual(state.paths["site:app-menu"]?.map(\.pageSlug), ["admin-shell", "team", "bookings"])
    }

    func testSigningOutDropsThePagesTheyCanNoLongerOpen() {
        var state = CmsAppNavigationState(siteTabs: [(id: "site:home", rootSlug: "home"), (id: "site:app-menu", rootSlug: "app-menu")],
                                          tabIDs: ["site:home", "site:app-menu"], selected: "site:app-menu")
        state.paths["site:app-menu"] = [CmsAppRoute(pageSlug: "my-bookings"), CmsAppRoute(pageSlug: "admin-shell"), CmsAppRoute(pageSlug: "bookings")]
        let next = state.following(siteTabs: [(id: "site:home", rootSlug: "home"), (id: "site:app-menu", rootSlug: "app-menu")],
                                   tabIDs: ["site:home", "site:app-menu"], openableSlugs: ["home", "app-menu", "my-bookings", "admin-shell"])
        XCTAssertEqual(next.paths["site:app-menu"]?.map(\.pageSlug), ["my-bookings", "admin-shell"])
        XCTAssertEqual(next.selected, "site:app-menu")
    }
}
