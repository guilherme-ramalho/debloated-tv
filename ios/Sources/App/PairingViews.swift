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
