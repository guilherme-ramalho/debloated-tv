import SwiftUI

// MARK: TV tab cards

/// TV tab before the new Home screen is installed: what setup does, and the way in.
struct TVSetupHeroCard: View {
    let info: TVSetupInfo
    let start: () -> Void
    /// Already set up (for example before reinstalling this app): press Home on the TV to see which Home it has.
    let check: (() -> Void)?
    var checkMessage = ""
    var body: some View {
        QuietCard { VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 26)).foregroundStyle(QuietTheme.cyan)
                .frame(width: 52, height: 52).background(QuietTheme.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Make your TV faster").font(.system(size: 22, weight: .semibold))
                Text("Switch off the preinstalled apps your TV runs in the background and get a clean, fast Home screen you edit from this iPhone.")
                    .font(.system(size: 14)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 9) {
                benefit("A tested list for your TV model")
                benefit("Nothing is deleted. Undo anytime")
                benefit("No computer needed, about 10 minutes")
            }
            modelRow
            Button("Start setup", action: start).buttonStyle(QuietPrimaryStyle())
            if let check {
                VStack(spacing: 4) {
                    Button("Already set up? Check my TV", action: check)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(QuietTheme.cyan).frame(maxWidth: .infinity, minHeight: 44)
                    Text(checkMessage.isEmpty ? String(localized: "Goes to the TV's Home screen to see which one it has.") : checkMessage)
                        .font(.system(size: 11)).foregroundStyle(QuietTheme.muted).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }
            }
        }.padding(20) }
    }
    private func benefit(_ text: String) -> some View {
        Label { Text(text).font(.system(size: 13)) } icon: { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(QuietTheme.cyan) }
    }
    @ViewBuilder private var modelRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "tv").font(.system(size: 18)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if info.supported == true {
                    Text(info.model).font(.system(size: 13, weight: .medium))
                    if !info.detail.isEmpty { Text(info.detail).font(.system(size: 11)).foregroundStyle(QuietTheme.muted) }
                } else {
                    Text("Check if my TV is supported").font(.system(size: 13, weight: .medium))
                    Text("Setup reads the model before changing anything").font(.system(size: 11)).foregroundStyle(QuietTheme.muted)
                }
            }
            Spacer(minLength: 6)
            if info.supported == true {
                Text("Supported").font(.system(size: 11, weight: .semibold)).foregroundStyle(QuietTheme.background)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(QuietTheme.cyan, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

/// TV tab when setup found no tested list for this model.
struct TVSetupUnsupportedCard: View {
    let info: TVSetupInfo
    let retry: () -> Void
    @Environment(\.openURL) private var openURL
    var body: some View {
        QuietCard { VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 26)).foregroundStyle(QuietTheme.muted)
                .frame(width: 52, height: 52).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("This TV isn't supported for setup yet").font(.system(size: 21, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("There's no tested list for this model, so the app won't guess which apps are safe to switch off. The remote and actions work as usual.")
                    .font(.system(size: 14)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Image(systemName: "tv").font(.system(size: 18)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.model).font(.system(size: 13, weight: .medium))
                    if !info.detail.isEmpty { Text(info.detail).font(.system(size: 11)).foregroundStyle(QuietTheme.muted) }
                }
                Spacer(minLength: 6)
                Text("Not yet").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }.padding(.horizontal, 12).padding(.vertical, 10)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            if let url = ModelRequest.url(info) {
                Button { openURL(url) } label: { Text("Ask for this model").frame(maxWidth: .infinity) }.buttonStyle(QuietSecondaryStyle())
            } else {
                ShareLink(item: ModelRequest.text(info), subject: Text("Purio TV model request")) {
                    Text("Share this model's details").frame(maxWidth: .infinity)
                }.buttonStyle(QuietSecondaryStyle())
            }
            QuietCaption(text: "Only the model and Android version, no personal data. Developers can add a model too.")
            Link("How to add a TV model", destination: ModelRequest.addTVGuide).font(.system(size: 12)).foregroundStyle(QuietTheme.cyan)
            Button("Check again", action: retry).font(.system(size: 12)).foregroundStyle(QuietTheme.muted).frame(minHeight: 44)
        }.padding(20) }
    }
}

