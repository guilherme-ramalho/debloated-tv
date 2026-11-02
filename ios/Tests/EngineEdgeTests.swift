import XCTest
import CryptoKit
@testable import TVRemoteCore

/// A TV that answers exact commands first, then prefixes, and can fail chosen commands (TESTING.md: DBL-*, LCH-*).
final class ScriptedTV: TVDevice, @unchecked Sendable {
    var exact: [String: String] = [:]
    var prefixes: [(String, String)] = []
    var failing: Set<String> = []
    var md5Override: String?
    var sent: [String] = []
    var pushed: [String: Data] = [:]
    struct Down: Error {}
    func push(_ data: Data, to path: String, mode: UInt32, progress: (@Sendable (Double) -> Void)?) async throws { pushed[path] = data }
    func shell(_ command: String, timeout: Double) async throws -> AdbClient.ShellResult {
        sent.append(command)
        if failing.contains(command) { throw Down() }
        if command.hasPrefix("md5sum"), let path = pushed.keys.first {
            let sum = md5Override ?? Insecure.MD5.hash(data: pushed[path]!).map { String(format: "%02x", $0) }.joined()
            return .init(output: "\(sum)  \(path)", status: 0)
        }
        if let answer = exact[command] { return .init(output: answer, status: 0) }
        for (prefix, answer) in prefixes where command.hasPrefix(prefix) { return .init(output: answer, status: 0) }
        if command.contains("WRITE_SECURE_SETTINGS") { return .init(output: command.hasPrefix("pm grant") ? "restore-granted" : "secure-settings-revoked", status: 0) }
        return .init(output: "", status: 0)
    }
}

final class DebloatEdgeTests: XCTestCase {
    private func inventory(_ installed: Set<String>, secure: String = "1") -> TVInventory {
        TVInventory(properties: [:], installed: installed, disabled: [], userScoped: true,
                    home: "com.google.android.apps.tv.launcherx/.home.HomeActivity", animationScales: [:], adbSecure: secure)
    }

    func testApplyStopsWhenTheTVStopsAnswering() async throws {
        let tv = ScriptedTV()
        tv.failing = ["pm disable-user --user 0 b.b"]
        tv.exact["pm list packages -e --user 0"] = "package:b.b\npackage:c.c"
        let result = try await Debloater(tv: tv).apply(DebloatPlan(disable: ["a.a", "b.b", "c.c"], skipped: [], notes: []))
        XCTAssertTrue(result.stoppedEarly)
        XCTAssertEqual(result.disabled, ["a.a"])
        XCTAssertEqual(result.stillEnabled, ["b.b", "c.c"])
        XCTAssertFalse(tv.sent.contains("pm disable-user --user 0 c.c"), "nothing after the failure is touched")
    }

    func testInspectFallsBackWhenUserScopedListingIsEmpty() async throws {
        let tv = ScriptedTV()
        tv.exact["pm list packages --user 0"] = ""
        tv.exact["pm list packages"] = "package:a.a\npackage:b.b"
        tv.exact["pm list packages -d"] = "package:b.b"
        let inv = try await Debloater(tv: tv).inspect()
        XCTAssertFalse(inv.userScoped)
        XCTAssertEqual(inv.installed, ["a.a", "b.b"])
        XCTAssertEqual(inv.disabled, ["b.b"])
    }

