import XCTest
@testable import TVRemoteCore

final class ProfileTests: XCTestCase {
    private func profilesRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Profiles")
    }

    func testBundledProfilesLoadAndMatchTheirTVs() throws {
        let all = DebloatProfile.loadAll(profilesRoot(), includeDevelopment: true)
        XCTAssertEqual(Set(all.map(\.id)), ["tcl-43c645", "dev-android-tv-emulator"])
        let tcl = try XCTUnwrap(DebloatProfile.match(["ro.product.device": "BeyondTV4", "ro.build.version.sdk": "30", "ro.product.model": "Smart TV Pro"], in: all))
        XCTAssertEqual(tcl.id, "tcl-43c645")
        XCTAssertTrue(tcl.list.entries.contains { $0.package == "com.tcl.bi" })
        XCTAssertTrue(tcl.list.neverDisable.contains("com.tcl.tvinput"))
        XCTAssertTrue(tcl.manifest.launcher.homeKeyService)
        XCTAssertNil(DebloatProfile.match(["ro.product.device": "BeyondTV4", "ro.build.version.sdk": "31"], in: all), "another Android version is not the tested firmware")
        XCTAssertEqual(DebloatProfile.match(["ro.product.model": "sdk_google_atv64_arm64"], in: all)?.id, "dev-android-tv-emulator")
        XCTAssertFalse(DebloatProfile.loadAll(profilesRoot(), includeDevelopment: false).contains { $0.id == "dev-android-tv-emulator" })
    }

    func testThemeGetsTheChosenDock() throws {
        let tcl = try DebloatProfile.load(profilesRoot().appendingPathComponent("tcl-43c645"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: try tcl.themeConfig(dock: ["com.netflix.ninja", "not a package"])) as? [String: Any])
        XCTAssertEqual(config["dock_apps"] as? [String], ["com.netflix.ninja"])
        XCTAssertEqual(config["correct_prehandled_volume_keys"] as? Bool, true)
        XCTAssertEqual(config["live_tv_package"] as? String, "com.tcl.tv")
        XCTAssertEqual(config["tile_menu"] as? Bool, false, "the phone arranges Home; the TV's tile menu stays off")
        XCTAssertEqual(config["glow_snap"] as? Bool, true, "no full-screen glow fade on the TCL's GPU")
    }
}
