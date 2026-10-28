import SwiftUI
import AppIntents

@MainActor final class ActionController: ObservableObject {
    @Published var running: UUID?
    @Published var progress = 0
    @Published var message = ""
    private var task: Task<Void, Never>?
    private var runner: CommandRunner?
    private var generation = 0
    func cancel() { generation += 1; task?.cancel(); task = nil; runner?.cancel(); runner = nil; running = nil }
    func run(_ action: QuickAction, model: RemoteModel, settings: AppSettings) {
        guard running == nil else { return }
        do { try action.validate() } catch { message = error.localizedDescription; return }
        running = action.id; progress = 0; message = ""
        generation += 1; let token = generation
        let result = CommandRunner(); runner = result
        task = Task {
            defer { if generation == token { running = nil; runner = nil; task = nil } }
            do {
                try await result.run(action.steps, host: model.host, apps: settings.value.apps,
                                     inputs: settings.value.editorHost == model.host ? settings.value.tvInputs : []) { [weak self] in if self?.generation == token { self?.progress = $0 } }
                guard generation == token else { return }; message = "Commands sent to TV"
            } catch is CancellationError { guard generation == token else { return }; message = "Action cancelled" }
            catch { guard generation == token else { return }; message = error.localizedDescription }
        }
    }
}

struct ActionsView: View {
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var actions: ActionController
    @State private var editing: QuickAction?
    var body: some View {
        NavigationStack {
            QuietPage {
                QuietHeading(title: "Actions") {
                    Button { editing = QuickAction(name: "New action", steps: [.init(.wake)]) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                        .foregroundStyle(QuietTheme.cyan).accessibilityLabel("Create quick action").disabled(settings.value.actions.count >= 30)
                }
                ForEach(settings.value.actions) { action in
                    QuietCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 11) {
                                Image(systemName: action.steps.contains(where: { $0.kind == .input }) ? "gamecontroller" : "movieclapper").font(.system(size: 21)).frame(width: 25)
                                Text(action.name).font(.system(size: 17, weight: .medium)); Spacer()
                                Button { editing = action } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Edit " + action.name)
                            }
                            Text(action.steps.map { stepName($0, settings: settings) }.joined(separator: " → "))
                                .font(.system(size: 12)).foregroundStyle(QuietTheme.muted).lineSpacing(4)
                            if actions.running == action.id {
                                HStack { ProgressView(); Text("\(actions.progress) of \(action.steps.count)"); Spacer(); Button("Cancel") { actions.cancel() } }.font(.footnote).frame(minHeight: 44)
                            } else {
                                Button("Run", systemImage: "play") { actions.run(action, model: model, settings: settings) }
                                    .font(.system(size: 13)).padding(.horizontal, 14).frame(minHeight: 44)
                                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(QuietTheme.edge, lineWidth: 1)).disabled(actions.running != nil)
                            }
                        }.padding(18)
                    }
                }
                if settings.value.actions.isEmpty { QuietCaption(text: "Create a quick action to run a short sequence.") }
                if !actions.message.isEmpty { QuietCaption(text: actions.message) }
                QuietSectionTitle(title: "Hands-free & quick access")
                QuietCard {
                    NavigationLink { SiriSettingsView() } label: { QuietRow(title: "Siri & Shortcuts", detail: "Control the TV without opening the app", symbol: "mic") }
                    Divider().overlay(QuietTheme.edge)
                    NavigationLink { WidgetHelpView() } label: { QuietRow(title: "Widgets & Control Center", detail: "Your favorite actions, one tap away", symbol: "rectangle.grid.2x2") }
                    Divider().overlay(QuietTheme.edge)
                    NavigationLink { SleepTimerView(model: model) } label: { QuietRow(title: "Sleep timer", detail: "Switch off after a delay", symbol: "moon", value: "") }
                }
            }.buttonStyle(.plain).toolbar(.hidden, for: .navigationBar)
                .sheet(item: $editing) { QuickActionForm(action: $0).environmentObject(settings) }
        }
    }
}

