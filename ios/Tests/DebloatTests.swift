import XCTest
@testable import TVRemoteCore

/// A scripted TV: the first matching prefix answers; everything sent is kept for assertions.
final class FakeTV: TVShell, @unchecked Sendable {
    var answers: [(String, String)]
    var sent: [String] = []
    var disabledNow: Set<String> = []
    var enabledAtStart: Set<String>
    init(enabled: Set<String>, answers: [(String, String)] = []) { enabledAtStart = enabled; self.answers = answers }
    func shell(_ command: String, timeout: Double) async throws -> AdbClient.ShellResult {
        sent.append(command)
        if command.hasPrefix("pm disable-user --user 0 ") { disabledNow.insert(String(command.dropFirst(25))); return .init(output: "Package new state: disabled-user", status: 0) }
        if command == "pm list packages -e --user 0" {
            return .init(output: enabledAtStart.subtracting(disabledNow).sorted().map { "package:" + $0 }.joined(separator: "\n"), status: 0)
        }
        for (prefix, answer) in answers where command.hasPrefix(prefix) { return .init(output: answer, status: 0) }
        return .init(output: "", status: 0)
    }
}

final class DebloatTests: XCTestCase {
    static let tcl = """
    \u{FEFF}# TCL G03 / BeyondTV4 firmware (AR11), reports as "Smart TV Pro"
    # Never disable: com.tcl.providers.config com.tcl.initsetup com.tcl.tvinput com.tcl.tv
    # com.tcl.settings com.google.android.gms
    # Kept by choice on both: Cast receiver (mediashell), Live TV (com.tcl.tv).

    # 1. Telemetry, promos, content rows
    com.tcl.bi
    com.tcl.partnercustomizer

    # 1b. Google TV first-run wizard (claims HOME once the stock launcher is off)
    com.google.android.tungsten.setupwraith

    # 3. Off by choice (the 60C635 kept both)
    com.tcl.versionUpdateApp                    # firmware updater
    com.tcl.miracast\r
    """

    func testParsesUpstreamListFormat() throws {
        let list = try DebloatList.parse(Self.tcl)
        XCTAssertEqual(list.entries.map(\.package), ["com.tcl.bi", "com.tcl.partnercustomizer", "com.google.android.tungsten.setupwraith", "com.tcl.versionUpdateApp", "com.tcl.miracast"])
        XCTAssertEqual(list.groups, ["Telemetry, promos, content rows", "Google TV first-run wizard (claims HOME once the stock launcher is off)", "Off by choice (the 60C635 kept both)"])
        XCTAssertEqual(list.entries[3].note, "firmware updater")
        XCTAssertEqual(list.neverDisable, ["com.tcl.providers.config", "com.tcl.initsetup", "com.tcl.tvinput", "com.tcl.tv", "com.tcl.settings", "com.google.android.gms"])
        XCTAssertThrowsError(try DebloatList.parse("com.ok.app\nrm -rf /\n"))
    }

    func testOnlyWellFormedPackageNamesComeBackFromTheTV() {
        let answer = "package:com.netflix.ninja\npackage:com.tcl.x;reboot\npackage:com.example.$(id)\npackage:android\npackage:com.ok_app.tv2 installer=x\nnoise"
        XCTAssertEqual(Pattern.packageNames(answer), ["com.netflix.ninja", "android", "com.ok_app.tv2"])
    }

    func testCorePackagesAreNeverDisabled() {
        XCTAssertTrue(DebloatRules.isCore("com.android.systemui"))
        XCTAssertTrue(DebloatRules.isCore("com.android.providers.settings"))
        XCTAssertFalse(DebloatRules.isCore("com.android.providers.calendar"))
        XCTAssertTrue(DebloatRules.isCore("com.google.android.overlay.modules.ext.services"))
        XCTAssertTrue(DebloatRules.isCore("com.android.location.fused"), "boot-looped a TCL 43S5400A (upstream #2803)")
        XCTAssertFalse(DebloatRules.isCore("com.tcl.bi"))
    }

    private func inventory(_ installed: Set<String>, home: String? = "com.google.android.apps.tv.launcherx/.home.HomeActivity") -> TVInventory {
        TVInventory(properties: [:], installed: installed, disabled: [], userScoped: true, home: home,
                    animationScales: ["window_animation_scale": "1.0", "transition_animation_scale": "null", "animator_duration_scale": "0.5"], adbSecure: "1")
    }

