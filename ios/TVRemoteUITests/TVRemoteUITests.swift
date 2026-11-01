import XCTest

/// Smoke tests of the main screens, without a TV (TESTING.md: UI-*). They run on a simulator from the
/// "Debloated TV Dev" scheme. A made-up TV address keeps the app from reaching a real TV, and the debug-only launch
/// arguments in TVRemoteApp.swift (UITestHooks) put the TV tab in each state.
final class TVRemoteUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(tvState: String = "fresh", offer: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // 192.0.2.x is reserved for documentation: nothing answers there.
        app.launchArguments = ["-tvHost", "192.0.2.10", "-uiTestTVState", tvState, "-uiTestOffer", offer ? "YES" : "NO",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]   // the assertions read English text
        app.launch()
        return app
    }

    func testTabsAreAllReachable() {
        let app = launch()
        for tab in ["Remote", "TV", "Actions", "Settings"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected, tab)
        }
    }

    func testFreshTVLeadsWithSetup() {
        let app = launch(tvState: "fresh")
        app.tabBars.buttons["TV"].tap()
        XCTAssertTrue(app.staticTexts["Make your TV faster"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Check if my TV is supported"].exists)
        app.buttons["Start setup"].tap()
        XCTAssertTrue(app.navigationBars["Set up TV"].waitForExistence(timeout: 5))
    }

    func testSupportedTVShowsItsModel() {
        let app = launch(tvState: "supported")
        app.tabBars.buttons["TV"].tap()
        XCTAssertTrue(app.staticTexts["Supported"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Test TV"].exists)
    }

    func testInstalledTVShowsTheEditorAndManage() {
        let app = launch(tvState: "installed")
        app.tabBars.buttons["TV"].tap()
        XCTAssertTrue(app.staticTexts["12 apps off · new Home screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Changes apply to the TV automatically."].exists, "edits apply by themselves, no Apply button")
        app.staticTexts["Debloated"].tap()
        XCTAssertTrue(app.staticTexts["Undo TV setup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Run setup again"].exists)
    }

    func testUnsupportedTVExplainsAndOffersARequest() {
        let app = launch(tvState: "unsupported")
        app.tabBars.buttons["TV"].tap()
        XCTAssertTrue(app.staticTexts["This TV isn't supported for setup yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Share this model's details"].exists || app.buttons["Ask for this model"].exists)
        XCTAssertFalse(app.buttons["Start setup"].exists, "no setup without a tested list")
    }

    func testOfferSheetOpensSetupOnce() {
        let app = launch(tvState: "fresh", offer: true)
        XCTAssertTrue(app.staticTexts["Your TV can be a lot faster"].waitForExistence(timeout: 5))
        app.buttons["Set up my TV"].tap()
        XCTAssertTrue(app.navigationBars["Set up TV"].waitForExistence(timeout: 5))
    }

    func testSettingsKeepsTVSetupAndLicenses() {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Debloat & new Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Undo TV setup"].exists)
        app.swipeUp()
        app.buttons["Credits & licenses"].tap()
        XCTAssertTrue(app.staticTexts["cleanyourtv"].waitForExistence(timeout: 5))
    }

    func testFirstLaunchGuidesToConnectAndTheAddressFieldTakesDots() {
        let app = launch()
        app.tabBars.buttons["Remote"].tap()
        XCTAssertTrue(app.staticTexts["Connect your TV"].waitForExistence(timeout: 5) || app.staticTexts["No TV found yet"].exists)
        let manual = app.buttons["My TV isn't listed: enter its address"].exists ? app.buttons["My TV isn't listed: enter its address"] : app.buttons["Enter the TV's address instead"]
        manual.tap()
        let field = app.textFields["The TV's IP address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("192,168,0,13")
        XCTAssertEqual(field.value as? String, "192.168.0.13", "commas become dots")
        XCTAssertTrue(app.staticTexts["Looks right"].exists)
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
    }
}
