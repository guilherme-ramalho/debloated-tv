import Foundation

public struct RemoteApp: Codable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var launchURL: String
    public var logo: String?
    public var installed: Bool?
    public var system: Bool
    public init(id: String, name: String, launchURL: String, logo: String? = nil, installed: Bool? = nil, system: Bool = false) {
        self.id = id; self.name = name; self.launchURL = launchURL; self.logo = logo; self.installed = installed; self.system = system
    }
    public static let known: [RemoteApp] = [
        .init(id: "com.netflix.ninja", name: "Netflix", launchURL: "https://www.netflix.com/title", logo: "NetflixLogo"),
        .init(id: "com.google.android.youtube.tv", name: "YouTube", launchURL: "https://www.youtube.com", logo: "YouTubeLogo"),
        .init(id: "com.amazon.amazonvideo.livingroom", name: "Prime Video", launchURL: "https://app.primevideo.com", logo: "PrimeVideoLogo"),
        .init(id: "com.disney.disneyplus", name: "Disney+", launchURL: "https://www.disneyplus.com", logo: "DisneyPlusLogo"),
        .init(id: "com.wbd.stream", name: "HBO Max", launchURL: "https://play.max.com", logo: "HBOMaxLogo"),
        .init(id: "com.crunchyroll.crunchyroid", name: "Crunchyroll", launchURL: "crunchyroll://", logo: "CrunchyrollLogo"),
        .init(id: "com.spotify.tv.android", name: "Spotify", launchURL: "spotify:"),
        .init(id: "com.surfshark.vpnclient.android", name: "Surfshark", launchURL: "intent:#Intent;action=android.intent.action.MAIN;category=android.intent.category.LEANBACK_LAUNCHER;package=com.surfshark.vpnclient.android;end"),
        .init(id: "live.abplayer.brsilveira", name: "AB Player", launchURL: "intent:#Intent;action=android.intent.action.MAIN;category=android.intent.category.LEANBACK_LAUNCHER;package=live.abplayer.brsilveira;end")
    ]
    public static func validPackage(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 180 && value.range(of: "^[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+$", options: .regularExpression) != nil
    }
}

