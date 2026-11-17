import SwiftUI
import Photos
import AVFoundation
import os

// Show on TV (1.3): the photo library, browsed like Photos; whatever is open full screen also appears on the TV
// through its built-in Cast player (Core: Cast.swift, MediaServer.swift). Nothing runs until the library opens,
// and leaving it closes the TV's player, the local server and the prepared files.

/// The TV side of the library: one Cast session, the server for the item on the TV, and the photo or video that
/// follows the phone. Lives only while the library is open.
@MainActor final class ShowOnTVModel: ObservableObject {
    enum TV: Equatable {
        case off
        case opening
        case on
        /// Sending paused by the person (the pill), so they can browse without the TV following.
        case paused
        case failed(String)
    }
    @Published private(set) var tv: TV = .off
    @Published private(set) var media: CastMediaStatus?
    /// When `media` arrived: the player reports only on changes, so the phone moves the position on itself.
    private(set) var mediaAt = Date()
    private var refreshTask: Task<Void, Never>?
    /// The asset currently on the TV.
    @Published private(set) var shownID: String?
    /// A video that played to the end: the TV shows its cover frame and the phone offers Play again.
    @Published private(set) var endedID: String?
    private var shownAsset: PHAsset?
    @Published private(set) var downloading: Double?
    @Published var problem: String?
    /// The TV refused a connection on the Cast port when Show on TV opened: it has no Chromecast built in (or it's
    /// turned off). Said at once, above the library, instead of after a photo is picked.
    @Published private(set) var noCast = false
    @Published private(set) var checkingCast = false
    /// The problem is about this item (offer the next one), not about the TV.
    @Published private(set) var problemIsItem = false
    let host: String
    let tvName: String
    private var session: CastSession?
    private let server = MediaServer()
    private var follower = CastFollower()
    private var focusedAsset: PHAsset?
    private var settleTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    /// The video being converted for the TV, if the one showing needed it.
    private var stream: VideoStream?
    private var shownIsVideo = false
    private var openedAt: Date?
    private var loadedAt: Date?
    /// The item on the TV has started (shown, playing or finished): a LOAD_FAILED after that is stale. The TV's
    /// player sends one when a video ends, which showed "couldn't play" for videos that played (1.3 test, 15 Nov).
    private var itemStarted = false
    /// Photos prepared for the TV, by asset: the one showing and its neighbours, so a swipe sends a ready file.
    private var prepared: [String: URL] = [:]
    private var neighbours: [PHAsset] = []
    private var prefetchTask: Task<Void, Never>?
    nonisolated private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShowOnTV", isDirectory: true)

    init(host: String, tvName: String) {
        self.host = host; self.tvName = tvName
        server.requestLog = { method, shared, range in ShowOnTVLog.note("TV fetched (\(method)\(shared ? "" : ", unknown path → 404")\(range.map { ", \($0)" } ?? ""))") }
        Self.clearFiles()      // left over if the app was closed while showing
        ShowOnTVLog.note("library opened (TV \(host))")
        Task { await checkCast() }
    }

    /// One connection to the TV's Cast port, closed at once. Only a refusal counts: a TV in standby or out of reach
    /// stays possible, and sending explains it then.
    func checkCast() async {
        checkingCast = true
        let answer = await PortKnock.answer(host: host, port: TVPorts.cast, timeout: 2)
        checkingCast = false
        ShowOnTVLog.note("Cast port \(answer)")
        noCast = answer == .refused
        if noCast { tv = .failed(CastSession.noCastMessage) }
        else if case .failed = tv { tv = .off; follower.forget(); sendIfDue() }
    }

