import Foundation
import AppIntents

enum TVQuickCommand: String, AppEnum {
    case wake, sleep, home, pause, mute, volumeUp, volumeDown, netflix, youtube, prime, disney, max, crunchyroll
    // 1.1: single remote keys, for the D-pad widget and Lock Screen / Control Center buttons.
    case power, up, down, left, right, select, back
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "TV action")
    static var caseDisplayRepresentations: [TVQuickCommand: DisplayRepresentation] = [
        .wake:"Wake TV", .sleep:"Turn off TV", .home:"TV Home", .pause:"Pause TV", .mute:"Mute TV",
        .volumeUp:"Volume up", .volumeDown:"Volume down", .netflix:"Open Netflix", .youtube:"Open YouTube",
        .prime:"Open Prime Video", .disney:"Open Disney+", .max:"Open HBO Max", .crunchyroll:"Open Crunchyroll",
        .power:"TV power (on or off)", .up:"Up", .down:"Down", .left:"Left", .right:"Right", .select:"OK", .back:"Back"
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
        case .power: return [.init(key: .power)]
        case .up: return [.init(key: .up)]
        case .down: return [.init(key: .down)]
        case .left: return [.init(key: .left)]
        case .right: return [.init(key: .right)]
        case .select: return [.init(key: .select)]
        case .back: return [.init(key: .back)]
        }
    }
}

#if !WIDGET_EXTENSION
enum IntentSettings {
    static func read() throws -> RemotePreferences {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVRemote/preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw RemoteFailure.message(String(localized: "Open Purio TV once to finish setup")) }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw RemoteFailure.message(String(localized: "Open Purio TV to check its saved settings")) }
        let settings = try JSONDecoder().decode(RemotePreferences.self, from: data); try settings.validate(); return settings
    }
    @MainActor static func run(_ steps: [ActionStep]) async throws {
        let host = UserDefaults.standard.string(forKey: "tvHost") ?? ""
        guard !host.isEmpty else { throw RemoteFailure.message(String(localized: "Open Purio TV and pair your TV first")) }
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
        throw RemoteFailure.message(String(localized: "Open Purio TV once to finish setup"))
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

/// The quick actions' names and step summaries, shared with the widgets through the App Group (1.1). Only names and
/// IDs: the steps run in the app, which reads its own preferences; no pairing keys are shared.
struct SharedAction: Codable, Equatable {
    let id: String
    let name: String
    let summary: String
}
enum SharedActions {
    static var url: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PurioAppGroup") as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appendingPathComponent("quick-actions.json")
    }
    static func read() -> [SharedAction] {
        guard let url, let data = try? Data(contentsOf: url), data.count <= 200_000,
              let list = try? JSONDecoder().decode([SharedAction].self, from: data) else { return [] }
        return Array(list.prefix(30))
    }
    /// Writes only when something changed, so saving settings doesn't wake the widgets for nothing.
    @discardableResult static func write(_ list: [SharedAction]) -> Bool {
        guard let url, list != read(), let data = try? JSONEncoder().encode(list) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

struct SavedTVAction: AppEntity {
    var id: String
    var name: String
    var summary: String = ""
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "TV quick action")
    static var defaultQuery = SavedTVActionQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct SavedTVActionQuery: EntityQuery {
    private func all() throws -> [SavedTVAction] {
        #if WIDGET_EXTENSION
        return SharedActions.read().map { SavedTVAction(id: $0.id, name: $0.name, summary: $0.summary) }
        #else
        return try IntentSettings.read().actions.map { SavedTVAction(id: $0.id.uuidString, name: $0.name) }
        #endif
    }
    func entities(for identifiers: [String]) async throws -> [SavedTVAction] { try all().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [SavedTVAction] { try all() }
}
struct RunTVQuickActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Run TV Quick Action"
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Quick action") var action: SavedTVAction
    init() {}
    init(action: SavedTVAction) { self.action = action }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await runSaved()
        return .result(dialog: "Sent \(name) to your TV.")
    }
    /// Runs the saved action and returns its name. The widget process can't run it (it continues in the app).
    private func runSaved() async throws -> String {
        #if WIDGET_EXTENSION
        throw RemoteFailure.message(String(localized: "Open Purio TV once to finish setup"))
        #else
        guard let saved = try IntentSettings.read().actions.first(where: { $0.id.uuidString == action.id }) else { throw RemoteFailure.message(String(localized: "This quick action no longer exists")) }
        try saved.validate(); try await IntentSettings.run(saved.steps)
        return saved.name
        #endif
    }
}
// Like TVCommandIntent: widget and Control Center taps run in the app's background process.
@available(iOSApplicationExtension, unavailable)
extension RunTVQuickActionIntent: ForegroundContinuableIntent {}

#if !WIDGET_EXTENSION
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
