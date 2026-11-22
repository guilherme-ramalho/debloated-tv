import SwiftUI

@main struct TVRemoteApp: App {
    @StateObject private var model = RemoteModel()
    @StateObject private var settings = AppSettings()
    @StateObject private var editor = HomeEditor()
    @StateObject private var actions = ActionController()
    @StateObject private var setup = TVSetupStatus(keychain: true)
    @Environment(\.scenePhase) private var phase
    @State private var selection = 0
    var body: some Scene {
        WindowGroup {
            TabView(selection: $selection) {
                RemoteView(model: model).tabItem { Label("Remote", systemImage: "appletvremote.gen4") }.tag(0)
                TVHomeView(model: model).tabItem { Label("TV", systemImage: "tv") }.tag(1)
                ActionsView(model: model).tabItem { Label("Actions", systemImage: "bolt") }.tag(2)
                SettingsView(model: model).tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(3)
            }
            .environmentObject(settings).environmentObject(editor).environmentObject(actions).environmentObject(setup)
            .preferredColorScheme(.dark).tint(.white)
            .task {
                #if DEBUG
                UITestHooks.apply(setup: setup, host: model.host)
                if UserDefaults.standard.bool(forKey: "uiTestKeepWatching") { editor.showSampleKeepWatching(UITestHooks.sampleKeepWatching) }
                if UITestHooks.storeDemo { editor.showStoreDemo(keepWatching: UITestHooks.demoKeepWatching(), inputs: UITestHooks.demoInputs) }
                #endif
                model.setAutoReconnect(settings.value.autoReconnect); if phase == .active { model.activate() }
            }
            .onChange(of: settings.value.autoReconnect) { _, value in model.setAutoReconnect(value) }
            .onChange(of: selection) { _, tab in if tab == 1 && model.kind == .androidTV { editor.autoConnect(model: model) } }
            .onChange(of: model.host) { _, _ in editor.close() }
            .onChange(of: model.foregroundPackage) { _, package in setup.sawForeground(model.host, package) }
            .onChange(of: editor.ready) { _, ready in if ready { setup.sawHome(model.host); editor.connectedApplyPending(settings) } }
            .onChange(of: settings.layoutChange) { _, change in editor.layoutChanged(change, settings: settings) }
            .onChange(of: model.pairings) { _, _ in if model.kind == .androidTV { setup.offerAfterPairing(model.host, showing: model.foregroundPackage) } }
            .onChange(of: setup.openSetup) { _, open in if open { selection = 1 } }
            .sheet(isPresented: Binding(get: { setup.offerFor != nil }, set: { if !$0 { setup.offerFor = nil } })) {
                TVSetupOfferSheet(start: { setup.offerFor = nil; selection = 1; setup.openSetup = true }, later: { setup.offerFor = nil })
            }
            .onChange(of: editor.snapshot?.revision) { _, _ in if let snapshot = editor.snapshot { settings.merge(snapshot, host: model.host) } }
            .onChange(of: phase) { _, value in
                if value == .active { model.activate(); if selection == 1 && model.kind == .androidTV { editor.autoConnect(model: model) } }
                else if value == .background { model.deactivate(); editor.close(); actions.cancel() }
            }
            .sheet(isPresented: Binding(get: { model.pairing }, set: { if !$0 { model.cancelPairing() } })) { TVPairingView(model: model).environmentObject(settings) }
            .alert("Purio TV", isPresented: Binding(get: { !settings.notice.isEmpty }, set: { if !$0 { settings.notice = "" } })) {
                Button("OK") { settings.notice = "" }
            } message: { Text(settings.notice) }
        }
    }
}