    /// The viewer settled on an asset: it goes to the TV once it has stayed in front for a moment (CST-03). The
    /// photos either side are prepared once it's showing.
    func focus(_ asset: PHAsset, neighbours: [PHAsset] = []) {
        focusedAsset = asset
        self.neighbours = neighbours
        follower.focused(asset.localIdentifier)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.36))
            guard !Task.isCancelled else { return }
            self?.sendIfDue()
        }
    }
    func toggleSending() {
        ShowOnTVLog.note("pill tapped while \(tv)")
        switch tv {
        case .paused, .failed:
            tv = shownID == nil ? .off : .on
            follower.forget()
            sendIfDue()
        default: tv = .paused
        }
    }
    func play() { session?.play() }
    func pause() { session?.pause() }
    func seek(to seconds: Double) {
        let target = max(0, min(seconds, media?.duration ?? seconds))
        session?.seek(to: target)
        if var status = media { status.currentTime = target; media = status; mediaAt = Date() }   // no jump back while the TV catches up
    }
    func skip(_ seconds: Double) { seek(to: position(at: Date()) + seconds) }
    /// Where the TV is now: its last report, moved on by the time since while playing.
    func position(at date: Date) -> Double {
        guard let media else { return 0 }
        let moved = media.playerState == "PLAYING" ? date.timeIntervalSince(mediaAt) : 0
        return min(media.currentTime + moved, media.duration ?? .infinity)
    }

    /// Closes the TV's player (it returns to Home) but keeps the library open.
    func stopOnTV() {
        ShowOnTVLog.note("stop on TV")
        sendTask?.cancel()
        session?.stop(); session = nil
        stopStream()
        follower.forget(); shownID = nil; media = nil; downloading = nil
        tv = .paused
        keepAwake(false)
    }
    /// Leaving the library: everything goes.
    func close() {
        ShowOnTVLog.note("library closed")
        settleTask?.cancel(); sendTask?.cancel(); prefetchTask?.cancel()
        session?.stop(); session = nil
        server.stop()
        keepAwake(false)
        stream?.stop(); stream = nil
        Self.clearFiles(); prepared = [:]
        AssetImages.stopPrefetching()
    }

    private func sendIfDue() {
        guard tv != .paused, tvFailure == nil, let asset = focusedAsset, follower.due() == asset.localIdentifier else { return }
        sendTask?.cancel()
        sendTask = Task { [weak self] in await self?.send(asset) }
    }
    private var tvFailure: String? { if case .failed(let reason) = tv { return reason }; return nil }

    private func send(_ asset: PHAsset) async {
        if session == nil { tv = .opening; openedAt = Date() }
        let kind = asset.mediaType == .video ? "video \(Int(asset.duration)) s" : "photo \(asset.pixelWidth)x\(asset.pixelHeight)"
        ShowOnTVLog.note("send \(kind)\(session == nil ? " (player not open yet)" : "")")
        do {
            guard let address = LocalAddress.current(for: host) else {
                throw RemoteFailure.message(String(localized: "This iPhone isn't on the TV's Wi-Fi network."))
            }
            let port = try await server.start()
            let choice: (path: String, contentType: String, hls: Bool)
            if asset.mediaType == .video { choice = try await video(asset) }
            else { let (file, type) = try await photoFile(asset); choice = (server.share(file, contentType: type), type, false) }
            guard !Task.isCancelled else { return }
            if asset.mediaType != .video { stopStream() }
            let contentType = choice.contentType
            let session = self.session ?? makeSession()
            shownID = asset.localIdentifier
            shownAsset = asset
            endedID = nil
            shownIsVideo = asset.mediaType == .video
            media = nil; itemStarted = false
            loadedAt = Date()
            ShowOnTVLog.note("load \(contentType) from \(address):\(port)")
            session.load(.init(url: "http://\(address):\(port)\(choice.path)", contentType: contentType,
                               title: asset.creationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Purio TV", hls: choice.hls))
            prefetch(around: asset)
        } catch is CancellationError {
            ShowOnTVLog.note("send cancelled (swiped on)")
        } catch {
            ShowOnTVLog.note("send failed: \(error.localizedDescription)")
            downloading = nil
            follower.forget()
            if tv == .opening { tv = shownID == nil ? .off : .on }
            problemIsItem = true
            problem = error.localizedDescription
        }
    }
    private func makeSession() -> CastSession {
        let session = CastSession(host: host)
        session.event = { [weak self] event in self?.handle(event) }
        self.session = session
        return session
    }
    private func handle(_ event: CastController.Event) {
        switch event {
        case .ready:
            ShowOnTVLog.note("TV player ready after \(openedAt.map { ShowOnTVLog.ms(since: $0) } ?? -1) ms")
            if tv == .opening { tv = .on }
        case .media(let status):
            if tv == .opening { tv = .on }
            if status.playerState != media?.playerState || status.idleReason != media?.idleReason {
                ShowOnTVLog.note("TV \(status.playerState)\(status.idleReason.map { " (\($0))" } ?? "") at \(Int(status.currentTime)) s, \(loadedAt.map { ShowOnTVLog.ms(since: $0) } ?? -1) ms after load")
            }
            media = status; mediaAt = Date()
            if status.playerState != "IDLE" || status.idleReason == "FINISHED" { itemStarted = true }
            if shownIsVideo && status.playing { startRefreshing() }
            if shownIsVideo && status.idleReason == "FINISHED", let asset = shownAsset, endedID != asset.localIdentifier { videoEnded(asset) }
            keepAwake(shownIsVideo && status.playing)
            if status.idleReason == "ERROR" { reportLoadFailure() }
        case .loadFailed:
            guard !itemStarted else { ShowOnTVLog.note("ignored a stale LOAD_FAILED (the item had already started)"); return }
            ShowOnTVLog.note("TV refused the item (LOAD_FAILED)")
            reportLoadFailure()
        case .receiverGone:
            ShowOnTVLog.note("TV player gone (Home, another app, or connection closed)")
            // Home pressed on the TV, another app, or the connection dropped: the next photo opens the player again.
            session = nil; shownID = nil; media = nil; follower.forget()
            if tv != .paused { tv = .off }
            keepAwake(false)
        case .failed(let reason):
            ShowOnTVLog.note("TV session failed: \(reason)")
            let wasOn = tv == .on
            session = nil; shownID = nil; media = nil; follower.forget()
            keepAwake(false)
            if wasOn { tv = .off; sendIfDue(); return }   // dropped while asleep or away: reconnect once, quietly
            tv = .failed(reason)
            problemIsItem = false
            problem = reason
        }
    }
    private func reportLoadFailure() {
        problemIsItem = true
        problem = shownIsVideo
            ? String(localized: "The TV couldn't play this video. It may use a format the TV's player doesn't support (often HDR or Dolby Vision from recent iPhones). Photos and other videos still work.")
            : String(localized: "The TV couldn't show this photo.")
        shownID = nil
    }
    private func keepAwake(_ on: Bool) { UIApplication.shared.isIdleTimerDisabled = on }

    /// The video played to the end: rather than leave the TV black, show its cover frame there, and let the phone
    /// play it again (the TV's player can't restart a finished item).
    private func videoEnded(_ asset: PHAsset) {
        ShowOnTVLog.note("video finished: showing its cover frame on the TV")
        endedID = asset.localIdentifier
        shownIsVideo = false; media = nil; keepAwake(false)
        stopStream()
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            guard let self, let image = await AssetImages.image(asset, side: CGFloat(PhotoPrep.tvPixel), fill: false),
                  let jpeg = image.jpegData(compressionQuality: 0.85), let address = LocalAddress.current(for: self.host),
                  let port = self.server.port, let session = self.session, !Task.isCancelled else { return }
            let file = Self.folder.appendingPathComponent("cover-\(UUID().uuidString).jpg")
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            guard (try? jpeg.write(to: file)) != nil else { return }
            let path = self.server.share(file, contentType: "image/jpeg")
            self.itemStarted = false
            session.load(.init(url: "http://\(address):\(port)\(path)", contentType: "image/jpeg", title: ""))
        }
    }
    /// Plays the finished video again from the start.
    func playAgain() {
        guard let asset = shownAsset, endedID == asset.localIdentifier else { return }
        ShowOnTVLog.note("play again")
        endedID = nil
        follower.forget()
        sendTask?.cancel()
        sendTask = Task { [weak self] in await self?.send(asset) }
    }
    /// While a video plays, asks the TV where it is every 5 seconds so the phone's position doesn't drift.
    private func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.shownIsVideo, self.media?.playing == true else { break }
                self.session?.refresh()
            }
            self?.refreshTask = nil
        }
    }

    // MARK: media for the TV

    /// The photo as a JPEG for the TV (it refuses HEIC), at most 1920 px: the TV's apps draw at 1920 x 1080, so
    /// more only makes the TV fetch and decode longer. Prepared off the main thread, kept while it's a neighbour.
    private func photoFile(_ asset: PHAsset, ahead: Bool = false) async throws -> (URL, String) {
        if let ready = prepared[asset.localIdentifier], FileManager.default.fileExists(atPath: ready.path) {
            ShowOnTVLog.note("photo ready (prepared ahead)")
            return (ready, "image/jpeg")
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = !ahead          // neighbours kept only in iCloud aren't downloaded ahead
        options.deliveryMode = .highQualityFormat
        options.version = .current
        if !ahead { options.progressHandler = { [weak self] progress, _, _, _ in Task { @MainActor in self?.downloading = progress < 1 ? progress : nil } } }
        let readStart = Date()
        let data: Data = try await withCheckedThrowingContinuation { result in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data { result.resume(returning: data) }
                else { result.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? RemoteFailure.message(String(localized: "This photo couldn't be read."))) }
            }
        }
        if !ahead { downloading = nil }
        try Task.checkCancellation()
        let file = Self.folder.appendingPathComponent("\(UUID().uuidString).jpg")
        let readMS = ShowOnTVLog.ms(since: readStart), originalKB = data.count / 1024
        let prepStart = Date()
        let jpegKB = try await Task.detached(priority: .userInitiated) { () -> Int in
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let jpeg = try PhotoPrep.jpeg(from: data, maxPixel: PhotoPrep.tvPixel)
            try jpeg.write(to: file)
            return jpeg.count / 1024
        }.value
        ShowOnTVLog.note("\(ahead ? "prepared ahead: " : "")photo read \(readMS) ms (\(originalKB) KB), converted to JPEG in \(ShowOnTVLog.ms(since: prepStart)) ms (\(jpegKB) KB)")
        prepared[asset.localIdentifier] = file
        return (file, "image/jpeg")
    }
    /// A video for the TV: straight from the library file when the TV's player handles it (1080p, up to 20 Mbit/s),
    /// otherwise converted to 1080p while it plays (VideoStream): the TV's player stutters at 4K and fails at 4K
    /// 60 fps (CST-15). Slow-motion and other composed videos are converted too.
    private func video(_ asset: PHAsset) async throws -> (path: String, contentType: String, hls: Bool) {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.progressHandler = { [weak self] progress, _, _, _ in Task { @MainActor in self?.downloading = progress < 1 ? progress : nil } }
        let avAsset: AVAsset = try await withCheckedThrowingContinuation { result in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset { result.resume(returning: avAsset) }
                else { result.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? RemoteFailure.message(String(localized: "This video couldn't be read."))) }
            }
        }
        downloading = nil
        try Task.checkCancellation()
        let source = await Self.describe(avAsset)
        stopStream()
        if let url = (avAsset as? AVURLAsset)?.url, FileManager.default.isReadableFile(atPath: url.path),
           let source, !VideoPlan.needsConversion(source) {
            ShowOnTVLog.note("video served from the library file (.\(url.pathExtension.lowercased()))")
            let type = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
            return (server.share(url, contentType: type), type, false)
        }
        let started = Date()
        let stream = try await VideoStream(asset: avAsset, folder: Self.folder.appendingPathComponent("stream-\(UUID().uuidString)", isDirectory: true))
        stream.log = { ShowOnTVLog.note("conversion: \($0)") }
        ShowOnTVLog.note("video converted while it plays: \(Int(stream.outputSize.width))x\(Int(stream.outputSize.height)) \(stream.frameRate) fps, set up in \(ShowOnTVLog.ms(since: started)) ms")
        self.stream = stream
        let base = server.shareFolder(stream.folder) { [weak stream] name in stream?.requested(name) }
        return (base + "index.m3u8", "application/x-mpegURL", true)
    }
    private func stopStream() {
        guard let stream else { return }
        stream.stop()
        try? FileManager.default.removeItem(at: stream.folder)
        self.stream = nil
    }
    /// Keeps the photos for the one showing and its neighbours, deletes the rest, and prepares the missing neighbours
    /// one at a time in the background.
    private func prefetch(around asset: PHAsset) {
        prefetchTask?.cancel()
        let keep = Set(([asset] + neighbours).map(\.localIdentifier))
        for (id, file) in prepared where !keep.contains(id) { try? FileManager.default.removeItem(at: file); prepared[id] = nil }
        let todo = neighbours.filter { $0.mediaType == .image && prepared[$0.localIdentifier] == nil }
        guard !todo.isEmpty else { return }
        prefetchTask = Task { [weak self] in
            for photo in todo {
                guard !Task.isCancelled, let self else { return }
                _ = try? await self.photoFile(photo, ahead: true)
            }
        }
    }
    private static func clearFiles() { try? FileManager.default.removeItem(at: folder) }
    /// Logs what the TV is asked to play (size, frame rate, bit rate, codec, HDR) and returns it for the decision.
    private static func describe(_ asset: AVAsset) async -> VideoPlan.Source? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, fps, rate, formats, transform) = try? await track.load(.naturalSize, .nominalFrameRate, .estimatedDataRate, .formatDescriptions, .preferredTransform) else { return nil }
        let format = formats.first
        let codec = format.map { description -> String in
            let code = CMFormatDescriptionGetMediaSubType(description).bigEndian
            return withUnsafeBytes(of: code) { String(decoding: $0, as: UTF8.self) }
        } ?? "?"
        let transfer = format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String } ?? "SDR"
        ShowOnTVLog.note("video \(Int(size.width))x\(Int(size.height)) \(Int(fps.rounded())) fps \(codec) \(Int(rate / 1_000_000)) Mbit/s \(transfer)")
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        return VideoPlan.Source(width: Int(abs(shown.width)), height: Int(abs(shown.height)), fps: Double(fps), bitsPerSecond: Double(rate))
    }
}

