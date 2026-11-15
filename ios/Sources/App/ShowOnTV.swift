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
    /// The asset currently on the TV.
    @Published private(set) var shownID: String?
    @Published private(set) var downloading: Double?
    @Published var problem: String?
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
    private var files: [URL] = []
    private var shownIsVideo = false
    private var openedAt: Date?
    private var loadedAt: Date?
    nonisolated private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShowOnTV", isDirectory: true)

    init(host: String, tvName: String) {
        self.host = host; self.tvName = tvName
        server.requestLog = { method, shared, range in ShowOnTVLog.note("TV fetched (\(method)\(shared ? "" : ", unknown path → 404")\(range.map { ", \($0)" } ?? ""))") }
        Self.clearFiles()      // left over if the app was closed while showing
        ShowOnTVLog.note("library opened (TV \(host))")
    }

    /// The viewer settled on an asset: it goes to the TV once it has stayed in front for a moment (CST-03).
    func focus(_ asset: PHAsset) {
        focusedAsset = asset
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
    func seek(to seconds: Double) { session?.seek(to: seconds) }
    func skip(_ seconds: Double) { seek(to: (media?.currentTime ?? 0) + seconds) }

    /// Closes the TV's player (it returns to Home) but keeps the library open.
    func stopOnTV() {
        ShowOnTVLog.note("stop on TV")
        sendTask?.cancel()
        session?.stop(); session = nil
        follower.forget(); shownID = nil; media = nil; downloading = nil
        tv = .paused
        keepAwake(false)
    }
    /// Leaving the library: everything goes.
    func close() {
        ShowOnTVLog.note("library closed")
        settleTask?.cancel(); sendTask?.cancel()
        session?.stop(); session = nil
        server.stop()
        keepAwake(false)
        Self.clearFiles(); files = []
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
            let (file, contentType) = asset.mediaType == .video ? try await videoFile(asset) : try await photoFile(asset)
            guard !Task.isCancelled else { return }
            let path = server.share(file, contentType: contentType)
            let session = self.session ?? makeSession()
            shownID = asset.localIdentifier
            shownIsVideo = asset.mediaType == .video
            media = nil
            loadedAt = Date()
            ShowOnTVLog.note("load \(contentType) from \(address):\(port)")
            session.load(.init(url: "http://\(address):\(port)\(path)", contentType: contentType,
                               title: asset.creationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Purio TV"))
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
            media = status
            keepAwake(shownIsVideo && status.playing)
            if status.idleReason == "ERROR" { reportLoadFailure() }
        case .loadFailed:
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

    // MARK: media for the TV

    /// The photo as a JPEG at most 4K (the TV refuses HEIC), prepared off the main thread and freed once written.
    private func photoFile(_ asset: PHAsset) async throws -> (URL, String) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.progressHandler = { [weak self] progress, _, _, _ in Task { @MainActor in self?.downloading = progress < 1 ? progress : nil } }
        let readStart = Date()
        let data: Data = try await withCheckedThrowingContinuation { result in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data { result.resume(returning: data) }
                else { result.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? RemoteFailure.message(String(localized: "This photo couldn't be read."))) }
            }
        }
        downloading = nil
        try Task.checkCancellation()
        let file = Self.folder.appendingPathComponent("\(UUID().uuidString).jpg")
        let readMS = ShowOnTVLog.ms(since: readStart), originalKB = data.count / 1024
        let prepStart = Date()
        let jpegKB = try await Task.detached(priority: .userInitiated) { () -> Int in
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let jpeg = try PhotoPrep.jpeg(from: data)
            try jpeg.write(to: file)
            return jpeg.count / 1024
        }.value
        ShowOnTVLog.note("photo read \(readMS) ms (\(originalKB) KB), converted to JPEG in \(ShowOnTVLog.ms(since: prepStart)) ms (\(jpegKB) KB)")
        track(file)
        return (file, "image/jpeg")
    }
    /// The video straight from the library file: the TV plays iPhone .mov (H.264, HEVC, HDR) as is (CST-02), so
    /// nothing is copied. Slow-motion and other composed videos are exported once to a temporary file.
    private func videoFile(_ asset: PHAsset) async throws -> (URL, String) {
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
        if let url = (avAsset as? AVURLAsset)?.url, FileManager.default.isReadableFile(atPath: url.path) {
            ShowOnTVLog.note("video served from the library file (.\(url.pathExtension.lowercased()))")
            return (url, url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4")
        }
        ShowOnTVLog.note("video needs an export (\(type(of: avAsset)))")
        guard let export = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw RemoteFailure.message(String(localized: "This video couldn't be read."))
        }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let file = Self.folder.appendingPathComponent("\(UUID().uuidString).mp4")
        export.outputURL = file
        export.outputFileType = .mp4
        downloading = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in export.exportAsynchronously { done.resume() } }
        downloading = nil
        guard export.status == .completed else { throw export.error ?? RemoteFailure.message(String(localized: "This video couldn't be read.")) }
        track(file)
        return (file, "video/mp4")
    }
    /// Keeps the two newest prepared files (the one on the TV and the one before it) and deletes older ones.
    private func track(_ file: URL) {
        files.append(file)
        while files.count > 2 { try? FileManager.default.removeItem(at: files.removeFirst()) }
    }
    private static func clearFiles() { try? FileManager.default.removeItem(at: folder) }
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
        .fullScreenCover(item: $viewer) { start in
            ShowOnTVViewer(remote: remote, tv: tv, items: start.items, start: start.index, slideshow: start.slideshow) { index in
                if start.items.count == assets.count { lastOpened = index }
            }
        }
    }

    private var library: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(LibrarySection.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 8)
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
                            .overlay(alignment: .bottomTrailing) {
                                if selecting {
                                    Image(systemName: selected.contains(asset.localIdentifier) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20)).foregroundStyle(.white, QuietTheme.cyan).padding(4).shadow(radius: 2)
                                }
                            }
                            .overlay { if index == lastOpened && !selecting { Rectangle().stroke(QuietTheme.cyan, lineWidth: 2) } }
                            .onTapGesture { tap(index, asset) }
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
        assets = section.fetch()
        if let index = lastOpened, index >= assets.count { lastOpened = nil }
    }
    private func tap(_ index: Int, _ asset: PHAsset) {
        if selecting {
            if let at = selected.firstIndex(of: asset.localIdentifier) { selected.remove(at: at) }
            else if asset.mediaType == .image { selected.append(asset.localIdentifier) }
            return
        }
        viewer = ViewerStart(items: .fetch(assets), index: index, slideshow: false)
    }
    private func startSlideshow() {
        if selecting {
            let picked = PHAsset.fetchAssets(withLocalIdentifiers: selected, options: nil)
            var byID: [String: PHAsset] = [:]
            picked.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
            let ordered = selected.compactMap { byID[$0] }
            selecting = false; selected = []
            guard !ordered.isEmpty else { return }
            viewer = ViewerStart(items: .list(ordered), index: 0, slideshow: true)
        } else {
            let start = lastOpened ?? (0..<assets.count).first { assets.object(at: $0).mediaType == .image } ?? 0
            viewer = ViewerStart(items: .fetch(assets), index: start, slideshow: true)
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
struct ViewerStart: Identifiable {
    let id = UUID()
    let items: ViewerItems
    let index: Int
    let slideshow: Bool
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
        .task(id: asset.localIdentifier) { image = await AssetImages.image(asset, side: side * scale, fill: true) }
        .onDisappear { image = nil }
    }
}

enum AssetImages {
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
    let opened: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current: Int?
    @State private var chrome = true
    @State private var playing = false
    @State private var slideshowTask: Task<Void, Never>?

    var body: some View {
        let index = current ?? start
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<items.count, id: \.self) { i in
                        ViewerPage(asset: items[i]).containerRelativeFrame([.horizontal, .vertical]).id(i)
                    }
                }.scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } }
            if chrome { overlay(index) }
        }
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
            Spacer()
            VStack(spacing: 14) {
                if asset.mediaType == .video { videoControls(asset) }
                HStack {
                    action(slideshowTask == nil ? "Slideshow" : "Stop slideshow", slideshowTask == nil ? "play.rectangle" : "pause.rectangle", hot: slideshowTask != nil) { toggleSlideshow() }
                        .disabled(asset.mediaType == .video && slideshowTask == nil)
                    Spacer()
                    action("Stop on TV", "stop.fill", hot: false) { slideshowTask?.cancel(); slideshowTask = nil; tv.stopOnTV() }
                        .disabled(tv.shownID == nil)
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
        let time = onTV ? (tv.media?.currentTime ?? 0) : 0
        return VStack(spacing: 12) {
            if onTV {
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { min(time, duration) }, set: { tv.seek(to: $0) }), in: 0...max(duration, 1))
                        .tint(QuietTheme.cyan).accessibilityLabel("Position")
                    HStack {
                        Text(Duration.seconds(time).formatted(.time(pattern: .minuteSecond)))
                        Spacer()
                        Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    }.font(.system(size: 11)).monospacedDigit().foregroundStyle(QuietTheme.muted)
                }
                HStack(spacing: 30) {
                    round("gobackward.10", "Back 10 seconds") { tv.skip(-10) }
                    Button { tv.media?.playing == true ? tv.pause() : tv.play() } label: {
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
        tv.focus(items[index])
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
    let asset: PHAsset
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView().tint(.white) }
                if asset.mediaType == .video {
                    Image(systemName: "play.tv").font(.system(size: 30)).padding(16).background(.black.opacity(0.45), in: Circle()).foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: asset.localIdentifier) { image = await AssetImages.image(asset, side: max(proxy.size.width, proxy.size.height) * scale, fill: false, network: true) }
            .onDisappear { image = nil }
        }
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
            .frame(maxWidth: 150)
        }
        .accessibilityIdentifier("tvPill")
        .accessibilityHint(tv.tv == .paused ? Text("Shows the open photo on the TV again") : Text("Stops sending photos to the TV while you browse"))
    }
}