    func testGuardsSkipWifiOwnerHomeOwnerInputDriversAndSettings() async throws {
        let list = try DebloatList.parse(Self.tcl + "\n# 6. Launcher\ncom.google.android.apps.tv.launcherx\ncom.tcl.tvhdmi\ncom.tcl.settings.extra\n")
        let installed = Set(list.entries.map(\.package))
        let tv = FakeTV(enabled: installed, answers: [
            ("dumpsys wifi", "Dump of WifiConfigManager\nID: 0 SSID: \"Office\" PROVIDER-NAME: null BSSID: null\n KeyMgmt: WPA_EAP IEEE8021X Protocols: RSN\n cuid=10071 cname=com.google.android.tungsten.setupwraith luid=1000\n"),
            ("cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME",
             "com.google.android.apps.tv.launcherx/.home.HomeActivity\ncom.google.android.tungsten.setupwraith/.RecoveryActivity"),
            ("s=$(getprop", "com.tcl.tvhdmi\n"),
            ("cmd package query-activities --brief -a android.intent.action.VIEW", "\n==\ncom.tcl.settings.extra/.Main\n"),
        ])
        let plan = try await Debloater(tv: tv).plan(list.entries.map(\.package), list: list, inventory: inventory(installed))
        let skipped = Set(plan.skipped.map(\.package))
        XCTAssertTrue(skipped.contains("com.google.android.tungsten.setupwraith"), "its enterprise Wi-Fi can't be saved again from the phone")
        XCTAssertTrue(skipped.contains("com.google.android.apps.tv.launcherx"), "owns Home with nothing else to take it")
        XCTAssertTrue(skipped.contains("com.tcl.tvhdmi"), "drives the inputs")
        XCTAssertTrue(skipped.contains("com.tcl.settings.extra"), "opens Settings")
        XCTAssertEqual(Set(plan.disable), ["com.tcl.bi", "com.tcl.partnercustomizer", "com.tcl.versionUpdateApp", "com.tcl.miracast"])
    }

    func testNeverDisableAndAlreadyDisabledAreLeftAlone() async throws {
        let list = try DebloatList.parse(Self.tcl)
        var inv = inventory(["com.tcl.bi", "com.tcl.tv", "com.tcl.miracast"])
        inv.disabled = ["com.tcl.miracast"]
        let plan = try await Debloater(tv: FakeTV(enabled: inv.installed)).plan(["com.tcl.bi", "com.tcl.tv", "com.tcl.miracast"], list: list, inventory: inv)
        XCTAssertEqual(plan.disable, ["com.tcl.bi"])
        XCTAssertEqual(plan.skipped.map(\.package), ["com.tcl.tv"])
    }

    func testApplyReadsTheTVBack() async throws {
        let tv = FakeTV(enabled: ["com.tcl.bi", "com.tcl.guard"])
        let result = try await Debloater(tv: tv).apply(DebloatPlan(disable: ["com.tcl.bi"], skipped: [], notes: []))
        XCTAssertEqual(result.disabled, ["com.tcl.bi"])
        XCTAssertEqual(result.stillEnabled, [])
        XCTAssertTrue(tv.sent.contains("pm disable-user --user 0 com.tcl.bi"))
    }

    func testRecordKeepsTheStateBeforeTheFirstRunAndRestoreReplaysIt() throws {
        let list = try DebloatList.parse(Self.tcl)
        var inv = inventory(["com.tcl.bi", "com.tcl.miracast", "com.google.android.apps.tv.launcherx"])
        inv.disabled = ["com.tcl.miracast"]
        let debloater = Debloater(tv: FakeTV(enabled: []))
        let first = debloater.record(list, listName: "tcl-43c645", host: "192.168.0.13", inventory: inv, existing: nil)
        XCTAssertEqual(first.packages["com.tcl.bi"], "enabled")
        XCTAssertEqual(first.packages["com.tcl.miracast"], "disabled")
        XCTAssertEqual(first.packages["com.tcl.partnercustomizer"], "absent")
        XCTAssertEqual(first.packages["com.google.android.apps.tv.launcherx"], "enabled")   // Home's owner
        // A retry after cleanup must not record the cleaned state as the original.
        inv.disabled.insert("com.tcl.bi")
        let again = debloater.record(list, listName: "tcl-43c645", host: "192.168.0.13", inventory: inv, existing: first)
        XCTAssertEqual(again.packages["com.tcl.bi"], "enabled")
        let commands = Debloater.restoreCommands(first)
        XCTAssertTrue(commands.contains("pm enable com.tcl.bi"))
        XCTAssertFalse(commands.contains("pm enable com.tcl.miracast"), "was already off before cleanup")
        XCTAssertTrue(commands.contains("cmd package set-home-activity --user 0 com.google.android.apps.tv.launcherx/.home.HomeActivity"))
        XCTAssertTrue(commands.contains("settings delete global transition_animation_scale"))
        XCTAssertTrue(commands.contains("settings put global animator_duration_scale 0.5"))
    }

    func testHomeChooserAndFallbackHomeAreNotRecorded() {
        XCTAssertTrue(DebloatRules.isChooser("android/com.android.internal.app.ResolverActivity"))
        XCTAssertTrue(DebloatRules.notALauncher("com.tcl.keycustomfunctionservice/.FallbackHome"))
        XCTAssertTrue(DebloatRules.notALauncher("com.google.android.tungsten.setupwraith/.RecoveryActivity"))
        XCTAssertFalse(DebloatRules.notALauncher("com.gathin.tvhome/.MainActivity"))
        XCTAssertEqual(DebloatRules.launchers(in: ["com.gathin.tvhome/.MainActivity", "com.android.tv.settings/.system.FallbackHome", "com.google.android.tungsten.setupwraith/.RecoveryActivity"]), ["com.gathin.tvhome"])
    }
}