// MARK: - Log

/// What Show on TV did and how long it took, for reviewing a test run: timings, sizes, memory and the TV's answers,
/// never photo contents or locations. Always to the system log (Console, subsystem com.guilhermeramalho.TVRemote,
/// category ShowOnTV); Dev builds also append to Documents/show-on-tv.log (capped at 1 MB), which can be copied off
/// the phone with `xcrun devicectl device copy from --domain-type appDataContainer`.
enum ShowOnTVLog {
    private static let logger = Logger(subsystem: "com.guilhermeramalho.TVRemote", category: "ShowOnTV")
    private static let queue = DispatchQueue(label: "tvremote.show-on-tv-log", qos: .utility)
    #if DEBUG
    static let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("show-on-tv.log")
    #endif

    static func note(_ message: String) {
        logger.log("\(message, privacy: .public)")
        #if DEBUG
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message) [mem \(memoryMB()) MB]\n"
        queue.async {
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 1_000_000 { try? FileManager.default.removeItem(at: file) }
            if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
            else { try? Data(line.utf8).write(to: file) }
        }
        #endif
    }
    /// The app's memory footprint, the number Xcode's memory gauge shows.
    static func memoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
    static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}

// MARK: - Library

enum LibrarySection: String, CaseIterable, Identifiable {
    case all, videos, favourites
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self { case .all: "All"; case .videos: "Videos"; case .favourites: "Favourites" }
    }
    func fetch() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        switch self {
        case .all: options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        case .videos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .favourites: options.predicate = NSPredicate(format: "favorite == YES AND (mediaType == %d OR mediaType == %d)", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        }
        return PHAsset.fetchAssets(with: options)
    }
}

