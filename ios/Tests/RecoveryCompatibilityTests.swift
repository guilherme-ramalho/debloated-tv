import XCTest
@testable import TVRemoteCore

/// Records written by upstream's tools/recovery.py (and by the Codex-era cleanup) must restore the same way here
/// (TESTING.md: UND-*).
final class RecoveryCompatibilityTests: XCTestCase {
    /// The shape recovery.py writes: Python's ISO time with a +0200 offset, a list given as a file path.
    static let upstreamRecord = """
    {"created": "2026-10-22T22:14:37+0200", "home": "com.google.android.apps.tv.launcherx/.home.HomeActivity",
     "host": "192.0.2.21", "list": "/path/to/batches/04-preloads.txt",
     "packages": {"com.google.android.apps.tv.launcherx": "enabled", "com.tcl.guard": "enabled",
                  "com.tcl.ocean.instructions": "enabled", "com.tcl.stan": "disabled", "com.tcl.gone": "absent"},
     "settings": {"animator_duration_scale": "1.0", "transition_animation_scale": "null", "window_animation_scale": "0.5"},
     "version": 1}
    """

    func testDecodesUpstreamRecords() throws {
        let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(Self.upstreamRecord.utf8))
        XCTAssertEqual(record.version, 1)
        XCTAssertEqual(record.packages.count, 5)
        XCTAssertEqual(record.home, "com.google.android.apps.tv.launcherx/.home.HomeActivity")
    }

    func testRestoreTurnsBackOnlyWhatWasOnAndPutsHomeBack() throws {
        let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(Self.upstreamRecord.utf8))
        let commands = Debloater.restoreCommands(record, stock: "com.google.android.apps.tv.launcherx")
        XCTAssertEqual(Array(commands.prefix(3)), ["pm enable com.google.android.apps.tv.launcherx", "pm enable com.tcl.guard", "pm enable com.tcl.ocean.instructions"])
        XCTAssertFalse(commands.contains("pm enable com.tcl.stan"), "it was off before the cleanup")
        XCTAssertFalse(commands.contains { $0.contains("com.tcl.gone") })
        XCTAssertTrue(commands.contains("cmd package set-home-activity --user 0 com.google.android.apps.tv.launcherx/.home.HomeActivity"))
        XCTAssertTrue(commands.contains("settings delete global transition_animation_scale"))
        XCTAssertTrue(commands.contains("settings put global window_animation_scale 0.5"))
    }

    func testRestoreNeverRunsInjectedSettingValues() throws {
        var record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(Self.upstreamRecord.utf8))
        record.settings["window_animation_scale"] = "1; reboot"
        let commands = Debloater.restoreCommands(record)
        XCTAssertFalse(commands.contains { $0.contains("reboot") })
    }

    func testRestoreNeverRunsInjectedPackagesOrHome() throws {
        var record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(Self.upstreamRecord.utf8))
        record.packages["com.ok; reboot"] = "enabled"
        record.packages["$(reboot)"] = "enabled"
        record.home = "com.x/.Main; reboot"
        let commands = Debloater.restoreCommands(record)
        XCTAssertFalse(commands.contains { $0.contains("reboot") }, commands.joined(separator: "\n"))
        XCTAssertTrue(commands.contains("pm enable com.tcl.guard"), "valid entries still restore")
    }

    func testOurRecordsUseUpstreamKeys() throws {
        let record = RecoveryRecord(created: "2026-11-01T10:00:00Z", host: "192.0.2.1", list: "tcl-43c645", home: nil, settings: [:], packages: ["a.b": "enabled"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "created", "host", "list", "settings", "packages"], "home is omitted when nil, as recovery.py reads it")
    }
}