/// TV tab after setup: the short status line that leads to managing the setup.
struct TVSetupStrip: View {
    let info: TVSetupInfo
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.shield").font(.system(size: 20)).foregroundStyle(Color(red: 127/255, green: 211/255, blue: 196/255))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Purio TV").font(.system(size: 14, weight: .medium))
                Text(info.disabledCount.map { "\($0) apps off · new Home screen" } ?? "New Home screen installed")
                    .font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
            }
            Spacer(minLength: 6)
            Text("Manage").font(.system(size: 13)).foregroundStyle(QuietTheme.cyan)
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
        }.padding(.horizontal, 13).padding(.vertical, 11).frame(minHeight: 44)
            .background(QuietTheme.toggle.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(QuietTheme.toggle.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Behind the strip: what was done, and the ways to redo or undo it.
struct TVSetupManageView: View {
    let host: String
    @EnvironmentObject private var status: TVSetupStatus
    var body: some View {
        let info = status.info(host)
        QuietPage {
            QuietCard {
                QuietRow(title: info.profile.isEmpty ? Text("New Home screen installed") : Text(verbatim: info.profile),
                         detail: info.disabledCount.map { Text("\($0) apps switched off. Nothing was deleted.") } ?? Text("Set up on this TV."),
                         symbol: "checkmark.shield", chevron: false)
            }
            QuietCard {
                NavigationLink { DebloatSetupView(host: host) } label: {
                    QuietRow(title: "Run setup again", detail: "Change what stays, or update the Home screen", symbol: "arrow.triangle.2.circlepath")
                }
                Divider().overlay(QuietTheme.edge)
                NavigationLink { UndoSetupView(defaultHost: host) } label: {
                    QuietRow(title: "Undo TV setup", detail: "Turn the apps back on and restore the stock Home", symbol: "arrow.uturn.backward")
                }
            }.buttonStyle(.plain)
            QuietCaption(text: "Both need network debugging on the TV for a few minutes. Turn it off again afterwards.")
        }.quietNavigation("TV setup")
    }
}

/// The one-time sheet after a new pairing.
struct TVSetupOfferSheet: View {
    let start: () -> Void
    let later: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Paired with your TV", systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(QuietTheme.cyan)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your TV can be a lot faster").font(.system(size: 24, weight: .semibold))
                Text("Setup switches off the bloat your TV ships with and installs a clean Home screen. It checks your model first, nothing is deleted, and you can undo it anytime.")
                    .font(.system(size: 14)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                fact("0", "apps deleted")
                fact("Undo", "anytime")
                fact("~10 min", "no computer")
            }
            Spacer(minLength: 0)
            Button("Set up my TV", action: start).buttonStyle(QuietPrimaryStyle())
            Button("Not now", action: later).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, minHeight: 44)
            Text("You'll find it in the TV tab whenever you're ready.").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                .frame(maxWidth: .infinity)
        }.padding(24).foregroundStyle(.white)
            .presentationDetents([.medium, .large]).presentationBackground(QuietTheme.panel)
    }
    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 18, weight: .semibold))
            Text(label).font(.system(size: 11)).foregroundStyle(QuietTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: Home screen update

/// TV tab: shown only when this app carries a newer TV Home than the TV reports (LauncherVersion).
struct HomeUpdateCard: View {
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.down.circle").font(.system(size: 20)).foregroundStyle(QuietTheme.cyan).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Home screen update").font(.system(size: 14, weight: .medium))
                Text("A newer TV Home comes with this app. Your layout stays.").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text("Update").font(.system(size: 13)).foregroundStyle(QuietTheme.cyan)
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
        }.padding(.horizontal, 13).padding(.vertical, 11).frame(minHeight: 44)
            .background(QuietTheme.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(QuietTheme.cyan.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Installs the newer TV Home over the old one and keeps everything the TV has (HomeUpdateFlow).
struct HomeUpdateView: View {
    @StateObject private var flow: HomeUpdateFlow
    /// Called once the TV has the new Home (to reconnect the editor and read the new version).
    let updated: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(host: String, updated: @escaping () -> Void) {
        _flow = StateObject(wrappedValue: HomeUpdateFlow(host: host)); self.updated = updated
    }

    var body: some View {
        QuietPage {
            switch flow.step {
            case .start: start
            case .connecting, .updating: working
            case .done: done
            }
            if let error = flow.error {
                QuietCard { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(.orange).padding(14) }
                if !flow.busy && flow.step != .done {
                    Button("Try again") { flow.update() }.buttonStyle(QuietPrimaryStyle()).accessibilityIdentifier("homeUpdateRetry")
                    if flow.installStarted {
                        QuietCaption(text: "The TV may have finished on its own. Try again checks it first and only finishes what's missing.")
                    }
                }
            }
        }
        .quietNavigation("Update Home screen")
        .navigationBarBackButtonHidden(flow.busy)
        .onAppear { flow.onDone = updated }
        // Leaving for another tab mid-update must not strand it: the TV carries on, and so does the phone.
        .onDisappear { if !flow.busy { flow.cancel() } }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update the TV's Home screen").font(.system(size: 24, weight: .bold))
            Text("A newer version of the Home screen comes with this app. Your dock, apps, wallpaper and Home settings stay as they are. Takes about a minute.")
                .font(.system(size: 14)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            QuietCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Turn on network debugging for a moment").font(.system(size: 15, weight: .semibold))
                    numbered(1, "On the TV, open Settings › System › Developer options.")
                    numbered(2, "Turn on USB debugging, and Network or ADB debugging if your TV shows it.")
                    numbered(3, "Check the TV's address in Settings › Network & Internet.")
                }.padding(14)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("TV address").font(.system(size: 13, weight: .medium)).foregroundStyle(QuietTheme.muted)
                TextField("192.168.1.20", text: $flow.address).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(QuietTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            Button("Update Home screen") { flow.update() }.buttonStyle(QuietPrimaryStyle()).disabled(TVAddress(flow.address) == nil || flow.busy)
            QuietCaption(text: "You'll turn debugging off again at the end.")
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 16) {
            if flow.waitingForApproval {
                Image(systemName: "tv.badge.wifi").font(.system(size: 44)).foregroundStyle(QuietTheme.cyan)
                Text("Allow this iPhone on the TV").font(.system(size: 24, weight: .bold))
                Text("The TV shows “Allow USB debugging?”. Tick “Always allow from this computer” and choose Allow. This continues by itself.")
                    .foregroundStyle(QuietTheme.muted)
            } else {
                Text(workingTitle).font(.system(size: 24, weight: .bold))
                if flow.step == .updating { ProgressView(value: flow.progress).tint(QuietTheme.cyan) }
            }
            if flow.busy {
                HStack(spacing: 10) { ProgressView(); Text(flow.message).font(.system(size: 13)).foregroundStyle(QuietTheme.muted) }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("homeUpdateWorking")
                if flow.slow {
                    QuietCaption(text: "The TV is taking longer than usual. Still working: keep the TV on and this iPhone near the Wi-Fi.")
                }
            }
        }
    }

    private var workingTitle: LocalizedStringKey {
        flow.checking ? "Checking the TV" : flow.step == .connecting ? "Connecting" : "Updating the Home screen"
    }

    private var doneTitle: LocalizedStringKey { flow.alreadyCurrent ? "The TV already has this Home screen" : "Home screen updated" }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(doneTitle, systemImage: "checkmark.circle")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(QuietTheme.cyan)
            if !flow.alreadyCurrent {
                QuietCaption(text: "Your layout and settings are as they were. New options appear in the TV tab once TV Home reconnects.")
            }
            Button("Turn off network debugging now") { flow.turnOffDebugging() }.buttonStyle(QuietPrimaryStyle()).disabled(flow.busy)
            if flow.busy { ProgressView() }
            if let closed = flow.debuggingClosed {
                Label(closed ? "Debugging is off: the TV refuses connections." : "The debugging port still accepts connections.",
                      systemImage: closed ? "checkmark.shield" : "exclamationmark.shield").foregroundStyle(closed ? .green : .orange).font(.system(size: 13))
            }
            Button("Done") { dismiss() }.buttonStyle(QuietSecondaryStyle())
        }
    }

    private func numbered(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).frame(width: 24, height: 24).background(QuietTheme.cyan.opacity(0.2), in: Circle())
            Text(text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
