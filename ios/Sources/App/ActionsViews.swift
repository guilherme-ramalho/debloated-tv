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
            List {
                Section("Quick actions") {
                    ForEach(settings.value.actions) { action in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(action.name, systemImage: "sparkles").font(.headline)
                                Spacer(); Button { editing = action } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Edit " + action.name)
                            }
                            Text(action.steps.map { stepName($0, settings: settings) }.joined(separator: " → ")).font(.caption).foregroundStyle(.secondary)
                            if actions.running == action.id {
                                HStack { ProgressView(); Text("\(actions.progress) of \(action.steps.count)"); Spacer(); Button("Cancel") { actions.cancel() } }
                            } else { Button("Run", systemImage: "play") { actions.run(action, model: model, settings: settings) }.disabled(actions.running != nil) }
                        }.padding(.vertical, 5)
                    }.onDelete { offsets in settings.update { $0.actions.remove(atOffsets: offsets) } }
                    if settings.value.actions.isEmpty { Text("Create a quick action to run a short sequence.").foregroundStyle(.secondary) }
                }
                if !actions.message.isEmpty { Section { Text(actions.message).font(.footnote).textSelection(.enabled) } }
                Section("Hands-free & quick access") {
                    NavigationLink { SiriSettingsView() } label: { Label("Siri & Shortcuts", systemImage: "mic") }
                    NavigationLink { WidgetHelpView() } label: { Label("Widgets & Control Center", systemImage: "rectangle.grid.2x2") }
                    NavigationLink { SleepTimerView(model: model) } label: { Label("Sleep timer", systemImage: "moon") }
                }
                Section {
                    Label("Photos & videos", systemImage: "photo.on.rectangle")
                    Text("Photo and video casting is a separate exploratory feature. It is not enabled in this build; native AirPlay support is not assumed.").font(.footnote).foregroundStyle(.secondary)
                }
            }.buttonStyle(.borderless).remoteForm().navigationTitle("Actions").toolbar {
                Button { editing = QuickAction(name: "New action", steps: [.init(.wake)]) } label: { Image(systemName: "plus") }.accessibilityLabel("Create quick action").disabled(settings.value.actions.count >= 30)
            }.sheet(item: $editing) { QuickActionForm(action: $0).environmentObject(settings) }
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
                Text("Steps run once in order. A failed step stops the sequence. Actions are cancelled when you leave the app.").font(.footnote).foregroundStyle(.secondary)
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
            Section {
                Text("“Hey Siri, open Netflix with TV Remote.”").font(.title2.weight(.semibold)).padding(.vertical, 10)
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
        }.remoteForm().navigationTitle("Siri & Shortcuts")
    }
}

struct WidgetHelpView: View {
    var body: some View {
        List {
            Section("Home Screen") {
                Label("TV Remote controls", systemImage: "rectangle.grid.2x2")
                Text("Add the TV Remote widget using your iPhone’s widget gallery. Edit the widget to choose its four actions.")
            }
            Section("Control Center · iOS 18+") {
                Label("TV quick action", systemImage: "switch.2")
                Text("In Control Center’s controls gallery, add TV Remote and choose the action it should run.")
            }
            Section { Text("Pair in TV Remote first. Controls use the existing pairing in the app’s background process; they do not install another TV service. Unlock may be required.").font(.footnote).foregroundStyle(.secondary) }
        }.remoteForm().navigationTitle("Quick access")
    }
}

struct SleepTimerView: View {
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var editor: HomeEditor
    @EnvironmentObject private var settings: AppSettings
    @State private var minutes = 30
    @State private var working = false
    var body: some View {
        Form {
            Section {
                if let deadline = editor.snapshot?.sleepDeadline, deadline > Date().timeIntervalSince1970 {
                    Label { Text("Scheduled for \(Date(timeIntervalSince1970: deadline).formatted(date: .omitted, time: .shortened))") } icon: { Image(systemName: "moon") }
                } else { Label("No confirmed timer", systemImage: "moon") }
                Stepper("Turn off in \(minutes) minutes", value: $minutes, in: 1...240, step: 5)
            } footer: { Text("The timer must be confirmed by the TV so it can finish after your phone disconnects. No phone-only timer is used.") }
            Section { EditorConnectionView(model: model) }
            Button("Set sleep timer") { schedule(minutes) }.disabled(!editor.ready || working)
            Button("Cancel TV timer", role: .destructive) { schedule(0) }.disabled(!editor.ready || working)
        }.remoteForm().navigationTitle("Sleep timer").onDisappear { editor.close() }
    }
    private func schedule(_ minutes: Int) {
        working = true
        Task {
            defer { working = false }
            do { try await editor.sleepTimer(minutes: minutes) } catch { settings.notice = error.localizedDescription }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { ConnectionView(model: model) } label: { Label("Connection", systemImage: "wifi") }
                    NavigationLink { ShortcutSettingsView() } label: { Label("Remote shortcuts", systemImage: "square.grid.2x2") }
                    NavigationLink { InputSettingsView(model: model) } label: { Label("Favorite inputs", systemImage: "gamecontroller") }
                    NavigationLink { BackupsView() } label: { Label("Backup & restore", systemImage: "archivebox") }
                }
                Section("Remote preferences") {
                    Toggle("Touch feedback", isOn: settings.binding(\.haptics))
                    Toggle("Reconnect automatically", isOn: settings.binding(\.autoReconnect))
                }
                Section("Performance") {
                    Label("No background TV companion", systemImage: "leaf")
                    Text("TV Home editing connects only while you use its editing session. Ordinary remote controls and the current app name use the built-in TV service.").font(.footnote).foregroundStyle(.secondary)
                }
            }.remoteForm().navigationTitle("Settings")
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var model: RemoteModel
    @State private var address = ""
    @State private var result = ""
    @State private var testing = false
    @State private var check: Task<Void, Never>?
    var body: some View {
        Form {
            Section("TV address") {
                TextField("192.168.1.100", text: $address).keyboardType(.decimalPad).textInputAutocapitalization(.never)
                Button("Save and connect") { _ = model.saveHost(address) }
                Button("Pair this TV") { if model.saveHost(address) { model.beginPairing() } }
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
        }.remoteForm().navigationTitle("Connection").onAppear { address = model.host }.onDisappear { check?.cancel() }
    }
}
