import XCTest

/// On-device proof that the hybrid-PQ engine and social feed work, driven through
/// the real (human-friendly) UI. Onboarding is bypassed via an env flag.
final class KithUITests: XCTestCase {
    private func app(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KITH_SKIP_ONBOARDING"] = "1"
        app.launchEnvironment["KITH_TAB"] = tab
        return app
    }

    /// You → Advanced → Run privacy check → all checks pass.
    func testPrivacyCheckPasses() {
        let app = app(tab: "you")
        app.launch()

        let advanced = app.buttons["Advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 15), "Advanced should be reachable")
        advanced.tap()

        let check = app.buttons["privacyCheck"]
        XCTAssertTrue(check.waitForExistence(timeout: 10), "privacy check button should exist")
        check.tap()

        let passed = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "checks passed")
        ).firstMatch
        XCTAssertTrue(passed.waitForExistence(timeout: 10), "all on-device checks should pass")
    }

    /// Posting to the circle feed round-trips through the social engine into the UI.
    func testSocialFeedPostAppears() {
        let app = app(tab: "circle")
        app.launch()

        let seeded = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Golden hour")
        ).firstMatch
        XCTAssertTrue(seeded.waitForExistence(timeout: 15), "seeded feed content should appear")

        let field = app.textFields["composeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("a sealed post from the UI test")
        app.buttons["composeSend"].tap()

        let posted = app.staticTexts["a sealed post from the UI test"]
        XCTAssertTrue(posted.waitForExistence(timeout: 5), "new post should appear in the feed")
    }
}
