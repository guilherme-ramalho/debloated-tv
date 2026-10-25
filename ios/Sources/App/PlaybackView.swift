import SwiftUI

struct PlaybackView: View {
    @ObservedObject var model: RemoteModel
    @State private var code = ""
    private var state: TVPlayback? { model.playbackInfo }
    private var source: String {
        TVPlayback.appName(for: state?.packageName ?? model.foregroundPackage) ?? state?.source ?? (model.foregroundPackage.isEmpty ? "Waiting for TV…" : "Another app")
    }
    private var logo: String? { ["YouTube":"YouTubeLogo", "Netflix":"NetflixLogo", "Prime Video":"PrimeVideoLogo", "Disney+":"DisneyPlusLogo", "HBO Max":"HBOMaxLogo", "Crunchyroll":"CrunchyrollLogo"][source] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.powerOn == false {
                    empty("TV is in standby", symbol: "moon", detail: "Wake the TV to see what’s on.")
                    Button("Wake TV") { model.power() }.buttonStyle(.borderedProminent).disabled(model.waking)
                } else if !model.ready {
                    empty("TV unavailable", symbol: "wifi.slash", detail: "Reconnect to see which app is open on your TV.")
                } else if !model.playbackDetailsRequested {
                    Group {
                        if let logo { Image(logo).resizable().renderingMode(.template).scaledToFit().padding(22) }
                        else { Image(systemName: source == "Home" ? "house" : "tv").font(.system(size: 38)) }
                    }.frame(width: 112, height: 86).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
                    Text(source).font(.largeTitle.weight(.semibold))
                    Text(model.foregroundPackage.isEmpty ? "Waiting for the TV to report its current app." : "Open on your TV")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Divider().padding(.vertical, 4)
                    Button { model.requestPlaybackDetails() } label: {
                        Label("Show title & device details", systemImage: "info.circle").frame(minHeight: 44)
                    }.buttonStyle(.bordered)
                    Text("Optional. Starts the TV companion for this screen only.").font(.footnote).foregroundStyle(.secondary)
                } else if let state, state.access {
                    HStack(spacing: 14) {
                        Group {
                            if let logo { Image(logo).resizable().renderingMode(.template).scaledToFit().padding(10) }
                            else { Image(systemName: state.kind == "hdmi" ? "gamecontroller" : state.kind == "home" ? "house" : "tv").font(.title2) }
                        }.frame(width: 52, height: 52).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
                        Text(state.kind == "hdmi" ? (state.input.isEmpty ? "HDMI" : state.input) : source).font(.headline)
                    }
                    Text(state.kind == "hdmi" || state.kind == "input" ? source : state.kind == "home" ? "Choose something to watch" : state.mediaTitle ?? "Title unavailable")
                        .font(.largeTitle.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(spacing: 9) {
                        PlaybackIndicator(playing: state.playback == "playing")
                        Text(state.kind == "hdmi" || state.kind == "input" ? "Input selected" : state.kind == "home" ? "No video playing" : state.playback == "playing" ? "Playing" : state.playback == "paused" ? "Paused" : state.playback == "buffering" ? "Buffering" : "On your TV")
                    }
                        .font(.subheadline).foregroundStyle(.secondary)
                    if state.kind == "app" && state.mediaTitle == nil {
                        Text("This app hasn’t shared a title with the TV.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Hide details") { model.hidePlaybackDetails() }.buttonStyle(.bordered)
                } else {
                    empty(model.playbackPaired ? model.playbackStatus : "Connect optional details", symbol: "tv", detail: model.playbackPaired ? "The TV companion runs only while details are requested." : "Open TV Playback on your TV and choose Connect iPhone. Then connect here using the code shown on your TV. After pairing, leave the TV setup screen and return to what you were watching.")
                    if !model.playbackError.isEmpty { Text(model.playbackError).font(.footnote).foregroundStyle(.orange) }
                    Button("Open TV setup") { model.launch("tvplayback://setup") }.buttonStyle(.bordered).disabled(!model.ready)
                    Button(model.playbackPaired ? "Pair playback information again" : "Connect playback information") { model.beginPlaybackPairing() }.buttonStyle(.borderedProminent)
                    Button("Return to app name") { model.hidePlaybackDetails() }.buttonStyle(.bordered)
                }
                Spacer(minLength: 20)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(28).padding(.top, 20)
        }
        .background(Color("LaunchBackground"))
        .navigationTitle("On TV").navigationBarTitleDisplayMode(.inline).tint(.white)
        .onAppear { model.setPlaybackVisible(true) }.onDisappear { model.setPlaybackVisible(false) }
        .sheet(isPresented: $model.showingPlaybackPIN) {
            NavigationStack {
                VStack(spacing: 22) {
                    Image(systemName: "tv").font(.system(size: 42))
                    Text("Connect playback information").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    Text("Enter the six-character code shown in TV Playback.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    TextField("A1B2C3", text: $code).font(.system(size: 30, weight: .medium, design: .monospaced)).multilineTextAlignment(.center).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onChange(of: code) { _, value in code = String(value.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(6)) }
                    if !model.playbackError.isEmpty { Text(model.playbackError).font(.footnote).foregroundStyle(.orange) }
                    Button("Connect") { model.submitPlaybackCode(code) }.buttonStyle(.borderedProminent).disabled(code.count != 6)
                }.padding(28).toolbar { Button("Cancel") { model.cancelPlaybackPairing() } }
            }.presentationDetents([.medium, .large]).interactiveDismissDisabled()
        }
    }
    private func empty(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.body).foregroundStyle(.secondary)
        }
    }
}
