import XCTest

/// Smoke tests of the main screens, without a TV (TESTING.md: UI-*). They run on a simulator from the
/// "Debloated TV Dev" scheme. A made-up TV address keeps the app from reaching a real TV, and the debug-only launch
/// arguments in TVRemoteApp.swift (UITestHooks) put the TV tab in each state.
final class TVRemoteUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(tvState: String = "fresh", offer: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // 192.0.2.x is reserved for documentation: nothing answers there.
        // -e2eNoDiscovery: the Connect screen never searches or knocks on TVs on this Mac's network.
        app.launchArguments = ["-tvHost", "192.0.2.10", "-uiTestTVState", tvState, "-uiTestOffer", offer ? "YES" : "NO",
                               "-e2eNoDiscovery", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]   // the assertions read English text
        app.launch()
        return app
    }

    /// UI-10 / CST-01: the remote's header keeps Show on TV, Type on TV and Inputs on screen without squeezing the
    /// TV's name, on every phone size (run on the 4.7-inch SE and a Pro Max). SHOTS_DIR saves a screenshot.
    func testHeaderFitsShowOnTV() throws {
        let app = launchRemote()
        let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'offline' OR label CONTAINS[c] 'standby' OR label CONTAINS[c] '192.0.2'")).firstMatch
        // 1.3: Inputs moved from the header to the round keys under the pad.
        let buttons = [app.buttons["showOnTV"], app.buttons["typeOnTV"]]
        for button in buttons { XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertTrue(button.isHittable, button.identifier) }
        let width = app.windows.firstMatch.frame.width
        XCTAssertLessThanOrEqual(buttons[1].frame.maxX, width - 8, "typing button off the edge")
        XCTAssertLessThan(buttons[0].frame.maxX, buttons[1].frame.minX)
        if chip.exists { XCTAssertGreaterThanOrEqual(chip.frame.width, 90, "the TV's name lost its room") }
        save(app, "header-\(Int(width))")
    }

    /// AST-05: with the assistant on, its button joins the header and everything still fits (the SE gets smaller
    /// buttons); it opens the Ask Purio sheet with a text field (dictation is the keyboard's mic).
    func testHeaderFitsTheAssistantButton() throws {
        let app = launchRemote(extra: ["-uiTestAssistant"])
        let buttons = [app.buttons["askPurio"], app.buttons["showOnTV"], app.buttons["typeOnTV"]]
        for button in buttons { XCTAssertTrue(button.waitForExistence(timeout: 5), button.identifier); XCTAssertTrue(button.isHittable, button.identifier) }
        let width = app.windows.firstMatch.frame.width
        XCTAssertLessThanOrEqual(buttons[2].frame.maxX, width - 8, "typing button off the edge")
        let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'offline' OR label CONTAINS[c] 'standby' OR label CONTAINS[c] '192.0.2' OR label CONTAINS[c] 'connection'")).firstMatch
        if chip.exists { XCTAssertGreaterThanOrEqual(chip.frame.width, 60, "the TV's name lost its room") }
        save(app, "header-assistant-\(Int(width))")
        app.buttons["askPurio"].tap()
        XCTAssertTrue(app.textFields["assistantField"].waitForExistence(timeout: 5) || app.textViews["assistantField"].exists)
        save(app, "assistant-\(Int(width))")
    }

    /// CST-04: the library opens from the header, a photo opens full screen, and a TV that can't be reached says so.
    /// Grant photo access first: xcrun simctl privacy <udid> grant photos com.guilhermeramalho.TVRemote.dev
    func testShowOnTVOpensAPhotoFullScreen() throws {
        let app = launchRemote()
        addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.buttons["showOnTV"].tap()
        XCTAssertTrue(app.navigationBars["Show on TV"].waitForExistence(timeout: 5))
        app.tap()   // lets the interruption monitor answer the permission prompt
        let item = app.descendants(matching: .any).matching(identifier: "libraryItem").firstMatch
        let found = item.waitForExistence(timeout: 10)
        save(app, "library")
        // GitHub's simulators show an empty library even with a photo added and access granted; there the rest is
        // skipped (CI sets PURIO_CI through TEST_RUNNER_PURIO_CI). On a developer's simulator it must pass.
        if !found, ProcessInfo.processInfo.environment["PURIO_CI"] == "1" { throw XCTSkip("CI simulator shows no photos") }
        XCTAssertTrue(found, "no photos in the simulator's library")
        item.tap()
        XCTAssertTrue(app.buttons["viewerBack"].waitForExistence(timeout: 5))
        save(app, "viewer")
        // 192.0.2.10 never answers: after the connection timeout the TV problem is explained.
        let alert = app.alerts["Purio TV"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "no message for an unreachable TV")
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS \"Couldn't reach the TV\"")).firstMatch.exists)
        save(app, "no-cast")
        alert.buttons["Keep browsing"].tap()
        app.buttons["viewerBack"].tap()
        app.buttons["closeShowOnTV"].tap()
        XCTAssertTrue(app.buttons["showOnTV"].waitForExistence(timeout: 5))
    }

    /// CST-27: a TV that refuses the Cast port (here this Mac: nothing listens on 127.0.0.1:8009) is explained as
    /// soon as Show on TV opens, above the library, with Check again.
    func testShowOnTVSaysAtOnceWhenTheTVHasNoChromecastBuiltIn() throws {
        let app = launchRemote(host: "127.0.0.1")
        addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.buttons["showOnTV"].tap()
        XCTAssertTrue(app.navigationBars["Show on TV"].waitForExistence(timeout: 5))
        app.tap()
        let banner = app.descendants(matching: .any)["noCast"]
        XCTAssertTrue(banner.waitForExistence(timeout: 8), "no up-front message for a TV without Chromecast built in")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Chromecast built in'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["checkCastAgain"].exists)
        save(app, "no-chromecast")
        app.buttons["closeShowOnTV"].tap()
    }

    /// REM-21: a Roku's remote keeps only the keys a Roku has (no subtitles, no input menu).
    func testRokuRemoteShowsOnlyTheKeysARokuHas() throws {
        let app = launchRemote(extra: ["-tvKinds", "{ \"192.0.2.10\" = roku; }"])
        XCTAssertTrue(app.buttons["remote-house.fill"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["remote-backward.fill"].exists)
        XCTAssertFalse(app.buttons["remote-captions.bubble"].exists, "Roku has no subtitles key")
        XCTAssertTrue(app.buttons["remote-gearshape"].exists, "Roku's * (options) key")
        XCTAssertFalse(app.buttons["inputsKey"].exists, "Roku has no input menu")
        XCTAssertTrue(app.buttons["showOnTV"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["padMode"].exists, "Roku has no number keys")
        save(app, "remote-roku")
    }

    /// REM-25: D-pad / Numbers swaps the pad for a number pad and back; the channel pill and the round keys sit
    /// between volume and channels; Inputs is a round key.
    func testNumberPadAndChannelPill() throws {
        let app = launchRemote()
        let numbers = app.buttons["Numbers"]
        XCTAssertTrue(numbers.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Channel up"].exists && app.buttons["Channel down"].exists)
        XCTAssertTrue(app.buttons["inputsKey"].exists, "Inputs among the round keys")
        XCTAssertTrue(app.buttons["remote-house.fill"].exists && app.buttons["remote-gearshape"].exists)
        save(app, "remote-dpad")
        numbers.tap()
        for n in 0...9 { XCTAssertTrue(app.buttons["digit-\(n)"].waitForExistence(timeout: 2), "digit \(n)") }
        XCTAssertTrue(app.buttons["numberOK"].exists && app.buttons["Delete"].exists)
        save(app, "remote-numbers")
        app.buttons["D-pad"].tap()
        XCTAssertFalse(app.buttons["digit-5"].waitForExistence(timeout: 1))
    }

    /// REM-26: the app row ends with All apps, which lists the TV's apps A to Z.
    func testAllAppsListsTheTVsApps() throws {
        let app = launchRemote()
        let all = app.buttons["allApps"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Netflix"].exists)
        all.tap()
        XCTAssertTrue(app.navigationBars["All apps"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "allAppsRow").count, 3, "a screenful of the TV's apps")
        save(app, "all-apps")
    }

    private func launchRemote(host: String = "192.0.2.10", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tvHost", host, "-uiTestRemote", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        app.tabBars.buttons["Remote"].tap()
        return app
    }
    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
        }
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

    /// KWT-04: the TV tab's Keep watching strip (sample shows), and a tap opens Resume on TV.
    func testKeepWatchingStripOpensResume() throws {
        // Keep watching sits on the Remote tab while the TV shows Purio Home (1.3).
        let app = launchRemote(extra: keepWatchingArguments)
        let cards = app.buttons.matching(identifier: "keepWatchingCard")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cards.count, 3)
        XCTAssertTrue(cards.firstMatch.label.contains("[Show title]"), cards.firstMatch.label)
        XCTAssertTrue(cards.firstMatch.label.contains("S2 · E5 · 23 min left"), cards.firstMatch.label)
        save(app, "keep-watching")
        cards.firstMatch.tap()
        XCTAssertTrue(app.buttons["resumeOnTV"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove from Keep watching"].exists)
        save(app, "keep-watching-sheet")
    }

    /// KWT-06: See all opens the full list; a row opens Resume on TV.
    func testKeepWatchingSeeAllListsEveryShow() throws {
        let app = launchRemote(extra: keepWatchingArguments)
        let seeAll = app.buttons["keepWatchingSeeAll"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 5))
        seeAll.tap()
        let rows = app.buttons.matching(identifier: "keepWatchingRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.element(boundBy: 1).label.contains("Prime Video"), rows.element(boundBy: 1).label)
        save(app, "keep-watching-all")
        rows.firstMatch.tap()
        XCTAssertTrue(app.buttons["resumeOnTV"].waitForExistence(timeout: 5))
    }

    private let keepWatchingArguments = ["-uiTestTVState", "installed", "-uiTestOffer", "NO", "-uiTestKeepWatching", "YES", "-e2eNoDiscovery"]

    /// KWT-07: Settings › Keep watching on the remote hides the row and brings it back.
    func testKeepWatchingSettingHidesTheRow() throws {
        let app = launchRemote(extra: keepWatchingArguments)
        let cards = app.buttons.matching(identifier: "keepWatchingCard")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["keepWatchingSetting"].exists ? app.switches["keepWatchingSetting"] : app.descendants(matching: .any)["keepWatchingSetting"]
        var tries = 0
        while !toggle.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
        toggle.tap()
        app.tabBars.buttons["Remote"].tap()
        XCTAssertFalse(cards.firstMatch.waitForExistence(timeout: 2), "the row stays hidden while the setting is off")
        app.tabBars.buttons["Settings"].tap()
        tries = 0
        while !toggle.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
        toggle.tap()   // back on, so other runs start from the default
        app.tabBars.buttons["Remote"].tap()
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
    }

    /// CON-17: each found TV says what it is and what Purio can do on it; a Chromecast can't be picked.
    func testFoundTVsSayWhatTheyAreAndOnlyAndroidTVsPair() {
        let app = XCUIApplication()
        app.launchArguments = ["-tvHost", "192.0.2.10", "-uiTestFoundTVs", "YES", "-e2eNoDiscovery", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.tabBars.buttons["Remote"].tap()
        let rows = app.buttons.matching(identifier: "foundTV")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 4)
        let lg = rows.matching(NSPredicate(format: "value == '192.0.2.20'")).firstMatch
        XCTAssertTrue(lg.label.contains("LG webOS · Remote and apps · Beta"), lg.label)
        XCTAssertTrue(lg.isEnabled)
        let cast = rows.matching(NSPredicate(format: "value == '192.0.2.21'")).firstMatch
        XCTAssertTrue(cast.label.contains("Chromecast · Not supported yet"), cast.label)
        XCTAssertFalse(cast.isEnabled)
        let tv = rows.matching(NSPredicate(format: "value == '192.0.2.13'")).firstMatch
        XCTAssertTrue(tv.label.contains("Android TV · Remote, setup and Show on TV"), tv.label)
        XCTAssertTrue(tv.isEnabled)
        for row in rows.allElementsBoundByIndex { XCTAssertLessThanOrEqual(row.frame.maxX, app.frame.maxX + 0.5, "fits the screen") }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "found-tvs"; shot.lifetime = .keepAlways; add(shot)
    }

    func testFirstLaunchGuidesToConnectAndTheAddressFieldTakesDots() {
        let app = launch()
        app.tabBars.buttons["Remote"].tap()
        XCTAssertTrue(app.staticTexts["Connect your TV"].waitForExistence(timeout: 5) || app.staticTexts["No TV found yet"].exists)
        let manual = app.buttons["My TV isn't listed: enter its address"].exists ? app.buttons["My TV isn't listed: enter its address"] : app.buttons["Enter the TV's address instead"]
        manual.tap()
        let field = app.textFields["The TV's IP address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
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
            let demo = env["STORE_SHOTS_DEMO"] == "1"
            app = XCUIApplication(bundleIdentifier: demo ? "com.guilhermeramalho.TVRemote.dev" : "com.guilhermeramalho.TVRemote")
            let locale = lang == "en" ? "en_US" : lang.replacingOccurrences(of: "-", with: "_")
            app.launchArguments = ["-AppleLanguages", "(\(lang))", "-AppleLocale", locale] + (demo ? ["-storeDemo", "YES"] : [])
            app.launch()
            let tabs = app.tabBars.buttons
            XCTAssertTrue(tabs.element(boundBy: 0).waitForExistence(timeout: 10), "\(lang): app didn't start")
            if demo { demoShots(tabs); app.terminate(); continue }
            if env["STORE_SHOTS_ONLY"] == "03" { setupReview(tabs); app.terminate(); continue }
            if env["STORE_SHOTS_ONLY"] == "cast" { tabs.element(boundBy: 0).tap(); pause(5); castShots(); app.terminate(); continue }

            tabs.element(boundBy: 0).tap(); pause(5)            // the remote connects to the paired TV
            shot("01-remote")
            castShots()
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

    /// 08 and 09 (1.2 build 22): Show on TV with the paired TV. The newest photo full screen once the TV shows it,
    /// then the newest item, a 4K video, playing on the TV. Needs photo access granted and that video in the library
    /// (store-shots-auto.sh). Casts to the real TV for a few seconds and stops.
    private func castShots() {
        let open = app.buttons["showOnTV"]
        guard open.waitForExistence(timeout: 5) else { print("STORE-SHOTS: no Show on TV button"); return }
        addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        open.tap()
        pause(2); app.tap()       // lets the monitor answer the first-time prompt
        let items = app.descendants(matching: .any).matching(identifier: "libraryItem")
        guard items.firstMatch.waitForExistence(timeout: 10), items.count >= 2 else {
            print("STORE-SHOTS: no photos (access not granted?)"); app.buttons["closeShowOnTV"].tap(); return
        }
        let count = items.count
        items.element(boundBy: count - 2).tap()
        if app.buttons["tvPill.on"].waitForExistence(timeout: 40) { pause(3); shot("08-show-on-tv") }
        else { print("STORE-SHOTS: the TV didn't show the photo") }
        app.buttons["viewerBack"].tap(); pause(2)
        items.element(boundBy: count - 1).tap()
        if app.descendants(matching: .any)["castingAnimation"].waitForExistence(timeout: 60) { pause(4); shot("09-show-video") }
        else { print("STORE-SHOTS: the video didn't start on the TV") }
        if app.buttons["stopOnTV"].exists { app.buttons["stopOnTV"].tap(); pause(2) }
        app.buttons["viewerBack"].tap(); pause(1)
        app.buttons["closeShowOnTV"].tap(); pause(1)
    }

    /// 1.3: the Dev app's store demo (`-storeDemo`, no TV): the remote on Purio Home, the remote scrolled to its
    /// Keep watching row, and the Inputs sheet with the TV's inputs.
    private func demoShots(_ tabs: XCUIElementQuery) {
        tabs.element(boundBy: 0).tap(); pause(2)
        shot("01-remote")
        let inputs = app.buttons["inputsKey"]
        if inputs.waitForExistence(timeout: 3) {
            inputs.tap(); pause(2)
            shot("10-inputs")
            app.navigationBars.buttons.firstMatch.tap(); pause(1)
        } else { print("STORE-SHOTS: no Inputs key") }
        // Last: a slow drag below the pad (no fling) to the end of the remote, Keep watching above the tab bar.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0.5)
        pause(2); shot("11-keep-watching")
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
        let listed = app.buttons.matching(NSPredicate(format: "identifier == 'foundTV' AND value CONTAINS %@", host)).firstMatch
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

/// The 1.2 remote checks (TESTING.md REM-17, REM-18, REM-19) against a real TV, with the RELEASE app already paired
/// in the simulator. Skipped unless TCL_CHECKS_DIR is set (pass it as TEST_RUNNER_TCL_CHECKS_DIR, with
/// -parallel-testing-enabled NO). At each step that needs the TV side it creates <dir>/<step>.ready and waits for
/// <dir>/<step>.go, which scripts/tcl-checks.py answers after reading the TV over ADB (mute state, keys received) or
/// pressing its keys.
/// Results go to <dir>/results.txt as "name=value" lines.
final class TCLChecks: XCTestCase {
    private var dir = ""
    private var app: XCUIApplication!

    func testRemote12OnTheTV() throws {
        guard let out = ProcessInfo.processInfo.environment["TCL_CHECKS_DIR"], !out.isEmpty else { throw XCTSkip("Runs with TCL_CHECKS_DIR") }
        dir = out
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: "com.guilhermeramalho.TVRemote")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        openRemote()
        if ProcessInfo.processInfo.environment["TCL_CHECKS_ONLY"] == "rem19" { typeOnTV(); return }

        // REM-17: mute from the app, unmute and mute with the TV's own key, reconnect while muted.
        report("rem17.start", muteLabel())
        sync("rem17-start")
        mute.tap()
        report("rem17.afterAppMute", waitLabel("Unmute") + " mutedText=\(app.staticTexts["Muted"].exists)")
        shot("rem17-muted")
        sync("rem17-muted-from-app")          // the script checks the TV is muted, then presses its mute key
        report("rem17.afterTVUnmute", waitLabel("Mute"))
        sync("rem17-unmuted-from-tv")         // the script mutes again with the TV's key
        report("rem17.afterTVMute", waitLabel("Unmute"))
        app.terminate()
        openRemote()
        report("rem17.afterReconnect", waitLabel("Unmute"))
        mute.tap()
        report("rem17.afterAppUnmute", waitLabel("Mute"))
        sync("rem17-done")                    // the script checks the TV is unmuted

        // REM-18: reverse swipe on, swipes go the other way, survives a restart; off goes back to normal.
        setReverse(true)
        openRemoteTab()
        sync("rem18-reversed-before")         // the script starts recording the keys the TV receives
        swipe(dx: -110, dy: 0); sleep(2)
        swipe(dx: 0, dy: -110); sleep(2)
        sync("rem18-reversed-after")          // expect RIGHT, then DOWN
        app.terminate()
        app.launch()
        report("rem18.afterRestart", reverseSwitch().value as? String ?? "?")
        setReverse(false)
        openRemoteTab()
        sync("rem18-normal-before")
        swipe(dx: -110, dy: 0); sleep(2)
        sync("rem18-normal-after")            // expect LEFT

        typeOnTV()
        sync("done")
    }

    /// REM-19: Type on TV opens focused with the keyboard up; "Hide text while typing" keeps the focus.
    private func typeOnTV() {
        app.buttons["typeOnTV"].tap()
        sleep(1)
        let field = app.textFields["Search or enter text"]
        report("rem19.fieldFocused", "\(field.exists && (field.value(forKey: "hasKeyboardFocus") as? Bool ?? false)) keyboard=\(app.keyboards.count > 0)")
        shot("rem19-keyboard")
        let hide = app.switches.containing(NSPredicate(format: "label CONTAINS %@", "Hide text while typing")).firstMatch
        hide.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()   // the switch itself, at the right
        sleep(1)
        let secure = app.secureTextFields["Search or enter text"]
        report("rem19.secureFocused", "switch=\(hide.value as? String ?? "?") \(secure.exists && (secure.value(forKey: "hasKeyboardFocus") as? Bool ?? false)) keyboard=\(app.keyboards.count > 0)")
        shot("rem19-secure")
        hide.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()   // the switch itself, at the right
        sleep(1)
        report("rem19.plainAgainFocused", "\(field.exists && (field.value(forKey: "hasKeyboardFocus") as? Bool ?? false)) keyboard=\(app.keyboards.count > 0)")
        shot("rem19-plain-again")
        app.navigationBars.buttons["Done"].tap()
    }

    private var mute: XCUIElement { app.buttons.matching(NSPredicate(format: "label == 'Mute' OR label == 'Unmute'")).firstMatch }
    private func muteLabel() -> String { mute.exists ? mute.label : "missing" }
    private func waitLabel(_ expected: String) -> String {
        for _ in 0..<20 where muteLabel() != expected { Thread.sleep(forTimeInterval: 0.5) }
        return muteLabel()
    }
    private func openRemote() {
        app.launch()
        openRemoteTab()
        let ready = NSPredicate(format: "isEnabled == true")
        expectation(for: ready, evaluatedWith: mute)
        waitForExpectations(timeout: 30)
        sleep(2)                                // the TV's first volume report
    }
    private func openRemoteTab() { app.tabBars.buttons.element(boundBy: 0).tap(); sleep(1) }
    private func reverseSwitch() -> XCUIElement {
        app.tabBars.buttons.element(boundBy: 3).tap(); sleep(1)
        let toggle = app.switches.containing(NSPredicate(format: "label CONTAINS %@", "Reverse swipe direction")).firstMatch
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        return toggle
    }
    private func setReverse(_ on: Bool) {
        let toggle = reverseSwitch()
        if (toggle.value as? String == "1") != on { toggle.tap() }
        report("rem18.switch", toggle.value as? String ?? "?")
    }
    private func swipe(dx: CGFloat, dy: CGFloat) {
        let centre = app.buttons["Select"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.press(forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: dx, dy: dy)))
    }
    private func report(_ name: String, _ value: String) {
        let line = "\(name)=\(value)\n"
        print("TCL-CHECK " + line, terminator: "")
        let path = dir + "/results.txt"
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile() }
        else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
    }
    private func sync(_ step: String) {
        FileManager.default.createFile(atPath: "\(dir)/\(step).ready", contents: Data())
        for _ in 0..<240 where !FileManager.default.fileExists(atPath: "\(dir)/\(step).go") { Thread.sleep(forTimeInterval: 0.5) }
    }
    private func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
