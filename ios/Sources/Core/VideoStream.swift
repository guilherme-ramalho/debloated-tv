import Foundation
import AVFoundation
import UniformTypeIdentifiers

// Heavy videos for the TV, converted on the phone while they play. The TV's Cast player plays 1080p smoothly but
// stutters at 4K 30 fps (25 Mbit/s) and fails at 4K 60 fps above its decoder's 80 Mbit/s (TCL, 15 Nov 2026), while
// iPhones record 4K 60 fps HDR at 55-90 Mbit/s. So those videos become an HLS stream of 6-second fMP4 H.264
// segments at 1080p SDR, made just ahead of where the TV is playing (docs/cast.md).

public enum VideoPlan {
    public struct Source: Equatable {
        public var width: Int, height: Int, fps: Double, bitsPerSecond: Double
        public init(width: Int, height: Int, fps: Double, bitsPerSecond: Double) {
            self.width = width; self.height = height; self.fps = fps; self.bitsPerSecond = bitsPerSecond
        }
    }
    public static let segmentSeconds = 6.0
    /// Larger than 1080p, heavier than 20 Mbit/s (the TV's Cast player can't keep up), or portrait (the player
    /// stretched a portrait video to fill the screen, 1.3 test): converted, into a 16:9 frame.
    public static func needsConversion(_ source: Source) -> Bool {
        source.height > source.width || source.width > 1920 || source.height > 1080 || source.bitsPerSecond > 20_000_000
    }
    /// The frame sent to the TV: always 16:9, 1920 x 1080 at most, never larger than the picture needs.
    public static func outputSize(width: Double, height: Double) -> CGSize {
        let scale = min(1, 1920 / width, 1080 / height)
        let frameHeight = max(height * scale, width * scale * 9 / 16)
        func even(_ value: Double) -> Double { max(2, (value / 2).rounded() * 2) }
        return CGSize(width: even(frameHeight * 16 / 9), height: even(frameHeight))
    }
    /// Where the upright picture sits in that frame: as large as fits, centred (black bars at the sides for
    /// portrait, as the TV would show it anyway).
    public static func pictureRect(width: Double, height: Double, in frame: CGSize) -> CGRect {
        let scale = min(frame.width / width, frame.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2, width: size.width, height: size.height)
    }
    /// 60 fps sources keep 60; everything else plays at 30.
    public static func outputFrameRate(_ fps: Double) -> Int32 { fps > 40 ? 60 : 30 }
    /// Whole 6-second segments, the last one shorter; a tail under 0.05 s joins the segment before.
    public static func segmentCount(duration: Double) -> Int { max(1, Int(((duration - 0.05) / segmentSeconds).rounded(.up))) }
    /// A complete (VOD) playlist written before any segment exists, so the TV knows the length and can seek; the
    /// segments are made on demand with exact 6-second boundaries.
    public static func playlist(duration: Double) -> String {
        let count = segmentCount(duration: duration)
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(segmentSeconds))\n#EXT-X-MEDIA-SEQUENCE:0\n"
        text += "#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for index in 0..<count {
            let length = index == count - 1 ? duration - Double(index) * segmentSeconds : segmentSeconds
            text += "#EXTINF:\(String(format: "%.3f", length)),\ns\(index).m4s\n"
        }
        return text + "#EXT-X-ENDLIST\n"
    }
    public static func segmentIndex(_ name: String) -> Int? {
        guard name.hasPrefix("s"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst().dropLast(4))
    }
}