/// Watches the library so the grid follows changes (new photos, a wider limited selection).
final class LibraryWatcher: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var revision = 0
    override init() { super.init(); PHPhotoLibrary.shared().register(self) }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    func photoLibraryDidChange(_ changeInstance: PHChange) { DispatchQueue.main.async { self.revision += 1 } }
}

struct ShowOnTVView: View {
    @ObservedObject var remote: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tv: ShowOnTVModel
    @StateObject private var watcher = LibraryWatcher()
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var section = LibrarySection.all
    @State private var assets = PHFetchResult<PHAsset>()
    @State private var viewer: ViewerStart?
    @State private var selecting = false
    @State private var selected: [String] = []
    @State private var lastOpened: Int?
    @Namespace private var zoom
    @Environment(\.displayScale) private var displayScale

    init(remote: RemoteModel) {
        self.remote = remote
        _tv = StateObject(wrappedValue: ShowOnTVModel(host: remote.host, tvName: remote.tvName))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch access {
                case .authorized, .limited: library
                case .notDetermined: Color.clear.task { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                default: noAccess
                }
            }
            .background(QuietTheme.background)
            .navigationDestination(item: $viewer) { start in
                ShowOnTVViewer(remote: remote, tv: tv, items: start.items, start: start.index, slideshow: start.slideshow,
                               zoom: start.zoomable ? zoom : nil) { index in
                    if start.zoomable { lastOpened = index }
                }
            }
            .navigationTitle("Show on TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(QuietTheme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { tv.close(); dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close").accessibilityIdentifier("closeShowOnTV")
                }
                ToolbarItem(placement: .primaryAction) { TVPill(tv: tv) }
            }
        }
        .tint(QuietTheme.cyan)
        .preferredColorScheme(.dark)
        .onChange(of: section) { _, _ in reload() }
        .onChange(of: watcher.revision) { _, _ in reload() }
        .onChange(of: access) { _, _ in reload() }
        .onAppear(perform: reload)
    }

    private var library: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(LibrarySection.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 8)
            if tv.noCast { noCastBanner }
            if access == .limited {
                Button { presentLimitedPicker() } label: {
                    Label("Purio sees only the photos you chose. Choose more…", systemImage: "photo.badge.plus").font(.footnote)
                }.padding(.bottom, 8)
            }
            if assets.count == 0 {
                ContentUnavailableView(section == .favourites ? LocalizedStringKey("No favourites yet") : LocalizedStringKey("No photos or videos"), systemImage: "photo.on.rectangle")
                    .frame(maxHeight: .infinity)
            } else {
                grid
            }
            bottomBar
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let side = floor((proxy.size.width - 6) / 4)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 2), count: 4), spacing: 2) {
                    ForEach(0..<assets.count, id: \.self) { index in
                        let asset = assets.object(at: index)
                        AssetThumbnail(asset: asset, side: side)
                            .modifier(ZoomSource(id: index, namespace: zoom))
                            .overlay(alignment: .bottomTrailing) {
                                if selecting {
                                    Image(systemName: selected.contains(asset.localIdentifier) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20)).foregroundStyle(.white, QuietTheme.cyan).padding(4).shadow(radius: 2)
                                }
                            }
                            .overlay { if index == lastOpened && !selecting { Rectangle().stroke(QuietTheme.cyan, lineWidth: 2) } }
                            .onTapGesture { tap(index, asset) }
                            .onAppear { if index % 16 == 0 { AssetImages.prefetch(assets, around: index, side: side * displayScale) } }
                            .accessibilityElement().accessibilityAddTraits(.isButton)
                            .accessibilityLabel(asset.mediaType == .video ? Text("Video") : Text("Photo"))
                            .accessibilityIdentifier("libraryItem")
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button { startSlideshow() } label: { selecting && !selected.isEmpty ? Text("Slideshow (\(selected.count))") : Text("Slideshow") }
                .disabled(selecting ? selected.isEmpty : !hasPhotos)
            Spacer()
            Text("\(assets.count) items").font(.caption).foregroundStyle(QuietTheme.muted).monospacedDigit()
            Spacer()
            Button { selecting.toggle(); selected = [] } label: { selecting ? Text("Cancel") : Text("Select") }
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(QuietTheme.background.overlay(alignment: .top) { Divider().overlay(QuietTheme.edge) })
    }

    private var noCastBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tv.slash").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: CastSession.noCastMessage).font(.footnote).fixedSize(horizontal: false, vertical: true)
                Button { Task { await tv.checkCast() } } label: {
                    if tv.checkingCast { ProgressView().controlSize(.mini) } else { Text("Check again").font(.footnote.weight(.semibold)) }
                }.disabled(tv.checkingCast).accessibilityIdentifier("checkCastAgain")
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16).padding(.bottom, 8)
        .accessibilityElement(children: .contain).accessibilityIdentifier("noCast")
    }

    private var noAccess: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(QuietTheme.cyan)
            Text("Purio can't see your photos").font(.headline)
            Text("To show photos and videos on your TV, allow access in Settings › Purio TV › Photos. They're read on this iPhone and sent only to your TV.")
                .font(.subheadline).foregroundStyle(QuietTheme.muted).multilineTextAlignment(.center)
            Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
                Text("Open Settings").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(red: 0.04, green: 0.16, blue: 0.19))
                    .padding(.horizontal, 22).padding(.vertical, 11).background(QuietTheme.cyan, in: Capsule())
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasPhotos: Bool { section != .videos && assets.count > 0 }

    private func reload() {
        guard access == .authorized || access == .limited else { return }
        AssetImages.stopPrefetching()
        assets = section.fetch()
        if let index = lastOpened, index >= assets.count { lastOpened = nil }
    }
    private func tap(_ index: Int, _ asset: PHAsset) {
        if selecting {
            if let at = selected.firstIndex(of: asset.localIdentifier) { selected.remove(at: at) }
            else if asset.mediaType == .image { selected.append(asset.localIdentifier) }
            return
        }
        viewer = ViewerStart(items: .fetch(assets), index: index, slideshow: false, zoomable: true)
    }
    private func startSlideshow() {
        if selecting {
            let picked = PHAsset.fetchAssets(withLocalIdentifiers: selected, options: nil)
            var byID: [String: PHAsset] = [:]
            picked.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
            let ordered = selected.compactMap { byID[$0] }
            selecting = false; selected = []
            guard !ordered.isEmpty else { return }
            viewer = ViewerStart(items: .list(ordered), index: 0, slideshow: true, zoomable: false)
        } else {
            let start = lastOpened ?? (0..<assets.count).first { assets.object(at: $0).mediaType == .image } ?? 0
            viewer = ViewerStart(items: .fetch(assets), index: start, slideshow: true, zoomable: true)
        }
    }
    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
}

