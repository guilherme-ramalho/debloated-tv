import SwiftUI

@main struct TVRemoteApp: App {
    @StateObject private var model = RemoteModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RemoteView(model: model)
                .preferredColorScheme(.dark)
                .task { model.activate() }
                .onChange(of: phase) { _, value in
                    if value == .active { model.activate() }
                    else if value == .background { model.deactivate() }
                }
        }
    }
}

struct RemoteView: View {
    @ObservedObject var model: RemoteModel
    @State private var settings = false
    @State private var address = ""
    @State private var code = ""
    private let ink = Color(red: 0.075, green: 0.085, blue: 0.11)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !model.error.isEmpty && !model.showingPIN {
                        Text(model.error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if !model.ready {
                        HStack {
                            Button("Connect") { model.connect() }.buttonStyle(.bordered)
                            Button("Pair TV") { model.beginPairing() }.buttonStyle(.borderedProminent)
                        }.disabled(model.preparing)
                    }

                    HStack(spacing: 14) {
                        topCommand("power", "Power", .power, Color(red: 1, green: 0.34, blue: 0.36))
                        Spacer()
                        topCommand("rectangle.on.rectangle", "Input", .inputs, Color(red: 0.36, green: 0.72, blue: 1))
                    }

                    ZStack {
                        Circle().fill(ink).overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
                        HoldKey(symbol: "chevron.up", key: .up, model: model)
                            .frame(width: 100, height: 66).offset(y: -103)
                        HoldKey(symbol: "chevron.down", key: .down, model: model)
                            .frame(width: 100, height: 66).offset(y: 103)
                        HoldKey(symbol: "chevron.left", key: .left, model: model)
                            .frame(width: 66, height: 100).offset(x: -103)
                        HoldKey(symbol: "chevron.right", key: .right, model: model)
                            .frame(width: 66, height: 100).offset(x: 103)
                        HoldKey(symbol: "", key: .select, model: model)
                            .frame(width: 116, height: 116)
                            .background(.white.opacity(0.09), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                    }.frame(width: 284, height: 284).opacity(model.ready ? 1 : 0.45)

                    HStack(spacing: 25) {
                        command("arrow.uturn.backward", "Back", .back)
                        command("house.fill", "Home", .home)
                        command("playpause.fill", "Play or pause", .playPause)
                    }
                    HStack(spacing: 0) {
                        HoldKey(symbol: "minus", key: .volumeDown, model: model).frame(width: 64, height: 56)
                        Text(model.volume).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                        HoldKey(symbol: "plus", key: .volumeUp, model: model).frame(width: 64, height: 56)
                        Button { model.tap(.mute) } label: {
                            Image(systemName: "speaker.slash").font(.system(size: 19)).frame(width: 48, height: 56)
                        }.tint(.white).accessibilityLabel("Mute").disabled(!model.ready).buttonStyle(RemotePressStyle())
                    }.background(ink, in: Capsule())
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                            app("Netflix", "https://www.netflix.com/title", "NetflixLogo", Color(red: 0.898, green: 0.035, blue: 0.078))
                            app("YouTube", "https://www.youtube.com", "YouTubeLogo", Color(red: 1, green: 0, blue: 0))
                            app("Prime Video", "https://app.primevideo.com", "PrimeVideoLogo", Color(red: 0, green: 0.51, blue: 0.73))
                            app("Disney+", "https://www.disneyplus.com", "DisneyPlusLogo", Color(red: 0, green: 0.36, blue: 0.39))
                            app("HBO Max", "https://play.max.com", "HBOMaxLogo", Color(red: 0.075, green: 0.075, blue: 0.09))
                            app("Crunchyroll", "crunchyroll://", "CrunchyrollLogo", Color(red: 1, green: 0.39, blue: 0.04))
                        }
                    }
                }.padding(.horizontal, 30).padding(.top, 4).padding(.bottom, 12)
            }
            .background(Color("LaunchBackground"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 7) {
                        Image(systemName: "tv").font(.system(size: 19, weight: .medium))
                        Text(model.currentAppName).font(.subheadline.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }.foregroundStyle(.white).frame(maxWidth: 155, alignment: .leading)
                        .accessibilityElement(children: .ignore).accessibilityLabel("On TV: " + model.currentAppName)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        HStack(spacing: 6) {
                            Circle().fill(model.ready ? Color.green : Color.orange).frame(width: 6, height: 6)
                            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.accessibilityElement(children: .combine)
                        Button { address = model.host; settings = true } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("Connection settings").tint(.white).buttonStyle(RemotePressStyle(radius: 12))
                    }
                }
            }
            .sheet(isPresented: $settings) {
                NavigationStack {
                    Form {
                        Section("TV address") {
                            if !model.error.isEmpty { Text(model.error).font(.footnote).foregroundStyle(.orange) }
                            TextField("192.168.1.100", text: $address).keyboardType(.decimalPad).textInputAutocapitalization(.never)
                            Button("Save and connect") { if model.saveHost(address) { settings = false } }
                        }
                        Section {
                            Button("Pair this TV") { if model.saveHost(address) { settings = false; model.beginPairing() } }
                            Text("Use the same local network as the TV. Pair once using the code on screen; the app remembers your TV and reconnects when opened.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.navigationTitle("Connection").toolbar { Button("Done") { settings = false } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $model.showingPIN) {
                NavigationStack {
                    VStack(spacing: 22) {
                        Image(systemName: "tv").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Pair your TV").font(.title2.bold())
                        Text("Enter the six-character code shown on the TV.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        TextField("A1B2C3", text: $code).font(.system(size: 30, weight: .medium, design: .monospaced))
                            .multilineTextAlignment(.center).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .onChange(of: code) { _, value in code = String(value.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(6)) }
                        if !model.error.isEmpty { Text(model.error).font(.footnote).foregroundStyle(.orange) }
                        Button("Pair") { model.submit(code) }.buttonStyle(.borderedProminent).disabled(code.count != 6)
                        Button("Start pairing again") { code = ""; model.beginPairing() }.font(.footnote)
                    }.padding(30).toolbar { Button("Cancel") { model.cancelPairing() } }
                }.presentationDetents([.medium, .large]).interactiveDismissDisabled()
            }
        }
    }
    private func command(_ symbol: String, _ label: String, _ key: TVKey) -> some View {
        Button { model.tap(key) } label: {
            Image(systemName: symbol).font(.system(size: 23, weight: .medium)).frame(width: 65, height: 50)
                .background(ink, in: RoundedRectangle(cornerRadius: 21))
        }.accessibilityLabel(label).disabled(!model.ready).tint(.white).buttonStyle(RemotePressStyle())
    }
    private func topCommand(_ symbol: String, _ label: String, _ key: TVKey, _ accent: Color) -> some View {
        let available = key == .power ? !model.preparing && !model.showingPIN && !model.waking : model.ready
        return Button { if key == .power { model.power() } else { model.tap(key) } } label: {
            Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(accent.opacity(0.11), in: Circle())
                .overlay(Circle().stroke(accent.opacity(0.25), lineWidth: 1))
        }.buttonStyle(RemotePressStyle(radius: 26)).disabled(!available)
            .opacity(available ? 1 : 0.45)
            .accessibilityLabel(key == .power && (!model.ready || model.powerOn == false) ? "Wake TV" : label)
    }
    private func app(_ name: String, _ link: String, _ logo: String, _ color: Color) -> some View {
        Button { model.launch(link) } label: {
            Image(logo).resizable().renderingMode(.template).scaledToFit()
                .frame(maxWidth: 108).frame(height: name == "Disney+" ? 42 : name == "HBO Max" ? 36 : 33).foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 64)
            .background(color, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).stroke(.white.opacity(0.12), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 21))
        }.buttonStyle(RemotePressStyle()).disabled(!model.ready)
            .opacity(model.ready ? 1 : 0.45).accessibilityLabel("Open " + name)
    }

}

struct HoldKey: View {
    let symbol: String
    let key: TVKey
    @ObservedObject var model: RemoteModel
    @State private var pressed = false
    var body: some View {
        Group {
            if symbol.isEmpty { Text("OK").font(.system(size: 26, weight: .semibold)) }
            else { Image(systemName: symbol).font(.system(size: 25, weight: .medium)) }
        }
        .foregroundStyle(.white.opacity(model.ready ? 1 : 0.35))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(pressed ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(pressed ? 0.55 : 0), lineWidth: 1))
        .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, value in value }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if !pressed && model.ready { pressed = true; model.press(key) }
        }.onEnded { _ in pressed = false; model.release(key) })
        .onDisappear { if pressed { model.release(key); pressed = false } }
        .accessibilityElement().accessibilityLabel(symbol.isEmpty ? "Select" : String(describing: key))
        .accessibilityAddTraits(.isButton).accessibilityAction { model.tap(key) }
    }
}

struct RemotePressStyle: ButtonStyle {
    var radius: CGFloat = 20
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: radius).fill(.white.opacity(configuration.isPressed ? 0.13 : 0)).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(configuration.isPressed ? 0.55 : 0), lineWidth: 1).allowsHitTesting(false))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, value in value }
    }
}
