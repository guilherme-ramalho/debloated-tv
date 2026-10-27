import SwiftUI

enum QuietTheme {
    static let background = Color(red: 16/255, green: 29/255, blue: 50/255)
    static let panel = Color(red: 24/255, green: 37/255, blue: 58/255)
    static let muted = Color(red: 174/255, green: 185/255, blue: 204/255)
    static let cyan = Color(red: 154/255, green: 227/255, blue: 236/255)
    static let toggle = Color(red: 71/255, green: 156/255, blue: 142/255)
    static let edge = Color.white.opacity(0.07)
}
struct QuietPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) { content }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity) }
            .background(QuietTheme.background).foregroundStyle(.white)
    }
}
struct QuietHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack { Text(title).font(.system(size: 25, weight: .semibold)); Spacer(); trailing }.frame(minHeight: 44)
    }
}
struct QuietCard<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QuietTheme.panel, in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(QuietTheme.edge, lineWidth: 1))
    }
}
struct QuietRow: View {
    let title: String
    var detail: String = ""
    var symbol: String = ""
    var value: String = ""
    var chevron = true
    var body: some View {
        HStack(spacing: 11) {
            if !symbol.isEmpty { Image(systemName: symbol).font(.system(size: 20)).frame(width: 25).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 6)
            if !value.isEmpty { Text(value).font(.system(size: 12)).foregroundStyle(QuietTheme.muted) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(QuietTheme.muted) }
        }.padding(.horizontal, 13).padding(.vertical, 10).frame(minHeight: 61).contentShape(Rectangle())
    }
}
struct QuietSectionTitle: View {
    let title: String
    var body: some View { Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(QuietTheme.muted).padding(.top, 4) }
}
struct QuietCaption: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3) }
}
struct QuietPrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .medium)).foregroundStyle(Color(red: 19/255, green: 33/255, blue: 58/255))
            .frame(maxWidth: .infinity, minHeight: 48).background(Color.white.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 15))
            .opacity(enabled ? 1 : 0.45)
    }
}
struct QuietSecondaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48).background(.white.opacity(configuration.isPressed ? 0.14 : 0.045), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.08), lineWidth: 1)).opacity(enabled ? 1 : 0.45)
    }
}
struct QuietToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() } } label: {
            HStack(spacing: 14) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                Capsule().fill(configuration.isOn ? QuietTheme.toggle : Color(red: 70/255, green: 82/255, blue: 105/255))
                    .frame(width: 43, height: 26)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 20, height: 20).padding(3)
                    }
            }.contentShape(Rectangle()).frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
extension View {
    func quietNavigation(_ title: String) -> some View {
        navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbarBackground(QuietTheme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
    }
}

enum StreamingBrand {
    static func logo(_ id: String) -> String? {
        if let logo = RemoteApp.known.first(where: { $0.id == id })?.logo { return logo }
        switch id.lowercased() {
        case "com.spotify.tv.android": return "SpotifyLogo"
        case "com.apple.atve.androidtv.appletv", "com.apple.atve.sony.appletv": return "AppleTVLogo"
        case "com.cbs.ott", "com.cbs.ca": return "ParamountPlusLogo"
        case "com.plexapp.android": return "PlexLogo"
        case "tv.twitch.android.app", "tv.twitch.android.viewer": return "TwitchLogo"
        case "com.dazn": return "DAZNLogo"
        case "com.tubitv": return "TubiLogo"
        default: return nil
        }
    }
    static func color(_ id: String) -> Color {
        switch id.lowercased() {
        case "com.netflix.ninja": return Color(red: 229/255, green: 9/255, blue: 20/255)
        case "com.google.android.youtube.tv": return .red
        case "com.amazon.amazonvideo.livingroom": return Color(red: 0, green: 131/255, blue: 186/255)
        case "com.disney.disneyplus": return Color(red: 0, green: 92/255, blue: 99/255)
        case "com.crunchyroll.crunchyroid": return Color(red: 1, green: 100/255, blue: 10/255)
        case "com.spotify.tv.android": return Color(red: 23/255, green: 104/255, blue: 61/255)
        case "com.surfshark.vpnclient.android": return Color(red: 23/255, green: 110/255, blue: 120/255)
        case "live.abplayer.brsilveira": return Color(red: 41/255, green: 75/255, blue: 131/255)
        case "com.cbs.ott", "com.cbs.ca": return Color(red: 0, green: 80/255, blue: 1)
        case "tv.twitch.android.app", "tv.twitch.android.viewer": return Color(red: 100/255, green: 65/255, blue: 165/255)
        default: return Color(red: 21/255, green: 21/255, blue: 24/255)
        }
    }
}
struct StreamingLogo: View {
    let app: RemoteApp?
    var body: some View {
        if let app, let logo = StreamingBrand.logo(app.id) ?? app.logo {
            Image(logo).resizable().renderingMode(.template).scaledToFit().foregroundStyle(.white)
        } else { Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.white) }
    }
}

struct QuietCounter: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        HStack(spacing: 8) {
            Button { value = max(range.lowerBound, value - 1) } label: { Image(systemName: "minus").frame(width: 36, height: 44).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10)) }
                .disabled(value <= range.lowerBound).accessibilityLabel("Fewer " + label)
            Text("\(value)").font(.system(size: 14)).monospacedDigit().frame(minWidth: 17).accessibilityLabel("\(value) " + label)
            Button { value = min(range.upperBound, value + 1) } label: { Image(systemName: "plus").frame(width: 36, height: 44).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10)) }
                .disabled(value >= range.upperBound).accessibilityLabel("More " + label)
        }.buttonStyle(.plain).foregroundStyle(.white)
    }
}