@MainActor func stepName(_ step: ActionStep, settings: AppSettings) -> String {
    switch step.kind {
    case .wake: return "Wake TV"
    case .sleep: return "Turn off TV"
    case .home: return "TV Home"
    case .mute: return "Mute TV"
    case .pause: return "Pause"
    case .playPause: return "Play / Pause"
    case .volumeUp: return "Volume up"
    case .volumeDown: return "Volume down"
    case .openApp: return "Open " + (settings.app(step.argument)?.name ?? "app")
    case .input: return "Select " + (settings.value.tvInputs.first(where: { $0.id == step.argument })?.name ?? "input")
    }
}

private struct QuickActionForm: View {
    @State var action: QuickAction
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Group {
                TextField("Action name", text: $action.name)
                Section("Steps") {
                    ForEach(action.steps) { step in Text(stepName(step, settings: settings)) }
                        .onMove { action.steps.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { action.steps.remove(atOffsets: $0) }
                    Menu("Add step", systemImage: "plus") {
                        Button("Wake TV") { action.steps.append(.init(.wake)) }
                        Button("Turn off TV") { action.steps.append(.init(.sleep)) }
                        Menu("Open app") { ForEach(settings.value.apps) { app in Button(app.name) { action.steps.append(.init(.openApp, argument: app.id)) } } }
                        Menu("Select input") { ForEach(settings.value.tvInputs) { input in Button(input.name) { action.steps.append(.init(.input, argument: input.id)) } } }.disabled(settings.value.tvInputs.isEmpty)
                        Button("TV Home") { action.steps.append(.init(.home)) }
                        Button("Mute TV") { action.steps.append(.init(.mute)) }
                        Button("Pause") { action.steps.append(.init(.pause)) }
                        Button("Play / Pause") { action.steps.append(.init(.playPause)) }
                    }.disabled(action.steps.count >= 12)
                }
                if settings.value.actions.contains(where: { $0.id == action.id }) {
                    Button("Delete action", role: .destructive) { settings.update { $0.actions.removeAll { $0.id == action.id } }; dismiss() }
                }
                Text("Steps run once in order. A failed step stops the sequence. Actions are cancelled when you leave the app.").font(.footnote).foregroundStyle(.secondary)

                }.listRowBackground(QuietTheme.panel)
}.navigationTitle("Quick action").environment(\.editMode, .constant(.active)).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    do {
                        try action.validate()
                        settings.update { value in if let index = value.actions.firstIndex(where: { $0.id == action.id }) { value.actions[index] = action } else { value.actions.append(action) } }
                        TVAppShortcuts.updateAppShortcutParameters(); dismiss()
                    } catch { settings.notice = error.localizedDescription }
                }.disabled(action.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || action.steps.isEmpty) }
            }
        }
    }
}

struct SiriSettingsView: View {
    var body: some View {
        List {
                Group {
            Section {
                Text("“Hey Siri, open Netflix with Debloated TV.”").font(.title2.weight(.semibold)).padding(.vertical, 10)
                SiriTipView(intent: TVCommandIntent(command: .wake))
            }
            Section {
                Label("Wake TV", systemImage: "power")
                Label("Turn off TV", systemImage: "moon")
                Label("Open a streaming app", systemImage: "play.rectangle")
                Label("Pause or mute TV", systemImage: "pause")
                Label("Run a saved quick action", systemImage: "sparkles")
                ShortcutsLink()
            } header: { Text("Available actions") } footer: { Text("In Shortcuts, add Control TV or Run TV Quick Action, choose its action, and give it the name you want to say to Siri. The phone must reach the paired TV on your local network. Unlock may be required.") }

                }.listRowBackground(QuietTheme.panel)
}.remoteForm().navigationTitle("Siri & Shortcuts")
    }
}

struct WidgetHelpView: View {
    var body: some View {
        List {
                Group {
            Section("Home Screen") {
                Label("Debloated TV controls", systemImage: "rectangle.grid.2x2")
                Text("Add the Debloated TV widget using your iPhone’s widget gallery. Edit the widget to choose its four actions.")
            }
            Section("Control Center · iOS 18+") {
                Label("TV quick action", systemImage: "switch.2")
                Text("In Control Center’s controls gallery, add Debloated TV and choose the action it should run.")
            }
            Section { Text("Pair in Debloated TV first. Controls use the existing pairing in the app’s background process; they do not install another TV service. Unlock may be required.").font(.footnote).foregroundStyle(.secondary) }

                }.listRowBackground(QuietTheme.panel)
}.remoteForm().navigationTitle("Quick access")
    }
}

