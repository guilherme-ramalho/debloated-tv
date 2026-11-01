import SwiftUI

struct TVPairingView: View {
    @ObservedObject var model: RemoteModel
    @State private var code = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: model.showingPIN ? 16 : 22) {
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
            }.padding(.horizontal, 24).padding(.vertical, 20).toolbar { Button("Cancel") { code = ""; model.cancelPairing() } }
        }.presentationDetents(model.showingPIN ? [.large] : [.medium, .large]).interactiveDismissDisabled().onDisappear { code = "" }
    }
}

/// Six boxes and an on-screen keypad with exactly the characters a TV code can contain
/// (0–9 and A–F), so numbers and letters are on one screen with no keyboard switching.
struct PairingCodeField: View {
    @Binding var code: String
    private static let rows = [["1", "2", "3", "A"], ["4", "5", "6", "B"], ["7", "8", "9", "C"], ["0", "D", "E", "F"]]
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    let chars = Array(code)
                    Text(verbatim: i < chars.count ? String(chars[i]) : "")
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity).frame(height: 58)
                        .background(QuietTheme.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(i == chars.count ? QuietTheme.cyan : .white.opacity(0.12), lineWidth: 1))
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Pairing code")
            .accessibilityValue(Text(verbatim: code.map(String.init).joined(separator: " ")))
            VStack(spacing: 8) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 8) { ForEach(row, id: \.self) { key($0) } }
                }
                HStack(spacing: 8) {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    Button { if !code.isEmpty { code.removeLast() } } label: {
                        Image(systemName: "delete.left").font(.system(size: 20, weight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 50).contentShape(Rectangle())
                    }
                    .buttonStyle(RemotePressStyle(radius: 12)).disabled(code.isEmpty)
                    .accessibilityLabel("Delete")
                }
            }
        }
    }
    private func key(_ character: String) -> some View {
        Button { if code.count < 6 { code.append(character) } } label: {
            Text(verbatim: character).font(.system(size: 24, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(RemotePressStyle(radius: 12)).foregroundStyle(.white)
    }
}
