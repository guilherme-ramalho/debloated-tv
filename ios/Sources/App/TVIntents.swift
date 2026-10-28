import Foundation
import AppIntents

enum TVQuickCommand: String, AppEnum {
    case wake, sleep, home, pause, mute, volumeUp, volumeDown, netflix, youtube, prime, disney, max, crunchyroll
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "TV action")
    static var caseDisplayRepresentations: [TVQuickCommand: DisplayRepresentation] = [
        .wake:"Wake TV", .sleep:"Turn off TV", .home:"TV Home", .pause:"Pause TV", .mute:"Mute TV",
        .volumeUp:"Volume up", .volumeDown:"Volume down", .netflix:"Open Netflix", .youtube:"Open YouTube",
        .prime:"Open Prime Video", .disney:"Open Disney+", .max:"Open HBO Max", .crunchyroll:"Open Crunchyroll"
    ]
    var steps: [ActionStep] {
        switch self {
        case .wake: return [.init(.wake)]
        case .sleep: return [.init(.sleep)]
        case .home: return [.init(.home)]
        case .pause: return [.init(.pause)]
        case .mute: return [.init(.mute)]
        case .volumeUp: return [.init(.volumeUp)]
        case .volumeDown: return [.init(.volumeDown)]
        case .netflix: return [.init(.wake), .init(.openApp, argument: "com.netflix.ninja")]
        case .youtube: return [.init(.wake), .init(.openApp, argument: "com.google.android.youtube.tv")]
        case .prime: return [.init(.wake), .init(.openApp, argument: "com.amazon.amazonvideo.livingroom")]
        case .disney: return [.init(.wake), .init(.openApp, argument: "com.disney.disneyplus")]
        case .max: return [.init(.wake), .init(.openApp, argument: "com.wbd.stream")]
        case .crunchyroll: return [.init(.wake), .init(.openApp, argument: "com.crunchyroll.crunchyroid")]
        }
    }
}

#if !WIDGET_EXTENSION
enum IntentSettings {
    static func read() throws -> RemotePreferences {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVRemote/preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw RemoteFailure.message("Open Debloated TV once to finish setup") }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw RemoteFailure.message("Open Debloated TV to check its saved settings") }
        let settings = try JSONDecoder().decode(RemotePreferences.self, from: data); try settings.validate(); return settings
    }
    @MainActor static func run(_ steps: [ActionStep]) async throws {
        let host = UserDefaults.standard.string(forKey: "tvHost") ?? ""
        guard !host.isEmpty else { throw RemoteFailure.message("Open Debloated TV and pair your TV first") }
        let settings = try read()
        let runner = CommandRunner()
        try await runner.run(steps, host: host, apps: settings.apps, inputs: settings.editorHost == host ? settings.tvInputs : [])
    }
}

#endif

struct TVCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Control TV"
    static var description = IntentDescription("Send one action to your paired TV over the local network.")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Action") var command: TVQuickCommand
    init() {}
    init(command: TVQuickCommand) { self.command = command }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        throw RemoteFailure.message("Open Debloated TV once to finish setup")
        #else
        try await IntentSettings.run(command.steps)
        #endif
        return .result(dialog: "Sent to your TV.")
    }
}

// Routes interactive widget/control actions to the main app's background process, where the
// existing pairing identity lives. No shared private keys, App Group or foreground UI is needed.
@available(iOSApplicationExtension, unavailable)
extension TVCommandIntent: ForegroundContinuableIntent {}

#if !WIDGET_EXTENSION
struct SavedTVAction: AppEntity {
    var id: String
    var name: String
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "TV quick action")
    static var defaultQuery = SavedTVActionQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct SavedTVActionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SavedTVAction] {
        try IntentSettings.read().actions.filter { identifiers.contains($0.id.uuidString) }.map { SavedTVAction(id: $0.id.uuidString, name: $0.name) }
    }
    func suggestedEntities() async throws -> [SavedTVAction] {
        try IntentSettings.read().actions.map { SavedTVAction(id: $0.id.uuidString, name: $0.name) }
    }
}
struct RunTVQuickActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Run TV Quick Action"
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Quick action") var action: SavedTVAction
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let saved = try IntentSettings.read().actions.first(where: { $0.id.uuidString == action.id }) else { throw RemoteFailure.message("This quick action no longer exists") }
        try saved.validate(); try await IntentSettings.run(saved.steps)
        return .result(dialog: "Sent \(saved.name) to your TV.")
    }
}
extension RunTVQuickActionIntent: ForegroundContinuableIntent {}

struct TVAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TVCommandIntent(command: .wake), phrases: ["Turn on the TV with \(.applicationName)", "Wake the TV with \(.applicationName)"], shortTitle: "Wake TV", systemImageName: "power")
        AppShortcut(intent: TVCommandIntent(command: .sleep), phrases: ["Turn off the TV with \(.applicationName)"], shortTitle: "Turn off TV", systemImageName: "moon")
        AppShortcut(intent: TVCommandIntent(command: .netflix), phrases: ["Open Netflix with \(.applicationName)"], shortTitle: "Open Netflix", systemImageName: "play.rectangle")
        AppShortcut(intent: TVCommandIntent(command: .youtube), phrases: ["Open YouTube with \(.applicationName)"], shortTitle: "Open YouTube", systemImageName: "play.rectangle")
        AppShortcut(intent: TVCommandIntent(command: .pause), phrases: ["Pause the TV with \(.applicationName)"], shortTitle: "Pause TV", systemImageName: "pause")
    }
}
#endif
