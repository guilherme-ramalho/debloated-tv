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
        if !UITestHooks.foundTVs.isEmpty { discovery.show(UITestHooks.foundTVs) }
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
                        let pairable = tv.host != nil && tv.support?.canPair != false
                        Button { if let host = tv.host { model.pair(with: host, name: tv.name) } } label: {
                            QuietRow(title: Text(verbatim: tv.name), detail: Text(verbatim: tv.detail), symbol: "tv", chevron: pairable)
                                .opacity(tv.support?.canPair == false ? 0.55 : 1)
                        }.buttonStyle(.plain).disabled(!pairable)
                        .accessibilityIdentifier("foundTV").accessibilityValue(Text(verbatim: tv.host ?? ""))
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

extension DiscoveredTV {
    /// The row's second line: the kind of TV and what Purio can do on it.
    var detail: String {
        guard let host else { return String(localized: "Finding its address…") }
        guard let support else { return kind == .androidTV ? kind.label + " · " + host : String(localized: "Checking…") }
        return kind.label + " · " + support.summary
    }
}

extension TVSupport {
    var summary: String {
        switch self {
        case .full(showOnTV: true): String(localized: "Remote, setup and Show on TV")
        case .full(showOnTV: false): String(localized: "Remote and setup")
        case .remoteComing: String(localized: "Remote coming soon")
        case .notYet: String(localized: "Not supported yet")
        }
    }
}

/// Typing the TV's address when it isn't found on the network.
struct AddressEntrySheet: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var checking = false
    /// What answered at that address when it isn't an Android TV.
    @State private var other: TVKind?
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
                if let other {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(QuietTheme.muted).accessibilityHidden(true)
                        Text(verbatim: other == .chromecast
                             ? String(localized: "That's a Chromecast. Purio can't control it yet.")
                             : String(format: String(localized: "That's a %@ TV. Its remote is coming to Purio soon."), other.label))
                            .font(.system(size: 13)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityElement(children: .combine).accessibilityIdentifier("otherTVKind")
                }
                Button { connect() } label: {
                    if checking { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…") } } else { Text("Connect") }
                }
                .buttonStyle(QuietPrimaryStyle()).disabled(!TVAddress.isIPv4(address) || checking)
                .onChange(of: address) { _, _ in other = nil }
            }.quietNavigation("TV address").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.large])
    }

    /// Knocks on the address first: an Android TV (or nothing answering, which pairing then explains) goes on to
    /// pairing; any other TV is named here instead of a pairing that could never work.
    private func connect() {
        let host = TVAddress.typed(address)
        if ProcessInfo.processInfo.arguments.contains("-e2eNoDiscovery") { dismiss(); model.pair(with: host, name: nil); return }
        checking = true
        Task {
            let open = await PortKnock.openPorts(host: host)
            checking = false
            if let kind = TVPorts.kind(open: open), kind != .androidTV { other = kind; return }
            dismiss(); model.pair(with: host, name: nil)
        }
    }
}

/// The connection button at the top of the remote: says what's going on and does the useful thing when tapped.
/// `.pill` is the compact capsule; `.block` is the remote's two-line header (TV and its state, then the app on screen).
struct TVConnectionChip: View {
    enum Layout { case pill, block }
    @ObservedObject var model: RemoteModel
    var layout: Layout = .pill
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
        if layout == .block { block } else { pill }
    }
    private static let green = Color(red: 92/255, green: 200/255, blue: 168/255)
    private static let amber = Color(red: 240/255, green: 170/255, blue: 90/255)
    private var block: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: tap) {
                HStack(spacing: 7) {
                    switch state {
                    case .connect: Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundStyle(QuietTheme.cyan); Text("Connect TV")
                    case .busy: ProgressView().controlSize(.mini); Text(verbatim: model.tvName).foregroundStyle(QuietTheme.muted)
                    case .connected: Circle().fill(Self.green).frame(width: 8, height: 8); Text(verbatim: model.tvName)
                    case .standby: Circle().fill(QuietTheme.muted).frame(width: 8, height: 8); Text("Standby · Wake")
                    case .offline: Circle().fill(Self.amber).frame(width: 8, height: 8); Text("Offline · Retry").foregroundStyle(Self.amber)
                    }
                }
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(state == .busy || model.showingPIN)
            .accessibilityLabel(state == .connect ? Text("Connect TV") : Text("TV connection"))
            .accessibilityValue(Text(verbatim: model.status))
            // The app on screen sits outside the button so VoiceOver and UI tests read it on its own ("On TV: …").
            if state == .connected, let app = model.currentAppName {
                HStack(spacing: 5) {
                    Image(systemName: "tv").font(.system(size: 12, weight: .medium))
                    Text(app).lineLimit(1).minimumScaleFactor(0.85)
                }
                .font(.system(size: 13)).foregroundStyle(QuietTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).onTapGesture(perform: tap)
                .accessibilityElement(children: .ignore).accessibilityLabel("On TV: " + app)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .onChange(of: model.ready) { _, ready in if ready { retried = false } }
    }
    private var pill: some View {
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

