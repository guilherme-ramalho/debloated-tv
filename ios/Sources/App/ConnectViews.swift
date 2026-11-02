import SwiftUI
import UIKit

/// The Remote tab before any TV is paired: find the TV on the network and pair with it, or type its address.
struct ConnectTVView: View {
    @ObservedObject var model: RemoteModel
    @StateObject private var discovery = TVDiscovery()
    @State private var typing = false
    @State private var waitedLong = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if discovery.tvs.isEmpty && (waitedLong || discovery.blocked) { noneFound } else { found }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        .onAppear { search() }
        .onDisappear { discovery.stop() }
        .onChange(of: phase) { _, value in if value == .active { search() } else { discovery.stop() } }
        .sheet(isPresented: $typing) { AddressEntrySheet(model: model) }
    }

    private func search() {
        waitedLong = false
        discovery.start()
        Task { try? await Task.sleep(for: .seconds(8)); waitedLong = true }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your TV").font(.system(size: 26, weight: .semibold))
                Text("Make sure the TV is on and on the same Wi-Fi as this iPhone. Then pick it below.")
                    .font(.system(size: 14)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("TVs on your network").font(.system(size: 13, weight: .medium)).foregroundStyle(QuietTheme.muted)
                Spacer()
                if discovery.searching {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Still looking…") }
                        .font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                }
            }
            if !discovery.tvs.isEmpty {
                QuietCard {
                    ForEach(discovery.tvs) { tv in
                        Button { if let host = tv.host { model.pair(with: host, name: tv.name) } } label: {
                            QuietRow(title: Text(verbatim: tv.name), detail: tv.host.map { Text(verbatim: $0) } ?? Text("Finding its address…"), symbol: "tv")
                        }.buttonStyle(.plain).disabled(tv.host == nil)
                        if tv.id != discovery.tvs.last?.id { Divider().overlay(QuietTheme.edge) }
                    }
                }
            }
            Button("My TV isn't listed: enter its address") { typing = true }
                .font(.system(size: 14)).foregroundStyle(QuietTheme.cyan).frame(maxWidth: .infinity, minHeight: 44)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(QuietTheme.muted).accessibilityHidden(true)
                Text("Works with Android TV and Google TV. Next, your TV shows a 6-character code to confirm it's you.")
                    .font(.system(size: 12)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var noneFound: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("No TV found yet").font(.system(size: 26, weight: .semibold))
                Text("Still looking. These usually fix it:").font(.system(size: 14)).foregroundStyle(QuietTheme.muted)
            }
            QuietCard {
                VStack(alignment: .leading, spacing: 4) {
                    tip(1, "Turn the TV on", "Fully on, not in standby, the first time.")
                    tip(2, "Same network", "This iPhone on the TV's Wi-Fi, not a guest network or mobile data.")
                    VStack(alignment: .leading, spacing: 0) {
                        tip(3, "Allow Local Network", "iOS needs your OK for the app to see the TV.")
                        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                            .font(.system(size: 12)).foregroundStyle(QuietTheme.cyan).padding(.leading, 50).frame(minHeight: 44)
                    }
                    tip(4, "An Android TV or Google TV", "Other systems (Samsung, LG webOS, Roku) aren't supported.")
                }.padding(.vertical, 6)
            }
            Button("Search again") { search() }.buttonStyle(QuietPrimaryStyle())
            Button("Enter the TV's address instead") { typing = true }
                .font(.system(size: 14)).foregroundStyle(QuietTheme.cyan).frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func tip(_ n: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(QuietTheme.cyan)
                .frame(width: 24, height: 24).background(QuietTheme.cyan.opacity(0.18), in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// An IPv4 field that works with every regional keyboard: a dot key, commas turned into dots, and a live check.
struct TVAddressField: View {
    @Binding var address: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AddressTextField(text: $address, label: String(localized: "The TV's IP address"))
                .padding(.horizontal, 14).frame(minHeight: 52)
                .background(QuietTheme.background, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(valid ? QuietTheme.cyan : .white.opacity(0.12), lineWidth: 1))
            if valid {
                Label("Looks right", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(QuietTheme.cyan)
            } else if !address.isEmpty {
                Text("Four numbers separated by dots, like 192.168.1.20").font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
    }
    var valid: Bool { TVAddress.isIPv4(address) }
}

/// The text field behind TVAddressField. Commas and spaces are fixed as each key is typed, inside UIKit,
/// so the field never round-trips through SwiftUI mid-typing (rewriting the binding in onChange dropped keystrokes).
private struct AddressTextField: UIViewRepresentable {
    @Binding var text: String
    let label: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "192.168.1.20"
        field.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        field.textColor = .label
        field.tintColor = .white
        field.keyboardType = .numbersAndPunctuation
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .done
        field.accessibilityLabel = label
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
        field.text = text
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text { field.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func edited(_ field: UITextField) { text.wrappedValue = field.text ?? "" }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let tidy = TVAddress.typed(string)
            guard tidy != string, let current = field.text, let swapped = Range(range, in: current) else { return true }
            let updated = current.replacingCharacters(in: swapped, with: tidy)
            field.text = updated
            if let caret = field.position(from: field.beginningOfDocument, offset: range.location + (tidy as NSString).length) {
                field.selectedTextRange = field.textRange(from: caret, to: caret)
            }
            text.wrappedValue = updated
            return false
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool { field.resignFirstResponder(); return true }
    }
}

/// Typing the TV's address when it isn't found on the network.
struct AddressEntrySheet: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    var body: some View {
        NavigationStack {
            QuietPage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The TV's IP address").font(.system(size: 13, weight: .medium)).foregroundStyle(QuietTheme.muted)
                    TVAddressField(address: $address)
                }
                QuietCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Where to find it").font(.system(size: 14, weight: .medium))
                        Text("On the TV: Settings › Network & Internet › your Wi-Fi or Ethernet connection › IP address. It looks like 192.168.1.20.")
                            .font(.system(size: 13)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }.padding(14)
                }
                Button("Connect") { dismiss(); model.pair(with: address, name: nil) }
                    .buttonStyle(QuietPrimaryStyle()).disabled(!TVAddress.isIPv4(address))
            }.quietNavigation("TV address").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.large])
    }
}