struct SleepTimerView: View {
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var editor: HomeEditor
    @EnvironmentObject private var settings: AppSettings
    @State private var minutes = 30
    @State private var working = false
    @State private var custom = false
    @State private var selected: Int?
    private var deadline: Date? {
        guard let value = editor.snapshot?.sleepDeadline, value > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: value)
    }
    var body: some View {
        QuietPage {
            QuietCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label(deadline.map { "Turn off at " + $0.formatted(date: .omitted, time: .shortened) } ?? "No confirmed timer", systemImage: "moon")
                        .font(.system(size: 17, weight: .medium))
                    QuietCaption(text: "The timer runs on the TV so it can finish after your phone disconnects.")
                }.padding(18)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { value in
                    Button { schedule(value) } label: {
                        Text("\(value) min").font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 52)
                            .background(selected == value && deadline != nil ? Color(red: 50/255, green: 67/255, blue: 94/255) : QuietTheme.panel, in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected == value && deadline != nil ? QuietTheme.cyan : QuietTheme.edge, lineWidth: 1))
                    }.buttonStyle(.plain).disabled(!editor.ready || working)
                }
            }
            Button("Custom duration") { custom = true }.buttonStyle(QuietSecondaryStyle())
            if deadline != nil { Button("Cancel timer") { schedule(0) }.buttonStyle(QuietSecondaryStyle()).disabled(!editor.ready || working) }
            if working { ProgressView("Confirming on TV…").font(.footnote) }
            QuietCard { EditorConnectionView(model: model).padding(14) }
            QuietCaption(text: "A timer is shown as active only after the TV confirms it. Connect the TV editor to schedule one.")
        }.quietNavigation("Sleep timer").onDisappear { editor.close() }
            .sheet(isPresented: $custom) {
                NavigationStack {
                    QuietPage {
                        TextField("Minutes", value: $minutes, format: .number).keyboardType(.numberPad).padding(14).background(QuietTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                        QuietCaption(text: "Choose between 1 and 240 minutes.")
                        Button("Set timer", systemImage: "moon") { custom = false; schedule(minutes) }.buttonStyle(QuietPrimaryStyle()).disabled(!editor.ready || working || !(1...240).contains(minutes))
                    }.quietNavigation("Custom timer").toolbar { Button("Cancel") { custom = false } }
                }.presentationDetents([.medium])
            }
    }
    private func schedule(_ value: Int) {
        working = true
        Task {
            defer { working = false }
            do { try await editor.sleepTimer(minutes: value); selected = value == 0 ? nil : value } catch { settings.notice = error.localizedDescription }
        }
    }
}

