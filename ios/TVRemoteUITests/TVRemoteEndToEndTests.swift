import XCTest

/// End to end: this app in the iOS Simulator against the Android TV emulator, through the real protocols (pairing and
/// remote on 6467/6466, ADB on 5555, the Home editor on 9764). Covers the CON, REM, SET, DBL, LCH, EDT and UND cases
/// TESTING.md marks "Manual, emulator" (see its "End-to-end suite" section for the mapping).
///
/// Run it with `scripts/e2e.sh`: it resets the emulator, forwards its ports to this Mac, starts the helper
/// (`scripts/e2e-helper.py`) that does the TV side over adb (reads the pairing code off the screen, accepts the
/// debugging prompt, reports what's in front), and sets E2E_HELPER for this test. Without E2E_HELPER the test skips,
/// so plain Xcode test runs and CI don't need an emulator.
final class TVRemoteEndToEndTests: XCTestCase {
    private var tv: E2EHelper!
    private var app: XCUIApplication!
    private var host = "127.0.0.1"
    private var adbAddress = "127.0.0.1:15555"
    private let launcher = "com.gathin.tvhome"
    private let stockLauncher = "com.google.android.tvlauncher"
    private let youtube = "com.google.android.youtube.tv"
    /// The development profile's list (Resources/Profiles/dev-android-tv-emulator/debloat.txt).
    private let listed = ["com.google.android.feedback", "com.google.android.partnersetup", "com.google.android.tvrecommendations",
                          "com.google.android.marvin.talkback", "com.google.android.play.games"]
    private let kept = "com.google.android.marvin.talkback"   // installed on the emulator image (Play Games is not)
    private let checklist = ["Home opens the new Home screen", "The remote's app buttons and volume work",
                             "An HDMI input shows a picture", "Settings opens from Home", "The TV is still online (open an app)"]
    /// Whether the TV's remote control channel (6466) came up after pairing. The Android TV emulator image on hand
    /// (android-tv, API 31) pairs but closes every control connection at the TLS hello (it has no remote input
    /// bridge), so the remote and editor cases run only where the channel works; the run says which it was.
    private var remoteUp = false

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["E2E_HELPER"], let url = URL(string: base) else {
            throw XCTSkip("Set E2E_HELPER (scripts/e2e.sh does) to run the end-to-end suite against the emulator")
        }
        continueAfterFailure = false
        tv = E2EHelper(base: url)
        host = env["E2E_TV_HOST"] ?? host
        adbAddress = env["E2E_ADB_ADDRESS"] ?? adbAddress
        _ = try tv.call("ping")
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]   // the assertions read English text
    }

    override func tearDown() {
        if let app, app.state != .notRunning {
            let texts = app.staticTexts.allElementsBoundByIndex.prefix(60).map(\.label).joined(separator: "\n")
            note("On screen at the end:\n" + texts)
        }
    }

    /// One run, in the order a user goes through it. The TV changes along the way, so the phases build on each other.
    func testPairSetUpEditUndoAndSecure() throws {
        app.launch()
        try pair()
        try remote()
        try runSetup()
        try edit()
        try undo()
        try secondRunAndTurnDebuggingOff()
    }

    // MARK: CON

    private func pair() throws {
        try step("CON-01e: enter the TV's address when it isn't listed") {
            app.tabBars.buttons["Remote"].tap()
            XCTAssertTrue(app.staticTexts["Connect your TV"].waitForExistence(timeout: 10) || app.staticTexts["No TV found yet"].exists)
            let listed = app.buttons["My TV isn't listed: enter its address"]
            (listed.exists ? listed : app.buttons["Enter the TV's address instead"]).tap()
            let field = app.textFields["The TV's IP address"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap(); field.typeText(host)
            XCTAssertTrue(app.staticTexts["Looks right"].waitForExistence(timeout: 3))
            app.buttons["Connect"].tap()
        }
        var code = ""
        try step("CON-01b/CON-03: the TV shows a code; a wrong one is refused") {
            XCTAssertTrue(app.staticTexts["Enter the code on your TV"].waitForExistence(timeout: 45), "the TV should show a pairing code")
            code = try tv.pairingCode()
            let wrong = String(code.first == "0" ? "1" : "0") + code.dropFirst()
            type(code: wrong)
            // The phone checks the code against the TV's key first ("does not match"); a code that passes that check
            // but is wrong for the TV comes back as rejected or a closed connection.
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'does not match' OR label CONTAINS[c] 'rejected' OR label CONTAINS[c] 'closed' OR label CONTAINS[c] 'expired' OR label CONTAINS[c] 'interrupted'")).firstMatch.waitForExistence(timeout: 20), "a wrong code should show an error in the sheet: \(visibleErrors())")
        }
        try step("CON-02: delete, type the right code; the pairing sheet closes") {
            // The TV keeps showing the same code after the phone's own check refused the wrong one.
            for _ in 0..<6 { app.buttons["Delete"].tap() }
            XCTAssertTrue(app.staticTexts["Enter the code on your TV"].exists)
            type(code: code)
            XCTAssertTrue(waitUntil(30) { !self.app.staticTexts["Enter the code on your TV"].exists }, "the pairing sheet should close: \(visibleErrors())")
            remoteUp = waitUntil(30) { self.app.buttons["Home"].firstMatch.isEnabled }
            note(remoteUp ? "Remote control channel: up" : "Remote control channel: not available on this TV (the emulator closes port 6466); REM, SET-10 and EDT skipped")
        }
        if remoteUp {
            try step("SET-10/SET-12: the one-time setup offer after pairing, declined") {
                XCTAssertTrue(app.staticTexts["Your TV can be a lot faster"].waitForExistence(timeout: 15), "the offer should appear once the TV reports its stock Home")
                app.buttons["Not now"].tap()
                XCTAssertTrue(waitUntil(5) { !self.app.staticTexts["Your TV can be a lot faster"].exists })
            }
        }
        try step("CON-08: reopen the app, it keeps the pairing and asks for no code") {
            app.terminate()
            app.launch()
            app.tabBars.buttons["Remote"].tap()
            XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 10), "the remote screen, not the connect screen")
            if remoteUp { waitForRemote() }
            XCTAssertFalse(app.staticTexts["Enter the code on your TV"].exists)
            XCTAssertFalse(app.staticTexts["Connect your TV"].exists)
            XCTAssertFalse(app.staticTexts["Your TV can be a lot faster"].exists, "the offer shows once only")
        }
    }

    // MARK: REM

    private func remote() throws {
        guard remoteUp else { return }
        try step("REM-10: a streaming shortcut opens the app on the TV; the header shows it") {
            app.buttons["Open YouTube"].firstMatch.tap()
            _ = try tv.waitForeground(youtube, timeout: 30)
            XCTAssertTrue(app.descendants(matching: .any)["On TV: YouTube"].waitForExistence(timeout: 15), "the remote should report YouTube in front")
        }
        try step("REM-04: Home brings the stock launcher back") {
            app.buttons["Home"].firstMatch.tap()
            _ = try tv.waitForeground(stockLauncher, timeout: 20)
        }
        try step("REM-01: D-pad taps and Back are accepted") {
            for key in ["right", "left", "down", "up"] { app.buttons[key].firstMatch.tap() }
            app.buttons["Back"].firstMatch.tap()
            _ = try tv.waitForeground(stockLauncher, timeout: 10)
        }
        try step("REM-05: volume up changes the TV's volume, as the TV reports it") {
            let label = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Volume' OR label == 'Muted'")).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 10), "the TV should report its volume")
            let before = label.label
            app.buttons["volumeUp"].firstMatch.tap()
            XCTAssertTrue(waitUntil(10) { label.label != before }, "volume should change from '\(before)'")
            app.buttons["volumeDown"].firstMatch.tap()
        }
    }

    // MARK: DBL and LCH

    private func runSetup() throws {
        try step("SET-01/SET-02/DBL-01: the TV tab leads with setup; Continue needs the risks acknowledged") {
            app.tabBars.buttons["TV"].tap()
            XCTAssertTrue(app.staticTexts["Make your TV faster"].waitForExistence(timeout: 10))
            app.buttons["Start setup"].tap()
            XCTAssertTrue(app.navigationBars["Set up TV"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Continue"].isEnabled)
            app.switches["I understand the risks"].tap()
            XCTAssertTrue(waitUntil(3) { self.app.buttons["Continue"].isEnabled })
            app.buttons["Continue"].tap()
        }
        try step("DBL-04/DBL-05: connect with a port in the address; approve this iPhone on the TV") {
            try connectSetup()
            XCTAssertTrue(app.staticTexts["Allow this iPhone on the TV"].waitForExistence(timeout: 30), "the TV should ask to allow this iPhone")
            _ = try tv.call("approve-debugging", ["timeout": "60"])
            XCTAssertTrue(app.staticTexts["Choose what stays"].waitForExistence(timeout: 90), "the emulator should be recognised: \(visibleErrors())")
        }
        try step("DBL-07: keep one app on") {
            XCTAssertTrue(app.switches[kept].waitForExistence(timeout: 5), "the development list should offer \(kept)")
            app.switches[kept].tap()
            app.buttons["Review changes"].tap()
        }
        try step("DBL-08/DBL-11: review, then apply") {
            let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+ apps will be disabled'")).firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 60), "the review should say how many apps are disabled: \(visibleErrors())")
            let count = Int(summary.label.split(separator: " ").first ?? "") ?? -1
            XCTAssertTrue((1...4).contains(count), "expected between 1 and 4 of the 5 listed apps (one kept), got \(summary.label)")
            XCTAssertFalse(app.buttons["Continue"].isEnabled)
            app.switches["I reviewed these changes"].tap()
            app.buttons["Continue"].tap()
            XCTAssertTrue(app.staticTexts["Choose Home"].waitForExistence(timeout: 5))
            XCTAssertEqual(installSwitch.value as? String, "1", "the Home install is on by default")
            app.buttons["Apply to TV"].tap()
            XCTAssertTrue(app.staticTexts["Test on the TV"].waitForExistence(timeout: 300), "apply and the Home install should finish: \(visibleErrors())")
        }
        try step("LCH-01/LCH-02/LCH-11: the new Home owns Home, the stock one is off, the chosen apps are disabled") {
            XCTAssertEqual(try tv.home(), launcher + "/.MainActivity")
            let disabled = try tv.disabled()
            XCTAssertTrue(disabled.contains(stockLauncher), "the stock launcher should be disabled after the handover")
            XCTAssertFalse(disabled.contains(kept), "the kept app must stay enabled")
            XCTAssertFalse(disabled.contains(youtube))
            XCTAssertFalse(disabled.contains("com.google.android.tv.remote.service"), "never-disable packages stay on")
            XCTAssertTrue(disabled.contains("com.google.android.feedback") || disabled.contains("com.google.android.partnersetup"))
            _ = try tv.call("key", ["code": "KEYCODE_HOME"])
            _ = try tv.waitForeground(launcher, timeout: 15)
            let dock = (try tv.launcherConfig()?["dock_apps"] as? [String]) ?? []
            XCTAssertTrue(dock.contains(youtube), "the dock chosen in setup should be in the launcher's config, got \(dock)")
        }
        try step("DBL-15: every check ticked before 'Everything works'") {
            XCTAssertFalse(app.buttons["Everything works"].isEnabled)
            for item in checklist { app.switches[item].tap() }
            XCTAssertTrue(waitUntil(3) { self.app.buttons["Everything works"].isEnabled })
            app.buttons["Everything works"].tap()
            XCTAssertTrue(app.staticTexts["Secure the TV"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Export recovery record"].exists, "DBL-17: the record can be exported")
            app.buttons["Done"].tap()
        }
        try step("SET-06/SET-09: the TV tab now shows the Debloated strip and the editor") {
            XCTAssertTrue(app.staticTexts["Debloated"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'apps off · new Home screen'")).firstMatch.exists)
            XCTAssertTrue(app.staticTexts["Changes apply to the TV automatically."].exists, "the editor is on the TV tab")
        }
    }

    // MARK: EDT

    private func edit() throws {
        guard remoteUp else { return }
        try step("EDT-01/EDT-13: with Home in front, the editor connects by itself through the remote's app link") {
            XCTAssertTrue(waitForEditor(), "the editor should connect: \(visibleErrors())")
        }
        try step("EDT-05: hide an app; it reaches the TV's launcher config without tapping Apply") {
            app.staticTexts["Apps & order"].tap()
            XCTAssertTrue(app.navigationBars["Apps & order"].waitForExistence(timeout: 5))
            app.staticTexts["YouTube"].firstMatch.tap()
            XCTAssertTrue(app.switches["Show on TV Home"].waitForExistence(timeout: 5))
            app.switches["Show on TV Home"].tap()
            app.buttons["Done"].tap()
            app.navigationBars["Apps & order"].buttons.element(boundBy: 0).tap()
            XCTAssertFalse(app.buttons["Apply to TV"].exists, "an edit needs no Apply")
            XCTAssertTrue(waitUntil(30) { ((try? self.tv.launcherConfig()?["hidden_apps"] as? [String]) ?? []).contains(self.youtube) },
                          "the edit should reach the TV by itself: \(visibleErrors())")
            // Put it back, so the TV stays as setup left it.
            app.staticTexts["Apps & order"].tap()
            app.staticTexts["YouTube"].firstMatch.tap()
            XCTAssertTrue(app.switches["Show on TV Home"].waitForExistence(timeout: 5))
            app.switches["Show on TV Home"].tap()
            app.buttons["Done"].tap()
            app.navigationBars["Apps & order"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(waitUntil(30) { ((try? self.tv.launcherConfig()?["hidden_apps"] as? [String]) ?? []).contains(self.youtube) == false })
        }
        try step("EDT-09: profiles keep their own layout; the chosen one applies") {
            app.buttons["New profile"].tap()
            let alert = app.alerts["New profile"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            alert.textFields.firstMatch.typeText("Kids")
            alert.buttons["Create"].tap()
            XCTAssertTrue(waitUntil(5) { self.app.buttons["Launcher profile"].value as? String == "Kids" })
            app.buttons["More dock icons"].tap()
            XCTAssertTrue(app.staticTexts["6 dock icons"].waitForExistence(timeout: 3))
            app.buttons["Launcher profile"].tap()
            app.buttons["Personal"].tap()
            XCTAssertTrue(app.staticTexts["5 dock icons"].waitForExistence(timeout: 5), "Personal keeps its own dock count")
            app.buttons["Launcher profile"].tap()
            app.buttons["Kids"].tap()
            XCTAssertTrue(app.staticTexts["6 dock icons"].waitForExistence(timeout: 5), "Kids keeps its own dock count")
            app.buttons["Apply to TV"].tap()
            XCTAssertTrue(app.staticTexts["TV Home updated"].waitForExistence(timeout: 30), visibleErrors())
        }
        try step("EDT-08: load the current TV layout into the draft") {
            app.buttons["Load current TV layout"].tap()
            app.buttons["Load TV layout"].tap()
            XCTAssertTrue(waitUntil(5) { !self.app.buttons["Load TV layout"].exists })
            XCTAssertFalse(app.alerts["Debloated TV"].exists, "loading the TV layout should not raise an error")
        }
        try step("EDT-02/EDT-03: with an app on screen the editor asks first; Connect now reconnects") {
            _ = try tv.call("start", ["package": youtube])
            _ = try tv.waitForeground(youtube, timeout: 30)
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(app.buttons["Connect now"].waitForExistence(timeout: 30), "with YouTube in front the editor should ask first: \(visibleErrors())")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'YouTube is on screen'")).firstMatch.exists)
            app.buttons["Connect now"].tap()
            XCTAssertTrue(waitForEditor(), visibleErrors())
            _ = try tv.call("key", ["code": "KEYCODE_HOME"])
            _ = try tv.waitForeground(launcher, timeout: 15)
        }
    }

    // MARK: UND

    private func undo() throws {
        try step("SET-09/UND-02: Manage › Undo; a closed port is a clear error, nothing changed") {
            app.staticTexts["Debloated"].tap()
            XCTAssertTrue(app.staticTexts["Undo TV setup"].waitForExistence(timeout: 5))
            app.staticTexts["Undo TV setup"].tap()
            XCTAssertTrue(app.navigationBars["Undo TV setup"].waitForExistence(timeout: 5))
            let record = app.staticTexts["dev-android-tv-emulator"]
            XCTAssertTrue(record.waitForExistence(timeout: 5), "the recovery record saved by setup should be listed")
            record.tap()
            replace(app.textFields.firstMatch, with: host + ":1")
            app.buttons["Restore this TV"].tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'debugging port'")).firstMatch.waitForExistence(timeout: 20))
            XCTAssertEqual(try tv.home(), launcher + "/.MainActivity", "a failed connection must change nothing")
        }
        try step("UND-01: restore from the record puts the apps and the stock Home back") {
            replace(app.textFields.firstMatch, with: adbAddress)
            // A TV that kept "Always allow" asks nothing more; the emulator image can't persist it and asks every
            // time, so the helper answers any prompt and the run records how many there were.
            _ = try tv.call("auto-approve", ["seconds": "120", "reset": "1"])
            app.buttons["Restore this TV"].tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Restored.'")).firstMatch.waitForExistence(timeout: 120), visibleErrors())
            notePrompts("UND-01 restore")
            XCTAssertTrue(try tv.home().hasPrefix(stockLauncher + "/"), "the stock launcher should own Home again")
            let disabled = try tv.disabled()
            for package in listed { XCTAssertFalse(disabled.contains(package), "\(package) should be enabled again") }
            XCTAssertFalse(disabled.contains(stockLauncher))
        }
        try step("UND-03: the TV tab shows the setup card again") {
            app.navigationBars["Undo TV setup"].buttons.element(boundBy: 0).tap()
            app.navigationBars["TV setup"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.staticTexts["Make your TV faster"].waitForExistence(timeout: 10))
        }
    }

    // MARK: second run and DBL-16b

    private func secondRunAndTurnDebuggingOff() throws {
        try step("DBL-13: a second setup reconnects without a prompt and can keep everything") {
            app.buttons["Start setup"].tap()
            XCTAssertTrue(app.navigationBars["Set up TV"].waitForExistence(timeout: 5))
            app.switches["I understand the risks"].tap()
            app.buttons["Continue"].tap()
            _ = try tv.call("auto-approve", ["seconds": "120", "reset": "1"])
            try connectSetup()
            XCTAssertTrue(app.staticTexts["Choose what stays"].waitForExistence(timeout: 90), visibleErrors())
            notePrompts("DBL-13 second setup")
            for package in listed where app.switches[package].exists { app.switches[package].tap() }
            app.buttons["Review changes"].tap()
            XCTAssertTrue(app.staticTexts["0 apps will be disabled"].waitForExistence(timeout: 60), visibleErrors())
            app.switches["I reviewed these changes"].tap()
            app.buttons["Continue"].tap()
            XCTAssertTrue(installSwitch.waitForExistence(timeout: 5))
            installSwitch.tap()
            app.buttons["Apply to TV"].tap()
            XCTAssertTrue(app.staticTexts["Test on the TV"].waitForExistence(timeout: 60), visibleErrors())
            for item in checklist { app.switches[item].tap() }
            app.buttons["Everything works"].tap()
            XCTAssertTrue(app.staticTexts["Secure the TV"].waitForExistence(timeout: 5))
        }
        try step("DBL-16b: after the link dropped, 'Turn off network debugging now' reconnects silently and switches it off") {
            _ = try tv.call("drop-adb")
            _ = try tv.call("auto-approve", ["seconds": "60", "reset": "1"])
            app.buttons["Turn off network debugging now"].tap()
            let off = app.staticTexts["Debugging is off: the TV refuses connections."]
            let stillOpen = app.staticTexts["The debugging port still accepts connections."]
            XCTAssertTrue(waitUntil(45) { off.exists || stillOpen.exists }, "the app should report the result: \(visibleErrors())")
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'no longer connected'")).firstMatch.exists, "it should have reconnected with the approved key")
            // On the emulator the port is a forward on this Mac, which still accepts and then closes, so either
            // message is right here; what matters is the TV: debugging is off, or adb lost it altogether.
            let state = try tv.call("adb")
            let alive = state["alive"] as? Bool ?? false
            let enabled = state["adb_enabled"] as? String ?? ""
            XCTAssertTrue(!alive || enabled == "0", "debugging should be off on the TV (adb alive: \(alive), adb_enabled: \(enabled))")
            note("DBL-16b: \(off.exists ? "port refused" : "port still answered (forward)"); TV adb alive: \(alive), adb_enabled: \(enabled)")
            notePrompts("DBL-16b turn off")
        }
    }

    // MARK: helpers

    /// How many "Allow USB debugging?" prompts the helper answered in a phase. None on a TV that kept "Always
    /// allow"; one per connection on the emulator image, which can't persist it (so this is noted, not asserted).
    private func notePrompts(_ phase: String) {
        let count = (try? tv.call("approvals")["count"] as? Int) ?? -1
        note("\(phase): debugging prompts answered by the helper: \(count) (a TV that kept 'Always allow' shows none)")
    }

    /// The toggle's label carries its description too, so it's matched by its first line.
    private var installSwitch: XCUIElement { app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Install the clean Home screen'")).firstMatch }

    private func step(_ name: String, _ block: () throws -> Void) throws {
        try XCTContext.runActivity(named: name) { _ in try block() }
    }

    /// A note kept in the result bundle even when the run passes (attachments are dropped on success by default).
    private func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func type(code: String) {
        for character in code { app.buttons[String(character)].firstMatch.tap() }
    }

    /// The remote is usable: a connected chip and an enabled Home key.
    private func waitForRemote() {
        XCTAssertTrue(waitUntil(30) { self.app.buttons["Home"].firstMatch.isEnabled }, "the remote should connect")
    }

    private func waitForEditor() -> Bool {
        waitUntil(60) {
            if self.app.staticTexts["Connected to TV Home"].exists { return true }
            if self.app.buttons["Connect now"].exists { self.app.buttons["Connect now"].tap() }
            else if self.app.buttons["Try again"].exists && !self.app.staticTexts["Connecting to TV Home…"].exists { self.app.buttons["Try again"].tap() }
            return false
        }
    }

    /// The setup flow's connect step: the address with the forwarded port, then Connect.
    private func connectSetup() throws {
        XCTAssertTrue(app.staticTexts["Turn on network debugging"].waitForExistence(timeout: 5))
        replace(app.textFields.firstMatch, with: adbAddress)
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
        app.buttons["Connect"].tap()
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2)) }
        field.typeText(text)
    }

    @discardableResult private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }

    private func visibleErrors() -> String {
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label)
        return "on screen: " + texts.filter { $0.count > 12 }.joined(separator: " | ")
    }
}

/// The helper on the Mac (scripts/e2e-helper.py): small synchronous GETs returning JSON.
final class E2EHelper {
    private let base: URL
    init(base: URL) { self.base = base }

    @discardableResult func call(_ endpoint: String, _ query: [String: String] = [:], timeout: TimeInterval = 120) throws -> [String: Any] {
        var components = URLComponents(url: base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var payload: Data?, failure: Error?
        URLSession.shared.dataTask(with: request) { data, _, error in payload = data; failure = error; done.signal() }.resume()
        _ = done.wait(timeout: .now() + timeout + 5)
        if let failure { throw failure }
        guard let payload, let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw NSError(domain: "E2EHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: "no JSON from \(endpoint)"])
        }
        guard object["ok"] as? Bool == true else {
            throw NSError(domain: "E2EHelper", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(endpoint): \(object["error"] ?? "failed")"])
        }
        return object
    }
    func pairingCode(not previous: String = "") throws -> String {
        guard let code = try call("pairing-code", ["timeout": "30", "not": previous])["code"] as? String else { throw NSError(domain: "E2EHelper", code: 3) }
        return code
    }
    func waitForeground(_ package: String, timeout: Int) throws -> [String: Any] {
        try call("wait-foreground", ["package": package, "timeout": String(timeout)])
    }
    func home() throws -> String { try call("home")["home"] as? String ?? "" }
    func disabled() throws -> Set<String> { Set(try call("disabled")["packages"] as? [String] ?? []) }
    func launcherConfig() throws -> [String: Any]? { try call("launcher-config")["config"] as? [String: Any] }
}
