import SwiftUI

@main struct TVRemoteApp: App {
    @StateObject private var model = RemoteModel()
    @StateObject private var settings = AppSettings()
    @StateObject private var editor = HomeEditor()
    @StateObject private var actions = ActionController()
    @Environment(\.scenePhase) private var phase
    @State private var selection = 0
    var body: some Scene {
        WindowGroup {
            TabView(selection: $selection) {
                RemoteView(model: model).tabItem { Label("Remote", systemImage: "appletvremote.gen4") }.tag(0)
                TVHomeView(model: model).tabItem { Label("TV Home", systemImage: "square.grid.2x2") }.tag(1)
                ActionsView(model: model).tabItem { Label("Actions", systemImage: "bolt") }.tag(2)
                SettingsView(model: model).tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(3)
            }
            .environmentObject(settings).environmentObject(editor).environmentObject(actions)
            .preferredColorScheme(.dark).tint(.white)
            .task { model.setAutoReconnect(settings.value.autoReconnect); if phase == .active { model.activate() } }
            .onChange(of: settings.value.autoReconnect) { _, value in model.setAutoReconnect(value) }
            .onChange(of: selection) { _, _ in editor.close() }
            .onChange(of: model.host) { _, _ in editor.close() }
            .onChange(of: editor.snapshot?.revision) { _, _ in if let snapshot = editor.snapshot { settings.merge(snapshot, host: model.host) } }
            .onChange(of: phase) { _, value in
                if value == .active { model.activate() }
                else if value == .background { model.deactivate(); editor.close(); actions.cancel() }
            }
            .sheet(isPresented: $model.showingPIN) { TVPairingView(model: model) }
            .sheet(isPresented: $editor.showingPIN) { EditorPairingView().environmentObject(editor) }
            .alert("TV Remote", isPresented: Binding(get: { !settings.notice.isEmpty }, set: { if !$0 { settings.notice = "" } })) {
                Button("OK") { settings.notice = "" }
            } message: { Text(settings.notice) }
        }
    }
}

struct RemoteView: View {
    @EnvironmentObject private var preferences: AppSettings
    @State private var keyboard = false
    @State private var inputs = false
    @ObservedObject var model: RemoteModel
    @State private var settings = false
    @State private var address = ""
    @State private var code = ""
    private let ink = Color(red: 0.075, green: 0.085, blue: 0.11)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    statusHeader
                    if !model.error.isEmpty && !model.showingPIN {
                        Text(model.error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if !model.ready {
                        HStack {
                            Button("Connect") { model.connect() }.buttonStyle(.bordered)
                            Button("Pair TV") { model.beginPairing() }.buttonStyle(QuietPrimaryStyle())
                        }.disabled(model.preparing)
                    }

                    HStack(spacing: 8) {
                        topCommand("power", "Power", .power, Color(red: 1, green: 0.34, blue: 0.36))
                        Spacer()
                        Button { keyboard = true } label: { Image(systemName: "keyboard").frame(width: 36, height: 44) }.accessibilityLabel("Type on TV").buttonStyle(RemotePressStyle(radius: 12))
                        Spacer()
                        Button { inputs = true } label: { Image(systemName: "rectangle.on.rectangle").font(.system(size: 24, weight: .medium)).frame(width: 52, height: 52).background(Color.blue.opacity(0.11), in: Circle()) }.accessibilityLabel("Favorite inputs").buttonStyle(RemotePressStyle(radius: 26))
                    }

                    UnifiedDPad(model: model, haptics: preferences.value.haptics).frame(width: 284, height: 284)
                        .accessibilityElement(children: .contain).accessibilityLabel("Directional pad. Swipe to navigate, tap an arrow or OK, or hold to repeat.")

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
                            ForEach(preferences.remoteApps) { item in
                                app(item.name, item.launchURL, StreamingBrand.logo(item.id) ?? item.logo ?? "", StreamingBrand.color(item.id))
                            }
                        }
                    }
                }.padding(.horizontal, 30).padding(.top, 4).padding(.bottom, 12)
            }
            .background(QuietTheme.background).tint(.white)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $settings) {
                NavigationStack {
                    Form {
                Group {
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

                }.listRowBackground(QuietTheme.panel)
}.navigationTitle("Connection").toolbar { Button("Done") { settings = false } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $keyboard) { KeyboardView(model: model) }
            .sheet(isPresented: $inputs) { NavigationStack { InputSettingsView(model: model).toolbar { Button("Done") { inputs = false } } } }

        }
    }
    private var statusHeader: some View {
        HStack(spacing: 12) {
            if let name = model.currentAppName {
                Label { Text(name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8) }
                    icon: { Image(systemName: "tv").font(.system(size: 19, weight: .medium)) }
                    .labelStyle(.titleAndIcon).foregroundStyle(.white)
                    .accessibilityElement(children: .ignore).accessibilityLabel("On TV: " + name)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(model.ready ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.fixedSize(horizontal: true, vertical: false).accessibilityElement(children: .combine)
            Button { address = model.host; settings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }.accessibilityLabel("Connection settings").tint(.white).buttonStyle(RemotePressStyle(radius: 12))
        }.frame(minHeight: 44)
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
            Group { if !logo.isEmpty { Image(logo).resizable().renderingMode(.template).scaledToFit() } else { Text(name).font(.headline) } }
                .frame(maxWidth: 108).frame(height: name == "Disney+" ? 42 : name == "HBO Max" ? 36 : 33).foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 58)
            .background(color, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.07), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 21))
        }.buttonStyle(RemotePressStyle()).disabled(!model.ready)
            .opacity(model.ready ? 1 : 0.45).accessibilityLabel("Open " + name)
    }

}

struct HoldKey: View {
    @EnvironmentObject private var preferences: AppSettings
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
        .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, value in value && preferences.value.haptics }
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
    @EnvironmentObject private var preferences: AppSettings
    var radius: CGFloat = 20
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: radius).fill(.white.opacity(configuration.isPressed ? 0.13 : 0)).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(configuration.isPressed ? 0.55 : 0), lineWidth: 1).allowsHitTesting(false))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, value in value && preferences.value.haptics }
    }
}
