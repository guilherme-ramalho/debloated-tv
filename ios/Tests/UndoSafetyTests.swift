import XCTest
@testable import TVRemoteCore

/// Undo after the review of Nov 2026 (TESTING.md UND-07…UND-12): one record per TV across lists, identity checks,
/// the new Home's helpers put back, and a restore that reads the TV back.
final class UndoSafetyTests: XCTestCase {
    private let launcherx = "com.google.android.apps.tv.launcherx"
    private let tcl = TVIdentity(androidId: "3f2a9c01d4e5b677", serial: "0123456789ABCDEF", model: "Smart TV Pro", device: "BeyondTV4")

    private func inventory(installed: Set<String>, disabled: Set<String> = [], home: String) -> TVInventory {
        TVInventory(properties: [:], installed: installed, disabled: disabled, userScoped: true, home: home,
                    animationScales: ["window_animation_scale": "1.0"], adbSecure: "1")
    }

    /// UND-07: list A applied, then list B: the record keeps the state before A (Home on the stock launcher, A's apps
    /// on), adds B's new apps, and lists both.
    func testOneRecordPerTVAcrossLists() throws {
        let a = try DebloatList.parse("# 1. A\ncom.tcl.bi\ncom.tcl.ota\n")
        let b = try DebloatList.parse("# 1. B\ncom.tcl.bi\ncom.tcl.weather\n")
        let engine = Debloater(tv: ScriptedTV())
        let before = inventory(installed: ["com.tcl.bi", "com.tcl.ota", "com.tcl.weather", launcherx], home: "\(launcherx)/.home.HomeActivity")
        let first = engine.record(a, listName: "list-a", host: "192.168.0.13", inventory: before, existing: nil, tv: tcl,
                                  accessibility: ["enabled_accessibility_services": "null", "accessibility_enabled": "0"])
        // After A: its apps and the stock launcher are off, Home is the new launcher, a helper is on.
        let after = inventory(installed: before.installed.union(["com.gathin.tvhome"]), disabled: ["com.tcl.bi", "com.tcl.ota", launcherx],
                              home: "com.gathin.tvhome/.MainActivity")
        let second = engine.record(b, listName: "list-b", host: "192.168.0.20", inventory: after, existing: first, tv: tcl,
                                   accessibility: ["enabled_accessibility_services": "com.gathin.tvhome/.HomeKeyService", "accessibility_enabled": "1"])
        XCTAssertEqual(second.packages["com.tcl.bi"], "enabled", "the state before the first setup wins")
        XCTAssertEqual(second.packages[launcherx], "enabled")
        XCTAssertEqual(second.packages["com.tcl.weather"], "enabled")
        XCTAssertEqual(second.home, "\(launcherx)/.home.HomeActivity")
        XCTAssertEqual(second.accessibility?["enabled_accessibility_services"], "null")
        XCTAssertEqual(second.lists, ["list-a", "list-b"])
        XCTAssertEqual(second.lastList, "list-b")
        XCTAssertEqual(second.host, "192.168.0.20")
        XCTAssertNil(second.packages["com.gathin.tvhome"], "our own launcher is never something to turn back on")
    }

    /// UND-08: records from builds before this one (one per list, no identity) fold into one, oldest state first.
    func testOlderRecordsMergeOldestFirst() {
        let old = RecoveryRecord(created: "2026-11-01T10:00:00Z", host: "h", list: "a", home: "\(launcherx)/.Home", settings: [:],
                                 packages: ["x": "enabled", launcherx: "enabled"])
        let newer = RecoveryRecord(created: "2026-11-02T10:00:00Z", host: "h2", list: "b", home: "com.gathin.tvhome/.MainActivity", settings: [:],
                                   packages: ["x": "disabled", "y": "enabled", launcherx: "disabled"])
        let merged = newer.merged(withOlder: old)
        XCTAssertEqual(merged.packages, ["x": "enabled", "y": "enabled", launcherx: "enabled"])
        XCTAssertEqual(merged.home, "\(launcherx)/.Home")
        XCTAssertEqual(merged.lists, ["a", "b"])
        XCTAssertEqual(merged.host, "h2")
        // A record written by upstream's recovery.py (no Purio fields) still decodes.
        let json = #"{"version":1,"created":"c","host":"h","list":"l","home":null,"settings":{},"packages":{"x":"enabled"}}"#
        XCTAssertNoThrow(try JSONDecoder().decode(RecoveryRecord.self, from: Data(json.utf8)))
    }

