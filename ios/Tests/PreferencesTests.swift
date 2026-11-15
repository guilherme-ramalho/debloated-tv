import XCTest
@testable import TVRemoteCore

final class PreferencesTests: XCTestCase {
    func testPadSwipesUseScreenDirectionsAndIgnoreJitter() {
        XCTAssertEqual(TVKey.swipeDirection(dx: 100, dy: 8), .right)
        XCTAssertEqual(TVKey.swipeDirection(dx: -100, dy: 8), .left)
        XCTAssertEqual(TVKey.swipeDirection(dx: 5, dy: -70), .up)
        XCTAssertEqual(TVKey.swipeDirection(dx: 5, dy: 70), .down)
        XCTAssertEqual(TVKey.swipeDirection(dx: 28, dy: 0), .right)
        XCTAssertNil(TVKey.swipeDirection(dx: 27, dy: 20))
        XCTAssertNil(TVKey.swipeDirection(dx: 0, dy: 0))
        XCTAssertNil(TVKey.swipeDirection(dx: .nan, dy: 20))
        XCTAssertNil(TVKey.swipeDirection(dx: .infinity, dy: 20))
    }
    func testReversedSwipesGoTheOtherWay() {
        XCTAssertEqual(TVKey.swipeDirection(dx: 100, dy: 8, reversed: true), .left)
        XCTAssertEqual(TVKey.swipeDirection(dx: 5, dy: -70, reversed: true), .down)
        XCTAssertNil(TVKey.swipeDirection(dx: 27, dy: 20, reversed: true))
        var pad = PadInteraction(); pad.reversed = true
        XCTAssertEqual(pad.begin(key: .right), [])
        XCTAssertEqual(pad.move(dx: 80, dy: 0), [])
        XCTAssertEqual(pad.end(dx: 100, dy: 0), [.tap(.left)])
        // A tap is still the button under the finger.
        XCTAssertEqual(pad.begin(key: .right), [])
        XCTAssertEqual(pad.end(dx: 3, dy: 2), [.tap(.right)])
    }
    func testPadTapSendsOneCommandOnRelease() {
        var pad = PadInteraction()
        XCTAssertEqual(pad.begin(key: .select), [])
        XCTAssertEqual(pad.move(dx: 5, dy: 4), [])
        XCTAssertEqual(pad.end(dx: 5, dy: 4), [.tap(.select)])
        XCTAssertEqual(pad.end(dx: 5, dy: 4), [])
    }
    func testSwipeDoesNotAlsoTapStartingArrowOrOK() {
        for startingKey in [TVKey.left, .select, .up] {
            var pad = PadInteraction()
            XCTAssertEqual(pad.begin(key: startingKey), [])
            XCTAssertEqual(pad.move(dx: 80, dy: 8), [])
            XCTAssertEqual(pad.hold(), [])
            XCTAssertEqual(pad.end(dx: 100, dy: 8), [.tap(.right)])
        }
    }
    func testPadHoldReleasesOnceWithoutAnExtraTap() {
        var pad = PadInteraction()
        XCTAssertEqual(pad.begin(key: .down), [])
        XCTAssertEqual(pad.hold(), [.press(.down)])
        XCTAssertEqual(pad.hold(), [])
        XCTAssertEqual(pad.end(dx: 1, dy: 2), [.release(.down)])
        XCTAssertEqual(pad.cancel(), [])
    }
    func testPadCancellationReleasesHeldKeyAndDiscardsPendingTap() {
        var pad = PadInteraction()
        _ = pad.begin(key: .select)
        XCTAssertEqual(pad.cancel(), [])
        XCTAssertEqual(pad.hold(), [])
        XCTAssertEqual(pad.end(dx: 0, dy: 0), [])
        _ = pad.begin(key: .left); _ = pad.hold()
        XCTAssertEqual(pad.cancel(), [.release(.left)])
        XCTAssertEqual(pad.cancel(), [])
    }
    func testAbortedSwipeDoesNotBecomeATap() {
        var pad = PadInteraction()
        _ = pad.begin(key: .select); _ = pad.move(dx: 70, dy: 0)
        XCTAssertEqual(pad.end(dx: 0, dy: 0), [])
        _ = pad.begin(key: nil)
        XCTAssertEqual(pad.end(dx: 0, dy: 0), [])
    }
    func testSwipeAfterHoldReleasesBeforeSendingDirection() {
        var pad = PadInteraction()
        _ = pad.begin(key: .select); _ = pad.hold()
        XCTAssertEqual(pad.move(dx: 0, dy: -90), [.release(.select)])
        XCTAssertEqual(pad.end(dx: 0, dy: -90), [.tap(.up)])
        XCTAssertEqual(pad.cancel(), [])
    }
    func testDefaultPreferencesRoundTripAndIndependentProfiles() throws {
        let initial = RemotePreferences()
        try initial.validate()
        XCTAssertEqual(try JSONDecoder().decode(RemotePreferences.self, from: JSONEncoder().encode(initial)), initial)
        var changed = initial
        changed.profiles[0].layout.dockCount = 2
        XCTAssertEqual(changed.profiles[1].layout.dockCount, 5)
        XCTAssertEqual(changed.profileID, changed.profiles[0].id)
    }
    func testHiddenAppsDoNotConsumeDockSlotsAndOrderIsPreserved() throws {
        var layout = HomeLayout()
        layout.dockCount = 3
        layout.hidden = [layout.order[0]]
        try layout.validate()
        XCTAssertEqual(layout.dock, Array(layout.order.dropFirst().prefix(3)))
        layout.order.swapAt(1, 2)
        XCTAssertEqual(layout.dock[0], RemoteApp.known[2].id)
    }
    func testRejectUnsafeOrUnboundedLayouts() {
        var layout = HomeLayout()
        layout.dockCount = 8; XCTAssertThrowsError(try layout.validate())
        layout.dockCount = 5; layout.order.append(layout.order[0]); XCTAssertThrowsError(try layout.validate())
        layout = .init(); layout.hidden = ["../settings"]; XCTAssertThrowsError(try layout.validate())
        layout = .init(); layout.wallpaper = "photo-../../secrets"; XCTAssertThrowsError(try layout.validate())
        XCTAssertFalse(RemoteApp.validPackage("com.example;reboot"))
        XCTAssertFalse(RemoteApp.validPackage(""))
    }
    func testBackupsRejectMissingPhotoAndFutureSchema() throws {
        let backup = HomeBackup(name: "Before changes", layout: .init())
        XCTAssertEqual(try HomeBackup.decode(JSONEncoder().encode(backup)), backup)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
        json["version"] = 100
        XCTAssertThrowsError(try HomeBackup.decode(JSONSerialization.data(withJSONObject: json)))
        var photo = HomeLayout(); photo.wallpaper = "photo-" + UUID().uuidString
        XCTAssertThrowsError(try HomeBackup.decode(JSONEncoder().encode(HomeBackup(name: "Photo", layout: photo))))
        XCTAssertThrowsError(try HomeBackup.decode(Data(repeating: 0, count: 2_000_001)))
    }
    func testKeyStepsAllowOnlyTheWidgetKeys() throws {
        try QuickAction(name: "Pad", steps: [.init(key: .up), .init(key: .select), .init(key: .power)]).validate()
        XCTAssertEqual(ActionStep(key: .rewind).key, .rewind)
        XCTAssertThrowsError(try QuickAction(name: "Delete", steps: [.init(key: .delete)]).validate())
        XCTAssertThrowsError(try QuickAction(name: "Junk", steps: [.init(.key, argument: "abc")]).validate())
        XCTAssertNil(ActionStep(.home).key)
    }