/// One video being converted for the TV. Files go to `folder` (index.m3u8, init.mp4, s<n>.m4s); MediaServer serves
/// them and tells `requested(_:)` what the TV asked for. Converts at most `ahead` segments past the TV's position,
/// restarts at a segment the TV jumps to, and deletes segments well behind it. stop() ends it.
public final class VideoStream: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    public let folder: URL
    public let duration: Double
    public let outputSize: CGSize
    public let frameRate: Int32
    public var log: ((String) -> Void)?
    public static let ahead = 8

    private let asset: AVAsset
    private let videoTrack: AVAssetTrack
    private let audioTrack: AVAssetTrack?
    private let transform: CGAffineTransform
    private let naturalSize: CGSize
    private let lock = NSLock()
    private let pump = DispatchQueue(label: "tvremote.video-stream", qos: .userInitiated)
    private var run: Run?
    private var watched = 0
    private var stopped = false
    private let segmentCount: Int

    private final class Run {
        let start: Int
        var next: Int
        var cancelled = false
        var finished = false
        let began = Date()
        var reader: AVAssetReader?
        var writer: AVAssetWriter?
        init(start: Int) { self.start = start; next = start }
    }

    public init(asset: AVAsset, folder: URL) async throws {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw RemoteFailure.message(String(localized: "This video couldn't be read."))
        }
        let audios = try await asset.loadTracks(withMediaType: .audio)
        var audio: AVAssetTrack?
        for track in audios {      // the stereo AAC track, not a spatial-audio one, when there are several
            let formats = try await track.load(.formatDescriptions)
            if formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) { audio = track; break }
        }
        let (size, transform, fps) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let seconds = try await asset.load(.duration).seconds
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        self.asset = asset; videoTrack = video; audioTrack = audio ?? audios.first
        self.transform = transform; naturalSize = size
        self.folder = folder
        duration = seconds
        outputSize = VideoPlan.outputSize(width: abs(shown.width), height: abs(shown.height))
        frameRate = VideoPlan.outputFrameRate(Double(fps))
        segmentCount = VideoPlan.segmentCount(duration: seconds)
        super.init()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(VideoPlan.playlist(duration: seconds).utf8).write(to: folder.appendingPathComponent("index.m3u8"))
        try begin(at: 0)
    }

    /// The TV asked for a file: keep converting just ahead of it, or restart where it jumped to.
    public func requested(_ name: String) {
        guard let index = VideoPlan.segmentIndex(name) else { return }
        lock.lock()
        watched = index
        let current = run
        let have = FileManager.default.fileExists(atPath: segmentURL(index).path)
        let restart = !have && !stopped && (current == nil || current!.finished || index < current!.start || index > current!.next + 1)
        lock.unlock()
        cleanUp(behind: index)
        if restart { log?("TV jumped to segment \(index): converting from \(Int(Double(index) * VideoPlan.segmentSeconds)) s"); try? begin(at: index) }
    }

    public func stop() {
        lock.lock(); stopped = true; let current = run; run = nil; lock.unlock()
        if let current { cancel(current) }
    }

    private func segmentURL(_ index: Int) -> URL { folder.appendingPathComponent("s\(index).m4s") }

    private func begin(at index: Int) throws {
        lock.lock()
        if let old = run { lock.unlock(); cancel(old); lock.lock() }
        let run = Run(start: index)
        self.run = run
        lock.unlock()

        let start = CMTime(seconds: Double(index) * VideoPlan.segmentSeconds, preferredTimescale: 600)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: start, end: CMTime(seconds: duration, preferredTimescale: 600))
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.videoComposition = composition()
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if let audioTrack {
            let output = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            if reader.canAdd(output) { reader.add(output); audioOutput = output }
        }

        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: VideoPlan.segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = start
        writer.delegate = self
        let framesPerSegment = Int(frameRate) * Int(VideoPlan.segmentSeconds)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputSize.width, AVVideoHeightKey: outputSize.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: frameRate > 30 ? 10_000_000 : 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: framesPerSegment,
                AVVideoMaxKeyFrameIntervalDurationKey: VideoPlan.segmentSeconds,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: frameRate]])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? RemoteFailure.message(String(localized: "This video couldn't be read."))
        }
        writer.startSession(atSourceTime: start)
        run.reader = reader; run.writer = writer

        var open = audioInput == nil ? 1 : 2
        let finishOne = { [weak self] in
            open -= 1
            guard open == 0 else { return }
            if run.cancelled { writer.cancelWriting(); return }
            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.lock.lock(); run.finished = true; self.lock.unlock()
                self.log?(writer.status == .completed
                    ? "conversion finished: segments \(run.start)-\(run.next - 1) in \(Int(Date().timeIntervalSince(run.began))) s"
                    : "conversion failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
        }
        // Both inputs pull on one serial queue, so a cancel (also on it) never races an append.
        videoInput.requestMediaDataWhenReady(on: pump) { [weak self] in
            while videoInput.isReadyForMoreMediaData {
                guard let self, !run.cancelled, self.waitIfAhead(run) else { videoInput.markAsFinished(); finishOne(); return }
                guard let buffer = videoOutput.copyNextSampleBuffer() else { videoInput.markAsFinished(); finishOne(); return }
                if !videoInput.append(buffer) { videoInput.markAsFinished(); finishOne(); return }
            }
        }
        if let audioInput, let audioOutput {
            audioInput.requestMediaDataWhenReady(on: pump) { [weak self] in
                while audioInput.isReadyForMoreMediaData {
                    guard let self, !run.cancelled, self.waitIfAhead(run) else { audioInput.markAsFinished(); finishOne(); return }
                    guard let buffer = audioOutput.copyNextSampleBuffer() else { audioInput.markAsFinished(); finishOne(); return }
                    if !audioInput.append(buffer) { audioInput.markAsFinished(); finishOne(); return }
                }
            }
        }
        log?("converting from segment \(index) to \(Int(outputSize.width))x\(Int(outputSize.height)) \(frameRate) fps H.264")
    }

    /// Holds the conversion while it's more than `ahead` segments past what the TV asked for. false = stop.
    private func waitIfAhead(_ run: Run) -> Bool {
        while true {
            lock.lock(); let far = run.next > watched + Self.ahead; let gone = run.cancelled || stopped; lock.unlock()
            if gone { return false }
            if !far { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func cancel(_ run: Run) {
        lock.lock(); run.cancelled = true; lock.unlock()
        pump.async { run.reader?.cancelReading(); if run.writer?.status == .writing { run.writer?.cancelWriting() } }
    }

    /// Segments more than three behind the TV are deleted; jumping back converts them again.
    private func cleanUp(behind index: Int) {
        guard index > 3 else { return }
        for old in max(0, index - 30)..<(index - 3) { try? FileManager.default.removeItem(at: segmentURL(old)) }
    }

    /// Upright, fitted and centred in the 16:9 frame, in SDR (Rec. 709): AVFoundation tone-maps HDR (HLG, Dolby
    /// Vision) here.
    private func composition() -> AVVideoComposition {
        let shown = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let picture = VideoPlan.pictureRect(width: abs(shown.width), height: abs(shown.height), in: outputSize)
        let scale = picture.width / abs(shown.width)
        let placed = transform.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: picture.minX, y: picture.minY))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(placed, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration + 1, preferredTimescale: 600))
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = outputSize
        composition.frameDuration = CMTime(value: 1, timescale: frameRate)
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }

    // MARK: AVAssetWriterDelegate

    public func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock()
        guard let run, run.writer === writer, !run.cancelled else { lock.unlock(); return }
        let file: URL
        var index = -1
        switch segmentType {
        case .initialization: file = folder.appendingPathComponent("init.mp4")
        default: index = run.next; file = segmentURL(index); run.next += 1
        }
        lock.unlock()
        if index >= segmentCount { return }
        if !FileManager.default.fileExists(atPath: file.path) {
            let part = file.appendingPathExtension("part")
            if (try? segmentData.write(to: part)) != nil { try? FileManager.default.moveItem(at: part, to: file) }
        }
        if index >= 0 && (index == run.start || index % 5 == 0) {
            let length = segmentReport?.trackReports.first(where: { $0.mediaType == .video })?.duration.seconds ?? 0
            log?("segment \(index) ready (\(segmentData.count / 1024) KB, \(String(format: "%.2f", length)) s) after \(String(format: "%.1f", Date().timeIntervalSince(run.began))) s")
        }
    }
}
