import SwiftUI
import UIKit

/// Typing here fills the focused field on the TV as you go. The field's whole text is sent once typing pauses
/// (debounced), so the TV gets one update per pause instead of one per keystroke; Return sends at once.
struct KeyboardView: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var secure = false
    @State private var message = ""
    /// What the TV's field holds, as far as this sheet knows.
    @State private var sent = ""
    @State private var stamp = 0
    @State private var sending = false
    static let delay: Duration = .milliseconds(400)
    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    if secure { SecureField("Search or enter text", text: $text).onSubmit(flush) }
                    else { TextField("Search or enter text", text: $text).onSubmit(flush) }
                    Toggle("Hide text while typing", isOn: $secure)
                } footer: { Text("First focus a search or password field on the TV. What you type appears there as you go. Text is sent over the paired encrypted connection and is never saved.") }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }

                }.listRowBackground(QuietTheme.panel)
}.textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle("Type on TV").toolbar { Button("Done") { stamp += 1; Task { await push(); dismiss() } } }
                .onChange(of: text) { _, _ in schedule() }
        }.onDisappear { stamp += 1 }.presentationDetents([.medium, .large])
    }
    private func schedule() {
        stamp += 1
        let mine = stamp
        Task {
            try? await Task.sleep(for: Self.delay)
            guard mine == stamp else { return }
            await push()
        }
    }
    private func flush() { stamp += 1; Task { await push() } }
    /// Brings the TV's field up to date with the text here. One send at a time; a newer text follows after.
    private func push() async {
        guard !sending, text != sent else { return }
        guard model.ready else { message = String(localized: "Connect the TV before sending text"); return }
        guard text.utf16.count <= 4096 else { message = String(localized: "Enter between 1 and 4096 characters"); return }
        sending = true
        let value = text
        do {
            // The TV can't be sent an empty field, so clearing it deletes what was sent, one character at a time.
            if value.isEmpty { for _ in 0..<min(sent.count, 256) { model.tap(.delete) } } else { try await model.sendText(value) }
            sent = value; message = ""
        } catch { message = error.localizedDescription }
        sending = false
        if text != sent && message.isEmpty { await push() }
    }
}

struct ShortcutSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        List {
                Group {
            Section { Stepper("Visible shortcuts: \(settings.value.remoteCount)", value: settings.binding(\.remoteCount), in: 1...12) }
            Section("Order") {
                ForEach(settings.value.remoteOrder, id: \.self) { id in
                    HStack { AppBadge(app: settings.app(id)); Text(settings.app(id)?.name ?? id) }
                }.onMove { from, to in settings.update { $0.remoteOrder.move(fromOffsets: from, toOffset: to) } }
                    .onDelete { offsets in settings.update { $0.remoteOrder.remove(atOffsets: offsets) } }
            }
            Section("More apps") {
                ForEach(settings.value.apps.filter { !settings.value.remoteOrder.contains($0.id) }) { app in
                    Button { settings.update { $0.remoteOrder.append(app.id) } } label: { Label(app.name, systemImage: "plus.circle") }
                }
            }
            Section { Text("Removing a shortcut keeps the app installed on the TV.").font(.footnote).foregroundStyle(.secondary) }

                }.listRowBackground(QuietTheme.panel)
}.navigationTitle("Remote shortcuts").toolbar { EditButton() }
    }
}

