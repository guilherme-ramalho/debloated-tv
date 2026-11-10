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
        app.staticTexts["Purio TV"].tap()
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

/// App Store screenshots (scripts/store-shots-auto.sh), skipped in every other run. Drives the RELEASE app already
/// installed in the simulator (bundle ID without .dev), paired with a real TV, in each language: Remote, Type on TV,
/// TV tab, Look, Actions, a quick action's steps, setup (03). Widgets (08) stay manual (store-shots.sh).
/// Taps go by accessibility identifier or position, never by text, so every language works.
final class StoreScreenshots: XCTestCase {
    private var dir = ""
    private var app: XCUIApplication!

    /// 03: Settings › Debloat & new Home, its first screen (what setup does and its risks), as in the 1.0 listing.
    /// Nothing connects to the TV.
    private func setupReview(_ tabs: XCUIElementQuery) {
        tabs.element(boundBy: 3).tap(); pause(1)
        let row = app.buttons["setupRow"]
        if !row.waitForExistence(timeout: 3) { app.swipeUp() }
        guard row.waitForExistence(timeout: 3) else { print("STORE-SHOTS: no setup row"); return }
        row.tap(); pause(2)
        shot("03-setup-review")
        app.navigationBars.buttons.firstMatch.tap(); pause(1)
    }

    func testStoreScreenshots() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["STORE_SHOTS_DIR"], !out.isEmpty else { throw XCTSkip("Runs from scripts/store-shots-auto.sh") }
        let languages = (env["STORE_SHOTS_LANGS"] ?? "en,de,es,fr,it,pt-BR").split(separator: ",").map(String.init)
        continueAfterFailure = true
        for lang in languages {
            dir = out + "/" + lang
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            app = XCUIApplication(bundleIdentifier: "com.guilhermeramalho.TVRemote")
            let locale = lang == "en" ? "en_US" : lang.replacingOccurrences(of: "-", with: "_")
            app.launchArguments = ["-AppleLanguages", "(\(lang))", "-AppleLocale", locale]
            app.launch()
            let tabs = app.tabBars.buttons
            XCTAssertTrue(tabs.element(boundBy: 0).waitForExistence(timeout: 10), "\(lang): app didn't start")
            if env["STORE_SHOTS_ONLY"] == "03" { setupReview(tabs); app.terminate(); continue }

            tabs.element(boundBy: 0).tap(); pause(5)            // the remote connects to the paired TV
            shot("01-remote")
            if app.buttons["typeOnTV"].exists {
                app.buttons["typeOnTV"].tap(); pause(1)
                let field = app.textFields.firstMatch
                if field.waitForExistence(timeout: 3) { field.tap(); field.typeText("Stranger Things") }
                pause(1); shot("04-type")
                app.navigationBars.buttons.firstMatch.tap(); pause(1)   // Done
            }
            app.buttons["remote-house.fill"].tap(); pause(3)    // the typing can open an app on the TV: back to Home
            tabs.element(boundBy: 1).tap(); pause(8)            // TV Home connects; the Look row appears with it
            app.swipeDown(); pause(1)
            shot("02-tv-home")
            let look = app.buttons["lookRow"]
            if look.waitForExistence(timeout: 5) {
                look.tap(); pause(2); shot("07-look")
                app.navigationBars.buttons.firstMatch.tap(); pause(1)
            } else { print("STORE-SHOTS \(lang): no Look row (TV Home not connected?)") }
            tabs.element(boundBy: 2).tap(); pause(2)
            shot("05-actions")
            let edit = app.buttons.matching(identifier: "editAction").firstMatch
            if edit.waitForExistence(timeout: 3) {
                edit.tap(); pause(2); shot("06-action-steps")
                app.navigationBars.buttons.firstMatch.tap(); pause(1)
            }
            setupReview(tabs)
            app.terminate()
        }
    }

    private func pause(_ seconds: UInt32) { sleep(seconds) }
    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let path = dir + "/" + name + ".png"
        if (try? png.write(to: URL(fileURLWithPath: path))) != nil { print("STORE-SHOTS saved \(path)") }
        else { XCTFail("Couldn't write \(path)") }
    }
}

/// Pairs the RELEASE app in a store-shots simulator with a TV, skipped unless STORE_PAIR_HOST is set (pass it and
/// STORE_PAIR_CODE_FILE as TEST_RUNNER_ variables, with -parallel-testing-enabled NO so the real simulator is used).
/// Picks the TV from the list (or types its address), creates <code file>.ready once the TV shows its code, then waits
/// for the code in the file (read off the TV, e.g. adb exec-out screencap) and types it on the keypad.
final class StorePairing: XCTestCase {
    func testPairWithTheTV() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["STORE_PAIR_HOST"], let codeFile = env["STORE_PAIR_CODE_FILE"] else { throw XCTSkip("Runs from scripts/store-shots-auto.sh") }
        let app = XCUIApplication(bundleIdentifier: "com.guilhermeramalho.TVRemote")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.tabBars.buttons["Remote"].tap()
        // Picked from the list when the TV is found, so the app knows its name; typed in otherwise.
        let listed = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", host)).firstMatch
        if listed.waitForExistence(timeout: 15) { listed.tap() } else {
            let manual = app.buttons["My TV isn't listed: enter its address"]
            let instead = app.buttons["Enter the TV's address instead"]
            XCTAssertTrue(manual.exists || instead.exists, "no Connect screen (already paired?)")
            (manual.exists ? manual : instead).tap()
            let field = app.textFields["The TV's IP address"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap(); field.typeText(host)
            app.buttons["Connect"].tap()
        }
        XCTAssertTrue(app.otherElements["Pairing code"].waitForExistence(timeout: 20) || app.staticTexts["Enter the code on your TV"].exists, "the TV didn't show a code")
        try? FileManager.default.removeItem(atPath: codeFile + ".ready")
        FileManager.default.createFile(atPath: codeFile + ".ready", contents: Data())
        var code = ""
        for _ in 0..<120 where code.count != 6 {
            code = ((try? String(contentsOfFile: codeFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if code.count != 6 { Thread.sleep(forTimeInterval: 1) }
        }
        XCTAssertEqual(code.count, 6, "no code written to \(codeFile)")
        for character in code { app.buttons[String(character)].firstMatch.tap() }
        Thread.sleep(forTimeInterval: 6)
        XCTAssertFalse(app.staticTexts["Enter the code on your TV"].exists, "code not accepted")
        app.terminate()
    }
}
