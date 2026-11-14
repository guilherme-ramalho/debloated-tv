import SwiftUI

/// The guided setup, native version of the Codex preview (debloat-flow-preview.html).
struct DebloatSetupView: View {
    @StateObject private var flow: DebloatFlow
    @EnvironmentObject private var status: TVSetupStatus
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRestore = false

    init(host: String) { _flow = StateObject(wrappedValue: DebloatFlow(host: host)) }

    var body: some View {
        QuietPage {
            ProgressView(value: Double(flow.step.rawValue + 1), total: Double(DebloatFlow.Step.allCases.count))
                .tint(QuietTheme.cyan)
            content
            if let error = flow.error {
                QuietCard {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(.orange).padding(14)
                }
            }
        }
        .navigationTitle("Set up TV").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if flow.step.rawValue > 0 && flow.step.rawValue < DebloatFlow.Step.apply.rawValue && !flow.busy {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back") { flow.error = nil; flow.step = DebloatFlow.Step(rawValue: flow.step.rawValue - 1) ?? .overview }
                }
            }
        }
        .navigationBarBackButtonHidden(flow.step != .overview)
        .onDisappear { flow.cancel() }
        // What the TV tab shows comes from what this flow saw.
        .onChange(of: flow.inventory?.properties) { _, properties in
            if let properties { status.inspected(setupHost, properties: properties, profile: flow.profile, listsFound: !flow.candidates.isEmpty) }
        }
        .onChange(of: flow.profile?.id) { _, _ in
            if let properties = flow.inventory?.properties, flow.profile != nil { status.inspected(setupHost, properties: properties, profile: flow.profile) }
        }
        .onChange(of: flow.step) { _, step in
            guard step == .test else { return }
            status.update(setupHost) {
                if flow.homeComponent != nil { $0.homeInstalled = true }
                if let result = flow.result { $0.disabledCount = result.disabled.count }
            }
        }
        .onChange(of: flow.restores) { _, _ in status.restored(setupHost) }
        .confirmationDialog("Undo the setup on this TV?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore the TV", role: .destructive) {
                if let url = flow.recordURL, let record = RecoveryStore.load(url) { flow.restore(record, stock: flow.profile?.manifest.stockLauncher) }
            }
        } message: { Text("Turns every app this setup disabled back on and gives Home back to the stock launcher.") }
    }

    private var setupHost: String { TVAddress(flow.address)?.host ?? flow.address }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .overview: overview
        case .developer: developer
        case .connect, .inspect: connecting
        case .choose: choose
        case .review: review
        case .home: home
        case .apply: applying
        case .test: test
        case .finish: finish
        }
    }

    // MARK: steps

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your TV, reclaimed").font(.system(size: 13, weight: .semibold)).foregroundStyle(QuietTheme.muted).textCase(.uppercase)
            Text("Less clutter.\nMore control.").font(.system(size: 30, weight: .bold))
            Text("A guided setup to keep your essentials, disable unwanted extras and choose a cleaner Home. No computer needed.")
                .foregroundStyle(QuietTheme.muted)
            QuietCard {
                QuietRow(title: "Choose what stays", detail: "Your apps, TV features and Home screen. Every change is reviewed first.", symbol: "checklist", chevron: false)
                Divider().overlay(QuietTheme.edge)
                QuietRow(title: "Save a recovery record", detail: "How every app was before setup, so it can all be put back. Not a full TV backup.", symbol: "arrow.uturn.backward.circle", chevron: false)
            }
            QuietCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("System changes carry risk").font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
                    Text("Apps are disabled, never uninstalled, and only from cleanyourtv's lists, tested by its community on real TVs. Still, a feature can stop working, and in rare cases recovery may need a factory reset. You use this at your own risk.")
                        .font(.system(size: 13)).foregroundStyle(QuietTheme.muted)
                    Toggle("I understand the risks", isOn: $flow.acknowledged).toggleStyle(QuietToggleStyle()).font(.system(size: 14, weight: .medium))
                }.padding(14)
            }
            QuietCaption(text: "Have the TV's remote ready: turning on debugging and approving this iPhone happen on the TV.")
            Button("Continue") { flow.step = .developer }.buttonStyle(QuietPrimaryStyle()).disabled(!flow.acknowledged)
        }
    }

    private var developer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Turn on network debugging").font(.system(size: 24, weight: .bold))
            QuietCard {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "On the TV, open Settings › System › About (on some TVs: Device Preferences › About).")
                    step(2, "Highlight “Build” (or “Android TV OS build”) and press the remote’s OK button seven times, until it says you’re a developer.")
                    step(3, "Go back to Settings › System › Developer options. Turn on USB debugging, and Network or ADB debugging if your TV shows it.")
                    step(4, "Find the TV’s IP address in Settings › Network & Internet, under your connection.")
                }.padding(14)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("TV address").font(.system(size: 13, weight: .medium)).foregroundStyle(QuietTheme.muted)
                TextField("192.168.1.20", text: $flow.address).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(QuietTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            QuietCaption(text: "Newer TVs with only “Wireless debugging” (a pairing code) aren’t supported yet.")
            Button("Connect") { flow.step = .connect; flow.connect() }.buttonStyle(QuietPrimaryStyle()).disabled(TVAddress(flow.address) == nil)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).frame(width: 24, height: 24).background(QuietTheme.cyan.opacity(0.2), in: Circle())
            Text(text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connecting: some View {
        VStack(alignment: .leading, spacing: 16) {
            if flow.waitingForApproval {
                Image(systemName: "tv.badge.wifi").font(.system(size: 44)).foregroundStyle(QuietTheme.cyan)
                Text("Allow this iPhone on the TV").font(.system(size: 24, weight: .bold))
                Text("The TV shows “Allow USB debugging?”. Tick “Always allow from this computer” and choose Allow. This continues by itself.")
                    .foregroundStyle(QuietTheme.muted)
            } else if !flow.busy && flow.inventory != nil && (flow.profile == nil || (flow.step == .inspect && flow.match?.kind != .tested)) {
                if flow.candidates.isEmpty { unsupported } else { listPicker }
            } else {
                Text(flow.step == .connect ? "Connecting" : "Checking the TV").font(.system(size: 24, weight: .bold))
            }
            if flow.busy { HStack { ProgressView(); Text(flow.message).font(.system(size: 13)).foregroundStyle(QuietTheme.muted) } }
            if !flow.busy && flow.error != nil {
                Button("Try again") {
                    if flow.step == .inspect && flow.inventory == nil && flow.message.contains("Reading") { flow.inspect() } else { flow.connect() }
                }
                    .buttonStyle(QuietPrimaryStyle())
            }
        }
    }

    private var unsupported: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This TV isn’t supported yet").font(.system(size: 24, weight: .bold))
            let p = flow.inventory?.properties ?? [:]
            QuietCard {
                QuietRow(title: p["ro.product.model"].map { Text(verbatim: $0) } ?? Text("Unknown model"), detail: Text(verbatim: "\(p["ro.product.manufacturer"] ?? "") · \(p["ro.product.device"] ?? "") · Android \(p["ro.build.version.release"] ?? "?")"), symbol: "tv", chevron: false)
            }
            QuietCaption(text: "None of cleanyourtv's lists fits this TV, so nothing was changed. Guessing which apps are safe to disable can leave inputs black or the TV unable to start.")
            if DebloatFlow.isDevelopmentBuild {
                QuietCaption(text: "Development build. Profiles in this build: " + (flow.profiles.isEmpty ? "none (Resources/Profiles wasn't bundled)" : flow.profiles.map(\.id).joined(separator: ", ")) + ".")
            }
            Button("Close") { dismiss() }.buttonStyle(QuietSecondaryStyle())
        }
    }

    @State private var showAllLists = false
    /// A list made for another model, waiting for the person to confirm it.
    @State private var closestPending: ProfileMatch?

    /// The lists ProfileMatcher found for this TV, best first; the person picks the one for their TV.
    private var listPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your TV's list").font(.system(size: 24, weight: .bold))
            let p = flow.inventory?.properties ?? [:]
            QuietCaption(text: String(localized: "This TV reports \(p["ro.product.model"] ?? "?") (\(p["ro.product.device"] ?? "?")). These lists come from cleanyourtv, each tested by its community on the TV it names. The best match is first."))
            let shown = showAllLists ? flow.candidates : Array(flow.candidates.prefix(3))
            QuietCard {
                ForEach(shown) { candidate in
                    Button { if candidate.kind == .closest { closestPending = candidate } else { flow.choose(candidate) } } label: {
                        QuietRow(title: Text(verbatim: candidate.profile.manifest.name), detail: Text(Self.matchDetail(candidate)),
                                 symbol: candidate.kind == .closest ? "questionmark.circle" : "checkmark.circle", chevron: true)
                    }.buttonStyle(.plain)
                    if candidate.id != shown.last?.id { Divider().overlay(QuietTheme.edge) }
                }
            }
            if flow.candidates.count > 3 && !showAllLists {
                Button("Show \(flow.candidates.count - 3) more") { showAllLists = true }.buttonStyle(QuietSecondaryStyle())
            }
            QuietCaption(text: "Nothing changes on the TV until you review and apply. Every change can be undone.")
            Button("Close") { dismiss() }.buttonStyle(QuietSecondaryStyle())
        }
        .confirmationDialog("Use a list made for another model?", isPresented: Binding(get: { closestPending != nil }, set: { if !$0 { closestPending = nil } }),
                            titleVisibility: .visible, presenting: closestPending) { candidate in
            Button("Use this list") { flow.choose(candidate) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Nobody has tested it on your TV. Only apps found on your TV are offered and the safety checks still run, but an app your TV needs can look like one to remove. Check every app before you apply.")
        }
    }

    /// One app gets its own sentence, as in matchDetail: the catalog has no plural variants.
    static func chooseFooter(protected: Int, handled: Int) -> String {
        switch (protected == 1, handled == 1) {
        case (true, true): return String(localized: "Keep switched on = stays enabled. 1 protected system app is never touched. 1 listed app is already off or not installed.")
        case (true, false): return String(localized: "Keep switched on = stays enabled. 1 protected system app is never touched. \(handled) listed apps are already off or not installed.")
        case (false, true): return String(localized: "Keep switched on = stays enabled. \(protected) protected system apps are never touched. 1 listed app is already off or not installed.")
        case (false, false): return String(localized: "Keep switched on = stays enabled. \(protected) protected system apps are never touched. \(handled) listed apps are already off or not installed.")
        }
    }

    static func matchDetail(_ match: ProfileMatch) -> String {
        // One app gets its own sentence: the catalog has no plural variants for these.
        let one = match.present == 1
        let names = match.named.joined(separator: ", ")
        switch match.kind {
        case .tested: return one ? String(localized: "Tested with Purio TV on this TV. 1 app to review.")
                                 : String(localized: "Tested with Purio TV on this TV. \(match.present) apps to review.")
        case .model: return one ? String(localized: "Made for this model (\(names)). 1 of its apps is on this TV.")
                                : String(localized: "Made for this model (\(names)). \(match.present) of its apps are on this TV.")
        case .closest: return one ? String(localized: "Made for another model, the closest match. 1 of its apps is on this TV.")
                                  : String(localized: "Made for another model, the closest match. \(match.present) of its apps are on this TV.")
        }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose what stays").font(.system(size: 24, weight: .bold))
            if let profile = flow.profile {
                QuietCard { QuietRow(title: Text(verbatim: profile.manifest.name), detail: Text(chooseDetail), symbol: flow.match?.kind == .closest ? "exclamationmark.triangle" : "checkmark.seal", chevron: false) }
                if profile.isCommunity { listNotes(profile) }
                ForEach(profile.list.groups, id: \.self) { group in
                    let entries = flow.choices.filter { $0.group == group }
                    if !entries.isEmpty {
                        QuietSectionTitle(title: group)
                        QuietCard {
                            ForEach(entries) { entry in
                                Toggle(isOn: Binding(get: { flow.keep.contains(entry.package) }, set: { if $0 { flow.keep.insert(entry.package) } else { flow.keep.remove(entry.package) } })) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(Self.title(entry)).font(.system(size: 14, weight: .medium))
                                        if !entry.note.isEmpty { Text(entry.package).font(.system(size: 11)).foregroundStyle(QuietTheme.muted) }
                                    }
                                }.toggleStyle(QuietToggleStyle()).padding(.horizontal, 13).padding(.vertical, 9)
                                if entry.id != entries.last?.id { Divider().overlay(QuietTheme.edge) }
                            }
                        }
                    }
                }
                QuietCaption(text: Self.chooseFooter(protected: flow.protectedCount, handled: flow.alreadyHandled))
            }
            Button(flow.busy ? "Checking…" : "Review changes") { flow.review() }.buttonStyle(QuietPrimaryStyle()).disabled(flow.busy)
        }
    }

    private var chooseDetail: String {
        switch flow.match?.kind {
        case .closest?: return String(localized: "This list was made for another model. Only apps installed on this TV are shown: check each one, and switch on anything you want to keep; the rest is disabled.")
        case .model?: return String(localized: "List from cleanyourtv, tested by its community on this model, not by Purio TV. Switch on anything you want to keep; the rest is disabled.")
        default: return String(localized: "Tested list from cleanyourtv. Switch on anything you want to keep; the rest is disabled.")
        }
    }

    /// What the list's testers wrote: the importer's warnings and the list's summary (tv.json notes).
    @ViewBuilder private func listNotes(_ profile: DebloatProfile) -> some View {
        let warnings = profile.manifest.warnings ?? []
        if !warnings.isEmpty {
            QuietSectionTitle(title: "From the list's testers")
            QuietCard {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(warnings, id: \.self) { warning in Label { Text(verbatim: warning).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) } }
                }.padding(14)
            }
        }
        if !profile.notes.isEmpty {
            DisclosureGroup("About this list") {
                Text(verbatim: profile.notes).font(.system(size: 12)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }.tint(.white).font(.system(size: 14))
        }
    }

    static func title(_ entry: DebloatList.Entry) -> String {
        guard let first = entry.note.first else { return entry.package }
        return String(first).uppercased() + String(entry.note.dropFirst())
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review").font(.system(size: 24, weight: .bold))
            if let plan = flow.plan {
                QuietCard { QuietRow(title: "\(plan.disable.count) apps will be disabled", detail: "Not uninstalled. The recovery record can turn them all back on.", symbol: "minus.circle", chevron: false) }
                if !plan.skipped.isEmpty {
                    QuietSectionTitle(title: "Kept by the safety checks")
                    QuietCard {
                        ForEach(plan.skipped) { skip in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skip.package).font(.system(size: 13, weight: .medium))
                                Text(skip.reason).font(.system(size: 12)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
                            }.padding(.horizontal, 13).padding(.vertical, 9)
                            if skip.id != plan.skipped.last?.id { Divider().overlay(QuietTheme.edge) }
                        }
                    }
                }
                ForEach(plan.notes, id: \.self) { QuietCaption(text: $0) }
                if !plan.wifiToResave.isEmpty { wifiResave(plan.wifiToResave) }
                DisclosureGroup("Show the \(plan.disable.count) apps") {
                    VStack(alignment: .leading, spacing: 4) { ForEach(plan.disable, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)) } }.padding(.top, 6)
                }.tint(.white).font(.system(size: 14))
                Toggle("I reviewed these changes", isOn: $flow.understood).toggleStyle(QuietToggleStyle()).font(.system(size: 14, weight: .medium))
                Button("Continue") { flow.step = .home }.buttonStyle(QuietPrimaryStyle()).disabled(!flow.understood || !flow.wifiReady)
            }
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Home").font(.system(size: 24, weight: .bold))
            if let block = flow.homeScreenBlock {
                QuietCard { QuietRow(title: Text("The TV keeps its own Home screen"), detail: Text(Self.homeBlockText(block)), symbol: "house", chevron: false) }
            } else {
                Toggle(isOn: $flow.installLauncher) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Install the clean Home screen").font(.system(size: 14, weight: .medium))
                        Text("Replaces the stock launcher, which is disabled once the new one is running. Needed for TV Home editing in this app.").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                    }
                }.toggleStyle(QuietToggleStyle())
                if flow.installLauncher, let profile = flow.profile, let inventory = flow.inventory {
                    QuietSectionTitle(title: "Dock (tap to add or remove, up to 7)")
                    QuietCard {
                        ForEach(profile.manifest.dockCandidates.filter { inventory.installed.contains($0) }, id: \.self) { id in
                            Button {
                                if let i = flow.dock.firstIndex(of: id) { flow.dock.remove(at: i) } else if flow.dock.count < 7 { flow.dock.append(id) }
                            } label: {
                                HStack {
                                    Text(TVSession.appName(for: id) ?? id).font(.system(size: 14))
                                    Spacer()
                                    if let i = flow.dock.firstIndex(of: id) { Text("\(i + 1)").font(.system(size: 12, weight: .bold)).frame(width: 22, height: 22).background(QuietTheme.cyan.opacity(0.25), in: Circle()) }
                                }.padding(.horizontal, 13).frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    QuietCaption(text: "You can rearrange everything later from the TV tab.")
                }
            }
            let blocked = flow.installLauncher && flow.homeScreenAvailable && flow.plan?.setupKeepsHome == true
            if blocked {
                QuietCard {
                    Label("The setup wizard stays on, and on this TV it takes the Home button, so the new Home screen can't take over. Go back to the review to see why it was kept, or apply without the new Home screen.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13)).foregroundStyle(.orange).padding(14)
                }
            }
            QuietCaption(text: "At the end the TV restarts once, so this phone can check that Home and your changes hold before debugging goes off.")
            Button("Apply to TV") { flow.apply() }.buttonStyle(QuietPrimaryStyle()).disabled(flow.busy || blocked)
        }
    }

    static func homeBlockText(_ block: DebloatFlow.HomeScreenBlock) -> String {
        switch block {
        case .fireOS: return String(localized: "Fire TV doesn't let another Home screen take over, so this setup only disables apps.")
        case .cvte: return String(localized: "This TV's board needs a special Home screen procedure that Purio TV doesn't do yet, so this setup only disables apps.")
        case .debloatOnly: return String(localized: "This list's testers only disabled apps on this TV, so this setup does the same.")
        case .customBuild: return String(localized: "This TV only accepts a Home screen built especially for it, which Purio TV doesn't carry, so this setup only disables apps.")
        case .noConfig: return String(localized: "Nobody has set up the new Home screen on this model with cleanyourtv yet, so this setup only disables apps.")
        }
    }

    /// The setup wizard owns these networks and deletes them when it's disabled, so they're saved again first.
    private func wifiResave(_ networks: [WifiNetwork]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            QuietSectionTitle(title: "Keep the TV's Wi-Fi")
            QuietCaption(text: "These networks were saved by the TV's setup wizard, and switching it off deletes them. Enter each password and this phone saves them again on the TV first, so the TV stays online.")
            Label("If a password is wrong, the TV drops off Wi-Fi. You'd then have to join the network again with the TV's own remote, in Settings › Network & Internet.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(.orange)
            QuietCard {
                ForEach(networks) { network in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: network.ssid).font(.system(size: 14, weight: .medium))
                        if network.needsPassword {
                            SecureField("Wi-Fi password", text: Binding(get: { flow.wifiPasswords[network.ssid] ?? "" }, set: { flow.wifiPasswords[network.ssid] = $0 }))
                                .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(10).background(QuietTheme.background, in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel(Text("Wi-Fi password for \(network.ssid)"))
                            SecureField("The same password again", text: Binding(get: { flow.wifiConfirm[network.ssid] ?? "" }, set: { flow.wifiConfirm[network.ssid] = $0 }))
                                .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(10).background(QuietTheme.background, in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel(Text("Wi-Fi password for \(network.ssid), again"))
                            let typed = flow.wifiPasswords[network.ssid] ?? "", again = flow.wifiConfirm[network.ssid] ?? ""
                            if !again.isEmpty && typed != again {
                                Text("The two passwords don't match.").font(.system(size: 12)).foregroundStyle(.orange)
                            }
                        } else {
                            Text("Open network: no password needed.").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                        }
                    }.padding(.horizontal, 13).padding(.vertical, 10)
                    if network.id != networks.last?.id { Divider().overlay(QuietTheme.edge) }
                }
            }
            QuietCaption(text: "The password goes to the TV once, over the debugging connection, which isn't encrypted. It's never saved on this phone.")
            QuietSectionTitle(title: "Safer: do it on the TV")
            QuietCaption(text: "On the TV, open Settings › Network & Internet, forget the network and join it again. The setup wizard no longer owns it then, and nothing needs typing here. Then review again.")
            Button("Review again") { flow.review() }.buttonStyle(QuietSecondaryStyle())
        }
    }

    private var applying: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(flow.busy ? "Applying" : (flow.error == nil ? "Applied" : "Stopped")).font(.system(size: 24, weight: .bold))
            ProgressView(value: flow.progress).tint(QuietTheme.cyan)
            Text(flow.message).font(.system(size: 13)).foregroundStyle(QuietTheme.muted)
            QuietCard {
                VStack(alignment: .leading, spacing: 6) { ForEach(Array(flow.log.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 12)) } }.padding(14)
            }
            if !flow.busy && flow.error != nil {
                QuietCaption(text: "Nothing after the failed step was changed. You can restore everything this setup changed, or go back and try again.")
                Button("Restore the TV") { confirmRestore = true }.buttonStyle(QuietSecondaryStyle())
                Button("Back to review") { flow.error = nil; flow.step = .review }.buttonStyle(QuietSecondaryStyle())
            }
        }
    }

    @State private var checks: Set<Int> = []
    private var checklist: [LocalizedStringKey] {
        [flow.homeComponent == nil ? "The Home button opens the TV's Home screen" : "Home opens the new Home screen",
         "The remote's app buttons and volume work", "An HDMI input shows a picture", "Settings opens from Home",
         "The TV is still online (open an app)"]
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test on the TV").font(.system(size: 24, weight: .bold))
            if let problem = flow.restartProblem {
                QuietCard {
                    Label { Text(verbatim: problem).font(.system(size: 13)) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }.padding(14)
                }
            }
            if flow.restartChecked {
                Label("Restarted and checked: Home works.", systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(.green)
            }
            if let note = flow.restartNote { QuietCaption(text: note) }
            if let result = flow.result, !result.stillEnabled.isEmpty {
                QuietCaption(text: "\(result.stillEnabled.count) apps stayed enabled because the TV refused: \(result.stillEnabled.joined(separator: ", ")).")
            }
            QuietCard {
                ForEach(checklist.indices, id: \.self) { i in
                    Toggle(checklist[i], isOn: Binding(get: { checks.contains(i) }, set: { if $0 { checks.insert(i) } else { checks.remove(i) } }))
                        .toggleStyle(QuietToggleStyle()).font(.system(size: 14)).padding(.horizontal, 13).padding(.vertical, 9)
                    if i < checklist.count - 1 { Divider().overlay(QuietTheme.edge) }
                }
            }
            Button("Everything works") { flow.step = .finish }.buttonStyle(QuietPrimaryStyle()).disabled(checks.count < checklist.count)
            Button("Something’s wrong: restore") { confirmRestore = true }.buttonStyle(QuietSecondaryStyle())
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Secure the TV").font(.system(size: 24, weight: .bold))
            if let url = flow.recordURL {
                ShareLink(item: url) { Label("Export recovery record", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    .buttonStyle(QuietSecondaryStyle())
                QuietCaption(text: "It's also kept in this app (Settings › Undo TV setup). Save a copy in Files in case you replace this iPhone.")
            }
            Button("Turn off network debugging now") { flow.turnOffDebugging() }.buttonStyle(QuietPrimaryStyle()).disabled(flow.busy)
            QuietCaption(text: "Switches debugging off on the TV and checks it's closed. Removing this iPhone's approval still needs the TV's menu (step 1).")
            QuietCard {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Settings › System › Developer options: choose Revoke USB debugging authorizations.")
                    step(2, "Turn off USB debugging, and Network or ADB debugging.")
                    step(3, "Restart the TV.")
                }.padding(14)
            }
            QuietCaption(text: "The remote and TV Home editing don't need debugging. Only another setup or a restore does.")
            Button("Check debugging is off") { flow.checkDebuggingClosed() }.buttonStyle(QuietSecondaryStyle()).disabled(flow.busy)
            if let closed = flow.debuggingClosed {
                Label(closed ? "Debugging is off: the TV refuses connections." : "The debugging port still accepts connections.",
                      systemImage: closed ? "checkmark.shield" : "exclamationmark.shield").foregroundStyle(closed ? .green : .orange).font(.system(size: 13))
            }
            Button("Done") { dismiss() }.buttonStyle(QuietSecondaryStyle())
        }
    }
}

