import SwiftUI

struct TVPairingView: View {
    @ObservedObject var model: RemoteModel
    @State private var code = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if !model.showingPIN {
                    Image(systemName: "tv").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Pair your TV").font(.title2.bold())
                }
                if model.showingPIN {
                    VStack(spacing: 6) {
                        Text("Enter the code on your TV").font(.system(size: 20, weight: .semibold))
                        Text("\(model.tvName) is showing a 6-character code.").font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    PairingCodeField(code: $code)
                        .onChange(of: code) { _, value in if value.count == 6 { model.submit(value) } }
                    if !model.error.isEmpty { Text(model.error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
                    Text("Letters A–F and numbers 0–9. It pairs as soon as all six are in.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("The TV shows no code: try again") { code = ""; model.beginPairing() }.font(.footnote).foregroundStyle(QuietTheme.cyan).frame(minHeight: 44)
                } else if !model.error.isEmpty {
                    Text("\(model.tvName) didn't answer.").multilineTextAlignment(.center)
                    Text(model.error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    Button("Try again") { model.beginPairing() }.buttonStyle(QuietPrimaryStyle())
                } else {
                    ProgressView()
                    Text("Asking \(model.tvName) to show a code…").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Keep the TV on and on the same Wi-Fi as this iPhone.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }.padding(30).toolbar { Button("Cancel") { code = ""; model.cancelPairing() } }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled().onDisappear { code = "" }
    }
}

/// Six boxes over one hidden text field, so typing, pasting and the code suggestion bar all work.
struct PairingCodeField: View {
    @Binding var code: String
    @FocusState private var focused: Bool
    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.asciiCapable).textInputAutocapitalization(.characters).autocorrectionDisabled()
                .textContentType(.oneTimeCode).focused($focused).opacity(0.02)
                .onChange(of: code) { _, value in
                    let clean = String(value.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(6))
                    if clean != value { code = clean }
                }
                .accessibilityLabel("Pairing code")
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    let chars = Array(code)
                    Text(verbatim: i < chars.count ? String(chars[i]) : "")
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity).frame(height: 58)
                        .background(QuietTheme.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(i == chars.count && focused ? QuietTheme.cyan : .white.opacity(0.12), lineWidth: 1))
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .contentShape(Rectangle()).onTapGesture { focused = true }
        .onAppear { focused = true }
    }
}