struct SettingsView: View {
    @State private var credits = false
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        NavigationStack {
            QuietPage {
                QuietHeading(title: "Settings") { EmptyView() }
                QuietCard {
                    NavigationLink { ConnectionView(model: model) } label: { QuietRow(title: "Connection", detail: "Paired TV · local network", symbol: "wifi", value: model.status) }
                    Divider().overlay(QuietTheme.edge)
                    NavigationLink { ShortcutSettingsView() } label: { QuietRow(title: "Remote shortcuts", detail: "Visibility and order", symbol: "square.grid.2x2") }
                    Divider().overlay(QuietTheme.edge)
                    NavigationLink { InputSettingsView(model: model) } label: { QuietRow(title: "Favorite inputs", detail: "Names and HDMI assignments", symbol: "gamecontroller") }
                    Divider().overlay(QuietTheme.edge)
                    NavigationLink { BackupsView() } label: { QuietRow(title: "Backup & restore", detail: "Launcher layouts and wallpaper", symbol: "archivebox") }
                }.buttonStyle(.plain)
                QuietSectionTitle(title: "Remote preferences")
                QuietCard {
                    Toggle(isOn: settings.binding(\.haptics)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Touch feedback").font(.system(size: 14, weight: .medium))
                            Text("Light haptics on button presses").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                        }
                    }.toggleStyle(QuietToggleStyle()).padding(.horizontal, 13).padding(.vertical, 10)
                    Divider().overlay(QuietTheme.edge)
                    Toggle(isOn: settings.binding(\.autoReconnect)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reconnect automatically").font(.system(size: 14, weight: .medium))
                            Text("When returning to Debloated TV").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                        }
                    }.toggleStyle(QuietToggleStyle()).padding(.horizontal, 13).padding(.vertical, 10)
                }
                QuietSectionTitle(title: "Performance")
                QuietCard { QuietRow(title: "No background TV companion", detail: "Home customization connects only while you edit.", symbol: "leaf", chevron: false) }
                Button("Artwork credits") { credits = true }.font(.footnote).foregroundStyle(QuietTheme.muted).frame(minHeight: 44)
                    .sheet(isPresented: $credits) {
                        NavigationStack {
                            QuietPage {
                                Text("Debloated TV").font(.title2.weight(.semibold))
                                Text("Android TV Remote & Control").foregroundStyle(QuietTheme.muted)
                                QuietSectionTitle(title: "Android robot")
                                Text("The Android robot is reproduced or modified from work created and shared by Google and used according to terms described in the Creative Commons 3.0 Attribution License.").font(.footnote)
                                Link("Creative Commons Attribution 3.0", destination: URL(string: "https://creativecommons.org/licenses/by/3.0/")!)
                                QuietCaption(text: "Android is a trademark of Google LLC. Debloated TV is an independent app.")
                                Link("Streaming logo sources", destination: URL(string: "https://github.com/guilherme-ramalho/custom-tv-remote#references-and-assets")!)
                            }.quietNavigation("Artwork credits").toolbar { Button("Done") { credits = false } }
                        }.presentationDetents([.medium, .large])
                    }
            }.toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var result = ""
    @State private var testing = false
    @State private var repairPairing = false
    @State private var check: Task<Void, Never>?
    var body: some View {
        Form {
                Group {
            Section("TV address") {
                TextField("192.168.1.100", text: $address).keyboardType(.decimalPad).textInputAutocapitalization(.never)
                Button("Save and connect") { _ = model.saveHost(address) }
                    .disabled(model.preparing || address.trimmingCharacters(in: .whitespacesAndNewlines) == model.host)
            }
            Section {
                if model.hasSavedPairing {
                    Label("Pairing saved", systemImage: "checkmark.shield")
                    Button("Reconnect", systemImage: "arrow.clockwise") { model.connect() }.disabled(model.preparing || model.showingPIN)
                } else {
                    Button("Pair TV", systemImage: "tv") { if model.saveHost(address) { dismiss(); model.beginPairing() } }.disabled(model.preparing)
                }
            } header: { Text("Connection") } footer: {
                Text(model.hasSavedPairing ? "Reconnecting uses the saved authorization. A code is not needed." : "Pair once while the TV is on, using the code displayed on it.")
            }
            if model.hasSavedPairing {
                Section {
                    Button("Pair again") { repairPairing = true }.disabled(model.preparing || model.showingPIN)
                } footer: { Text("Only needed if the TV has forgotten this phone or its pairing was reset. An offline TV does not normally need re-pairing.") }
            }
            Section {
                Label(model.status, systemImage: model.ready ? "checkmark.circle" : "wifi.slash")
                Text(TVPairingStore.pin(host: model.host) == nil ? "No saved pairing" : "Pairing saved in Keychain").font(.footnote)
                Button(testing ? "Checking…" : "Test connection") {
                    testing = true; result = ""
                    check = Task {
                        defer { testing = false }
                        let runner = CommandRunner()
                        do { try await runner.diagnose(host: model.host); result = "The paired TV responded. No command was sent." }
                        catch { result = error.localizedDescription }
                    }
                }.disabled(testing)
                if !result.isEmpty { Text(result).font(.footnote).textSelection(.enabled) }
            } header: { Text("Diagnostics") } footer: { Text("Use the same local network as the TV. A connection test cannot distinguish every router, Local Network permission, or TV standby problem.") }
            if !model.error.isEmpty { Text(model.error).font(.footnote).foregroundStyle(.secondary) }

                }.listRowBackground(QuietTheme.panel)
}.remoteForm().navigationTitle("Connection").onAppear { address = model.host }.onDisappear { check?.cancel() }
            .confirmationDialog("Pair this phone again?", isPresented: $repairPairing, titleVisibility: .visible) {
                Button("Show code on TV") { if model.saveHost(address) { dismiss(); model.beginPairing() } }
            } message: { Text("Keep the TV on. Your saved pairing is replaced only after a new code is accepted.") }
    }
}
