import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// TV Home editing through the launcher. The key travels through the remote's existing pairing, so there is no second
/// pairing. Opening a session briefly shows an invisible screen on the TV, which can pause what's playing, so it opens
/// by itself only when Home is in front; with an app or input on screen the user confirms first.
@MainActor final class HomeEditor: ObservableObject {
    @Published var ready = false
    @Published var busy = false
    @Published var message = "Turn on the TV to load its Home screen. Drafts are saved on this iPhone."
    @Published private(set) var snapshot: LauncherSnapshot?
    /// Set when an app or input is in front: the name to show in the "Connect now?" prompt.
    @Published private(set) var waitingFor: String?
    static let homePackage = "com.gathin.tvhome"
    private let client = LauncherClient()
    private var operation: Task<Void, Never>?
    private var generation = 0
    /// True while the TV tab wants a session: a dropped one reconnects by itself (within `reconnects`).
    private var wanted = false
    private weak var model: RemoteModel?
    private var reconnects: [Date] = []

    func close() {
        generation += 1; wanted = false; snapshot = nil; operation?.cancel(); operation = nil; client.close()
        ready = false; busy = false; waitingFor = nil
        message = "TV Home connects when you open the TV tab with the TV on."
    }

    /// Called whenever the TV's state changes while the TV tab is visible.
    func autoConnect(model: RemoteModel) {
        self.model = model
        guard !ready, !busy else { return }
        guard model.ready else { waitingFor = nil; message = "Waiting for the TV. Drafts are saved on this iPhone."; return }
        if model.powerOn == false { waitingFor = nil; message = "The TV is in standby. Turn it on to load its Home screen."; return }
        if model.foregroundPackage == Self.homePackage { connect(model: model); return }
        // The remote reports the app in front, not whether it is playing, so any app or input asks first.
        let name = TVSession.appName(for: model.foregroundPackage) ?? (model.foregroundPackage.isEmpty ? "The TV" : "An app or input")
        waitingFor = name
        message = "\(name) is on screen. Connecting opens TV Home's editor in the background, which can pause what's playing."
    }

    /// Opens a session unless one is open or opening. `force` starts over (Try again, Connect now).
    func connect(model: RemoteModel, force: Bool = false) {
        guard force || (!ready && !busy) else { return }
        close()
        self.model = model
        let token = generation
        wanted = true
        guard model.ready else { message = "Waiting for the TV. Drafts are saved on this iPhone."; return }
        waitingFor = nil; busy = true; message = "Connecting to TV Home…"
        client.event = { [weak self] event in
            guard let self, self.generation == token else { return }
            switch event {
            case .disconnected(let reason):
                self.ready = false; self.busy = false; self.snapshot = nil; self.message = reason
                self.reconnectIfWanted()
            }
        }
        let host = model.host
        operation = Task { [weak self, weak model] in
            guard let self, let model else { return }
            var lastError: Error = RemoteFailure.message("TV Home did not answer")
            // Up to three tries, each with a fresh key: the remote may need a moment after the phone wakes.
            for attempt in 1...3 {
                do {
                    guard await model.freshen() else { throw RemoteFailure.message("The TV remote connection isn't responding yet.") }
                    let key = try EditorLink.newKey()
                    try await model.sendLink(EditorLink.url(key: key))
                    try await self.client.open(host: host, key: key)
                    try await self.refresh()
                    if self.generation == token { self.busy = false }
                    return
                } catch is CancellationError {
                    if self.generation == token { self.busy = false }
                    return
                } catch {
                    guard self.generation == token else { return }
                    lastError = error
                    if attempt < 3 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                }
            }
            guard self.generation == token else { return }
            self.client.close(); self.ready = false; self.busy = false
            self.message = "Couldn’t reach TV Home. \(lastError.localizedDescription)"
        }
    }

