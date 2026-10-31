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
}
