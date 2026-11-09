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
    let entry: RemoteEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Purio TV").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
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
/// 1.1: a D-pad remote on the Home Screen (medium). Each tap is one App Intent: the app connects, sends the key and
/// lets go, so there's a short delay per press and nothing runs in the background between taps.
struct PadEntry: TimelineEntry { let date: Date }
struct PadProvider: TimelineProvider {
    func placeholder(in context: Context) -> PadEntry { PadEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (PadEntry) -> Void) { completion(PadEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PadEntry>) -> Void) {
        completion(Timeline(entries: [PadEntry(date: .now)], policy: .never))
    }
}
struct PadWidgetView: View {
    let entry: PadEntry
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(.white.opacity(0.07))
                key(.up, size: CGSize(width: 46, height: 34)).offset(y: -45)
                key(.down, size: CGSize(width: 46, height: 34)).offset(y: 45)
                key(.left, size: CGSize(width: 34, height: 46)).offset(x: -45)
                key(.right, size: CGSize(width: 34, height: 46)).offset(x: 45)
                Button(intent: TVCommandIntent(command: .select)) {
                    Text("OK").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 50, height: 50).background(.white.opacity(0.14), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel(Text("OK"))
            }.frame(width: 132, height: 132)
            VStack(alignment: .leading, spacing: 8) {
                Text("Purio TV").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { tile(.power, tint: Color(red: 1, green: 0.34, blue: 0.38)); tile(.home) }
                    GridRow { tile(.volumeDown); tile(.volumeUp) }
                }
            }
        }.containerBackground(Color(red: 0.04, green: 0.08, blue: 0.14), for: .widget)
    }
    private func key(_ command: TVQuickCommand, size: CGSize) -> some View {
        Button(intent: TVCommandIntent(command: command)) {
            Image(systemName: command.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size.width, height: size.height).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Text(command.label))
    }
    private func tile(_ command: TVQuickCommand, tint: Color = .white) -> some View {
        Button(intent: TVCommandIntent(command: command)) {
            Image(systemName: command.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint == .white ? .white : tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background((tint == .white ? Color.white.opacity(0.09) : tint.opacity(0.2)), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel(Text(command.label))
    }
}
struct PadWidget: Widget {
    let kind = "TVRemote.Pad"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PadProvider()) { PadWidgetView(entry: $0) }
            .configurationDisplayName("Remote").description("Arrows, OK, power, Home and volume for your paired TV.")
            .supportedFamilies([.systemMedium])
    }
}

/// 1.1: one button on the Lock Screen (circular), e.g. TV power.
struct LockButtonConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "TV button"
    static var description = IntentDescription("One control for your paired TV.")
    @Parameter(title: "Action", default: .power) var command: TVQuickCommand
}
struct LockButtonEntry: TimelineEntry {
    let date: Date
    let configuration: LockButtonConfiguration
}
struct LockButtonProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LockButtonEntry { LockButtonEntry(date: .now, configuration: .init()) }
    func snapshot(for configuration: LockButtonConfiguration, in context: Context) async -> LockButtonEntry { LockButtonEntry(date: .now, configuration: configuration) }
    func timeline(for configuration: LockButtonConfiguration, in context: Context) async -> Timeline<LockButtonEntry> {
        Timeline(entries: [LockButtonEntry(date: .now, configuration: configuration)], policy: .never)
    }
}
struct LockButtonView: View {
    let entry: LockButtonEntry
    var body: some View {
        Button(intent: TVCommandIntent(command: entry.configuration.command)) {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: entry.configuration.command.symbol).font(.system(size: 20, weight: .semibold))
            }
        }.buttonStyle(.plain).accessibilityLabel(Text(entry.configuration.command.label))
            .containerBackground(.clear, for: .widget)
    }
}
struct LockButtonWidget: Widget {
    let kind = "TVRemote.LockButton"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LockButtonConfiguration.self, provider: LockButtonProvider()) { LockButtonView(entry: $0) }
            .configurationDisplayName("TV button").description("One control for your paired TV on the Lock Screen.")
            .supportedFamilies([.accessoryCircular])
    }
}

/// 1.1: one of your quick actions ("Movie night") on the Home Screen (small) or Lock Screen (circle). The names come
/// from the app through the App Group; tapping Run asks the app to run the steps, as Siri does.
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
    @Environment(\.widgetFamily) private var family
    let entry: QuickActionEntry
    var body: some View {
        Group {
            if family == .accessoryCircular { circle } else { card }
        }
    }
    private var circle: some View {
        Group {
            if let action = entry.action {
                Button(intent: RunTVQuickActionIntent(action: action)) {
                    ZStack { AccessoryWidgetBackground(); Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold)) }
                }.buttonStyle(.plain).accessibilityLabel(Text(verbatim: action.name))
            } else {
                ZStack { AccessoryWidgetBackground(); Image(systemName: "movieclapper").font(.system(size: 18)) }
            }
        }.containerBackground(.clear, for: .widget)
    }
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
            .supportedFamilies([.systemSmall, .accessoryCircular])
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
        PadWidget()
        QuickActionWidget()
        LockButtonWidget()
        if #available(iOS 18.0, *) { RemoteControl() }
    }
}