struct RemoteView: View {
    @State private var assistant = false
    /// The assistant's button: on in Settings and Apple Intelligence ready (read when the remote shows).
    @State private var assistantButton = false
    @AppStorage(AssistantSettings.key) private var assistantOn = false
    @EnvironmentObject private var preferences: AppSettings
    @EnvironmentObject private var editor: HomeEditor
    @State private var keyboard = false
    @State private var inputs = false
    @State private var showOnTV = false
    @State private var allApps = false
    /// The pad or the number pad (1.3); the pad when the TV has no number keys.
    enum PadMode: Hashable { case dpad, numbers }
    @State private var padMode = PadMode.dpad
    @ObservedObject var model: RemoteModel
    @State private var settings = false
    @StateObject private var pad = DPadGestureController()
    @GestureState private var padTouching = false
    @Environment(\.scenePhase) private var phase
    private let ink = Color(red: 0.075, green: 0.085, blue: 0.11)
    /// Keep watching on the remote: only while the TV shows Purio Home (choosing what to watch), so asking it for the
    /// list never interrupts something playing; on Android TV, switched on in Settings, and with shows to list.
    private var onPurioHome: Bool { model.foregroundPackage == HomeEditor.homePackage || UITestHooks.onPurioHome }
    private var keepWatchingShows: [WatchingShow]? {
        guard preferences.value.showsKeepWatching, model.kind == .androidTV, onPurioHome,
              let list = editor.keepWatching, list.allowed, !list.items.isEmpty else { return nil }
        return list.items
    }
    private func keepWatchingIfOnHome() {
        guard preferences.value.showsKeepWatching, model.kind == .androidTV, model.foregroundPackage == HomeEditor.homePackage else { return }
        if editor.ready { Task { await editor.freshenKeepWatching() } } else { editor.autoConnect(model: model) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                if (!model.hasSavedPairing || UITestHooks.showsConnect) && !model.preparing && !UITestHooks.showsRemote {
                    ConnectTVView(model: model)
                } else {
                VStack(spacing: 12) {
                    controlsHeader
                    // 1.3: the pad or the number pad (TVs with number keys); swipes on the pad still move the focus.
                    if hasNumberPad {
                        // Slim, so the pad keeps today's full size.
                        HStack(spacing: 2) {
                            padModeButton("D-pad", .dpad)
                            padModeButton("Numbers", .numbers)
                        }
                        .padding(2).background(QuietTheme.panel, in: Capsule())
                        .accessibilityElement(children: .contain).accessibilityIdentifier("padMode")
                    }
                    if padMode == .numbers && hasNumberPad { numberPad } else { dpad }
                    // Volume and channels as pills, the other keys round between them.
                    HStack(alignment: .center, spacing: 0) {
                        pill(up: .volumeUp, upSymbol: "plus", label: Text(verbatim: model.volume.allSatisfy(\.isNumber) && !model.volume.isEmpty ? "VOL \(model.volume)" : "VOL"), down: .volumeDown, downSymbol: "minus", hold: true)
                            .accessibilityIdentifier("volumePill")
                        Spacer(minLength: 8)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(54), spacing: 10), count: 3), spacing: 10) {
                            roundKey("arrow.uturn.backward", "Back", .back)
                            roundKey("house.fill", "Home", .home)
                            roundKey("gearshape", "TV settings", .settings)
                            roundKey("backward.fill", "Rewind", .rewind)
                            roundKey("playpause.fill", "Play or pause", .playPause)
                            roundKey("forward.fill", "Fast-forward", .fastForward)
                            roundKey("captions.bubble", "Subtitles", .captions)
                            muteKey
                            inputsKey
                        }.frame(width: 182)
                        Spacer(minLength: 8)
                        if model.supports(.channelUp) {
                            pill(up: .channelUp, upSymbol: "chevron.up", label: Text("CH"), down: .channelDown, downSymbol: "chevron.down", hold: false)
                                .accessibilityIdentifier("channelPill")
                        } else {
                            Color.clear.frame(width: 66, height: 182)
                        }
                    }
                    // The same room above and below the app row (12 + 12).
                    appRow.padding(.top, 12)
                    if let shows = keepWatchingShows {
                        KeepWatchingStrip(tvName: model.tvName, shows: shows).padding(.top, 12)
                    }
                }.padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 12)
                }
            }
            .background(QuietTheme.background).tint(.white)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $settings) {
                NavigationStack { ConnectionView(model: model).toolbar { Button("Done") { settings = false } } }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $keyboard) { KeyboardView(model: model) }
            .sheet(isPresented: $assistant) { AssistantSheet(remote: model, apps: preferences.value.apps) }
            .onAppear { assistantButton = AssistantSettings.showsButton; keepWatchingIfOnHome() }
            .onChange(of: model.foregroundPackage) { _, _ in keepWatchingIfOnHome() }
            .onChange(of: assistantOn) { _, _ in assistantButton = AssistantSettings.showsButton }
            .onChange(of: settings) { _, open in if !open { assistantButton = AssistantSettings.showsButton } }
            .sheet(isPresented: $inputs) { TVInputsSheet(model: model) }
            .fullScreenCover(isPresented: $showOnTV) { ShowOnTVView(remote: model) }
            .sheet(isPresented: $allApps) { AllAppsSheet(model: model) }

        }
    }
    // MARK: 1.3 layout: the pad, the number pad, the pills, the round keys and the app row

    private var hasNumberPad: Bool { model.supports(.digit1) }

    private func padModeButton(_ title: LocalizedStringKey, _ mode: PadMode) -> some View {
        Button { padMode = mode } label: {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(height: 26)
                .foregroundStyle(padMode == mode ? .white : QuietTheme.muted)
                .background(padMode == mode ? Color.white.opacity(0.16) : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(padMode == mode ? .isSelected : [])
    }

    private var dpad: some View {
        ZStack {
            Circle().fill(ink).overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
            HoldKey(symbol: "chevron.up", key: .up, model: model, externallyPressed: pad.highlighted == .up)
                .frame(width: 100, height: 66).offset(y: -103)
            HoldKey(symbol: "chevron.down", key: .down, model: model, externallyPressed: pad.highlighted == .down)
                .frame(width: 100, height: 66).offset(y: 103)
            HoldKey(symbol: "chevron.left", key: .left, model: model, externallyPressed: pad.highlighted == .left)
                .frame(width: 66, height: 100).offset(x: -103)
            HoldKey(symbol: "chevron.right", key: .right, model: model, externallyPressed: pad.highlighted == .right)
                .frame(width: 66, height: 100).offset(x: 103)
            HoldKey(symbol: "", key: .select, model: model, externallyPressed: pad.highlighted == .select)
                .frame(width: 116, height: 116)
                .background(.white.opacity(0.09), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
        }.frame(width: 284, height: 284).opacity(model.ready ? 1 : 0.45)
            .coordinateSpace(name: "dpad").contentShape(Circle())
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("dpad"))
                .updating($padTouching) { _, active, _ in active = true }
                .onChanged { pad.changed($0, model: model, reversed: preferences.value.reversesSwipes) }.onEnded { pad.ended($0) })
            .onChange(of: padTouching) { _, touching in if !touching { pad.gestureReset() } }
            .onChange(of: model.ready) { _, ready in if !ready { pad.cancel() } }
            .onChange(of: phase) { _, value in if value != .active { pad.cancel() } }
            .onDisappear { pad.cancel() }
    }

    /// 1 to 9, Delete, 0, OK: channel numbers on Live TV or a set-top box, PINs on the TV.
    private var numberPad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(1..<10, id: \.self) { digitKey($0) }
            Button { model.tap(.delete) } label: {
                Image(systemName: "delete.left").font(.system(size: 20, weight: .medium)).frame(maxWidth: .infinity).frame(height: 62)
                    .background(ink, in: Capsule())
            }.tint(.white).buttonStyle(RemotePressStyle(radius: 31)).disabled(!model.ready).accessibilityLabel("Delete")
            digitKey(0)
            Button { model.tap(.select) } label: {
                Text("OK").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 62)
                    .background(ink, in: Capsule())
            }.tint(.white).buttonStyle(RemotePressStyle(radius: 31)).disabled(!model.ready).accessibilityIdentifier("numberOK")
        }.frame(width: 284, height: 284).opacity(model.ready ? 1 : 0.45).accessibilityIdentifier("numberPad")
    }
    private func digitKey(_ n: Int) -> some View {
        Button { model.tap(TVKey.digits[n]) } label: {
            Text(verbatim: "\(n)").font(.system(size: 24, weight: .medium)).frame(maxWidth: .infinity).frame(height: 62)
                .background(ink, in: Capsule())
        }.tint(.white).buttonStyle(RemotePressStyle(radius: 31)).disabled(!model.ready).accessibilityIdentifier("digit-\(n)")
    }

    /// A tall pill: + / − (held repeats, for volume) or up / down, with its label between.
    private func pill(up: TVKey, upSymbol: String, label: Text, down: TVKey, downSymbol: String, hold: Bool) -> some View {
        VStack(spacing: 0) {
            pillKey(up, upSymbol, hold: hold)
            label.font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(QuietTheme.muted)
                .lineLimit(1).minimumScaleFactor(0.7).frame(height: 54)
            pillKey(down, downSymbol, hold: hold)
        }.frame(width: 66, height: 182).background(ink, in: Capsule()).opacity(model.ready ? 1 : 0.45)
    }
    @ViewBuilder private func pillKey(_ key: TVKey, _ symbol: String, hold: Bool) -> some View {
        if hold {
            HoldKey(symbol: symbol, key: key, model: model).frame(width: 66, height: 64)
        } else {
            Button { model.tap(key) } label: {
                Image(systemName: symbol).font(.system(size: 21, weight: .semibold)).frame(width: 66, height: 64)
            }.tint(.white).buttonStyle(RemotePressStyle(radius: 33)).disabled(!model.ready)
                .accessibilityLabel(key == .channelUp ? Text("Channel up") : Text("Channel down"))
        }
    }

    /// A round key; one this TV doesn't have (a Roku has no subtitles key) keeps its place, empty.
    @ViewBuilder private func roundKey(_ symbol: String, _ label: LocalizedStringKey, _ key: TVKey) -> some View {
        if model.supports(key) {
            Button { model.tap(key) } label: {
                Image(systemName: symbol).font(.system(size: 19, weight: .medium)).frame(width: 54, height: 54)
                    .background(ink, in: Circle())
            }.accessibilityLabel(Text(label)).accessibilityIdentifier("remote-\(symbol)").disabled(!model.ready).tint(.white)
                .buttonStyle(RemotePressStyle(radius: 27)).opacity(model.ready ? 1 : 0.45)
        } else {
            Color.clear.frame(width: 54, height: 54)
        }
    }
    /// Shows what a tap does, from the TV's own mute state: muted → speaker (unmute).
    private var muteKey: some View {
        Button { model.tap(.mute) } label: {
            Image(systemName: model.muted ? "speaker.wave.2" : "speaker.slash").font(.system(size: 18)).frame(width: 54, height: 54)
                .background(ink, in: Circle()).contentTransition(.symbolEffect(.replace))
        }.tint(.white).accessibilityLabel(model.muted ? "Unmute" : "Mute").disabled(!model.ready)
            .buttonStyle(RemotePressStyle(radius: 27)).opacity(model.ready ? 1 : 0.45)
    }
    /// Android TVs list their inputs through Purio's TV Home; other TVs get their own input menu, where they have one.
    @ViewBuilder private var inputsKey: some View {
        if model.kind == .androidTV || model.supports(.inputs) {
            Button { if model.kind == .androidTV { inputs = true } else { model.tap(.inputs) } } label: {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 18, weight: .medium)).frame(width: 54, height: 54)
                    .background(ink, in: Circle())
            }.tint(.white).accessibilityLabel("Inputs").accessibilityIdentifier("inputsKey")
                .buttonStyle(RemotePressStyle(radius: 27)).disabled(model.kind != .androidTV && !model.ready)
        } else {
            Color.clear.frame(width: 54, height: 54)
        }
    }

    /// Five app buttons (the TV Home dock's apps first) and All apps, which lists every app on the TV.
    private var appRow: some View {
        let apps = Array((model.kind == .androidTV ? preferences.remoteApps : preferences.shortcutApps).prefix(5))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
            ForEach(apps) { item in appTile(item) }
            Button { allApps = true } label: {
                VStack(spacing: 5) {
                    Color.clear.aspectRatio(1, contentMode: .fit).overlay { AllAppsMark() }
                    Text("All apps").font(.system(size: 10)).foregroundStyle(QuietTheme.muted).lineLimit(1)
                }
            }.buttonStyle(.plain).accessibilityIdentifier("allApps").accessibilityLabel("All apps on the TV")
        }
    }
    private func appTile(_ item: RemoteApp) -> some View {
        let logo = StreamingBrand.logo(item.id) ?? item.logo ?? ""
        return Button { model.open(item) } label: {
            VStack(spacing: 5) {
                // A square the width of its column first, the logo inside it: every button the same size,
                // whatever the logo's own shape.
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .background(StreamingBrand.color(item.id), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.1), lineWidth: 1))
                    .overlay {
                        if !logo.isEmpty { Image(logo).resizable().renderingMode(.template).scaledToFit().padding(item.name == "Netflix" ? 13 : 10) }
                        else { Text(item.name.prefix(2)).font(.system(size: 17, weight: .bold)) }
                    }
                    .foregroundStyle(.white)
                Text(item.name).font(.system(size: 10)).foregroundStyle(QuietTheme.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
        }.buttonStyle(RemotePressStyle(radius: 14)).disabled(!model.ready).opacity(model.ready ? 1 : 0.45)
            .accessibilityLabel("Open " + item.name)
    }

    /// Remote 1: power, then the TV and the app on screen (tap for connection settings), then Show on TV, typing
    /// and inputs. Narrow phones (4.7-inch SE) get smaller round buttons so the TV's name keeps its room.
    private var controlsHeader: some View {
        ViewThatFits(in: .horizontal) {
            header(button: 46, spacing: 12, nameRoom: 130)
            header(button: 40, spacing: 8, nameRoom: 96)
            // With the assistant's button too, the 4.7-inch SE needs one size smaller.
            header(button: 36, spacing: 6, nameRoom: 72)
        }.frame(minHeight: 52)
    }
    private func header(button side: CGFloat, spacing: CGFloat, nameRoom: CGFloat) -> some View {
        HStack(spacing: spacing) {
            topCommand("power", "Power", .power, Color(red: 1, green: 0.34, blue: 0.36))
            TVConnectionChip(model: model, layout: .block) { settings = true }
                .frame(minWidth: nameRoom, alignment: .leading)
                .contextMenu { Button("Connection settings", systemImage: "wifi") { settings = true } }
            roundButton("photo.on.rectangle.angled", side: side, fill: Color(red: 22/255, green: 48/255, blue: 79/255), tint: QuietTheme.cyan) { showOnTV = true }
                .accessibilityLabel("Show photos on TV").accessibilityIdentifier("showOnTV")
            if assistantButton {
                roundButton("sparkles", side: side, fill: QuietTheme.panel, tint: QuietTheme.cyan) { assistant = true }
                    .accessibilityLabel("Ask Purio").accessibilityIdentifier("askPurio")
            }
            roundButton("keyboard", side: side, fill: QuietTheme.panel) { keyboard = true }
                .accessibilityLabel("Type on TV").accessibilityIdentifier("typeOnTV")
        }
    }
    private func roundButton(_ symbol: String, side: CGFloat, fill: Color, tint: Color = .white, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: side * 0.41, weight: .medium)).foregroundStyle(tint)
                .frame(width: side, height: side).background(fill, in: Circle())
        }.buttonStyle(RemotePressStyle(radius: side / 2))
    }
    /// A key this TV doesn't have (a Roku has no subtitles button) is left out; the row stays centred.
    @ViewBuilder private func command(_ symbol: String, _ label: LocalizedStringKey, _ key: TVKey) -> some View {
        if model.supports(key) {
            Button { model.tap(key) } label: {
                Image(systemName: symbol).font(.system(size: 23, weight: .medium)).frame(width: 65, height: 50)
                    .background(ink, in: RoundedRectangle(cornerRadius: 21))
            }.accessibilityLabel(Text(label)).accessibilityIdentifier("remote-\(symbol)").disabled(!model.ready).tint(.white).buttonStyle(RemotePressStyle())
        }
    }
    private func topCommand(_ symbol: String, _ label: String, _ key: TVKey, _ accent: Color) -> some View {
        let available = key == .power ? !model.preparing && !model.showingPIN && !model.waking : model.ready
        return Button { if key == .power { model.power() } else { model.tap(key) } } label: {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(accent.opacity(0.11), in: Circle())
                .overlay(Circle().stroke(accent.opacity(0.25), lineWidth: 1))
        }.buttonStyle(RemotePressStyle(radius: 24)).disabled(!available)
            .opacity(available ? 1 : 0.45)
            .accessibilityLabel(key == .power && (!model.ready || model.powerOn == false) ? "Wake TV" : label)
    }
    private func app(_ item: RemoteApp, _ logo: String, _ color: Color) -> some View {
        let name = item.name
        return Button { model.open(item) } label: {
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
    var externallyPressed: Bool? = nil
    private var highlighted: Bool { externallyPressed ?? pressed }
    var body: some View {
        Group {
            if symbol.isEmpty { Text("OK").font(.system(size: 26, weight: .semibold)) }
            else { Image(systemName: symbol).font(.system(size: 25, weight: .medium)) }
        }
        .foregroundStyle(.white.opacity(model.ready ? 1 : 0.35))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(highlighted ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(highlighted ? 0.55 : 0), lineWidth: 1))
        .sensoryFeedback(.impact(weight: .light), trigger: highlighted) { _, value in value && preferences.value.haptics }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if !pressed && model.ready { pressed = true; model.press(key) }
        }.onEnded { _ in pressed = false; model.release(key) }, including: externallyPressed == nil ? .all : .none)
        .allowsHitTesting(externallyPressed == nil)
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