/// Puts a TV back from a saved recovery record.
/// What a restore's read-back says, for the setup flow and the Undo screen.
enum RestoreText {
    static func summary(_ report: RestoreReport) -> String {
        if !report.notBack.isEmpty {
            return String(localized: "Restored, but \(report.notBack.count) apps didn't come back on: \(report.notBack.joined(separator: ", ")). Run the restore again; if they stay off, turn them on in the TV's Settings › Apps.")
        }
        if !report.homeOK, let expected = report.expectedHome {
            return String(localized: "Restored, but Home is now \(report.home.isEmpty ? "nothing" : report.home) instead of \(expected). Run the restore again, or choose a Home app on the TV.")
        }
        return String(localized: "Restored and checked: everything that was on before setup is on again. \(report.keptOff.count) apps stay disabled because they were already off before setup.")
    }
}

struct UndoSetupView: View {
    let defaultHost: String
    @EnvironmentObject private var status: TVSetupStatus
    @State private var records = RecoveryStore.all()
    @State private var selected: URL?
    @State private var address = ""
    @State private var busy = false
    @State private var waiting = false
    @State private var message = ""
    @State private var done = false

    var body: some View {
        QuietPage {
            Text("Undo TV setup").font(.system(size: 24, weight: .bold))
            if records.isEmpty {
                QuietCaption(text: "No recovery records on this iPhone yet. One is saved automatically before a setup changes anything.")
            } else {
                QuietCard {
                    ForEach(records) { item in
                        Button { selected = item.url; address = item.record.host } label: {
                            HStack {
                                QuietRow(title: Text(verbatim: (item.record.lists ?? [item.record.list]).joined(separator: " + ")), detail: Text("\(item.record.host) · \(String(item.record.created.prefix(10))) · \(item.record.packages.values.filter { $0 == "enabled" }.count) apps to turn back on"), symbol: "tv", chevron: false)
                                if selected == item.url { Image(systemName: "checkmark.circle.fill").foregroundStyle(QuietTheme.cyan).padding(.trailing, 13) }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                TextField("TV address", text: $address).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(QuietTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                QuietCaption(text: "Network debugging must be on. The TV's address may have changed since setup.")
                Button(busy ? "Restoring…" : "Restore this TV") { restore() }.buttonStyle(QuietPrimaryStyle())
                    .disabled(busy || selected == nil || TVAddress(address) == nil)
                if waiting { QuietCaption(text: "On the TV, allow this iPhone (“Allow USB debugging?”).") }
                if !message.isEmpty { Text(message).font(.system(size: 13)).foregroundStyle(done ? .green : .orange) }
            }
        }.navigationTitle("Undo TV setup").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Read again on every visit: SwiftUI builds this screen before the link is tapped (Settings), so a
                // record saved by a setup since then wouldn't be listed otherwise (found by the E2E community scenario).
                records = RecoveryStore.all()
                if address.isEmpty { address = defaultHost }
            }
    }

    private func restore() {
        guard let url = selected, let record = RecoveryStore.load(url), let target = TVAddress(address) else { return }
        busy = true; done = false; message = ""
        Task {
            defer { busy = false; waiting = false }
            do {
                let client = AdbClient(host: target.host, port: target.port, key: try AdbKey.loadOrCreate())
                _ = try await client.connect(name: "Purio TV@iPhone", approvalTimeout: 120) { Task { @MainActor in waiting = true } }
                waiting = false
                let profile = Bundle.main.url(forResource: "Profiles", withExtension: nil)
                    .flatMap { try? DebloatProfile.load($0.appendingPathComponent(record.list)) }
                let report = try await Debloater(tv: client).restore(record, stock: profile?.manifest.stockLauncher ?? "com.google.android.tvlauncher")
                await client.close()
                done = report.complete
                if report.complete { status.restored(target.host) }
                message = RestoreText.summary(report)
            } catch { message = error.localizedDescription }
        }
    }
}
