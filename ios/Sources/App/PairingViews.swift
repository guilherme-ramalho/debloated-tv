import SwiftUI

struct TVPairingView: View {
    @ObservedObject var model: RemoteModel
    @State private var code = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "tv").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Pair your TV").font(.title2.bold())
                if model.showingPIN {
                    Text("Enter the six-character code shown on the TV.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    TextField("A1B2C3", text: $code).font(.system(size: 30, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onChange(of: code) { _, value in code = String(value.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(6)) }
                    if !model.error.isEmpty { Text(model.error).font(.footnote).foregroundStyle(.orange) }
                    Button("Pair") { model.submit(code) }.buttonStyle(QuietPrimaryStyle()).disabled(code.count != 6)
                    Button("Start pairing again") { code = ""; model.beginPairing() }.font(.footnote)
                } else if !model.error.isEmpty {
                    Text("The TV at \(model.host) didn't answer.").multilineTextAlignment(.center)
                    Text(model.error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    Button("Try again") { model.beginPairing() }.buttonStyle(QuietPrimaryStyle())
                } else {
                    ProgressView()
                    Text("Asking the TV at \(model.host) to show a code…").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Keep the TV on and on the same Wi-Fi as this iPhone.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }.padding(30).toolbar { Button("Cancel") { code = ""; model.cancelPairing() } }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled().onDisappear { code = "" }
    }
}