    func testInspectRefusesATVThatListsNothing() async {
        do { _ = try await Debloater(tv: ScriptedTV()).inspect(); XCTFail("should refuse") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no apps")) }
    }

    static let wizardWifi = """
    Dump of WifiConfigManager
    Configured networks Begin ----
      ID: 3 SSID: "Casa 'Ramalho'" PROVIDER-NAME: null BSSID: null FQDN: null PRIO: 0 HIDDEN: false
     NetworkSelectionStatus NETWORK_SELECTION_ENABLED
     KeyMgmt: WPA_PSK Protocols: WPA RSN
     cuid=10071 cname=com.google.android.tungsten.setupwraith luid=1000 lname=android.uid.system:1000
      ID: 4 SSID: "Guest" PROVIDER-NAME: null BSSID: null FQDN: null PRIO: 0 HIDDEN: false
     KeyMgmt: NONE Protocols: RSN
     cuid=1000 cname=android.uid.system:1000 luid=1000
    """

    func testSetupWizardFollowsTheWifiCheck() async throws {
        let list = try DebloatList.parse("# 1. Setup\ncom.google.android.tungsten.setupwraith\ncom.tcl.bi\n")
        let inv = inventory(["com.google.android.tungsten.setupwraith", "com.tcl.bi", "com.google.android.apps.tv.launcherx"])
        let claims = (DebloatRules.claimQuery, "com.google.android.apps.tv.launcherx/.home.HomeActivity\ncom.google.android.tungsten.setupwraith/.RecoveryActivity")
        let wizard = DebloatRules.setupwraith

        // Unreadable: the wizard stays, and the Home step is warned that it keeps Home.
        let unknown = ScriptedTV(); unknown.prefixes = [claims]
        let kept = try await Debloater(tv: unknown).plan(list.entries.map(\.package), list: list, inventory: inv)
        XCTAssertEqual(kept.disable, ["com.tcl.bi"])
        XCTAssertTrue(kept.setupKeepsHome)

        // Readable, no network of the wizard's (a TV on a cable): disabled, nothing to ask.
        let cable = ScriptedTV(); cable.prefixes = [("dumpsys wifi", "Dump of WifiConfigManager\nConfigured networks Begin ----\n"), claims]
        let off = try await Debloater(tv: cable).plan(list.entries.map(\.package), list: list, inventory: inv)
        XCTAssertEqual(Set(off.disable), [wizard, "com.tcl.bi"])
        XCTAssertTrue(off.wifiToResave.isEmpty)
        XCTAssertFalse(off.setupKeepsHome)

        // The wizard owns a WPA2 network and the TV can save networks from the shell: saved again first.
        let wifi = ScriptedTV(); wifi.prefixes = [("dumpsys wifi", Self.wizardWifi), ("cmd wifi help", "connect-network <ssid> open|owe|wpa2|wpa3 [<passphrase>]\nforget-network <networkId>\n"), claims]
        let resave = try await Debloater(tv: wifi).plan(list.entries.map(\.package), list: list, inventory: inv)
        XCTAssertEqual(Set(resave.disable), [wizard, "com.tcl.bi"])
        XCTAssertEqual(resave.wifiToResave, [WifiNetwork(networkId: 3, ssid: "Casa 'Ramalho'", security: "wpa2", owner: wizard)])

        // Without connect-network on the TV: the wizard stays, with the rejoin-on-the-TV explanation.
        let old = ScriptedTV(); old.prefixes = [("dumpsys wifi", Self.wizardWifi), ("cmd wifi help", "status\n"), claims]
        let noShell = try await Debloater(tv: old).plan(list.entries.map(\.package), list: list, inventory: inv)
        XCTAssertEqual(noShell.disable, ["com.tcl.bi"])
        XCTAssertTrue(noShell.skipped.contains { $0.package == wizard && $0.reason.contains("join it again") })
    }

    func testWifiParsingAndTheResaveCommand() {
        let networks = DebloatRules.wifiNetworks(Self.wizardWifi) ?? []
        XCTAssertEqual(networks.map(\.ssid), ["Casa 'Ramalho'", "Guest"])
        XCTAssertEqual(networks.map(\.security), ["wpa2", "open"])
        XCTAssertNil(DebloatRules.wifiNetworks("Service dumps disabled due to hung system process."))
        // Forget first (connect-network keeps an existing network's creator), detached so a TV on Wi-Fi finishes it.
        // Checked with sh: the TV runs  forget-network 3 && connect-network "Casa 'Ramalho'" wpa2 "it's $ecret".
        XCTAssertEqual(DebloatRules.resaveWifiCommand(networks[0], password: "it's $ecret"),
                       #"nohup sh -c 'cmd wifi forget-network 3 && cmd wifi connect-network '\''Casa '\''\'\'''\''Ramalho'\''\'\'''\'''\'' wpa2 '\''it'\''\'\'''\''s $ecret'\''' >/dev/null 2>&1 &"#)
        XCTAssertFalse(DebloatRules.resaveWifiCommand(networks[1], password: "ignored").contains("ignored"), "open networks take no password")
    }

    func testOpenDebuggingPortIsCalledOut() async throws {
        let list = try DebloatList.parse("com.tcl.bi\n")
        let plan = try await Debloater(tv: ScriptedTV()).plan(["com.tcl.bi"], list: list, inventory: inventory(["com.tcl.bi"], secure: "0"))
        XCTAssertTrue(plan.notes.contains { $0.contains("without asking") })
    }

    func testFirmwareWithoutPermissionsKeepsThePackage() async throws {
        let list = try DebloatList.parse("com.tcl.mystery\n")
        let tv = ScriptedTV()
        tv.prefixes = [("s=$(getprop", "NOCHK com.tcl.mystery\n")]
        let plan = try await Debloater(tv: tv).plan(["com.tcl.mystery"], list: list, inventory: inventory(["com.tcl.mystery"]))
        XCTAssertEqual(plan.disable, [])
        XCTAssertTrue(plan.skipped.first?.reason.contains("stays enabled") == true)
    }

    func testListsRejectNonPackageLines() {
        XCTAssertThrowsError(try DebloatList.parse("com.ok.app\n$(reboot)\n"))
        XCTAssertThrowsError(try DebloatList.parse("com.ok.app; reboot\n"))
    }
}

final class LauncherInstallEdgeTests: XCTestCase {
    let apk = Data(repeating: 9, count: 2048)
    private func tv() -> ScriptedTV {
        let tv = ScriptedTV()
        tv.exact["getprop ro.build.version.sdk"] = "30"
        tv.prefixes = [(DebloatRules.homeQuery, "com.google.android.apps.tv.launcherx/.home.HomeActivity")]
        return tv
    }

    func testDamagedUploadInstallsNothing() async {
        let tv = tv(); tv.md5Override = String(repeating: "0", count: 32)
        do { _ = try await LauncherInstaller(tv: tv).install(apk: apk, options: .init()); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("damaged")) }
        XCTAssertFalse(tv.sent.contains { $0.hasPrefix("pm install") })
        XCTAssertTrue(tv.sent.contains { $0.hasPrefix("rm -f") }, "the damaged file is removed")
    }

    func testDifferentlySignedBuildIsExplained() async {
        let tv = tv(); tv.prefixes.insert(("pm install", "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]"), at: 0)
        do { _ = try await LauncherInstaller(tv: tv).install(apk: apk, options: .init()); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("another key")) }
        XCTAssertFalse(tv.sent.contains { $0.hasPrefix("pm disable-user") })
    }

