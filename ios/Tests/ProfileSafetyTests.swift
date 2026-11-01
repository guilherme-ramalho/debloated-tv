import XCTest
@testable import TVRemoteCore

/// Every bundled profile, checked the way a contributor's new one will be (TESTING.md: PRO-*).
final class ProfileSafetyTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Profiles")
    }
    private var folders: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    func testEveryProfileFolderLoads() throws {
        XCTAssertFalse(folders.isEmpty)
        for folder in folders {
            XCTAssertNoThrow(try DebloatProfile.load(folder), folder.lastPathComponent)
            let profile = try DebloatProfile.load(folder)
            XCTAssertEqual(profile.id, folder.lastPathComponent, "profile.json id matches its folder")
        }
    }

    func testNoProfileCanDisableCoreOrTheNewHome() throws {
        for profile in DebloatProfile.loadAll(root, includeDevelopment: true) {
            let core = profile.list.entries.map(\.package).filter(DebloatRules.isCore)
            XCTAssertEqual(core, [], "\(profile.id) lists core packages")
            XCTAssertFalse(profile.list.entries.contains { $0.package == DebloatRules.customLauncher }, profile.id)
        }
    }

    func testManifestsAreComplete() throws {
        for profile in DebloatProfile.loadAll(root, includeDevelopment: true) {
            XCTAssertFalse(profile.manifest.match.isEmpty, "\(profile.id): an empty match would claim every TV")
            XCTAssertTrue(profile.manifest.match.values.allSatisfy { !$0.isEmpty }, profile.id)
            if let stock = profile.manifest.stockLauncher {
                XCTAssertTrue(DebloatRules.stockLaunchers.contains(stock), "\(profile.id): unknown stock launcher \(stock)")
            }
            XCTAssertTrue(profile.manifest.dockCandidates.allSatisfy(Pattern.isPackage), profile.id)
            let config = try XCTUnwrap(JSONSerialization.jsonObject(with: profile.themeConfig(dock: [])) as? [String: Any], profile.id)
            XCTAssertNotNil(config["dock_apps"], profile.id)
            XCTAssertFalse(profile.list.entries.isEmpty, profile.id)
        }
    }

    func testNoTwoProfilesClaimTheSameTV() throws {
        let all = DebloatProfile.loadAll(root, includeDevelopment: true)
        for a in all {
            // A TV reporting exactly a's first listed values must not also match another profile.
            let props = a.manifest.match.mapValues { $0[0] }
            let matching = all.filter { $0.matches(props) }.map(\.id)
            XCTAssertEqual(matching, [a.id], "\(a.id) overlaps \(matching)")
        }
    }

    func testReleaseBuildsHideDevelopmentProfiles() {
        XCTAssertTrue(DebloatProfile.loadAll(root, includeDevelopment: false).allSatisfy { $0.manifest.developmentOnly != true })
    }
}
