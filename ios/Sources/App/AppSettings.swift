import SwiftUI
import UniformTypeIdentifiers
import ImageIO

@MainActor final class AppSettings: ObservableObject {
    @Published private(set) var value: RemotePreferences
    @Published private(set) var backups: [HomeBackup] = []
    @Published var notice = ""
    private let directory: URL
    private var settingsURL: URL { directory.appendingPathComponent("preferences.json") }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TVRemote", isDirectory: true)
        value = .init()
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                let data = try Data(contentsOf: settingsURL)
                guard data.count <= 2_000_000 else { throw RemoteFailure.message("Saved settings are too large") }
                let restored = try JSONDecoder().decode(RemotePreferences.self, from: data)
                try restored.validate(); value = restored
            } else {
                try JSONEncoder().encode(value).write(to: settingsURL, options: .atomic)
            }
            let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
            backups = files.filter { $0.lastPathComponent.hasPrefix("backup-") }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                .prefix(20).compactMap { url in
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
                          let data = try? Data(contentsOf: url) else { return nil }; return try? HomeBackup.decode(data)
                }.sorted { $0.date > $1.date }
        } catch { notice = "Saved preferences could not be loaded. Your existing file was preserved. \(error.localizedDescription)" }
    }
    func update(_ change: (inout RemotePreferences) -> Void) {
        var next = value; change(&next)
        do { try next.validate(); try JSONEncoder().encode(next).write(to: settingsURL, options: .atomic); value = next }
        catch { notice = error.localizedDescription }
    }
    var profile: HomeProfile { value.profiles.first(where: { $0.id == value.profileID }) ?? value.profiles[0] }
    var layout: HomeLayout { profile.layout }
    func editLayout(_ change: (inout HomeLayout) -> Void) {
        let id = profile.id
        update { settings in if let index = settings.profiles.firstIndex(where: { $0.id == id }) { change(&settings.profiles[index].layout) } }
    }
    func app(_ id: String) -> RemoteApp? { value.apps.first { $0.id == id } }
    var remoteApps: [RemoteApp] { Array(value.remoteOrder.compactMap(app).prefix(value.remoteCount)) }
    func merge(_ snapshot: LauncherSnapshot, host: String) {
        update { settings in
            settings.tvInputs = snapshot.inputs; settings.editorHost = host
            settings.apps = snapshot.apps.map { item in
                var item = item; let known = RemoteApp.known.first(where: { $0.id == item.id }); item.logo = known?.logo; item.launchURL = known?.launchURL ?? item.launchURL; return item
            }
        }
    }
    func binding<T>(_ key: WritableKeyPath<RemotePreferences, T>) -> Binding<T> {
        Binding(get: { self.value[keyPath: key] }, set: { new in self.update { $0[keyPath: key] = new } })
    }
    func layoutBinding<T>(_ key: WritableKeyPath<HomeLayout, T>) -> Binding<T> {
        Binding(get: { self.layout[keyPath: key] }, set: { new in self.editLayout { $0[keyPath: key] = new } })
    }
    func addProfile(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, !value.profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            notice = "Choose a unique profile name, up to 60 characters."; return
        }
        let new = HomeProfile(name: name, layout: layout)
        update { $0.profiles.append(new); $0.profileID = new.id }
    }
    func photoURL(_ id: String) -> URL? { HomeLayout.validPhoto(id) ? directory.appendingPathComponent(id + ".jpg") : nil }
    func wallpaperData(_ layout: HomeLayout) -> Data? { photoURL(layout.wallpaper).flatMap { try? Data(contentsOf: $0) } }
    func importPhoto(_ data: Data) throws -> String {
        guard data.count <= 40_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1920, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw RemoteFailure.message("Choose a supported image under 40 MB")
        }
        var encoded: Data?
        for quality in [0.85, 0.7, 0.55, 0.4] {
            let result = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), result.length <= 1_000_000 { encoded = result as Data; break }
        }
        guard let encoded else { throw RemoteFailure.message("Could not fit this wallpaper within 1 MB") }
        let id = "photo-" + UUID().uuidString
        try encoded.write(to: photoURL(id)!, options: .atomic)
        return id
    }
    /// The uncropped photo a wallpaper was made from, kept on this iPhone only so the framing can be changed later.
    func sourceURL(_ id: String) -> URL? { HomeLayout.validPhoto(id) ? directory.appendingPathComponent(id + "-source.jpg") : nil }
    /// The photo to frame for this wallpaper: its saved original, or the wallpaper itself for older ones.
    func framingSource(_ id: String) -> UIImage? {
        if let url = sourceURL(id), let image = UIImage(contentsOfFile: url.path) { return image }
        return photoURL(id).flatMap { UIImage(contentsOfFile: $0.path) }
    }
    /// Loads a picked photo for framing: upright and at most 2560 px, enough detail to zoom in.
    static func framingImage(_ data: Data) throws -> UIImage {
        guard data.count <= 40_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2560, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw RemoteFailure.message("Choose a supported image under 40 MB")
        }
        return UIImage(cgImage: image)
    }
    /// Saves the framed part of `source` (a rect in its pixels) as a new 16:9 wallpaper, keeping the original for
    /// later changes. Returns the new wallpaper ID.
    func saveFramedPhoto(_ source: UIImage, crop: CGRect) throws -> String {
        guard let cg = source.cgImage, let part = cg.cropping(to: crop.integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))) else {
            throw RemoteFailure.message("Could not frame this photo")
        }
        let size = CGSize(width: 1920, height: 1080)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let framed = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: part).draw(in: CGRect(origin: .zero, size: size))
        }
        var encoded: Data?
        for quality in [0.85, 0.7, 0.55, 0.4] {
            if let data = framed.jpegData(compressionQuality: quality), data.count <= 1_000_000 { encoded = data; break }
        }
        guard let encoded, let original = source.jpegData(compressionQuality: 0.85) else { throw RemoteFailure.message("Could not fit this wallpaper within 1 MB") }
        let id = "photo-" + UUID().uuidString
        try encoded.write(to: photoURL(id)!, options: .atomic)
        try original.write(to: sourceURL(id)!, options: .atomic)
        return id
    }
    @discardableResult func backup(name: String? = nil) throws -> HomeBackup {
        let backup = HomeBackup(name: name ?? profile.name + " · Home backup", layout: layout, wallpaperJPEG: wallpaperData(layout))
        _ = try HomeBackup.decode(JSONEncoder().encode(backup))
        try JSONEncoder().encode(backup).write(to: directory.appendingPathComponent("backup-\(backup.id).json"), options: .atomic)
        backups.insert(backup, at: 0); backups = Array(backups.prefix(20))
        return backup
    }
    func restore(_ backup: HomeBackup) throws {
        _ = try HomeBackup.decode(JSONEncoder().encode(backup))
        var layout = backup.layout
        if let image = backup.wallpaperJPEG { layout.wallpaper = try importPhoto(image) }
        editLayout { $0 = layout }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(_ backup: HomeBackup) throws { data = try JSONEncoder().encode(backup) }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw RemoteFailure.message("This backup is empty") }
        _ = try HomeBackup.decode(data); self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