    func testHomeChooserWithOneStockLauncherIsResolved() async throws {
        let tv = ScriptedTV()
        tv.prefixes = [(DebloatRules.homeQuery, "android/com.android.internal.app.ResolverActivity"),
                       (DebloatRules.claimQuery, "com.google.android.tvlauncher/.MainActivity\ncom.android.tv.settings/.system.FallbackHome")]
        let stock = try await LauncherInstaller(tv: tv).stockLauncher()
        XCTAssertEqual(stock, "com.google.android.tvlauncher")
    }

    func testSetupWizardOwningHomeStopsBeforeAnyChange() async {
        let tv = ScriptedTV()
        tv.exact["getprop ro.build.version.sdk"] = "30"
        tv.prefixes = [(DebloatRules.homeQuery, "com.google.android.tungsten.setupwraith/.RecoveryActivity")]
        do { _ = try await LauncherInstaller(tv: tv).install(apk: apk, options: .init()); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("setup wizard")) }
        XCTAssertTrue(tv.pushed.isEmpty)
    }

    func testThemeMustBeAJSONObjectAndAcceptedByTheTV() async {
        do { try await LauncherInstaller(tv: ScriptedTV()).applyTheme(Data("[1,2]".utf8)); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Invalid")) }
        let refusing = ScriptedTV(); refusing.prefixes = [("{ o=$(content write", "theme-rc=1")]
        do { try await LauncherInstaller(tv: refusing).applyTheme(Data("{}".utf8)); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("refused")) }
    }
}

final class AdbFramingEdgeTests: XCTestCase {
    func testMessagesSurviveAnySplitAndCoalescing() throws {
        let a = Adb.encode(Adb.Message(Adb.okay, 1, 2))
        let b = Adb.encode(Adb.Message(Adb.wrte, 1, 2, Data("hello".utf8)))
        let stream = a + b
        for cut in 1..<stream.count {
            var decoder = Adb.Decoder()
            var out = try decoder.append(stream.prefix(cut))
            out += try decoder.append(stream.dropFirst(cut))
            XCTAssertEqual(out.map(\.command), [Adb.okay, Adb.wrte], "cut at \(cut)")
            XCTAssertEqual(out.last?.payload, Data("hello".utf8))
        }
    }

    func testCorruptOrOversizedHeadersAreRejected() {
        var bad = Adb.encode(Adb.Message(Adb.okay, 0, 0))
        bad[20] ^= 0xff
        var decoder = Adb.Decoder()
        XCTAssertThrowsError(try decoder.append(bad))
        var huge = Adb.encode(Adb.Message(Adb.wrte, 0, 0))
        huge.replaceSubrange(12..<16, with: withUnsafeBytes(of: UInt32(Adb.maxData * 4 + 1).littleEndian) { Data($0) })
        var decoder2 = Adb.Decoder()
        XCTAssertThrowsError(try decoder2.append(huge))
    }

    func testBannerWithoutPropertiesIsEmpty() {
        XCTAssertEqual(Adb.bannerProperties(Data("device::".utf8)), [:])
        XCTAssertEqual(Adb.bannerProperties(Data()), [:])
    }
}
