import SwiftUI
import WidgetKit
import AppIntents

struct RemoteWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "TV controls"
    static var description = IntentDescription("Choose four controls for your paired TV.")
    @Parameter(title: "Top left", default: .wake) var first: TVQuickCommand
    @Parameter(title: "Top right", default: .sleep) var second: TVQuickCommand
    @Parameter(title: "Bottom left", default: .netflix) var third: TVQuickCommand
    @Parameter(title: "Bottom right", default: .youtube) var fourth: TVQuickCommand
}
struct RemoteEntry: TimelineEntry {
    let date: Date
    let configuration: RemoteWidgetConfiguration
}
struct RemoteProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RemoteEntry { RemoteEntry(date: .now, configuration: .init()) }
    func snapshot(for configuration: RemoteWidgetConfiguration, in context: Context) async -> RemoteEntry { RemoteEntry(date: .now, configuration: configuration) }
    func timeline(for configuration: RemoteWidgetConfiguration, in context: Context) async -> Timeline<RemoteEntry> {
        Timeline(entries: [RemoteEntry(date: .now, configuration: configuration)], policy: .never)
    }
}
extension TVQuickCommand {
    var symbol: String {
        switch self {
        case .wake: return "power"
        case .sleep: return "moon"
        case .home: return "house"
        case .pause: return "pause"
        case .mute: return "speaker.slash"
        case .volumeUp: return "speaker.plus"
        case .volumeDown: return "speaker.minus"
        case .power: return "power"
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        case .select: return "circle.circle"
        case .back: return "arrow.uturn.backward"
        default: return "play.rectangle"
        }
    }
    var label: String {
        switch self {
        case .wake: return String(localized: "Wake")
        case .sleep: return String(localized: "Off")
        case .home: return String(localized: "Home")
        case .pause: return String(localized: "Pause")
        case .mute: return String(localized: "Mute")
        case .volumeUp: return String(localized: "Volume up")
        case .volumeDown: return String(localized: "Volume down")
        case .netflix: return "Netflix"
        case .youtube: return "YouTube"
        case .prime: return "Prime Video"
        case .disney: return "Disney+"
        case .max: return "HBO Max"
        case .crunchyroll: return "Crunchyroll"
        case .power: return String(localized: "Power")
        case .up: return String(localized: "Up")
        case .down: return String(localized: "Down")
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        case .select: return String(localized: "OK")
        case .back: return String(localized: "Back")
        }
    }
}
struct RemoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RemoteEntry
    private var commands: [TVQuickCommand] {
        [entry.configuration.first, entry.configuration.second, entry.configuration.third, entry.configuration.fourth]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 10 : 8) {
            Text("Purio TV").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            if family == .systemMedium {
                // One row of four bigger buttons: each tap is a single action (1.1: no D-pad, navigation is the app's).
                HStack(spacing: 8) { ForEach(commands.indices, id: \.self) { control(commands[$0], large: true) } }
            } else {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { control(commands[0]); control(commands[1]) }
                    GridRow { control(commands[2]); control(commands[3]) }
                }
            }
        }.containerBackground(Color(red: 0.025, green: 0.06, blue: 0.12), for: .widget)
    }
    func control(_ command: TVQuickCommand, large: Bool = false) -> some View {
        Button(intent: TVCommandIntent(command: command)) {
            VStack(spacing: large ? 6 : 4) {
                Image(systemName: command.symbol).font(.system(size: large ? 20 : 16, weight: .semibold))
                Text(command.label).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(command.isPower ? Color(red: 1, green: 0.6, blue: 0.63) : .white)
        }.buttonStyle(.plain).padding(4)
            .background(command.isPower ? Color(red: 1, green: 0.34, blue: 0.38).opacity(0.22) : .white.opacity(0.09), in: RoundedRectangle(cornerRadius: large ? 16 : 12))
    }
}
extension TVQuickCommand {
    var isPower: Bool { self == .wake || self == .power }
}
struct RemoteWidget: Widget {
    let kind = "TVRemote.Controls"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: RemoteWidgetConfiguration.self, provider: RemoteProvider()) { RemoteWidgetView(entry: $0) }
            .configurationDisplayName("TV controls").description("Four one-tap actions for your paired TV. No background polling.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
/// 1.1: one of your quick actions ("Movie night") on the Home Screen (small). The names come from the app through the
/// App Group; tapping Run asks the app to run the steps, as Siri does. No Lock Screen version in 1.1: a round Lock
/// Screen widget only opened the app on the TCL test (9 Nov 2026).
struct QuickActionConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Quick action"
    static var description = IntentDescription("Run one of your quick actions.")
    @Parameter(title: "Quick action") var action: SavedTVAction?
}
struct QuickActionEntry: TimelineEntry {
    let date: Date
    let action: SavedTVAction?
}
struct QuickActionProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickActionEntry {
        QuickActionEntry(date: .now, action: SavedTVAction(id: "", name: String(localized: "Movie night"), summary: String(localized: "Wake TV · Open Netflix")))
    }
    func snapshot(for configuration: QuickActionConfiguration, in context: Context) async -> QuickActionEntry { entry(configuration) }
    func timeline(for configuration: QuickActionConfiguration, in context: Context) async -> Timeline<QuickActionEntry> {
        Timeline(entries: [entry(configuration)], policy: .never)   // the app reloads it when actions change
    }
    /// The chosen action as the app last shared it (a rename shows up), or the first one while none is chosen.
    private func entry(_ configuration: QuickActionConfiguration) -> QuickActionEntry {
        let shared = SharedActions.read()
        let found = configuration.action.flatMap { chosen in shared.first { $0.id == chosen.id } } ?? (configuration.action == nil ? shared.first : nil)
        return QuickActionEntry(date: .now, action: found.map { SavedTVAction(id: $0.id, name: $0.name, summary: $0.summary) })
    }
}
struct QuickActionView: View {
    let entry: QuickActionEntry
    var body: some View { card }
    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "movieclapper").font(.system(size: 18, weight: .medium)).foregroundStyle(Color(red: 154/255, green: 227/255, blue: 236/255))
            if let action = entry.action {
                Text(verbatim: action.name).font(.headline).foregroundStyle(.white).lineLimit(2)
                Text(verbatim: action.summary).font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                Spacer(minLength: 0)
                Button(intent: RunTVQuickActionIntent(action: action)) {
                    Label("Run", systemImage: "play.fill").font(.caption.weight(.semibold)).foregroundStyle(Color(red: 14/255, green: 17/255, blue: 22/255))
                        .frame(maxWidth: .infinity, minHeight: 30).background(Color(red: 154/255, green: 227/255, blue: 236/255), in: Capsule())
                }.buttonStyle(.plain)
            } else {
                Text("No quick actions yet").font(.headline).foregroundStyle(.white)
                Text("Create one in the app's Actions tab.").font(.caption2).foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(Color(red: 0.04, green: 0.08, blue: 0.14), for: .widget)
    }
}
struct QuickActionWidget: Widget {
    let kind = "TVRemote.QuickAction"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: QuickActionConfiguration.self, provider: QuickActionProvider()) { QuickActionView(entry: $0) }
            .configurationDisplayName("Quick action").description("Run one of your quick actions, like Movie night.")
            .supportedFamilies([.systemSmall])
    }
}

@available(iOS 18.0, *)
struct RemoteControlConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "TV action"
    @Parameter(title: "Action", default: .wake) var command: TVQuickCommand
}
@available(iOS 18.0, *)
struct RemoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "TVRemote.Action", intent: RemoteControlConfiguration.self) { configuration in
            ControlWidgetButton(action: TVCommandIntent(command: configuration.command)) {
                Label(configuration.command.label, systemImage: configuration.command.symbol)
            }
        }.displayName("TV action").description("Send an action to your paired TV.")
    }
}
@main struct TVRemoteWidgetBundle: WidgetBundle {
    var body: some Widget {
        RemoteWidget()
        QuickActionWidget()
        if #available(iOS 18.0, *) { RemoteControl() }
    }
}
