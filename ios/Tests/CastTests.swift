import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import TVRemoteCore

final class CastTests: XCTestCase {
    // MARK: frames

    func testMessageRoundTripsThroughFrames() throws {
        let message = CastMessage(source: "sender-purio", destination: "receiver-0", namespace: CastNamespace.receiver, json: ["type": "LAUNCH", "appId": "CC1AD845"])
        var decoder = CastFrameDecoder()
        let framed = message.framed + message.framed
        var bodies = try decoder.append(framed.prefix(7))           // split inside the first frame
        XCTAssertTrue(bodies.isEmpty)
        bodies = try decoder.append(framed.dropFirst(7))
        XCTAssertEqual(bodies.count, 2)
        let decoded = try CastMessage.decode(bodies[0])
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.type, "LAUNCH")
        XCTAssertEqual(Array(message.framed.prefix(4)), [0, 0, 0, UInt8(message.body.count)])
    }

    func testOversizedFrameIsRefused() {
        var decoder = CastFrameDecoder(maxFrameSize: 16)
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 1, 0]) + Data(count: 4)))
    }

    // MARK: controller

    private func status(_ apps: [[String: Any]]) -> CastMessage {
        CastMessage(source: "receiver-0", destination: "*", namespace: CastNamespace.receiver, json: ["type": "RECEIVER_STATUS", "status": ["applications": apps]])
    }
    private let player: [String: Any] = ["appId": "CC1AD845", "transportId": "t-1", "sessionId": "s-1", "displayName": "Default Media Receiver"]
    private let photo = CastController.Load(url: "http://192.168.0.14:5000/abc/IMG_1.jpg", contentType: "image/jpeg", title: "IMG_1")

    func testFirstLoadLaunchesThePlayerThenLoadsOnceItIsUp() {
        var cast = CastController()
        let launch = cast.load(photo)
        XCTAssertEqual(launch.map(\.type), ["CONNECT", "LAUNCH"])
        XCTAssertEqual(launch[1].json["appId"] as? String, "CC1AD845")
        XCTAssertEqual(cast.state, .launching)
        XCTAssertTrue(cast.load(photo).isEmpty, "a second load while launching only replaces the pending one")

        XCTAssertTrue(cast.receive(status([])).send.isEmpty, "status before the player is up changes nothing")
        let (out, events) = cast.receive(status([player]))
        XCTAssertEqual(events, [.ready])
        XCTAssertEqual(out.map(\.type), ["CONNECT", "LOAD"])
        XCTAssertEqual(out[0].destination, "t-1")
        let media = out[1].json["media"] as? [String: Any]
        XCTAssertEqual(media?["contentId"] as? String, photo.url)
        XCTAssertEqual(out[1].json["sessionId"] as? String, "s-1")
        XCTAssertNil(cast.pending)
    }

    func testHeartbeatIsAnswered() {
        var cast = CastController()
        let out = cast.receive(CastMessage(source: "receiver-0", destination: "sender-purio", namespace: CastNamespace.heartbeat, json: ["type": "PING"])).send
        XCTAssertEqual(out.map(\.type), ["PONG"])
        XCTAssertEqual(out[0].destination, "receiver-0")
    }

    func testMediaCommandsNeedTheMediaSessionFromTheTV() {
        var cast = CastController()
        _ = cast.load(photo); _ = cast.receive(status([player]))
        XCTAssertTrue(cast.pause().isEmpty, "no media session yet")
        let (_, events) = cast.receive(CastMessage(source: "t-1", destination: "sender-purio", namespace: CastNamespace.media, json: [
            "type": "MEDIA_STATUS", "status": [["mediaSessionId": 7, "playerState": "PLAYING", "currentTime": 3.5, "media": ["duration": 72.0]]]]))
        XCTAssertEqual(events, [.media(CastMediaStatus(playerState: "PLAYING", currentTime: 3.5, duration: 72, idleReason: nil))])
        let pause = cast.pause()
        XCTAssertEqual(pause.first?.json["mediaSessionId"] as? Int, 7)
        XCTAssertEqual(cast.seek(to: -4).first?.json["currentTime"] as? Double, 0)
    }

    func testPlayerClosedOnTheTVIsReportedAndTheNextLoadRelaunches() {
        var cast = CastController()
        _ = cast.load(photo); _ = cast.receive(status([player]))
        XCTAssertEqual(cast.receive(status([])).events, [.receiverGone], "Home pressed on the TV")
        XCTAssertEqual(cast.state, .idle)
        XCTAssertEqual(cast.load(photo).map(\.type), ["CONNECT", "LAUNCH"])
    }

    func testLoadFailureIsReported() {
        var cast = CastController()
        _ = cast.load(photo); _ = cast.receive(status([player]))
        XCTAssertEqual(cast.receive(CastMessage(source: "t-1", destination: "sender-purio", namespace: CastNamespace.media, json: ["type": "LOAD_FAILED"])).events, [.loadFailed])
    }

    func testFailureOfAReplacedLoadIsIgnored() {
        var cast = CastController()
        _ = cast.load(photo); _ = cast.receive(status([player]))
        let first = cast.load(CastController.Load(url: "http://x/long.m3u8", contentType: "application/x-mpegURL", title: "long", hls: true))
        let second = cast.load(photo)
        XCTAssertEqual((first[0].json["media"] as? [String: Any])?["hlsSegmentFormat"] as? String, "fmp4")
        let failed = { (id: Any) in CastMessage(source: "t-1", destination: "sender-purio", namespace: CastNamespace.media, json: ["type": "LOAD_FAILED", "requestId": id]) }
        XCTAssertEqual(cast.receive(failed(first[0].json["requestId"]!)).events, [], "the TV dropping the first load for the second")
        XCTAssertEqual(cast.receive(failed(second[0].json["requestId"]!)).events, [.loadFailed])
        XCTAssertEqual(cast.status().map(\.type), ["GET_STATUS"])
    }

    func testStopClosesThePlayer() {
        var cast = CastController()
        XCTAssertTrue(cast.stop().isEmpty, "nothing to stop before a session")
        _ = cast.load(photo); _ = cast.receive(status([player]))
        let out = cast.stop()
        XCTAssertEqual(out.map(\.type), ["STOP", "CLOSE"])
        XCTAssertEqual(out[0].json["sessionId"] as? String, "s-1")
        XCTAssertEqual(cast.state, .stopped)
    }

    func testConnectionFailuresAreExplained() {
        XCTAssertTrue(CastSession.reason(for: .posix(.ECONNREFUSED)).contains("Chromecast built in"), "nothing listens on 8009")
        XCTAssertTrue(CastSession.reason(for: .posix(.ETIMEDOUT)).contains("Couldn't reach the TV"))
        XCTAssertTrue(CastSession.reason(for: .posix(.EHOSTUNREACH)).contains("Couldn't reach the TV"))
    }

    // MARK: following the swipes (CST-03)

    func testFastSwipesSendOnlyThePhotoYouStopOn() {
        var follow = CastFollower(settle: 0.35)
        let t0 = Date()
        for i in 0..<20 { follow.focused("photo-\(i)", now: t0.addingTimeInterval(Double(i) * 0.1)) }
        XCTAssertNil(follow.due(now: t0.addingTimeInterval(2.0)), "0.2 s after the last swipe: not settled")
        XCTAssertEqual(follow.due(now: t0.addingTimeInterval(2.25)), "photo-19")
        XCTAssertNil(follow.due(now: t0.addingTimeInterval(3)), "never twice")
        follow.forget()
        XCTAssertEqual(follow.due(now: t0.addingTimeInterval(3)), "photo-19", "sent again after the TV dropped it")
    }

    // MARK: HTTP

    func testByteRanges() {
        XCTAssertEqual(ByteRange.resolve(nil, size: 1000), ByteRange(start: 0, end: 999))
        XCTAssertEqual(ByteRange.resolve("bytes=0-", size: 1000), ByteRange(start: 0, end: 999))
        XCTAssertEqual(ByteRange.resolve("bytes=100-199", size: 1000), ByteRange(start: 100, end: 199))
        XCTAssertEqual(ByteRange.resolve("bytes=900-5000", size: 1000), ByteRange(start: 900, end: 999))
        XCTAssertEqual(ByteRange.resolve("bytes=-100", size: 1000), ByteRange(start: 900, end: 999))
        XCTAssertNil(ByteRange.resolve("bytes=1000-", size: 1000))
        XCTAssertNil(ByteRange.resolve("bytes=5-2", size: 1000))
        XCTAssertNil(ByteRange.resolve("bytes=0-1,5-6", size: 1000))
        XCTAssertNil(ByteRange.resolve("items=0-1", size: 1000))
    }

    func testRequestHead() {
        XCTAssertNil(HTTPRequestHead.parse(Data("GET /a HTTP/1.1\r\nHost: x".utf8)))
        let head = HTTPRequestHead.parse(Data("GET /abc/IMG_1.jpg HTTP/1.1\r\nHost: 192.168.0.14\r\nRange: bytes=0-\r\n\r\n".utf8))
        XCTAssertEqual(head?.method, "GET")
        XCTAssertEqual(head?.path, "/abc/IMG_1.jpg")
        XCTAssertEqual(head?.headers["range"], "bytes=0-")
    }

    func testServerServesOnlySharedFilesWithRanges() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cast-test-\(UUID().uuidString).bin")
        try Data((0..<200_000).map { UInt8($0 % 251) }).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = MediaServer()
        let port = try await server.start()
        defer { server.stop() }
        let path = server.share(file, contentType: "video/mp4")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.setValue("bytes=100000-100009", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 100000-100009/200000")
        XCTAssertEqual(Array(data), (100000..<100010).map { UInt8($0 % 251) })
        let (whole, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        XCTAssertEqual(whole.count, 200_000)
        let (_, missing) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/nothing/here.jpg")!)
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
        // Sharing more items than it keeps unshares the oldest.
        for _ in 0..<3 { _ = server.share(file, contentType: "video/mp4") }
        let (_, gone) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        XCTAssertEqual((gone as? HTTPURLResponse)?.statusCode, 404)
    }

    func testLocalAddressPrefersTheTVsSubnet() {
        let interfaces = [LocalAddress.Interface(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0"),
                          LocalAddress.Interface(name: "pdp_ip0", address: "10.20.30.40", netmask: "255.255.255.255"),
                          LocalAddress.Interface(name: "en0", address: "192.168.0.14", netmask: "255.255.255.0")]
        XCTAssertEqual(LocalAddress.pick(for: "192.168.0.13", from: interfaces), "192.168.0.14")
        XCTAssertEqual(LocalAddress.pick(for: "tv.local", from: interfaces), "192.168.0.14", "a name falls back to Wi-Fi")
        XCTAssertNil(LocalAddress.pick(for: "192.168.0.13", from: Array(interfaces.prefix(2))))
    }

    // MARK: photos (CST-02)

    func testPhotoBecomesAnUprightJPEGAtMost4KWithoutLocation() throws {
        // A 6000 x 4000 photo stored sideways (EXIF orientation 6) with a GPS position.
        let context = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 6000, height: 4000))
        let original = NSMutableData()
        let destination = CGImageDestinationCreateWithData(original, UTType.heic.identifier as CFString, 1, nil)
            ?? CGImageDestinationCreateWithData(original, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.15, kCGImagePropertyGPSLongitude: 8.61]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let jpeg = try PhotoPrep.jpeg(from: original as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2560, "turned upright")
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 3840, "long side at most 3840")
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "no location reaches the TV")
        XCTAssertLessThan(jpeg.count, 3_000_000)
        let forTV = try PhotoPrep.jpeg(from: original as Data, maxPixel: PhotoPrep.tvPixel)
        let tvProperties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(forTV as CFData, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(tvProperties?[kCGImagePropertyPixelHeight] as? Int, 1920, "the app sends at most 1920 px")
    }

    func testUnreadablePhotoFailsClearly() {
        XCTAssertThrowsError(try PhotoPrep.jpeg(from: Data("not a photo".utf8)))
    }

    // MARK: live (CAST_TEST_HOST=<TV address> swift test --filter CastTests/testLive)

    func testLiveShowsAPhotoOnTheTVAndStops() async throws {
        guard let host = ProcessInfo.processInfo.environment["CAST_TEST_HOST"] else { throw XCTSkip("Set CAST_TEST_HOST to a Cast TV") }
        let address = try XCTUnwrap(LocalAddress.current(for: host), "no address on the TV's network")
        let context = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.06, green: 0.11, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        context.setFillColor(CGColor(red: 0.6, green: 0.89, blue: 0.93, alpha: 1)); context.fill(CGRect(x: 760, y: 340, width: 400, height: 400))
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("purio-live-\(UUID().uuidString).jpg")
        try PhotoPrep.jpeg(from: png as Data).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let server = MediaServer()
        let port = try await server.start()
        defer { server.stop() }
        let path = server.share(file, contentType: "image/jpeg")
        let session = CastSession(host: host)
        let shown = expectation(description: "photo shown")
        var events: [CastController.Event] = []
        session.event = { event in
            events.append(event)
            if case .media(let status) = event, status.playerState == "PAUSED" || status.playerState == "PLAYING" { shown.fulfill() }
        }
        session.load(.init(url: "http://\(address):\(port)\(path)", contentType: "image/jpeg", title: "Purio live test"))
        await fulfillment(of: [shown], timeout: 40)
        XCTAssertTrue(events.contains(.ready))
        try await Task.sleep(for: .seconds(3))
        session.stop()
        try await Task.sleep(for: .seconds(2))
    }
}