    func testSnapshotsFromOlderLaunchersHaveNoHomeSettings() throws {
        let old = #"{"revision":"r","layout":{"dockCount":5,"order":[],"hidden":[],"wallpaper":"quiet-night"},"apps":[],"inputs":[]}"#
        XCTAssertNil(try JSONDecoder().decode(LauncherSnapshot.self, from: Data(old.utf8)).home)
        let new = #"{"revision":"r","layout":{"dockCount":5,"order":[],"hidden":[],"wallpaper":"quiet-night"},"apps":[],"inputs":[],"home":{"features":["weather","sleepTimer"],"weather":true,"weatherAuto":true,"weatherPlace":"Valladolid","locationAllowed":true}}"#
        let home = try XCTUnwrap(try JSONDecoder().decode(LauncherSnapshot.self, from: Data(new.utf8)).home)
        XCTAssertTrue(home.supports("weather"))
        XCTAssertEqual(home.weatherPlace, "Valladolid")
    }

    /// LCH-15: the update is offered only when the app carries a newer launcher than the TV reports.
    func testHomeUpdateIsOfferedOnlyForANewerBundledLauncher() throws {
        let base = #"{"revision":"r","layout":{"dockCount":5,"order":[],"hidden":[],"wallpaper":"quiet-night"},"apps":[],"inputs":[]"#
        let old = try JSONDecoder().decode(LauncherSnapshot.self, from: Data((base + "}").utf8))
        let withoutVersion = try JSONDecoder().decode(LauncherSnapshot.self, from: Data((base + #","home":{"features":["looks"]}}"#).utf8))
        let current = try JSONDecoder().decode(LauncherSnapshot.self, from: Data((base + #","home":{"features":["looks"],"version":13}}"#).utf8))
        XCTAssertEqual(LauncherVersion.onTV(old), 12, "the 1.0 launcher reports nothing: it is versionCode 12")
        XCTAssertEqual(LauncherVersion.onTV(withoutVersion), 12)
        XCTAssertEqual(LauncherVersion.onTV(current), 13)

        let bundled = LauncherVersion.bundled(Data(#"{"versionCode": 13}"#.utf8))
        XCTAssertEqual(bundled, 13)
        XCTAssertTrue(LauncherVersion.updateAvailable(tv: LauncherVersion.onTV(old), bundled: bundled))
        XCTAssertFalse(LauncherVersion.updateAvailable(tv: LauncherVersion.onTV(current), bundled: bundled), "same version: no card")
        XCTAssertFalse(LauncherVersion.updateAvailable(tv: 14, bundled: bundled), "the TV is newer than the app: no card")
        XCTAssertFalse(LauncherVersion.updateAvailable(tv: 12, bundled: nil), "a build without tvhome.json never offers it")
        for broken in [nil, Data("junk".utf8), Data(#"{"versionCode":"13"}"#.utf8), Data(#"{"versionCode":0}"#.utf8)] {
            XCTAssertNil(LauncherVersion.bundled(broken))
        }
    }

    func testQuickActionsRejectInvalidStepsAndPostShutdownCommands() throws {
        try QuickAction(name: "Movie time", steps: [.init(.wake), .init(.openApp, argument: "com.netflix.ninja")]).validate()
        XCTAssertThrowsError(try QuickAction(name: "Empty", steps: []).validate())
        XCTAssertThrowsError(try QuickAction(name: "Invalid app", steps: [.init(.openApp, argument: "https://example.com")]).validate())
        XCTAssertThrowsError(try QuickAction(name: "Unassigned input", steps: [.init(.input)]).validate())
        XCTAssertThrowsError(try QuickAction(name: "Unsafe sequence", steps: [.init(.sleep), .init(.home)]).validate())
        XCTAssertThrowsError(try QuickAction(name: "Too long", steps: Array(repeating: .init(.home), count: 13)).validate())
    }
    func testKeyboardUsesUTF16SelectionAndCurrentCounters() throws {
        let text = "A😀é"
        let packet = try TVSession.textMessage(text, imeCounter: 12, fieldCounter: 7)
        let body = try XCTUnwrap(Wire.fields(packet).first?.bytes)
        XCTAssertEqual(try Wire.number(1, in: body), 12)
        XCTAssertEqual(try Wire.number(2, in: body), 7)
        let edit = try XCTUnwrap(Wire.fields(body).first(where: { $0.number == 3 })?.bytes)
        let object = try XCTUnwrap(Wire.fields(edit).first(where: { $0.number == 2 })?.bytes)
        XCTAssertEqual(try Wire.number(1, in: object), UInt64(text.utf16.count - 1))
        XCTAssertEqual(try Wire.fields(object).first(where: { $0.number == 3 })?.bytes, Data(text.utf8))
        XCTAssertThrowsError(try TVSession.textMessage("", imeCounter: 0, fieldCounter: 0))
        XCTAssertThrowsError(try TVSession.textMessage(String(repeating: "a", count: 4097), imeCounter: 0, fieldCounter: 0))
    }

    /// REM-16: typing after a pause sends only the change; the TV inserts at its cursor, so the whole text doubled it.
    func testTypingSendsOnlyTheChange() {
        func edit(_ a: String, _ b: String) -> String { let e = TVSession.typingEdit(from: a, to: b); return "\(e.deletes)|\(e.insert)" }
        XCTAssertEqual(edit("test", "testing"), "0|ing")
        XCTAssertEqual(edit("", "hi"), "0|hi")
        XCTAssertEqual(edit("testing", "test"), "3|")
        XCTAssertEqual(edit("hi", ""), "2|")
        XCTAssertEqual(edit("abc", "abd"), "1|d", "a changed last letter: delete it, type the new one")
        XCTAssertEqual(edit("café", "cafe"), "1|e", "counts characters, not bytes")
        XCTAssertEqual(edit("same", "same"), "0|")
    }
    func testLargeEditorFramesDoNotRelaxControlConnectionLimit() throws {
        let body = Data(repeating: 31, count: 100_000)
        let frame = Wire.varint(UInt64(body.count)) + body
        var standard = FrameDecoder()
        XCTAssertThrowsError(try standard.append(frame))
        var editor = FrameDecoder(maxFrameSize: 4_194_304)
        XCTAssertTrue(try editor.append(frame.prefix(1000)).isEmpty)
        XCTAssertEqual(try editor.append(frame.dropFirst(1000)), [body])
        XCTAssertThrowsError(try editor.append(Wire.varint(4_194_305)))
    }

    func testRemoteShortcutsFollowTheDockThenTheList() {
        var preferences = RemotePreferences()
        let netflix = "com.netflix.ninja", youtube = "com.google.android.youtube.tv", prime = "com.amazon.amazonvideo.livingroom"
        let disney = "com.disney.disneyplus", max = "com.wbd.stream", crunchyroll = "com.crunchyroll.crunchyroid", spotify = "com.spotify.tv.android"
        XCTAssertEqual(preferences.remoteShortcutIDs(dock: nil), [netflix, youtube, prime, disney, max, crunchyroll], "no TV Home: the list")
        XCTAssertEqual(preferences.remoteShortcutIDs(dock: [spotify, youtube, netflix]), [spotify, youtube, netflix, prime, disney, max],
                       "a 3-app dock leads, then the list fills the rest without repeats")
        XCTAssertEqual(preferences.remoteShortcutIDs(dock: [youtube, "com.unknown.app"]).first, youtube, "dock apps the phone doesn't know are skipped")
        preferences.remoteCount = 2
        XCTAssertEqual(preferences.remoteShortcutIDs(dock: [spotify, youtube, netflix]), [spotify, youtube])
        preferences.remoteOrder = [crunchyroll, netflix]
        preferences.remoteCount = 4
        XCTAssertEqual(preferences.remoteShortcutIDs(dock: [youtube]), [youtube, crunchyroll, netflix], "the reordered list fills in")
    }
}
