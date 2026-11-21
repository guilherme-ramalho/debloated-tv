import Foundation

/// The assistant's vocabulary (App: Assistant.swift, on Apple's on-device model): the key names the model may use,
/// the words people say for them, and finding an app by the name someone says. Kept here, without the model, so it
/// can be tested.
public enum AssistantCommands {
    /// The names offered to the model, in the order it sees them.
    public static let keyNames = ["up", "down", "left", "right", "ok", "back", "home", "playPause", "play", "pause",
                                  "rewind", "fastForward", "volumeUp", "volumeDown", "mute", "subtitles", "settings", "inputs", "channelUp", "channelDown"]

    public static func key(named name: String) -> TVKey? {
        switch name.lowercased().filter({ $0.isLetter }) {
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        case "ok", "select", "enter", "center": .select
        case "back", "return": .back
        case "home": .home
        case "playpause", "toggle": .playPause
        case "play", "resume": .play
        case "pause", "stop": .pause
        case "rewind", "back10", "skipback": .rewind
        case "fastforward", "forward", "skipforward": .fastForward
        case "volumeup", "louder": .volumeUp
        case "volumedown", "quieter": .volumeDown
        case "mute", "unmute": .mute
        case "subtitles", "captions", "cc": .captions
        case "settings", "menu", "options": .settings
        case "inputs", "input", "source", "hdmi": .inputs
        case "channelup", "nextchannel": .channelUp
        case "channeldown", "previouschannel": .channelDown
        default: nil
        }
    }

    /// How many times to press: 1 to 10, whatever the model asked.
    public static func times(_ asked: Int) -> Int { min(max(asked, 1), 10) }

    /// The app someone named, among the remote's apps (same rules as on Roku/LG/Samsung TVs).
    public static func app(named name: String, in apps: [RemoteApp]) -> RemoteApp? {
        let candidates = apps.map { BrandApp(id: $0.id, name: $0.name) }
        guard let found = BrandApps.match(name, in: candidates) else { return nil }
        return apps.first { $0.id == found.id }
    }
}
