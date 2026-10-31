import Foundation

/// A supported TV: upstream's tested debloat.txt plus what the app needs to run it alone (Resources/Profiles/README.md).
public struct DebloatProfile: Identifiable, Equatable {
    public struct Manifest: Codable, Equatable {
        public var id: String
        public var name: String
        public var source: String
        public var developmentOnly: Bool?
        public var match: [String: [String]]
        public var stockLauncher: String?
        public var launcher: LauncherOptions
        public var dockCandidates: [String]
    }
    public var id: String { manifest.id }
    public let manifest: Manifest
    public let list: DebloatList
    /// The launcher's config.json for this TV, without dock_apps (filled in from what the user keeps).
    public let theme: [String: Any]
    public let notes: String

    public static func == (a: DebloatProfile, b: DebloatProfile) -> Bool { a.manifest == b.manifest && a.list == b.list }

    public init(manifest: Manifest, list: DebloatList, theme: [String: Any], notes: String = "") {
        self.manifest = manifest; self.list = list; self.theme = theme; self.notes = notes
    }

    /// Every property in `match` must be one of its listed values.
    public func matches(_ properties: [String: String]) -> Bool {
        !manifest.match.isEmpty && manifest.match.allSatisfy { key, values in
            guard let value = properties[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return values.contains(value)
        }
    }

    /// config.json for the launcher: the profile's theme with the dock the user chose.
    public func themeConfig(dock: [String]) throws -> Data {
        var config = theme
        config["dock_apps"] = dock.filter(Pattern.isPackage)
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    /// Reads one profile folder: profile.json, debloat.txt and (optional) tv.json.
    public static func load(_ folder: URL) throws -> DebloatProfile {
        let data = try Data(contentsOf: folder.appendingPathComponent("profile.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let list = try DebloatList.parse(String(decoding: try Data(contentsOf: folder.appendingPathComponent("debloat.txt")), as: UTF8.self))
        var notes = ""
        if let tv = try? Data(contentsOf: folder.appendingPathComponent("tv.json")),
           let json = try? JSONSerialization.jsonObject(with: tv) as? [String: Any] { notes = json["notes"] as? String ?? "" }
        return DebloatProfile(manifest: manifest, list: list, theme: object["theme"] as? [String: Any] ?? [:], notes: notes)
    }

    /// All profiles under a folder (the app's bundled Profiles), skipping development ones unless asked.
    public static func loadAll(_ root: URL, includeDevelopment: Bool) -> [DebloatProfile] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.compactMap { try? load($0) }
            .filter { includeDevelopment || $0.manifest.developmentOnly != true }
            .sorted { $0.manifest.name < $1.manifest.name }
    }

    public static func match(_ properties: [String: String], in profiles: [DebloatProfile]) -> DebloatProfile? {
        profiles.first { $0.matches(properties) }
    }
}
