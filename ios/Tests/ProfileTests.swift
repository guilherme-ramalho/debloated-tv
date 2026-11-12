import XCTest
@testable import TVRemoteCore

final class ProfileTests: XCTestCase {
    private func profilesRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Profiles")
    }

    func testBundledProfilesLoadAndMatchTheirTVs() throws {
        let all = DebloatProfile.loadAll(profilesRoot(), includeDevelopment: true)
        XCTAssertTrue(Set(all.map(\.id)).isSuperset(of: ["tcl-43c645", "dev-android-tv-emulator"]))
        XCTAssertEqual(all.filter { !$0.isCommunity }.map(\.id).sorted(), ["dev-android-tv-emulator", "tcl-43c645"])
        // The maintainer's TCL, as its getprop reads (recovery kit, 2026-10-22).
        let mine = ["ro.product.device": "BeyondTV4", "ro.product.name": "G03_4K_GB", "ro.build.version.incremental": "AR11",
                    "ro.build.version.sdk": "30", "ro.product.model": "Smart TV Pro"]
        let tcl = try XCTUnwrap(DebloatProfile.match(mine, in: all))
        XCTAssertEqual(tcl.id, "tcl-43c645")
        XCTAssertTrue(tcl.list.entries.contains { $0.package == "com.tcl.bi" })
        // Upstream #3533: a 43C641 rebooted on every wake from standby with the TCL account app off.
        XCTAssertFalse(tcl.list.entries.contains { $0.package == "com.tcl.usercenter" })
        XCTAssertFalse(tcl.list.entries.contains { $0.package == "com.tcl.keyhelp" }, "keeps the remote's app buttons working inside apps")
        // Same board name on other firmware or another market is not the tested TV (tcl-55s546-us, tcl-55c725 on AR09).
        for (key, other) in [("ro.product.name", "G03_4K_US"), ("ro.build.version.incremental", "AR09")] {
            var props = mine; props[key] = other
            XCTAssertNil(DebloatProfile.match(props, in: all), "\(key)=\(other)")
        }
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
        XCTAssertEqual(config["app_keys"] as? [String], ["KEYCODE_TCL_NETFLIX:com.netflix.ninja", "KEYCODE_TCL_YOUTUBE:com.google.android.youtube.tv",
                                                         "4099:com.amazon.amazonvideo.livingroom"], "a profile keeps its own remote buttons")
    }

    /// LCH-17: a model whose profile doesn't name remote buttons, a Settings key or a Live TV app gets none, never the
    /// launcher's built-in ones (upstream's TCL).
    func testOtherModelsDontInheritTheLaunchersTCLDefaults() throws {
        let emulator = try DebloatProfile.load(profilesRoot().appendingPathComponent("dev-android-tv-emulator"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: try emulator.themeConfig(dock: [])) as? [String: Any])
        XCTAssertEqual(config["app_keys"] as? [String], [])
        XCTAssertEqual(config["settings_key_keycodes"] as? [Int], [])
        XCTAssertEqual(config["hidden_apps"] as? [String], [])
        XCTAssertEqual(config["live_tv_package"] as? String, "")
        XCTAssertEqual(config["columns"] as? Int, 5, "the profile's own values still apply")
    }

    // MARK: community lists (scripts/import-tv-lists.py)

    private static let loaded = DebloatProfile.loadAll(
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Profiles"),
        includeDevelopment: false)

    /// SET-20: every list folder loads, its list parses, and the importer's Home screen rule holds.
    func testEveryCommunityListLoads() throws {
        let folders = try FileManager.default.contentsOfDirectory(atPath: profilesRoot().path).filter { !$0.hasSuffix(".md") }
        let all = DebloatProfile.loadAll(profilesRoot(), includeDevelopment: true)
        XCTAssertEqual(all.count, folders.count, "a folder whose profile or list doesn't load would vanish from setup")
        let community = all.filter(\.isCommunity)
        XCTAssertGreaterThan(community.count, 400)
        for p in community {
            XCTAssertFalse(p.list.entries.isEmpty, p.id)
            XCTAssertTrue(p.manifest.match.isEmpty, "community lists are chosen by ProfileMatcher: \(p.id)")
            if p.manifest.homeScreen == true {
                XCTAssertTrue(FileManager.default.fileExists(atPath: profilesRoot().appendingPathComponent(p.id).appendingPathComponent("config.json").path),
                              "Home screen only where the list ships a launcher config: \(p.id)")
                XCTAssertFalse((p.manifest.brand ?? "").localizedCaseInsensitiveContains("amazon"), p.id)
                XCTAssertFalse(p.list.entries.contains { $0.package.hasPrefix("com.cvte.") }, "no Home screen on CVTE boards: \(p.id)")
            }
            XCTAssertNil(p.theme["dock_apps"], p.id)
        }
    }

    private func installed(_ id: String, extra: [String] = []) throws -> Set<String> {
        let p = try XCTUnwrap(Self.loaded.first { $0.id == id })
        return Set(p.list.entries.map(\.package) + ["com.android.systemui", "com.google.android.tvlauncher"] + extra)
    }

    /// SET-21: the tested TCL profile still wins on the TCL; without it, the lists naming its device come first.
    func testMatcherPrefersTheTestedProfileThenTheModel() throws {
        let tcl = ["ro.product.device": "BeyondTV4", "ro.product.name": "G03_4K_GB", "ro.product.model": "Smart TV Pro",
                   "ro.product.manufacturer": "TCL", "ro.build.version.sdk": "30", "ro.build.version.incremental": "AR11"]
        let pkgs = try installed("tcl-43c645")
        let ranked = ProfileMatcher.rank(tcl, installed: pkgs, in: Self.loaded)
        XCTAssertEqual(ranked.first?.profile.id, "tcl-43c645")
        XCTAssertEqual(ranked.first?.kind, .tested)
        let community = ProfileMatcher.rank(tcl, installed: pkgs, in: Self.loaded.filter(\.isCommunity))
        XCTAssertEqual(community.first?.kind, .model)
        XCTAssertTrue(community.first?.named.contains("BeyondTV4") == true, "\(community.first?.profile.id ?? "none")")
        XCTAssertTrue(community.first?.profile.manifest.brand == "TCL")
    }

    /// SET-22: another brand's TV gets its own model's list.
    func testMatcherFindsTheModelsOwnList() throws {
        // Fingerprint ACER/ACER/R3: product ACER. R3 alone is also Essentiel B's and Challenger's board name.
        let acer = ["ro.product.device": "R3", "ro.product.name": "ACER", "ro.product.model": "R3", "ro.product.manufacturer": "ACER", "ro.build.version.sdk": "34"]
        let ranked = ProfileMatcher.rank(acer, installed: try installed("acer-ar3-r3"), in: Self.loaded)
        XCTAssertEqual(ranked.first?.profile.id, "acer-ar3-r3")
        XCTAssertEqual(ranked.first?.kind, .model)
        var noProduct = acer; noProduct["ro.product.name"] = nil
        XCTAssertFalse(ProfileMatcher.rank(noProduct, installed: try installed("acer-ar3-r3"), in: Self.loaded).contains { $0.kind == .model },
                       "a shared board name alone doesn't say which list is this TV's")
    }

    /// SET-23: a model with no list of its own gets the closest list of its brand, marked as made for another model.
    func testMatcherOffersTheClosestListForAnUnknownModel() throws {
        var pkgs = try installed("tcl-43c645")
        pkgs.remove("com.tcl.bi")
        let ranked = ProfileMatcher.rank(["ro.product.device": "NotARealBoard9", "ro.product.manufacturer": "TCL"], installed: pkgs,
                                         in: Self.loaded.filter(\.isCommunity))
        XCTAssertFalse(ranked.isEmpty)
        XCTAssertTrue(ranked.allSatisfy { $0.kind == .closest })
        XCTAssertEqual(ranked.first?.profile.manifest.brand, "TCL")
    }

    /// SET-24: nothing is offered for a TV no list resembles.
    func testMatcherOffersNothingForAnUnrelatedTV() {
        let ranked = ProfileMatcher.rank(["ro.product.device": "mystery", "ro.product.manufacturer": "Nobody"],
                                         installed: ["com.android.systemui", "com.google.android.youtube.tv", "org.example.app"], in: Self.loaded)
        XCTAssertTrue(ranked.isEmpty, ranked.map(\.id).joined(separator: ", "))
    }

    /// SET-28: "made for this model" comes only from the names a list gives its own unit. A board name many lists
    /// share needs the product too; another list mentioned in a header claims nothing.
    func testModelClaimsComeFromTheListsOwnNames() throws {
        let community = Self.loaded.filter(\.isCommunity)
        // A US BeyondTV4 (product G03_4K_US) is not the UK BeyondTV6 build or the G03_4K_GB sets.
        let us = ["ro.product.device": "BeyondTV4", "ro.product.name": "G03_4K_US", "ro.product.manufacturer": "TCL"]
        let ranked = ProfileMatcher.rank(us, installed: try installed("tcl-55s546-us"), in: community)
        let models = ranked.filter { $0.kind == .model }.map(\.id)
        XCTAssertTrue(models.contains("tcl-55s546-us"), "\(models)")
        XCTAssertFalse(models.contains("tcl-beyondtv4-uk"), "product BeyondTV6 is another unit")
        XCTAssertFalse(models.contains("tcl-55c725"), "product G03_4K_GB is another unit")
        // acer-ar3-r3's header points to acer-ar55ar2851udpro: that list's TV is not claimed by it.
        let acer = try XCTUnwrap(community.first { $0.id == "acer-ar3-r3" })
        XCTAssertEqual(acer.manifest.names?["device"], ["R3"])
    }

    /// The end-to-end community scenario (scripts/e2e.sh): on the emulator its own list comes first as "made for this
    /// model", and the other development list is offered only as "closest".
    func testEmulatorCommunityListsRankAsTheScenarioExpects() throws {
        let all = DebloatProfile.loadAll(profilesRoot(), includeDevelopment: true).filter { $0.isCommunity }
        let emulator = ["ro.product.device": "emulator64_arm64", "ro.product.name": "sdk_google_atv64_arm64",
                        "ro.product.model": "sdk_google_atv64_arm64", "ro.product.manufacturer": "Google"]
        let installed: Set<String> = ["com.google.android.feedback", "com.google.android.partnersetup", "com.google.android.tvrecommendations",
                                      "com.google.android.marvin.talkback", "com.google.android.tvlauncher", "com.google.android.youtube.tv"]
        let ranked = ProfileMatcher.rank(emulator, installed: installed, in: all, limit: 50)
        XCTAssertEqual(ranked.first?.id, "dev-community-model")
        XCTAssertEqual(ranked.first?.kind, .model)
        XCTAssertEqual(ranked.first { $0.id == "dev-community-closest" }?.kind, .closest)
        XCTAssertFalse(DebloatProfile.loadAll(profilesRoot(), includeDevelopment: false).contains { $0.id.hasPrefix("dev-") })
    }

    /// Setup loads every list when it opens: keep that quick.
    func testLoadingAllListsIsQuick() {
        let start = Date()
        _ = DebloatProfile.loadAll(profilesRoot(), includeDevelopment: false)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "release builds are several times faster than this debug test")
    }
}