/// What the viewer pages through: the library section (by index, nothing copied) or a slideshow selection.
enum ViewerItems {
    case fetch(PHFetchResult<PHAsset>)
    case list([PHAsset])
    var count: Int { switch self { case .fetch(let r): r.count; case .list(let l): l.count } }
    subscript(_ index: Int) -> PHAsset { switch self { case .fetch(let r): r.object(at: index); case .list(let l): l[index] } }
}
struct ViewerStart: Identifiable, Hashable {
    let id = UUID()
    let items: ViewerItems
    let index: Int
    let slideshow: Bool
    /// Opened from the grid (not a selection), so it can zoom out of and back into the photo's cell.
    let zoomable: Bool
    static func == (a: ViewerStart, b: ViewerStart) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// iOS 18+: the grid cell a photo zooms out of, and back into when the viewer is swiped down (as in Photos).
struct ZoomSource: ViewModifier {
    let id: Int
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18, *) { content.matchedTransitionSource(id: id, in: namespace) } else { content }
    }
}
struct ZoomDestination: ViewModifier {
    let id: Int
    let namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if #available(iOS 18, *), let namespace { content.navigationTransition(.zoom(sourceID: id, in: namespace)) } else { content }
    }
}

/// A grid cell: a small thumbnail for the cell's size only, dropped when it scrolls away so memory stays at what's
/// on screen (the grid keeps views it has shown).
struct AssetThumbnail: View {
    let asset: PHAsset
    let side: CGFloat
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(QuietTheme.panel)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            if asset.mediaType == .video {
                Text(Duration.seconds(asset.duration).formatted(.time(pattern: asset.duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.white).shadow(radius: 2).padding(4)
            }
        }
        .frame(width: side, height: side).clipped()
        .task(id: asset.localIdentifier) {
            // A quick low-resolution picture at once, then the sharp one, decoded off the main thread.
            for await next in AssetImages.thumbnails(asset, side: side * scale) {
                image = await next.byPreparingForDisplay() ?? next
            }
        }
        .onDisappear { image = nil }
    }
}