    /// A session that dropped while the TV tab is open comes back by itself, at most three times a minute.
    private func reconnectIfWanted() {
        guard wanted, let model else { return }
        let now = Date()
        reconnects = reconnects.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard reconnects.count <= 3 else { message += " Tap Try again to reconnect."; return }
        let token = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.generation == token, self.wanted, !self.ready, !self.busy else { return }
            self.autoConnect(model: model)
        }
    }

    func refresh() async throws {
        let token = generation
        let result = try await client.request("snapshot", as: LauncherSnapshot.self)
        guard generation == token else { throw CancellationError() }
        try result.validate(); snapshot = result; ready = true; message = "Connected to TV Home"
    }
    func apply(_ layout: HomeLayout, wallpaper: Data?) async throws {
        try layout.validate()
        guard ready, let snapshot else { throw RemoteFailure.message("Wait for TV Home to connect before applying") }
        guard (wallpaper?.count ?? 0) <= 1_000_000 else { throw RemoteFailure.message("Wallpaper exceeds 1 MB") }
        var payload: [String: Any] = ["expectedRevision":snapshot.revision, "layout":try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout))]
        if let wallpaper, HomeLayout.validPhoto(layout.wallpaper) { payload["wallpaperJPEG"] = try Self.tvWallpaper(wallpaper).base64EncodedString() }
        let token = generation
        let result = try await client.request("applyLayout", payload: payload, as: LauncherSnapshot.self)
        guard generation == token else { throw CancellationError() }
        try result.validate(); self.snapshot = result; message = "TV Home updated"
    }
    /// Backs up the current draft, then applies it. Shared by the TV tab and the wallpaper screens.
    func applyDraft(_ settings: AppSettings) async -> Bool {
        do {
            _ = try settings.backup(name: "Before applying · " + settings.profile.name)
            try await apply(settings.layout, wallpaper: settings.wallpaperData(settings.layout))
            return true
        } catch { settings.notice = error.localizedDescription; return false }
    }
    struct Confirmation: Decodable { let status: String }
    func uninstall(_ app: RemoteApp) async throws {
        guard ready, app.installed == true, !app.system, RemoteApp.validPackage(app.id) else { throw RemoteFailure.message("Sync installed apps before uninstalling") }
        let token = generation
        let result = try await client.request("uninstall", payload: ["package":app.id], as: Confirmation.self)
        guard generation == token else { throw CancellationError() }
        guard result.status == "confirmationRequired" else { throw RemoteFailure.message("Unexpected uninstall response. Refresh the app list.") }
        message = "Confirm uninstall on your TV. Refresh afterward to check the result."
    }
    func sleepTimer(minutes: Int) async throws {
        guard ready, (0...240).contains(minutes) else { throw RemoteFailure.message("Wait for TV Home to connect to schedule a sleep timer") }
        let token = generation
        let result = try await client.request("sleepTimer", payload: ["minutes":minutes], as: LauncherSnapshot.self)
        guard generation == token else { throw CancellationError() }
        try result.validate(); snapshot = result
    }

    /// The photo as the TV shows it: centre-cropped to 16:9 at 1280×720. Home decodes it at that size, about 1.8 MB
    /// instead of about 4 MB at 1080p; behind the tiles it looks the same from the sofa.
    static func tvWallpaper(_ data: Data) throws -> Data {
        let width = 1280, height = 720
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw RemoteFailure.message("This photo can't be used as a TV wallpaper")
        }
        let scale = max(Double(width) / Double(full.width), Double(height) / Double(full.height))
        let drawn = CGSize(width: Double(full.width) * scale, height: Double(full.height) * scale)
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: (Double(width) - drawn.width) / 2, y: (Double(height) - drawn.height) / 2, width: drawn.width, height: drawn.height))
        let encoded = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RemoteFailure.message("This photo can't be used as a TV wallpaper")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length <= 1_000_000 else { throw RemoteFailure.message("This photo can't be used as a TV wallpaper") }
        return encoded as Data
    }
}