struct AppBadge: View {
    let app: RemoteApp?
    var body: some View {
        StreamingLogo(app: app).padding(5).frame(width: 36, height: 36)
            .background(StreamingBrand.color(app?.id ?? "").opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct InputSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var settings: AppSettings
    @State private var selected: FavoriteInput?
    @State private var message = ""
    var body: some View {
        List {
                Group {
            Section {
                ForEach(settings.value.inputs) { input in
                    HStack {
                        Button {
                            guard settings.value.editorHost == model.host, let id = input.inputID, let found = settings.value.tvInputs.first(where: { $0.id == id }) else {
                                message = String(localized: "Sync the TV editor and assign an input first."); return
                            }
                            model.launch(found.launchURL)
                        } label: {
                            Label { VStack(alignment: .leading) { Text(input.name); Text(settings.value.tvInputs.first(where: { $0.id == input.inputID })?.name ?? "Not assigned").font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "gamecontroller") }
                        }.disabled(!model.ready)
                        Spacer()
                        Button { selected = input } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }.accessibilityLabel("Edit " + input.name)
                    }
                }.onDelete { offsets in settings.update { $0.inputs.remove(atOffsets: offsets) } }
            } footer: { Text("Input assignments come from your TV. No HDMI port is guessed from the device name.") }
            Button("Add favorite", systemImage: "plus") { selected = FavoriteInput(name: "New device") }
            Section { Button("Open TV input menu", systemImage: "rectangle.on.rectangle") { model.tap(.inputs); dismiss() }.disabled(!model.ready) }

                }.listRowBackground(QuietTheme.panel)
}.buttonStyle(.borderless).navigationTitle("Favorite inputs").toolbar { EditButton() }
            .sheet(item: $selected) { input in InputForm(input: input).environmentObject(settings) }
            .alert("Inputs", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) { Button("OK") { message = "" } } message: { Text(message) }
    }
}

private struct InputForm: View {
    @State var input: FavoriteInput
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Group {
                TextField("Device name", text: $input.name)
                Picker("TV input", selection: Binding(get: { input.inputID ?? "" }, set: { input.inputID = $0.isEmpty ? nil : $0 })) {
                    Text("Not assigned").tag("")
                    ForEach(settings.value.tvInputs) { Text($0.name).tag($0.id) }
                }
                if settings.value.tvInputs.isEmpty { Text("Connect the TV editor to sync available inputs.").font(.footnote) }

                }.listRowBackground(QuietTheme.panel)
}.navigationTitle("Edit input").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    input.name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    settings.update { value in
                        if let index = value.inputs.firstIndex(where: { $0.id == input.id }) { value.inputs[index] = input } else { value.inputs.append(input) }
                    }; dismiss()
                }.disabled(input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.name.count > 60) }
            }
        }
    }
}

/// Gesture arbitration for the original SwiftUI D-pad; no replacement controls or overlay view.
@MainActor final class DPadGestureController: ObservableObject {
    @Published private(set) var highlighted: TVKey?
    private var interaction = PadInteraction()
    private var tracking = false
    private var generation = 0
    private var holdTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private weak var model: RemoteModel?

    func changed(_ value: DragGesture.Value, model: RemoteModel) {
        guard model.ready else { cancel(); return }
        if !tracking {
            generation += 1; flashTask?.cancel(); flashTask = nil
            self.model = model; tracking = true
            let key = key(at: value.startLocation)
            send(interaction.begin(key: key)); highlighted = key
            let token = generation
            holdTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                guard let self, self.tracking, self.generation == token, model.ready else { return }
                self.send(self.interaction.hold())
            }
        }
        send(interaction.move(dx: Double(value.translation.width), dy: Double(value.translation.height)))
        if interaction.isSwiping {
            holdTask?.cancel(); holdTask = nil
            highlighted = TVKey.swipeDirection(dx: Double(value.translation.width), dy: Double(value.translation.height))
        }
    }
    func ended(_ value: DragGesture.Value) {
        guard tracking else { return }
        tracking = false; holdTask?.cancel(); holdTask = nil
        let commands = interaction.end(dx: Double(value.translation.width), dy: Double(value.translation.height))
        send(commands)
        if case .tap(let key) = commands.last {
            highlighted = key; let token = generation
            flashTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
                guard let self, self.generation == token else { return }; self.highlighted = nil
            }
        } else { highlighted = nil }
    }
    func gestureReset() {
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, self.tracking else { return }; self.cancel()
        }
    }
    func cancel() {
        generation += 1; tracking = false
        holdTask?.cancel(); holdTask = nil; flashTask?.cancel(); flashTask = nil
        send(interaction.cancel()); highlighted = nil
    }
    private func send(_ commands: [PadInteraction.Command]) {
        for command in commands {
            switch command {
            case .tap(let key): model?.tap(key)
            case .press(let key): model?.press(key)
            case .release(let key): model?.release(key)
            }
        }
    }
    private func key(at point: CGPoint) -> TVKey? {
        let regions: [(TVKey, CGRect)] = [
            (.up, CGRect(x: 92, y: 6, width: 100, height: 66)),
            (.down, CGRect(x: 92, y: 212, width: 100, height: 66)),
            (.left, CGRect(x: 6, y: 92, width: 66, height: 100)),
            (.right, CGRect(x: 212, y: 92, width: 66, height: 100)),
            (.select, CGRect(x: 84, y: 84, width: 116, height: 116))
        ]
        return regions.first { $0.1.contains(point) }?.0
    }
}