enum AssetImages {
    /// One manager for the grid, which keeps recently used thumbnails at hand as you scroll back and forth.
    static let grid = PHCachingImageManager()

    /// The grid cell's picture: the quick, low-resolution version first (shown at once, as Photos does), then the
    /// sharp one. Cancelled with the calling task.
    private static var gridOptions: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return options
    }
    /// The rows Photos is keeping ready: only those around the screen. Rows left behind are released, so memory
    /// stays flat however far you scroll (1.3 test: keeping them all reached 250 MB).
    @MainActor private static var cached = IndexSet()
    /// Asks Photos to get the thumbnails a few rows either side of the screen ready, so scrolling meets them done.
    @MainActor static func prefetch(_ assets: PHFetchResult<PHAsset>, around index: Int, side: CGFloat) {
        let wanted = IndexSet(integersIn: max(0, index - 32)..<min(assets.count, index + 32))
        let size = CGSize(width: side, height: side)
        let dropped = cached.subtracting(wanted).filteredIndexSet { $0 < assets.count }
        let added = wanted.subtracting(cached)
        if !dropped.isEmpty { grid.stopCachingImages(for: assets.objects(at: dropped), targetSize: size, contentMode: .aspectFill, options: gridOptions) }
        if !added.isEmpty { grid.startCachingImages(for: assets.objects(at: added), targetSize: size, contentMode: .aspectFill, options: gridOptions) }
        cached = wanted
    }
    @MainActor static func stopPrefetching() { grid.stopCachingImagesForAllAssets(); cached = IndexSet() }
    static func thumbnails(_ asset: PHAsset, side: CGFloat) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let id = grid.requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: gridOptions) { image, info in
                if let image { continuation.yield(image) }
                if !((info?[PHImageResultIsDegradedKey] as? Bool) ?? false) { continuation.finish() }
            }
            continuation.onTermination = { _ in grid.cancelImageRequest(id) }
        }
    }

    /// One image at about `side` pixels; cancelled with the calling task.
    static func image(_ asset: PHAsset, side: CGFloat, fill: Bool, network: Bool = false) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network
        let size = CGSize(width: side, height: side)
        let request = RequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (result: CheckedContinuation<UIImage?, Never>) in
                var finished = false
                request.id = PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: fill ? .aspectFill : .aspectFit, options: options) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !finished, !degraded || image == nil else { return }
                    finished = true
                    result.resume(returning: image)
                }
            }
        } onCancel: { PHImageManager.default().cancelImageRequest(request.id) }
    }
    private final class RequestBox: @unchecked Sendable { var id: PHImageRequestID = PHInvalidImageRequestID }
}

// MARK: - Viewer

struct ShowOnTVViewer: View {
    @ObservedObject var remote: RemoteModel
    @ObservedObject var tv: ShowOnTVModel
    let items: ViewerItems
    let start: Int
    let slideshow: Bool
    let zoom: Namespace.ID?
    let opened: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current: Int?
    @State private var chrome = true
    @State private var slideshowTask: Task<Void, Never>?
    @State private var scrub: Double?
    /// How far the viewer is pulled down (swipe down to go back, where the zoom transition doesn't do it).
    @State private var pull: CGFloat = 0
    private var pullsByHand: Bool {
        if #available(iOS 18, *) { return zoom == nil }
        return true
    }