    /// UND-09: a dummy serial says nothing; android_id tells TVs apart.
    func testIdentityIgnoresDummySerials() {
        var other = tcl; other.androidId = "aaaabbbbccccdddd"
        XCTAssertFalse(tcl.sameTV(as: other), "same dummy serial, different android_id")
        XCTAssertTrue(tcl.sameTV(as: tcl))
        XCTAssertNil(tcl.realSerial)
        XCTAssertEqual(tcl.key, "id-3f2a9c01d4e5b677")
        let noId = TVIdentity(androidId: "", serial: "0123456789ABCDEF", model: "M", device: "D")
        XCTAssertNil(noId.key, "nothing identifies it: the record is keyed by address instead")
        XCTAssertTrue(noId.sameTV(as: TVIdentity(androidId: "", serial: "unknown", model: "M", device: "D")))
        XCTAssertFalse(noId.sameTV(as: TVIdentity(androidId: "", serial: "", model: "N", device: "D")))
    }

    private func record(accessibility: [String: String]? = nil) -> RecoveryRecord {
        RecoveryRecord(created: "c", host: "h", list: "l", home: "\(launcherx)/.home.HomeActivity", settings: [:],
                       packages: ["com.tcl.bi": "enabled", "com.tcl.old": "disabled", launcherx: "enabled"],
                       tv: tcl, lists: ["l"], accessibility: accessibility)
    }

    private func tv(identity: TVIdentity, enabled: [String], home: String) -> ScriptedTV {
        let tv = ScriptedTV()
        tv.exact = ["settings get secure android_id": identity.androidId, "getprop ro.serialno": identity.serial,
                    "getprop ro.product.model": identity.model, "getprop ro.product.device": identity.device,
                    "pm list packages --user 0": ["com.tcl.bi", "com.tcl.old", launcherx, "com.gathin.tvhome"].map { "package:" + $0 }.joined(separator: "\n"),
                    "pm list packages -e --user 0": enabled.map { "package:" + $0 }.joined(separator: "\n")]
        tv.prefixes = [(DebloatRules.homeQuery, home)]
        return tv
    }

    /// UND-10: a record from another TV is refused before any command.
    func testRestoreRefusesAnotherTV() async {
        var other = tcl; other.androidId = "aaaabbbbccccdddd"
        let scripted = tv(identity: other, enabled: [], home: "")
        do { _ = try await Debloater(tv: scripted).restore(record()); XCTFail("another TV's record must be refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("another TV"), error.localizedDescription) }
        XCTAssertFalse(scripted.sent.contains { $0.hasPrefix("pm enable") || $0.hasPrefix("cmd package set-home-activity") })
    }

    /// UND-11: the restore reads the TV back and says what didn't come back.
    func testRestoreChecksItsResult() async throws {
        let good = tv(identity: tcl, enabled: ["com.tcl.bi", launcherx, "com.gathin.tvhome"], home: "\(launcherx)/.home.HomeActivity")
        let ok = try await Debloater(tv: good).restore(record(), stock: launcherx)
        XCTAssertTrue(ok.complete)
        XCTAssertEqual(ok.keptOff, ["com.tcl.old"])
        // A firmware update renamed Home, and one app refused to come back.
        let bad = tv(identity: tcl, enabled: [launcherx], home: "com.gathin.tvhome/.MainActivity")
        let report = try await Debloater(tv: bad).restore(record(), stock: launcherx)
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.notBack, ["com.tcl.bi"])
        XCTAssertFalse(report.homeOK)
        XCTAssertEqual(report.expectedHome, launcherx)
        // No answer is not success.
        let silent = tv(identity: tcl, enabled: [], home: "")
        do { _ = try await Debloater(tv: silent).restore(record()); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("couldn't be checked")) }
    }

