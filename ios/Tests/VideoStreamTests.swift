import XCTest
import AVFoundation
@testable import TVRemoteCore

final class VideoStreamTests: XCTestCase {
    func testWhichVideosAreConverted() {
        XCTAssertTrue(VideoPlan.needsConversion(.init(width: 3840, height: 2160, fps: 60, bitsPerSecond: 85_000_000)), "iPhone 4K 60 fps HDR")
        XCTAssertTrue(VideoPlan.needsConversion(.init(width: 3840, height: 2160, fps: 30, bitsPerSecond: 25_000_000)), "4K 30 stutters on the TV")
        XCTAssertTrue(VideoPlan.needsConversion(.init(width: 2160, height: 3840, fps: 30, bitsPerSecond: 18_000_000)), "portrait 4K")
        XCTAssertTrue(VideoPlan.needsConversion(.init(width: 1920, height: 1080, fps: 60, bitsPerSecond: 35_000_000)), "1080p but very heavy")
        XCTAssertFalse(VideoPlan.needsConversion(.init(width: 1920, height: 1080, fps: 30, bitsPerSecond: 16_000_000)), "iPhone 1080p plays as is")
        XCTAssertFalse(VideoPlan.needsConversion(.init(width: 1080, height: 1920, fps: 30, bitsPerSecond: 10_000_000)), "portrait 1080p plays as is")
    }

    func testOutputSizeKeepsTheShapeInside1080p() {
        XCTAssertEqual(VideoPlan.outputSize(width: 3840, height: 2160), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(VideoPlan.outputSize(width: 2160, height: 3840), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(VideoPlan.outputSize(width: 4032, height: 3024), CGSize(width: 1440, height: 1080))
        XCTAssertEqual(VideoPlan.outputSize(width: 1280, height: 720), CGSize(width: 1280, height: 720), "never enlarged")
        XCTAssertEqual(VideoPlan.outputFrameRate(59.94), 60)
        XCTAssertEqual(VideoPlan.outputFrameRate(29.97), 30)
        XCTAssertEqual(VideoPlan.outputFrameRate(24), 30)
    }

    func testPlaylistListsEverySegmentWithItsLength() {
        XCTAssertEqual(VideoPlan.segmentCount(duration: 13), 3)
        XCTAssertEqual(VideoPlan.segmentCount(duration: 12.02), 2, "a sliver joins the segment before")
        XCTAssertEqual(VideoPlan.segmentCount(duration: 3), 1)
        let playlist = VideoPlan.playlist(duration: 13)
        XCTAssertTrue(playlist.hasPrefix("#EXTM3U\n"))
        XCTAssertTrue(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(playlist.contains("#EXTINF:6.000,\ns0.m4s\n#EXTINF:6.000,\ns1.m4s\n#EXTINF:1.000,\ns2.m4s\n#EXT-X-ENDLIST"))
        XCTAssertEqual(VideoPlan.segmentIndex("s12.m4s"), 12)
        XCTAssertNil(VideoPlan.segmentIndex("init.mp4"))
    }

    /// A 13 s 4K video becomes init.mp4 and three H.264 1080p segments of 6, 6 and 1 s that play.
    func testConvertsA4KVideoInto1080pSegments() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stream-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("source.mov")
        try await Self.makeVideo(at: source, width: 3840, height: 2160, seconds: 13, fps: 30)

        let stream = try await VideoStream(asset: AVURLAsset(url: source), folder: folder.appendingPathComponent("out"))
        defer { stream.stop() }
        XCTAssertEqual(stream.outputSize, CGSize(width: 1920, height: 1080))
        let out = stream.folder
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("index.m3u8").path))
        for index in 0..<3 {
            stream.requested("s\(index).m4s")
            try await Self.waitFor(out.appendingPathComponent("s\(index).m4s"), seconds: 60)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("s3.m4s").path), "nothing past the end")
        let initData = try Data(contentsOf: out.appendingPathComponent("init.mp4"))
        for (index, expected) in [6.0, 6.0, 1.0].enumerated() {
            let joined = folder.appendingPathComponent("check\(index).mp4")
            try (initData + Data(contentsOf: out.appendingPathComponent("s\(index).m4s"))).write(to: joined)
            let asset = AVURLAsset(url: joined)
            let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
            let (size, formats) = try await track.load(.naturalSize, .formatDescriptions)
            XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
            XCTAssertEqual(formats.first.map { CMFormatDescriptionGetMediaSubType($0) }, kCMVideoCodecType_H264)
            let length = try await asset.load(.duration).seconds
            XCTAssertEqual(length, expected, accuracy: 0.15, "segment \(index) is \(length) s")
        }
    }

    /// A segment the TV jumps to is converted from there, without the ones before it.
    func testJumpAheadConvertsFromThere() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stream-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("source.mov")
        try await Self.makeVideo(at: source, width: 1920, height: 1080, seconds: 40, fps: 30)
        let stream = try await VideoStream(asset: AVURLAsset(url: source), folder: folder.appendingPathComponent("out"))
        defer { stream.stop() }
        stream.requested("s0.m4s")
        try await Self.waitFor(stream.folder.appendingPathComponent("s0.m4s"), seconds: 60)
        stream.requested("s5.m4s")      // 30 s in
        try await Self.waitFor(stream.folder.appendingPathComponent("s5.m4s"), seconds: 60)
        let joined = folder.appendingPathComponent("jump.mp4")
        try (Data(contentsOf: stream.folder.appendingPathComponent("init.mp4")) + Data(contentsOf: stream.folder.appendingPathComponent("s5.m4s"))).write(to: joined)
        let length = try await AVURLAsset(url: joined).load(.duration).seconds
        XCTAssertEqual(length, 6, accuracy: 0.15)
    }

    // MARK: helpers

    static func waitFor(_ file: URL, seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !FileManager.default.fileExists(atPath: file.path) {
            guard Date() < deadline else { throw RemoteFailure.message("\(file.lastPathComponent) never appeared") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A moving test picture with a tone, written with AVAssetWriter.
    static func makeVideo(at url: URL, width: Int, height: Int, seconds: Int, fps: Int32) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            memset(base, Int32(frame * 7 % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}