    var body: some View {
        let index = current ?? start
        ZStack {
            Color.black.opacity(Double(1 - min(pull, 300) / 400)).ignoresSafeArea()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<items.count, id: \.self) { i in
                        ViewerPage(asset: items[i], casting: casting(for: items[i]), tvName: tv.tvName, animates: !chrome)
                            .containerRelativeFrame([.horizontal, .vertical]).id(i)
                    }
                }.scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .offset(y: pull)
            .scaleEffect(CGFloat(1 - min(pull, 300) / 1200))
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } }
            .simultaneousGesture(pullsByHand ? pullDown : nil)
            if chrome && pull == 0 { overlay(index).transition(.opacity) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .modifier(ZoomDestination(id: index, namespace: zoom))
        .statusBarHidden(!chrome)
        .preferredColorScheme(.dark)
        .onAppear { current = start; focus(start); if slideshow { toggleSlideshow() } }
        .onChange(of: current) { _, value in if let value { focus(value) } }
        .onDisappear { slideshowTask?.cancel() }
        .alert("Purio TV", isPresented: Binding(get: { tv.problem != nil }, set: { if !$0 { tv.problem = nil } })) {
            if tv.problemIsItem && index + 1 < items.count { Button("Next item") { tv.problem = nil; withAnimation { current = index + 1 } } }
            Button("Keep browsing", role: .cancel) { tv.problem = nil }
        } message: { Text(tv.problem ?? "") }
    }

    /// Pull down to go back, like Photos: the photo follows the finger and shrinks, the black fades.
    private var pullDown: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) * 1.3 else { return }
                pull = value.translation.height
            }
            .onEnded { value in
                if pull > 110 || (pull > 0 && value.predictedEndTranslation.height > 350) { dismiss() }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pull = 0 } }
            }
    }
    /// The video page's state on the TV, for its animation.
    private func casting(for asset: PHAsset) -> ViewerPage.Casting? {
        guard asset.mediaType == .video, tv.shownID == asset.localIdentifier, let media = tv.media else { return nil }
        if media.playerState == "PLAYING" { return .playing }
        if media.playerState == "BUFFERING" { return .buffering }
        return media.playerState == "PAUSED" ? .paused : nil
    }

    private func overlay(_ index: Int) -> some View {
        let asset = items[index]
        return VStack(spacing: 0) {
            HStack(alignment: .center) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                        .background(.white.opacity(0.12), in: Circle())
                }.accessibilityLabel("Back to library").accessibilityIdentifier("viewerBack")
                Spacer()
                VStack(spacing: 1) {
                    if let date = asset.creationDate {
                        Text(date.formatted(.dateTime.day().month().year())).font(.system(size: 14, weight: .semibold))
                        Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
                TVPill(tv: tv)
            }
            .padding(.horizontal, 14).padding(.top, 6)
            if tv.tv == .opening {
                HStack(spacing: 10) {
                    ProgressView().tint(QuietTheme.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Opening on \(tv.tvName)…").font(.system(size: 13, weight: .semibold))
                        Text("The TV starts its player, about 10 seconds the first time.").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12).background(QuietTheme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 14).padding(.top, 10)
                .transition(.opacity)
            } else if let progress = tv.downloading {
                Label { Text("Downloading from iCloud… \(Int(progress * 100))%") } icon: { ProgressView().tint(QuietTheme.cyan) }
                    .font(.system(size: 13)).padding(10).background(QuietTheme.panel.opacity(0.96), in: Capsule()).padding(.top, 10)
            }
            // While the controls show, the casting animation lives in the space between them and the top bar,
            // shrunk to fit, so it never runs into the position bar on any screen (1.3 test).
            if let state = casting(for: asset) {
                GeometryReader { space in
                    CastingAnimation(state: state, tvName: tv.tvName)
                        .scaleEffect(min(1, space.size.height / 300))
                        .frame(width: space.size.width, height: space.size.height)
                }
                .transition(.opacity)
            } else {
                Spacer()
            }
            VStack(spacing: 14) {
                if asset.mediaType == .video { videoControls(asset) }
                HStack {
                    action(slideshowTask == nil ? "Slideshow" : "Stop slideshow", slideshowTask == nil ? "play.rectangle" : "pause.rectangle", hot: slideshowTask != nil) { toggleSlideshow() }
                        .disabled(asset.mediaType == .video && slideshowTask == nil)
                    Spacer()
                    action("Stop on TV", "stop.fill", hot: false) { slideshowTask?.cancel(); slideshowTask = nil; tv.stopOnTV() }
                        .disabled(tv.shownID == nil).accessibilityIdentifier("stopOnTV")
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 10).padding(.top, 30)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)).ignoresSafeArea())
        }
        .foregroundStyle(.white)
    }

    private func videoControls(_ asset: PHAsset) -> some View {
        let onTV = tv.shownID == asset.localIdentifier
        let duration = tv.media?.duration ?? asset.duration
        return VStack(spacing: 12) {
            if tv.endedID == asset.localIdentifier {
                Button { tv.playAgain() } label: {
                    Label("Play again", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .semibold)).padding(.horizontal, 24).padding(.vertical, 14)
                        .background(QuietTheme.cyan, in: Capsule()).foregroundStyle(Color(red: 0.04, green: 0.16, blue: 0.19))
                }.accessibilityIdentifier("playAgain")
                Text("Finished. The TV shows the video's first frame.").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
            } else if onTV {
                // Redrawn twice a second from the TV's last report, so the bar follows the TV between reports.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let time = scrub ?? tv.position(at: context.date)
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { min(time, duration) }, set: { scrub = $0 }), in: 0...max(duration, 1)) { editing in
                            if !editing, let target = scrub { tv.seek(to: target); scrub = nil }
                        }
                        .tint(QuietTheme.cyan).accessibilityLabel("Position")
                        HStack {
                            Text(Duration.seconds(time).formatted(.time(pattern: .minuteSecond)))
                            Spacer()
                            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                        }.font(.system(size: 11)).monospacedDigit().foregroundStyle(QuietTheme.muted)
                    }
                }
                HStack(spacing: 30) {
                    round("gobackward.10", "Back 10 seconds") { tv.skip(-10) }
                    Button { tv.media?.playing == true ? tv.pause() : (tv.media?.idleReason == "FINISHED" ? tv.playAgain() : tv.play()) } label: {
                        Image(systemName: tv.media?.playing == true ? "pause.fill" : "play.fill").font(.system(size: 22))
                            .frame(width: 60, height: 60).background(QuietTheme.cyan, in: Circle()).foregroundStyle(Color(red: 0.04, green: 0.16, blue: 0.19))
                    }.accessibilityLabel(tv.media?.playing == true ? "Pause" : "Play")
                    round("goforward.10", "Forward 10 seconds") { tv.skip(10) }
                }
                HStack(spacing: 0) {
                    Button { remote.tap(.volumeDown) } label: { Image(systemName: "minus").frame(width: 56, height: 40) }.accessibilityLabel("Volume down")
                    Text(remote.volume).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
                    Button { remote.tap(.volumeUp) } label: { Image(systemName: "plus").frame(width: 56, height: 40) }.accessibilityLabel("Volume up")
                }
                .background(.white.opacity(0.1), in: Capsule()).disabled(!remote.ready)
                Text("Keep Purio open while the video plays: the TV streams it from your iPhone.")
                    .font(.system(size: 12)).foregroundStyle(QuietTheme.muted).multilineTextAlignment(.center)
            }
        }
    }
    private func round(_ symbol: String, _ label: LocalizedStringKey, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: symbol).font(.system(size: 18)).frame(width: 46, height: 46).background(.white.opacity(0.13), in: Circle()) }
            .accessibilityLabel(label)
    }
    private func action(_ title: LocalizedStringKey, _ symbol: String, hot: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 44, height: 44)
                    .background(hot ? QuietTheme.cyan.opacity(0.22) : .white.opacity(0.13), in: Circle())
                    .foregroundStyle(hot ? QuietTheme.cyan : .white)
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func focus(_ index: Int) {
        guard index >= 0, index < items.count else { return }
        opened(index)
        let around = [index - 1, index + 1].filter { $0 >= 0 && $0 < items.count }.map { items[$0] }
        tv.focus(items[index], neighbours: around)
    }
    /// Every 5 seconds to the next photo; videos are skipped, the end stops it, a swipe keeps it going from there.
    private func toggleSlideshow() {
        if let task = slideshowTask { task.cancel(); slideshowTask = nil; return }
        slideshowTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                let from = current ?? start
                guard let next = ((from + 1)..<items.count).first(where: { items[$0].mediaType == .image }) else { break }
                withAnimation(.easeInOut(duration: 0.4)) { current = next }
            }
            slideshowTask = nil
        }
    }
}

