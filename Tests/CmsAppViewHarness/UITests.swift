import XCTest

/// Drives CmsAppView's tab bar on an iPhone simulator, against the scratch
/// site `tab-bar-iphone-scratch`: six site tabs (so More), a badge on Inbox,
/// an accessory, a long Home page, links that push and one that selects a tab,
/// and a host Account tab. See docs/cms-app-view.md.
final class CmsAppViewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--fresh"]
        if name.contains("SiteIsNotLoaded") || name.contains("ImageChains") { return }  // these launch themselves
        app.launch()
        XCTAssertTrue(tab("home").waitForExistence(timeout: 30), "the site loads and its tab bar appears")
    }

    /// Pictures from image chains: a link list row's `image.chain` in the
    /// style's picture slot (a 404 falls back to the icon). The page's offers
    /// grid needs its query, which an anonymous visitor's token may not run,
    /// so its logo chain is checked on the owner path (the CMS Test Bed).
    func testPicturesFromImageChains() {
        app.launchArguments = ["--fresh", "--page", "pictures"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Chain picture"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Chain 404, icon fallback"].exists)
        XCTAssertTrue(app.staticTexts["Icon only"].exists)
        sleep(3)  // let the pictures land before the picture is taken
        shot("9-pictures-from-image-chains")
    }

    func testHostTabsStayWhenTheSiteIsNotLoaded() {
        app.launchArguments = ["--fresh", "--refused"]
        app.launch()
        XCTAssertTrue(tab("status").waitForExistence(timeout: 30), "a status tab stands in for the site's tabs")
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 30), "with the load's failure and Retry")
        shot("7-not-loaded-status")
        tapTab("account", "host tab")
        XCTAssertTrue(app.buttons["Sign out"].waitForExistence(timeout: 5), "the host's Account tab, with Sign out, is reachable")
        shot("8-not-loaded-account")
        tapTab("status", "back to status")
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
    }

    private func tab(_ slug: String) -> XCUIElement {
        app.buttons["tabbar.\(slug)"].firstMatch
    }

    /// Tap a tab once its button is there (the bar rebuilds its buttons as
    /// stacks change, so the query can miss for a moment).
    private func tapTab(_ slug: String, _ step: String, line: UInt = #line) {
        XCTAssertTrue(tab(slug).waitForExistence(timeout: 5), "\(step): tabbar.\(slug) is there", line: line)
        tab(slug).tap()
    }

    private func text(_ prefix: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func link(_ label: String) -> XCUIElement {
        app.buttons[label].firstMatch
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["CMS_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testBarIdentifiersLabelsBadgeAndAccessory() {
        for slug in ["home", "shifts", "inbox", "jobs"] {
            XCTAssertTrue(tab(slug).exists, "tabbar.\(slug)")
        }
        XCTAssertEqual(tab("shifts").label, "Shifts", "VoiceOver reads the tab's own label")
        XCTAssertTrue(tab("home").isSelected)
        // The badge ("3" on Inbox) is drawn by the system but not exposed to
        // XCUITest on iOS 26.4; the screenshot shows it.
        XCTAssertTrue(app.staticTexts["Clocked in since 09:00"].waitForExistence(timeout: 5), "the accessory shows")
        XCTAssertTrue(app.navigationBars["Home"].exists, "large title on the tab's first page")
        shot("1-bar")
    }

    func testMoreHoldsTheTabsAfterTheFifth() {
        let more = app.tabBars.buttons["More"].firstMatch
        XCTAssertTrue(more.exists, "an iPhone shows More with seven tabs")
        more.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Account"].exists, "the host tab is listed too")
        shot("2-more")
        app.staticTexts["Settings"].tap()
        XCTAssertTrue(text("Settings.").waitForExistence(timeout: 5), "a tab opened from More shows its page")
        shot("3-more-settings")
    }

    func testEachTabKeepsItsPlace() {
        tapTab("shifts", "step 1")
        link("Open shift detail").tap()
        XCTAssertTrue(text("One shift").waitForExistence(timeout: 5), "a link pushes onto the tab's stack")
        XCTAssertTrue(app.navigationBars.buttons["Shifts"].exists || app.navigationBars.buttons.element(boundBy: 0).exists,
                      "the system back button")
        tapTab("home", "step 2")
        XCTAssertTrue(text("Home row 1").waitForExistence(timeout: 5))
        tapTab("shifts", "step 3")
        XCTAssertTrue(text("One shift").waitForExistence(timeout: 5), "Shifts is still on the page pushed onto it")
        shot("4-kept-place")
    }

    func testRetapPopsThenScrollsToTop() {
        tapTab("shifts", "step 4")
        link("Open shift detail").tap()
        XCTAssertTrue(text("One shift").waitForExistence(timeout: 5))
        link("Open another page").tap()
        XCTAssertTrue(text("A second page deep").waitForExistence(timeout: 5))
        tapTab("shifts", "step 5")
        XCTAssertTrue(text("Your shifts").waitForExistence(timeout: 5), "re-tap pops to the tab's first page")
        XCTAssertFalse(text("A second page deep").exists)

        tapTab("home", "step 6")
        let first = text("Home row 1")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let homeBar = app.navigationBars["Home"]
        let largeTitleHeight = homeBar.frame.height
        app.swipeUp()
        app.swipeUp()
        XCTAssertFalse(first.isHittable, "Home has scrolled")
        shot("5-home-scrolled")
        if !tab("home").exists {
            // iOS 26 shrank the bar while scrolling down (minimizeOnScroll): the
            // selected tab sits alone beside the accessory, and the first tap
            // only brings the bar back.
            app.tabBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(tab("home").waitForExistence(timeout: 5), "the bar comes back")
            shot("5b-bar-back")
        }
        tapTab("home", "step 7")
        let back = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: first)
        wait(for: [back], timeout: 5)
        // As in Apple's apps, the very top: the large title open again, not
        // the first row tucked under an inline title.
        var height = homeBar.frame.height
        for _ in 0..<20 where height < largeTitleHeight - 1 {
            usleep(150_000)
            height = homeBar.frame.height
        }
        XCTAssertGreaterThanOrEqual(height, largeTitleHeight - 1, "the large title shows again after the re-tap")
        shot("6-home-scrolled-to-top")
    }

    func testALinkToATabsFirstPageSelectsThatTab() {
        link("Go to Jobs").tap()
        XCTAssertTrue(text("Jobs list").waitForExistence(timeout: 5))
        XCTAssertTrue(tab("jobs").isSelected, "the Jobs tab is selected, not a page pushed onto Home")
        tapTab("home", "step 8")
        XCTAssertTrue(text("Home row 1").waitForExistence(timeout: 5), "Home was left on its own first page")
    }

    func testTheChosenTabIsRememberedAcrossLaunches() {
        tapTab("jobs", "step 9")
        XCTAssertTrue(tab("jobs").isSelected)
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(tab("jobs").waitForExistence(timeout: 30))
        XCTAssertTrue(tab("jobs").isSelected, "the app reopens on the tab chosen last")
    }
}