/// The connection button at the top of the remote: says what's going on and does the useful thing when tapped.
struct TVConnectionChip: View {
    @ObservedObject var model: RemoteModel
    let openDetails: () -> Void
    @State private var retried = false
    private enum ChipState { case connect, busy, connected, standby, offline }
    private var state: ChipState {
        if !model.hasSavedPairing { return .connect }
        if model.preparing || model.waking || model.status == String(localized: "Connecting…") { return .busy }
        if model.ready { return model.powerOn == false ? .standby : .connected }
        return .offline
    }
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 7) {
                switch state {
                case .connect: Text("Connect TV").font(.system(size: 13, weight: .semibold))
                case .busy: ProgressView().controlSize(.mini); Text(verbatim: model.tvName).font(.system(size: 13))
                case .connected: Circle().fill(Color(red: 92/255, green: 200/255, blue: 168/255)).frame(width: 8, height: 8); Text(verbatim: model.tvName).font(.system(size: 13))
                case .standby: Circle().fill(QuietTheme.muted).frame(width: 8, height: 8); Text("Standby · Wake").font(.system(size: 13))
                case .offline: Circle().fill(Color(red: 240/255, green: 170/255, blue: 90/255)).frame(width: 8, height: 8); Text("Offline · Retry").font(.system(size: 13))
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(state == .connect ? Color(red: 19/255, green: 33/255, blue: 58/255) : (state == .busy ? QuietTheme.muted : .white))
            .padding(.horizontal, 12).frame(minHeight: 36)
            .background(background, in: Capsule())
            .overlay(Capsule().stroke(state == .offline ? Color(red: 240/255, green: 170/255, blue: 90/255).opacity(0.4) : .clear, lineWidth: 1))
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain).disabled(state == .busy || model.showingPIN)
        .accessibilityLabel(state == .connect ? Text("Connect TV") : Text("TV connection"))
        .accessibilityValue(Text(verbatim: model.status))
        .onChange(of: model.ready) { _, ready in if ready { retried = false } }
    }
    private var background: Color {
        switch state {
        case .connect: .white
        case .offline: Color(red: 240/255, green: 170/255, blue: 90/255).opacity(0.16)
        default: .white.opacity(0.07)
        }
    }
    private func tap() {
        switch state {
        case .connect: openDetails()
        case .standby: model.power()
        case .offline:
            // First tap retries; if the TV still isn't reachable, the details say why and what to check.
            if retried { openDetails() } else { retried = true; model.connect() }
        default: openDetails()
        }
    }
}