/// One full-screen page: a screen-sized image (the TV gets its own 4K JPEG when it's shown), released when the
/// page scrolls away.
struct ViewerPage: View {
    enum Casting { case playing, buffering, paused }
    let asset: PHAsset
    var casting: Casting? = nil
    var tvName = ""
    /// The animation is drawn here only while the viewer's controls are hidden; with them, the viewer draws it
    /// in the space above them.
    var animates = true
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .blur(radius: casting == nil ? 0 : 24).opacity(casting == nil ? 1 : 0.45)
                        .animation(.easeInOut(duration: 0.5), value: casting == nil)
                } else { ProgressView().tint(.white) }
                if let casting {
                    if animates { CastingAnimation(state: casting, tvName: tvName).transition(.opacity.combined(with: .scale(scale: 0.9))) }
                } else if asset.mediaType == .video {
                    Image(systemName: "play.tv").font(.system(size: 30)).padding(16).background(.black.opacity(0.45), in: Circle()).foregroundStyle(.white.opacity(0.9))
                }
            }
            .animation(.easeInOut(duration: 0.4), value: casting)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: asset.localIdentifier) { image = await AssetImages.image(asset, side: max(proxy.size.width, proxy.size.height) * scale, fill: false, network: true) }
            .onDisappear { image = nil }
        }
    }
}

/// While a video plays on the TV: rings going out from a TV with a little level meter on its screen. It stops
/// when the video pauses, and stays still with Reduce Motion. Drawn by TimelineView only while on screen.
struct CastingAnimation: View {
    let state: ViewerPage.Casting
    let tvName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let moving = state != .paused && !reduceMotion
        VStack(spacing: 18) {
            TimelineView(.animation(paused: !moving)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<3, id: \.self) { ring in
                        let phase = moving ? (t / 2.4 + Double(ring) / 3).truncatingRemainder(dividingBy: 1) : 0.3 + Double(ring) * 0.3
                        Circle()
                            .stroke(QuietTheme.cyan.opacity(moving ? 0.6 * (1 - phase) : 0.14), lineWidth: 2)
                            .frame(width: 104 + 130 * phase, height: 104 + 130 * phase)
                    }
                    Circle().fill(QuietTheme.cyan.opacity(0.15)).frame(width: 104, height: 104)
                    Image(systemName: "tv").font(.system(size: 44, weight: .regular)).foregroundStyle(QuietTheme.cyan)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<4, id: \.self) { bar in
                            Capsule().frame(width: 3.5, height: moving && state == .playing ? 5 + 9 * abs(sin(t * 2.6 + Double(bar) * 0.9)) : 4)
                        }
                    }
                    .frame(height: 14, alignment: .bottom)
                    .foregroundStyle(QuietTheme.cyan)
                    .offset(y: -4)
                }
                .frame(width: 240, height: 240)
            }
            Text(state == .paused ? "Paused on \(tvName)" : "Playing on \(tvName)")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("castingAnimation")
    }
}

/// Which TV the taps go to and whether it's following: tap to pause or resume sending.
struct TVPill: View {
    @ObservedObject var tv: ShowOnTVModel
    var body: some View {
        Button { tv.toggleSending() } label: {
            HStack(spacing: 6) {
                switch tv.tv {
                case .opening: ProgressView().controlSize(.mini).tint(QuietTheme.cyan); Text("Opening…")
                case .on: Circle().fill(QuietTheme.cyan).frame(width: 7, height: 7); Text("On TV")
                case .paused: Circle().fill(QuietTheme.muted).frame(width: 7, height: 7); Text("Not on TV")
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text("TV")
                case .off: Circle().fill(QuietTheme.muted).frame(width: 7, height: 7); Text(verbatim: tv.tvName).lineLimit(1)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tv.tv == .on || tv.tv == .opening ? QuietTheme.cyan : QuietTheme.muted)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(tv.tv == .on ? QuietTheme.cyan.opacity(0.16) : QuietTheme.panel, in: Capsule())
            .fixedSize()          // hugs its text, so it sits flush right like the back button on the left
        }
        .accessibilityIdentifier(tv.tv == .on ? "tvPill.on" : "tvPill")
        .accessibilityHint(tv.tv == .paused ? Text("Shows the open photo on the TV again") : Text("Stops sending photos to the TV while you browse"))
    }
}