public struct HomeLayout: Codable, Equatable {
    public var dockCount = 5
    public var order = RemoteApp.known.map(\.id)
    public var hidden: [String] = []
    public var wallpaper = "quiet-night"
    public init() {}
    public var dock: [String] { Array(order.filter { !hidden.contains($0) }.prefix(dockCount)) }
    public func validate() throws {
        guard (1...7).contains(dockCount), order.count <= 200, hidden.count <= 200,
              Set(order).count == order.count, Set(hidden).count == hidden.count,
              (order + hidden).allSatisfy(RemoteApp.validPackage),
              ["quiet-night", "aurora", "dusk"].contains(wallpaper) || Self.validPhoto(wallpaper) else {
            throw RemoteFailure.message("Invalid TV Home layout")
        }
    }
    public static func validPhoto(_ value: String) -> Bool {
        value.hasPrefix("photo-") && UUID(uuidString: String(value.dropFirst(6))) != nil
    }
}
public struct HomeProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var layout: HomeLayout
    public init(name: String, layout: HomeLayout = .init()) { id = UUID(); self.name = name; self.layout = layout }
}
public struct FavoriteInput: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var inputID: String?
    public init(name: String, inputID: String? = nil) { self.name = name; self.inputID = inputID }
}
public struct TVInput: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var launchURL: String
}
public struct ActionStep: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, CaseIterable { case wake, sleep, openApp, input, home, mute, playPause, pause, volumeUp, volumeDown }
    public var id = UUID()
    public var kind: Kind
    public var argument: String
    public init(_ kind: Kind, argument: String = "") { self.kind = kind; self.argument = argument }
}
public struct QuickAction: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var steps: [ActionStep]
    public init(name: String, steps: [ActionStep]) { self.name = name; self.steps = steps }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 60, (1...12).contains(steps.count),
              steps.allSatisfy({ $0.argument.utf8.count <= 1024 && ($0.kind != .openApp || RemoteApp.validPackage($0.argument)) && ($0.kind != .input || !$0.argument.isEmpty) }),
              !steps.dropLast().contains(where: { $0.kind == .sleep }) else {
            throw RemoteFailure.message("An action needs a name and between 1 and 12 valid steps.")
        }
    }
}
public struct HomeBackup: Codable, Identifiable, Equatable {
    public let version: Int
    public var id: UUID
    public var name: String
    public var date: Date
    public var layout: HomeLayout
    public var wallpaperJPEG: Data?
    public init(name: String, layout: HomeLayout, wallpaperJPEG: Data? = nil) {
        version = 1; id = UUID(); self.name = name; date = Date(); self.layout = layout; self.wallpaperJPEG = wallpaperJPEG
    }
    public static func decode(_ data: Data) throws -> HomeBackup {
        guard data.count <= 2_000_000 else { throw RemoteFailure.message("Backup exceeds 2 MB") }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        try backup.layout.validate()
        guard backup.version == 1, backup.name.count <= 80, (backup.wallpaperJPEG?.count ?? 0) <= 1_000_000,
              !HomeLayout.validPhoto(backup.layout.wallpaper) || backup.wallpaperJPEG != nil else {
            throw RemoteFailure.message("Unsupported or incomplete backup")
        }
        return backup
    }
}
public struct RemotePreferences: Codable, Equatable {
    public var version = 1
    public var remoteOrder = Array(RemoteApp.known.prefix(6).map(\.id))
    public var remoteCount = 6
    public var haptics = true
    public var autoReconnect = true
    public var profiles = [HomeProfile(name: "Personal"), HomeProfile(name: "Family")]
    public var profileID: UUID?
    public var inputs = [FavoriteInput(name: "PlayStation 5"), FavoriteInput(name: "Nintendo Switch")]
    public var actions = [QuickAction(name: "Movie time", steps: [.init(.wake), .init(.openApp, argument: "com.netflix.ninja")])]
    public var apps = RemoteApp.known
    public var tvInputs: [TVInput] = []
    public var editorHost: String?
    public init() { profileID = profiles.first?.id }
    public func validate() throws {
        guard version == 1, (1...12).contains(remoteCount), remoteOrder.count <= 200, Set(remoteOrder).count == remoteOrder.count,
              remoteOrder.allSatisfy(RemoteApp.validPackage), (1...20).contains(profiles.count), actions.count <= 30, inputs.count <= 20,
              apps.count <= 200, apps.allSatisfy({ RemoteApp.validPackage($0.id) && $0.name.count <= 120 && $0.launchURL.utf8.count <= 2048 }),
              inputs.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 60 }),
              profiles.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 60 }),
              tvInputs.count <= 40, tvInputs.allSatisfy({ $0.id.utf8.count <= 512 && $0.name.count <= 120 && $0.launchURL.utf8.count <= 2048 }),
              Set(profiles.map(\.id)).count == profiles.count else { throw RemoteFailure.message("Invalid remote preferences") }
        for profile in profiles { try profile.layout.validate() }
        for action in actions { try action.validate() }
    }
}

public struct LauncherSnapshot: Codable {
    public let revision: String
    public let layout: HomeLayout
    public let apps: [RemoteApp]
    public let inputs: [TVInput]
    public let sleepDeadline: Double?
    public let wallpaperJPEG: Data?
    public func validate() throws {
        try layout.validate()
        guard revision.count <= 120, apps.count <= 200, inputs.count <= 40, (wallpaperJPEG?.count ?? 0) <= 1_000_000,
              apps.allSatisfy({ RemoteApp.validPackage($0.id) && $0.name.count <= 120 && $0.launchURL.utf8.count <= 2048 }),
              inputs.allSatisfy({ $0.id.utf8.count <= 512 && $0.name.count <= 120 && $0.launchURL.utf8.count <= 2048 }) else { throw RemoteFailure.message("Invalid TV editor response") }
    }
}
