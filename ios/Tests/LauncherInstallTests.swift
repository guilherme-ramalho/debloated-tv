import XCTest
import CryptoKit
@testable import TVRemoteCore

final class FakeDevice: TVDevice, @unchecked Sendable {
    var sent: [String] = []
    var pushed: [String: Data] = [:]
    var answers: [(String, String)]
    var homeAfterHandover: String
    private var handedOver = false
    init(answers: [(String, String)], homeAfterHandover: String = "com.gathin.tvhome/.MainActivity") {
        self.answers = answers; self.homeAfterHandover = homeAfterHandover
    }
    func push(_ data: Data, to path: String, mode: UInt32, progress: (@Sendable (Double) -> Void)?) async throws { pushed[path] = data; progress?(1) }
    func shell(_ command: String, timeout: Double) async throws -> AdbClient.ShellResult {
        sent.append(command)
        if command.hasPrefix("cmd package set-home-activity --user 0 com.gathin.tvhome") { handedOver = true }
        if command.hasPrefix(DebloatRules.homeQuery) {
            return .init(output: handedOver ? homeAfterHandover : "com.google.android.apps.tv.launcherx/.home.HomeActivity", status: 0)
        }
        if command.hasPrefix("md5sum"), let apk = pushed["/data/local/tmp/tvhome.apk"] {
            return .init(output: Insecure.MD5.hash(data: apk).map { String(format: "%02x", $0) }.joined() + "  /data/local/tmp/tvhome.apk", status: 0)
        }
        for (prefix, answer) in answers where command.hasPrefix(prefix) { return .init(output: answer, status: 0) }
        return .init(output: "", status: 0)
    }
}

final class LauncherInstallTests: XCTestCase {
    let apk = Data(repeating: 7, count: 1000)
    let answers = [("getprop ro.build.version.sdk", "30\n"), ("pm install", "Success\n"), ("am start -W", "Starting: Intent\nStatus: ok\nComplete\n")]

    func testInstallsStartsThenHandsHomeOver() async throws {
        let tv = FakeDevice(answers: answers)
        let home = try await LauncherInstaller(tv: tv).install(apk: apk, options: LauncherOptions(homeKeyService: true))
        XCTAssertEqual(home, "com.gathin.tvhome/.MainActivity")
        let start = tv.sent.firstIndex { $0.hasPrefix("am start -W") }!
        let disable = tv.sent.firstIndex(of: "pm disable-user --user 0 com.google.android.apps.tv.launcherx")!
        XCTAssertLessThan(start, disable, "the stock launcher goes only after the new one started")
        XCTAssertTrue(tv.sent.contains { $0.contains("enabled_accessibility_services") && $0.contains("HomeKeyService enabled") })
        XCTAssertFalse(tv.sent.contains { $0.contains("InputKeyService") })
    }

    func testFailedHandoverPutsTheStockLauncherBack() async throws {
        let tv = FakeDevice(answers: answers, homeAfterHandover: "com.google.android.tungsten.setupwraith/.RecoveryActivity")
        do {
            _ = try await LauncherInstaller(tv: tv).install(apk: apk, options: .init())
            XCTFail("should have rolled back")
        } catch {
            XCTAssertTrue(tv.sent.contains("pm enable --user 0 com.google.android.apps.tv.launcherx"))
            XCTAssertTrue(error.localizedDescription.contains("setup wizard"))
        }
    }

    func testRefusesOldAndroidBeforeTouchingAnything() async throws {
        let tv = FakeDevice(answers: [("getprop ro.build.version.sdk", "25")])
        do { _ = try await LauncherInstaller(tv: tv).install(apk: apk, options: .init()); XCTFail() } catch {}
        XCTAssertTrue(tv.pushed.isEmpty)
        XCTAssertFalse(tv.sent.contains { $0.hasPrefix("pm ") })
    }

    func testStartFailureLeavesStockLauncherAlone() async throws {
        let tv = FakeDevice(answers: [("getprop ro.build.version.sdk", "30"), ("pm install", "Success"), ("am start -W", "Error: Activity not started")])
        do { _ = try await LauncherInstaller(tv: tv).install(apk: apk, options: .init()); XCTFail() } catch {}
        XCTAssertFalse(tv.sent.contains { $0.hasPrefix("pm disable-user") })
    }
}
