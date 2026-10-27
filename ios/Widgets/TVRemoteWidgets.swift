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
        default: return "play.rectangle"
        }
    }
    var label: String {
        switch self {
        case .wake: return "Wake"
        case .sleep: return "Off"
        case .home: return "Home"
        case .pause: return "Pause"
        case .mute: return "Mute"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .netflix: return "Netflix"
        case .youtube: return "YouTube"
        case .prime: return "Prime Video"
        case .disney: return "Disney+"
        case .max: return "HBO Max"
        case .crunchyroll: return "Crunchyroll"
        }
    }
}
struct RemoteWidgetView: View {
    let entry: RemoteEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TV Remote").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { control(entry.configuration.first); control(entry.configuration.second) }
                GridRow { control(entry.configuration.third); control(entry.configuration.fourth) }
            }
        }.containerBackground(Color(red: 0.025, green: 0.06, blue: 0.12), for: .widget)
    }
    func control(_ command: TVQuickCommand) -> some View {
        Button(intent: TVCommandIntent(command: command)) {
            Label(command.label, systemImage: command.symbol).font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.white)
        }.buttonStyle(.plain).padding(7).background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct RemoteWidget: Widget {
    let kind = "TVRemote.Controls"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: RemoteWidgetConfiguration.self, provider: RemoteProvider()) { RemoteWidgetView(entry: $0) }
            .configurationDisplayName("TV controls").description("Four controls for your paired TV. No background polling.")
            .supportedFamilies([.systemSmall, .systemMedium])
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
        if #available(iOS 18.0, *) { RemoteControl() }
    }
}
