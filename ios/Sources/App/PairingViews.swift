import SwiftUI

struct TVPairingView: View {
    @ObservedObject var model: RemoteModel
    @State private var code = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "tv").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Pair your TV").font(.title2.bold())
                Text("Enter the six-character code shown on the TV.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                TextField("A1B2C3", text: $code).font(.system(size: 30, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .onChange(of: code) { _, value in code = String(value.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(6)) }
                if !model.error.isEmpty { Text(model.error).font(.footnote).foregroundStyle(.orange) }
                Button("Pair") { model.submit(code) }.buttonStyle(QuietPrimaryStyle()).disabled(code.count != 6)
                Button("Start pairing again") { code = ""; model.beginPairing() }.font(.footnote)
            }.padding(30).toolbar { Button("Cancel") { code = ""; model.cancelPairing() } }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled().onDisappear { code = "" }
    }
}

struct EditorPairingView: View {
    @EnvironmentObject private var editor: HomeEditor
    @State private var code = ""
    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    TextField("A1B2C3", text: $code).font(.system(.title2, design: .monospaced)).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onChange(of: code) { _, new in code = String(new.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(6)) }
                    Button("Connect") { editor.submit(code) }.buttonStyle(QuietPrimaryStyle()).disabled(code.count != 6)
                } footer: { Text("Enter the code displayed by TV Home. This pairs the editing session separately from remote control.") }
                Text(editor.message).font(.footnote)

                }.listRowBackground(QuietTheme.panel)
}.navigationTitle("Pair TV Home").toolbar { Button("Cancel") { code = ""; editor.close() } }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled().onDisappear { code = "" }
    }
}
