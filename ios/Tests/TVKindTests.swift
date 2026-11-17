import XCTest
import Network
@testable import TVRemoteCore

/// Telling the TV type on Connect (CON-17..20): the port rules, which announcements are worth a knock, merging one
/// TV's several announcements into one row, and the knock itself against local ports.
final class TVKindTests: XCTestCase {
    func testPortsTellTheKindAndTheRemoteServicesWinOverCast() {
        XCTAssertEqual(TVPorts.kind(open: [6466, 6467, 8009]), .androidTV)
        XCTAssertEqual(TVPorts.kind(open: [8060, 8009]), .roku)
        XCTAssertEqual(TVPorts.kind(open: [3001]), .lg)
        XCTAssertEqual(TVPorts.kind(open: [3000, 8009]), .lg)
        XCTAssertEqual(TVPorts.kind(open: [8002]), .samsung)
        XCTAssertEqual(TVPorts.kind(open: [8009]), .chromecast)
        XCTAssertNil(TVPorts.kind(open: []))
        XCTAssertNil(TVPorts.kind(open: [7000]))
        XCTAssertFalse(TVPorts.all.contains(5555), "ADB is never knocked")
    }

    func testWhatPurioCanDoOnEachKind() {
        XCTAssertEqual(TVPorts.support(.androidTV, open: [6466, 8009]), .full(showOnTV: true))
        XCTAssertEqual(TVPorts.support(.androidTV, open: [6466]), .full(showOnTV: false))
        for kind in [TVKind.roku, .lg, .samsung] { XCTAssertEqual(TVPorts.support(kind, open: []), .remoteComing) }
        XCTAssertEqual(TVPorts.support(.chromecast, open: [8009]), .notYet)
        XCTAssertTrue(TVSupport.full(showOnTV: false).canPair)
        XCTAssertFalse(TVSupport.remoteComing.canPair)
        XCTAssertFalse(TVSupport.notYet.canPair)
    }

    func testOnlyVideoCastDevicesAndOtherMakersAirPlayAreChecked() {
        XCTAssertTrue(TVSighting(service: .androidTV, name: "TV").worthChecking)
        XCTAssertTrue(TVSighting(service: .cast, name: "Chromecast-1", txt: ["ca": "4101", "fn": "Bedroom"]).worthChecking)
        XCTAssertFalse(TVSighting(service: .cast, name: "Google-Home-1", txt: ["ca": "2052"]).worthChecking, "speaker")
        XCTAssertFalse(TVSighting(service: .cast, name: "Group", txt: ["ca": "4133"]).worthChecking, "group")
        XCTAssertFalse(TVSighting(service: .cast, name: "x").worthChecking)
        XCTAssertTrue(TVSighting(service: .airPlay, name: "[LG] webOS TV", txt: ["Manufacturer": "LG Electronics"]).worthChecking)
        XCTAssertFalse(TVSighting(service: .airPlay, name: "Living Room", txt: ["model": "AppleTV14,1"]).worthChecking)
        XCTAssertFalse(TVSighting(service: .airPlay, name: "MacBook", txt: ["manufacturer": "Apple Inc."]).worthChecking)
        XCTAssertEqual(TVSighting(service: .cast, name: "Chromecast-1", txt: ["fn": "Bedroom"]).displayName, "Bedroom")
    }

    func testOneRowPerTVAndOthersOnlyOnceChecked() {
        let tcl = TVSighting(service: .androidTV, name: "Living Room TV", host: "192.168.0.13")
        let tclCast = TVSighting(service: .cast, name: "TCL-abc", host: "192.168.0.13", txt: ["ca": "4101", "fn": "Living Room TV"])
        let lgAir = TVSighting(service: .airPlay, name: "[LG] webOS TV OLED55", host: "192.168.0.20", txt: ["manufacturer": "LG Electronics"])
        let lgCast = TVSighting(service: .cast, name: "LG-123", host: "192.168.0.20", txt: ["ca": "4101", "fn": "LG cast"])
        let speaker = TVSighting(service: .airPlay, name: "Kitchen", host: "192.168.0.30", txt: ["manufacturer": "Sonos"])
        let resolving = TVSighting(service: .androidTV, name: "Bedroom TV")
        let all = [tcl, tclCast, lgAir, lgCast, speaker, resolving]

        let before = TVSightings.merge(all, probes: [:])
        XCTAssertEqual(before.map(\.name), ["Bedroom TV", "Living Room TV"], "Android TVs show at once; others wait for the knock")
        XCTAssertNil(before[1].support)

        let after = TVSightings.merge(all, probes: ["192.168.0.13": [6466, 8009], "192.168.0.20": [3001, 8009], "192.168.0.30": []])
        XCTAssertEqual(after.map(\.name), ["[LG] webOS TV OLED55", "Bedroom TV", "Living Room TV"])
        XCTAssertEqual(after[0].kind, .lg); XCTAssertEqual(after[0].support, .remoteComing); XCTAssertEqual(after[0].host, "192.168.0.20")
        XCTAssertEqual(after[2].support, .full(showOnTV: true))
        XCTAssertNil(after[1].host)
    }

    func testKnockFindsOpenAndClosedPorts() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port?.rawValue)
        let open = await PortKnock.openPorts(host: "127.0.0.1", ports: [port, 1], timeout: 1)
        XCTAssertEqual(open, [port])
        let answer = await PortKnock.answer(host: "127.0.0.1", port: port)
        XCTAssertEqual(answer, .open)
    }

    /// CST-27: only a refusal means "no Chromecast built in"; a TV that doesn't answer (standby, away) isn't judged.
    func testARefusedPortIsToldApartFromASilentOne() async {
        let refused = await PortKnock.answer(host: "127.0.0.1", port: 1, timeout: 1)
        XCTAssertEqual(refused, .refused)
        let silent = await PortKnock.answer(host: "192.0.2.10", port: 8009, timeout: 1)   // documentation range: nobody there
        XCTAssertEqual(silent, .silent)
    }
}