    /// UND-12: the new Home's helpers go back to the accessibility settings from before setup, and the launcher loses
    /// WRITE_SECURE_SETTINGS; unreadable values are skipped, never passed to the shell.
    func testRestorePutsTheHelpersBack() {
        let none = Debloater.restoreCommands(record(accessibility: ["enabled_accessibility_services": "null", "accessibility_enabled": "0"]))
        XCTAssertTrue(none.contains("settings delete secure enabled_accessibility_services"))
        XCTAssertTrue(none.contains("settings put secure accessibility_enabled 0"))
        XCTAssertTrue(none.contains { $0.hasPrefix("pm revoke com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS") })
        let talkback = Debloater.restoreCommands(record(accessibility: ["enabled_accessibility_services": "com.google.android.marvin.talkback/.TalkBackService",
                                                                        "accessibility_enabled": "1"]))
        XCTAssertTrue(talkback.contains("settings put secure enabled_accessibility_services com.google.android.marvin.talkback/.TalkBackService"))
        let hostile = Debloater.restoreCommands(record(accessibility: ["enabled_accessibility_services": "x; reboot", "accessibility_enabled": "1; reboot"]))
        XCTAssertFalse(hostile.contains { $0.contains("reboot") })
        XCTAssertFalse(Debloater.restoreCommands(record()).contains { $0.contains("accessibility") }, "a record from before this field leaves them alone")
        XCTAssertFalse(Debloater.restoreCommands(record(), stock: "x; reboot").contains { $0.contains("reboot") })
    }

    /// DBL-11b: an empty answer after disabling is a check that didn't run, not "everything is off".
    func testApplyRefusesAnEmptyReadback() async {
        let tv = ScriptedTV()
        do { _ = try await Debloater(tv: tv).apply(DebloatPlan(disable: ["com.tcl.bi"], skipped: [], notes: [])); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("couldn't be checked")) }
    }
}

/// DBL-18: the restart at the end of apply (PROMPT.md: reboot once, then compare).
final class RestartCheckTests: XCTestCase {
    func testRestartCheckJudgesHomeAndReEnabledApps() {
        let ours = RestartCheck.judge(home: "com.gathin.tvhome/.MainActivity", enabled: ["com.tcl.usercenter"],
                                      disabledBySetup: ["com.tcl.bi", "com.tcl.usercenter"], expectedHome: "com.gathin.tvhome")
        XCTAssertTrue(ours.homeOK)
        XCTAssertEqual(ours.reEnabled, ["com.tcl.usercenter"], "firmware that turns apps back on at boot is noted")
        XCTAssertFalse(RestartCheck.judge(home: "com.google.android.apps.tv.launcherx/.home.HomeActivity", enabled: [], disabledBySetup: [],
                                          expectedHome: "com.gathin.tvhome").homeOK, "the stock launcher took Home back")
        XCTAssertFalse(RestartCheck.judge(home: "com.google.android.tungsten.setupwraith/.RecoveryActivity", enabled: [], disabledBySetup: [],
                                          expectedHome: nil).homeOK, "black Home (acer-r4g)")
        XCTAssertFalse(RestartCheck.judge(home: "com.android.tv.settings/.system.FallbackHome", enabled: [], disabledBySetup: [], expectedHome: nil).homeOK)
        XCTAssertFalse(RestartCheck.judge(home: "", enabled: [], disabledBySetup: [], expectedHome: nil).homeOK)
        XCTAssertTrue(RestartCheck.judge(home: "com.google.android.apps.tv.launcherx/.home.HomeActivity", enabled: [], disabledBySetup: [],
                                         expectedHome: nil).homeOK, "debloat only: the TV's own Home is fine")
    }
}