#if DEBUG
/// Launch arguments the UI tests use to put the TV tab in a known state without a TV
/// (TVRemoteUITests/TVRemoteUITests.swift): `-uiTestTVState fresh|supported|installed|unsupported` and `-uiTestOffer YES`.
enum UITestHooks {
    @MainActor static func apply(setup: TVSetupStatus, host: String) {
        let defaults = UserDefaults.standard
        guard let state = defaults.string(forKey: "uiTestTVState"), !host.isEmpty else { return }
        let info: TVSetupInfo
        switch state {
        case "supported": info = TVSetupInfo(supported: true, model: "Test TV", detail: "testtv · Android 11", profile: "Test profile", offered: true)
        case "installed": info = TVSetupInfo(homeInstalled: true, supported: true, model: "Test TV", profile: "Test profile", disabledCount: 12, offered: true)
        case "unsupported": info = TVSetupInfo(supported: false, model: "Test TV", detail: "testtv · Android 11", offered: true)
        default: info = TVSetupInfo(offered: true)
        }
        setup.update(host) { $0 = info }
        if defaults.bool(forKey: "uiTestOffer") { setup.offerFor = host }
    }
    /// `-uiTestRemote YES`: the remote's controls without a paired TV (header layout and Show on TV tests).
    static var showsRemote: Bool { UserDefaults.standard.bool(forKey: "uiTestRemote") || storeDemo }
    /// The TV shows Purio Home (Keep watching on the remote).
    static var onPurioHome: Bool { UserDefaults.standard.bool(forKey: "uiTestKeepWatching") || storeDemo }
    /// `-storeDemo YES` (scripts/store-shots-auto.sh --demo): a connected "Living room TV" on Purio Home with made-up
    /// shows and inputs, for store screenshots without a TV. Nothing is sent anywhere.
    static var storeDemo: Bool { UserDefaults.standard.bool(forKey: "storeDemo") }
    static let demoInputs = [
        TVInputRow(id: "hdmi1", name: "HDMI 1", kind: "hdmi", connected: true),
        TVInputRow(id: "hdmi2", name: "HDMI 2", kind: "hdmi", connected: true),
        TVInputRow(id: "hdmi3", name: "HDMI 3", kind: "hdmi", connected: false),
        TVInputRow(id: "av", name: "AV", kind: "av", connected: nil),
        TVInputRow(id: "live-tv", name: String(localized: "Live TV"), kind: "live", connected: nil),
    ]
    /// Made-up titles with drawn posters (no real show's artwork).
    @MainActor static func demoKeepWatching() -> KeepWatchingList {
        func poster(_ top: UIColor, _ bottom: UIColor, _ sun: UIColor) -> Data? {
            let size = CGSize(width: 480, height: 270)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                let cg = context.cgContext
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                cg.setFillColor(sun.cgColor); cg.fillEllipse(in: CGRect(x: 300, y: 50, width: 110, height: 110))
                cg.setFillColor(UIColor.black.withAlphaComponent(0.35).cgColor)
                let hills = UIBezierPath(); hills.move(to: CGPoint(x: 0, y: 200))
                hills.addCurve(to: CGPoint(x: 480, y: 180), controlPoint1: CGPoint(x: 140, y: 120), controlPoint2: CGPoint(x: 300, y: 250))
                hills.addLine(to: CGPoint(x: 480, y: 270)); hills.addLine(to: CGPoint(x: 0, y: 270)); hills.close()
                cg.addPath(hills.cgPath); cg.fillPath()
            }
            return image.jpegData(compressionQuality: 0.85)
        }
        return KeepWatchingList(allowed: true, items: [
            WatchingShow(id: "1", package: "com.netflix.ninja", title: "The Quiet Coast", episode: "S2 · E5", positionMs: 1_900_000, durationMs: 3_280_000, lastWatched: 1_794_900_000,
                         posterJPEG: poster(UIColor(red: 0.98, green: 0.55, blue: 0.35, alpha: 1), UIColor(red: 0.35, green: 0.12, blue: 0.35, alpha: 1), UIColor(red: 1, green: 0.85, blue: 0.5, alpha: 1))),
            WatchingShow(id: "2", package: "com.amazon.amazonvideo.livingroom", title: "Northern Lights", episode: "", positionMs: 3_700_000, durationMs: 6_180_000, lastWatched: 1_794_800_000,
                         posterJPEG: poster(UIColor(red: 0.08, green: 0.2, blue: 0.4, alpha: 1), UIColor(red: 0.1, green: 0.55, blue: 0.5, alpha: 1), UIColor(red: 0.8, green: 0.95, blue: 1, alpha: 1))),
            WatchingShow(id: "3", package: "com.wbd.stream", title: "Orbit Kitchen", episode: "S1 · E3", positionMs: 611_000, durationMs: 1_632_000, lastWatched: 1_794_700_000,
                         posterJPEG: poster(UIColor(red: 0.2, green: 0.1, blue: 0.45, alpha: 1), UIColor(red: 0.9, green: 0.3, blue: 0.5, alpha: 1), UIColor(red: 1, green: 0.95, blue: 0.7, alpha: 1))),
        ])
    }
    /// `-showConnect YES` (Dev builds): the Connect screen even with a paired TV, to check discovery on a real network.
    static var showsConnect: Bool { UserDefaults.standard.bool(forKey: "showConnect") }
    /// `-uiTestKeepWatching YES`: the TV tab's Keep watching strip with sample shows (no TV, no posters).
    static let sampleKeepWatching = KeepWatchingList(allowed: true, items: [
        WatchingShow(id: "1", package: "com.netflix.ninja", title: "[Show title]", episode: "S2 · E5", positionMs: 1_900_000, durationMs: 3_280_000, lastWatched: 1_794_900_000, posterJPEG: nil),
        WatchingShow(id: "2", package: "com.amazon.amazonvideo.livingroom", title: "[Film title]", episode: "", positionMs: 3_700_000, durationMs: 8_180_000, lastWatched: 1_794_800_000, posterJPEG: nil),
        WatchingShow(id: "3", package: "com.wbd.stream", title: "[Series title with a long name]", episode: "S5 · E2", positionMs: 611_000, durationMs: 1_132_000, lastWatched: 1_794_700_000, posterJPEG: nil),
    ])
    /// `-uiTestFoundTVs YES`: the Connect list shows one TV of each kind, without searching the network.
    static var foundTVs: [DiscoveredTV] {
        guard UserDefaults.standard.bool(forKey: "uiTestFoundTVs") else { return [] }
        return [DiscoveredTV(id: "a", name: "Living Room TV", host: "192.0.2.13", kind: .androidTV, support: .full(showOnTV: true)),
                DiscoveredTV(id: "b", name: "Bedroom TV", host: "192.0.2.14", kind: .androidTV, support: .full(showOnTV: false)),
                DiscoveredTV(id: "c", name: "[LG] webOS TV OLED55C1", host: "192.0.2.20", kind: .lg, support: .remote),
                DiscoveredTV(id: "d", name: "Kitchen", host: "192.0.2.21", kind: .chromecast, support: .notYet)]
    }
}
#else
enum UITestHooks { static let showsRemote = false; static let onPurioHome = false; static let showsConnect = false; static let foundTVs: [DiscoveredTV] = [] }
#endif
