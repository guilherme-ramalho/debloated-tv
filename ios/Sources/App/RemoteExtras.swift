import SwiftUI
import UIKit

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
                Group {
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

                }.listRowBackground(QuietTheme.panel)
}.textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle("Type on TV").toolbar { Button("Done") { text = ""; dismiss() } }
        }.onDisappear { text = "" }.presentationDetents([.medium, .large])
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

/// Buttons keep tap/hold accessibility. The parent pan cancels button touches before
/// a swipe can become a tap; exactly one direction is sent when that swipe ends.
struct UnifiedDPad: UIViewRepresentable {
    @ObservedObject var model: RemoteModel
    var haptics: Bool
    func makeCoordinator() -> Coordinator { Coordinator(model: model, haptics: haptics) }
    func makeUIView(context: Context) -> PadUIView {
        let view = PadUIView()
        for (key, button) in view.buttons {
            button.tag = Int(key.rawValue)
            button.addTarget(context.coordinator, action: #selector(Coordinator.tap(_:)), for: .touchUpInside)
        }
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipe(_:)))
        pan.maximumNumberOfTouches = 1; pan.cancelsTouchesInView = true
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.35; hold.allowableMovement = 12; hold.cancelsTouchesInView = true
        view.addGestureRecognizer(pan); view.addGestureRecognizer(hold)
        context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: PadUIView, context: Context) {
        context.coordinator.haptics = haptics
        view.isUserInteractionEnabled = model.ready; view.alpha = model.ready ? 1 : 0.45
        if !model.ready { context.coordinator.release() }
    }
    static func dismantleUIView(_ view: PadUIView, coordinator: Coordinator) { coordinator.release() }
    @MainActor final class Coordinator: NSObject {
        let model: RemoteModel
        var haptics: Bool
        weak var view: PadUIView?
        private var held: TVKey?
        init(model: RemoteModel, haptics: Bool) { self.model = model; self.haptics = haptics }
        func feedback() { if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
        @objc func tap(_ sender: UIButton) {
            guard model.ready, let key = TVKey(rawValue: UInt64(sender.tag)) else { return }
            model.tap(key); feedback()
        }
        @objc func swipe(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { release() }
            guard gesture.state == .ended, model.ready else { return }
            let delta = gesture.translation(in: gesture.view)
            guard let key = TVKey.swipeDirection(dx: Double(delta.x), dy: Double(delta.y)) else { return }
            model.tap(key); feedback(); view?.flash(key)
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard model.ready, let view, let key = view.key(at: gesture.location(in: view)) else { return }
                held = key; view.buttons[key]?.isHighlighted = true; model.press(key); feedback()
            case .ended, .cancelled, .failed: release()
            default: break
            }
        }
        func release() {
            guard let key = held else { return }; held = nil
            view?.buttons[key]?.isHighlighted = false; model.release(key)
        }
    }
}

final class PadUIView: UIView {
    private(set) var buttons: [TVKey: UIButton] = [:]
    private let disk = UIView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        disk.backgroundColor = UIColor(red: 21/255, green: 27/255, blue: 39/255, alpha: 1)
        disk.layer.borderColor = UIColor.white.withAlphaComponent(0.07).cgColor; disk.layer.borderWidth = 1
        disk.isUserInteractionEnabled = false; addSubview(disk)
        for (key, symbol, label) in [(TVKey.up, "chevron.up", "Up"), (.down, "chevron.down", "Down"), (.left, "chevron.left", "Left"), (.right, "chevron.right", "Right"), (.select, "", "Select")] {
            let button = UIButton(type: .custom)
            button.tintColor = .white; button.setTitleColor(.white, for: .normal); button.accessibilityLabel = label
            if symbol.isEmpty { button.setTitle("OK", for: .normal); button.titleLabel?.font = .systemFont(ofSize: 26, weight: .semibold) }
            else { button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .medium)), for: .normal) }
            button.configurationUpdateHandler = { button in
                button.backgroundColor = UIColor.white.withAlphaComponent(button.isHighlighted ? 0.2 : (key == .select ? 0.09 : 0))
                button.layer.borderColor = UIColor.white.withAlphaComponent(button.isHighlighted ? 0.55 : (key == .select ? 0.12 : 0)).cgColor
                button.layer.borderWidth = 1
            }
            button.backgroundColor = UIColor.white.withAlphaComponent(key == .select ? 0.09 : 0)
            addSubview(button); buttons[key] = button
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); disk.frame = bounds; disk.layer.cornerRadius = bounds.width/2
        let cx = bounds.midX, cy = bounds.midY
        buttons[.up]?.frame = CGRect(x: cx-50, y: cy-136, width: 100, height: 66)
        buttons[.down]?.frame = CGRect(x: cx-50, y: cy+70, width: 100, height: 66)
        buttons[.left]?.frame = CGRect(x: cx-136, y: cy-50, width: 66, height: 100)
        buttons[.right]?.frame = CGRect(x: cx+70, y: cy-50, width: 66, height: 100)
        buttons[.select]?.frame = CGRect(x: cx-58, y: cy-58, width: 116, height: 116)
        for (key, button) in buttons { button.layer.cornerRadius = key == .select ? 58 : 24 }
    }
    func key(at point: CGPoint) -> TVKey? { buttons.first(where: { $0.value.frame.contains(point) })?.key }
    func flash(_ key: TVKey) {
        guard let button = buttons[key] else { return }; button.isHighlighted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak button] in button?.isHighlighted = false }
    }
}
