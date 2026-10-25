import XCTest
@testable import TVRemoteCore

final class PlaybackTests: XCTestCase {
    private func state(_ changes: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["access": true, "kind": "app", "package": "com.example.player", "source": "Player", "title": "A title", "playback": "playing", "input": ""]
        value.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testPlaybackTitleAndStates() throws {
        let playing = try TVPlayback.decode(state())
        XCTAssertEqual(playing.mediaTitle, "A title")
        XCTAssertEqual(playing.playback, "playing")
        XCTAssertNil(try TVPlayback.decode(state(["title": " \n ", "playback": "paused"])).mediaTitle)
        let hdmi = try TVPlayback.decode(state(["kind": "hdmi", "source": "PlayStation 5", "input": "HDMI 1", "title": "", "playback": "unknown"]))
        XCTAssertEqual(hdmi.source, "PlayStation 5")
        XCTAssertNil(hdmi.mediaTitle)
    }
    func testRejectMalformedOrUnboundedMetadata() throws {
        XCTAssertThrowsError(try TVPlayback.decode(state(["playback": "invented"])))
        XCTAssertThrowsError(try TVPlayback.decode(state(["kind": "invented"])))
        XCTAssertThrowsError(try TVPlayback.decode(state(["title": String(repeating: "x", count: 513)])))
        XCTAssertThrowsError(try TVPlayback.decode(Data("{}".utf8)))
    }
}
