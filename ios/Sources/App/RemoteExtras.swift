import SwiftUI
import UIKit

struct TouchSurface: UIViewRepresentable {
    let send: (TVKey) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(send: send) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))); pan.maximumNumberOfTouches = 1
        let select = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.select)); select.require(toFail: pan)
        let back = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.back)); back.numberOfTouchesRequired = 2
        select.require(toFail: back)
        view.addGestureRecognizer(pan); view.addGestureRecognizer(select); view.addGestureRecognizer(back)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.send = send }
    final class Coordinator: NSObject {
        var send: (TVKey) -> Void
        var last = Date.distantPast
        init(send: @escaping (TVKey) -> Void) { self.send = send }
        @objc func select() { send(.select) }
        @objc func back() { send(.back) }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let offset = gesture.translation(in: gesture.view)
            let distance = max(abs(offset.x), abs(offset.y))
            guard (distance >= 36 && Date().timeIntervalSince(last) > 0.09) || (gesture.state == .ended && distance > 12) else { return }
            send(abs(offset.x) > abs(offset.y) ? (offset.x > 0 ? .right : .left) : (offset.y > 0 ? .down : .up))
            gesture.setTranslation(.zero, in: gesture.view); last = Date()
        }
    }
}

struct TouchpadView: View {
    @ObservedObject var model: RemoteModel
    @EnvironmentObject private var settings: AppSettings
    @State private var feedback = 0
    private func send(_ key: TVKey) { guard model.ready else { return }; model.tap(key); feedback += 1 }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(.white.opacity(0.04))
            VStack(spacing: 12) {
                Image(systemName: "hand.draw").font(.system(size: 34))
                Text("Swipe to navigate").font(.headline)
                Text("Tap to select · two fingers to go back").font(.caption).foregroundStyle(.secondary)
            }.allowsHitTesting(false)
            TouchSurface(send: send)
        }.frame(height: 284).opacity(model.ready ? 1 : 0.45)
            .sensoryFeedback(.impact(weight: .light), trigger: feedback) { _, _ in settings.value.haptics }
            .accessibilityElement(children: .ignore).accessibilityLabel("TV touchpad")
            .accessibilityAction(named: "Up") { send(.up) }.accessibilityAction(named: "Down") { send(.down) }
            .accessibilityAction(named: "Left") { send(.left) }.accessibilityAction(named: "Right") { send(.right) }
            .accessibilityAction(named: "Select") { send(.select) }.accessibilityAction(named: "Back") { send(.back) }
    }
}

struct KeyboardView: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var secure = false
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if secure { SecureField("Search or enter text", text: $text) }
                    else { TextField("Search or enter text", text: $text) }
                    Toggle("Hide text while typing", isOn: $secure)
                } footer: { Text("First focus a search or password field on the TV. Text is sent over the paired encrypted connection and is never saved.") }
                Button(busy ? "Sending…" : "Send to TV") {
                    busy = true; message = ""
                    Task {
                        defer { busy = false }
                        do { try await model.sendText(text); text = ""; message = "Text sent" }
                        catch { message = error.localizedDescription }
                    }
                }.disabled(!model.ready || text.isEmpty || text.utf16.count > 4096 || busy)
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle("Type on TV").toolbar { Button("Done") { text = ""; dismiss() } }
        }.onDisappear { text = "" }.presentationDetents([.medium, .large])
    }
}

struct ShortcutSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        List {
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
        }.navigationTitle("Remote shortcuts").toolbar { EditButton() }
    }
}

struct AppBadge: View {
    let app: RemoteApp?
    var body: some View {
        Group {
            if let logo = app?.logo, UIImage(named: logo) != nil { Image(logo).resizable().renderingMode(.template).scaledToFit().padding(5) }
            else { Image(systemName: "app").font(.title3) }
        }.foregroundStyle(.white).frame(width: 38, height: 38).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
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
            Section {
                ForEach(settings.value.inputs) { input in
                    HStack {
                        Button {
                            guard settings.value.editorHost == model.host, let id = input.inputID, let found = settings.value.tvInputs.first(where: { $0.id == id }) else {
                                message = "Sync the TV editor and assign an input first."; return
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
                TextField("Device name", text: $input.name)
                Picker("TV input", selection: Binding(get: { input.inputID ?? "" }, set: { input.inputID = $0.isEmpty ? nil : $0 })) {
                    Text("Not assigned").tag("")
                    ForEach(settings.value.tvInputs) { Text($0.name).tag($0.id) }
                }
                if settings.value.tvInputs.isEmpty { Text("Connect the TV editor to sync available inputs.").font(.footnote) }
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
