import SwiftUI
import Network

/// Saved recovery records, one per TV (by its android_id or a real serial; older builds kept one per TV and list).
/// They're the only way to undo a setup exactly, so they live in Application Support (backed up with the iPhone) and
/// can be exported.
enum RecoveryStore {
    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVRemote/recovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func url(profile: String, tv: String) -> URL {
        let safe = tv.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" ? Character($0) : "_" }
        return directory.appendingPathComponent("recovery-\(profile)-\(String(safe)).json")
    }
    static func load(_ url: URL) -> RecoveryRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecoveryRecord.self, from: data)
    }
    static func save(_ record: RecoveryRecord, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }
    static func url(for identity: TVIdentity, host: String) -> URL { url(profile: "tv", tv: identity.key ?? "host-" + host) }

    /// This TV's record, with any older per-list records of it folded in (oldest state wins), and those older files.
    static func forTV(_ identity: TVIdentity, host: String) -> (url: URL, existing: RecoveryRecord?, legacy: [URL]) {
        let url = url(for: identity, host: host)
        let legacy = all().filter { saved in
            guard saved.url != url, !saved.url.lastPathComponent.hasPrefix("recovery-tv-") else { return false }
            if let tv = saved.record.tv { return tv.sameTV(as: identity) && tv.key != nil && tv.key == identity.key }
            if let serial = identity.realSerial { return saved.url.lastPathComponent.hasSuffix("-\(safe(serial)).json") }
            return saved.record.host == host
        }.sorted { $0.record.created < $1.record.created }
        var older: RecoveryRecord?
        for saved in legacy { older = older.map { saved.record.merged(withOlder: $0) } ?? saved.record }
        let current = load(url)
        let existing: RecoveryRecord? = switch (current, older) {
        case let (c?, o?): c.merged(withOlder: o)
        case let (c?, nil): c
        case let (nil, o): o
        }
        return (url, existing, legacy.map(\.url))
    }
    private static func safe(_ s: String) -> String {
        String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" ? Character($0) : "_" })
    }

    struct Saved: Identifiable { let url: URL; let record: RecoveryRecord; var id: URL { url } }
    static func all() -> [Saved] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in load(url).map { Saved(url: url, record: $0) } }
            .sorted { $0.record.created > $1.record.created }
    }
}

/// The guided setup: connect over network debugging, recognise the TV, choose, review, apply, install the new Home
/// screen, test, and close debugging again. Every TV change goes through Debloater / LauncherInstaller, which carry
/// upstream's safety checks; this class only sequences them and keeps the recovery record saved before any change.
@MainActor final class DebloatFlow: ObservableObject {
    enum Step: Int, CaseIterable { case overview, developer, connect, inspect, choose, review, home, apply, test, finish }

    @Published var step: Step = .overview
    @Published var address: String
    @Published var acknowledged = false
    @Published var busy = false
    @Published var waitingForApproval = false
    @Published var message = ""
    @Published var error: String?
    @Published private(set) var inventory: TVInventory?
    @Published private(set) var profile: DebloatProfile?
    /// The lists setup can offer for this TV, best first (ProfileMatcher), and the one in use.
    @Published private(set) var candidates: [ProfileMatch] = []
    @Published private(set) var match: ProfileMatch?
    @Published var keep: Set<String> = []
    @Published private(set) var plan: DebloatPlan?
    @Published var understood = false
    /// Passwords typed for the Wi-Fi networks the setup wizard owns (plan.wifiToResave). Kept only until they're
    /// sent; never saved.
    @Published var wifiPasswords: [String: String] = [:]
    /// Each password typed a second time: a typo would take the TV off Wi-Fi.
    @Published var wifiConfirm: [String: String] = [:]
    @Published var installLauncher = true
    @Published var dock: [String] = []
    @Published private(set) var progress: Double = 0
    @Published private(set) var log: [String] = []
    @Published private(set) var result: ApplyResult?
    @Published private(set) var recordURL: URL?
    @Published private(set) var homeComponent: String?
    @Published var debuggingClosed: Bool?
    /// Counts successful restores, so the TV tab can show setup again.
    @Published private(set) var restores = 0

    let profiles: [DebloatProfile]
    private var adb: AdbClient?
    private var task: Task<Void, Never>?

    init(host: String) {
        address = host
        profiles = Self.loadProfiles()
    }

    /// Debug builds (Cmd+R in Xcode) include development-only profiles; Release (Archive, TestFlight, App Store) never does.
    static var isDevelopmentBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    var launcherAPK: Data? { Self.bundledAPK }
    static var bundledAPK: Data? {
        Bundle.main.url(forResource: "tvhome", withExtension: "apk", subdirectory: "Launcher").flatMap { try? Data(contentsOf: $0) }
    }
    static func loadProfiles() -> [DebloatProfile] {
        let all = Bundle.main.url(forResource: "Profiles", withExtension: nil).map { DebloatProfile.loadAll($0, includeDevelopment: isDevelopmentBuild) } ?? []
        // Development builds: the emulator's tested profile normally; with -e2eCommunity (the end-to-end suite's
        // community scenario) the development community lists instead, so setup shows the list picker. Those never
        // load otherwise, so a Dev build on a real TV can't be offered them.
        let community = ProcessInfo.processInfo.arguments.contains("-e2eCommunity")
        return all.filter { $0.manifest.developmentOnly != true || $0.isCommunity == community }
    }

    func cancel() {
        task?.cancel(); task = nil
        busy = false; waitingForApproval = false
        if let adb { Task { await adb.close() } }
        adb = nil
    }

    private func run(_ work: @escaping () async throws -> Void) {
        task?.cancel()
        error = nil; busy = true
        task = Task {
            do { try await work() }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
            self.busy = false; self.waitingForApproval = false
        }
    }
    private func note(_ line: String) { log.append(line); message = line }

    // MARK: connect and inspect

    func connect() {
        guard let target = TVAddress(address) else { error = String(localized: "Enter the TV's IP address, for example 192.168.1.20"); return }
        run {
            self.message = String(localized: "Connecting to \(target.host)…")
            let client = AdbClient(host: target.host, port: target.port, key: try AdbKey.loadOrCreate())
            self.adb = client
            let props = try await client.connect(name: "Purio TV@iPhone", approvalTimeout: 120) {
                Task { @MainActor in self.waitingForApproval = true; self.message = String(localized: "On the TV, choose “Always allow” and Allow.") }
            }
            self.waitingForApproval = false
            self.note(String(localized: "Connected to \(props["ro.product.model"] ?? "the TV")"))
            self.step = .inspect
            try await self.inspectNow()
        }
    }

    func inspect() { run { try await self.inspectNow() } }

    private func inspectNow() async throws {
        guard let adb else { throw RemoteFailure.message(String(localized: "Connect to the TV first")) }
        message = String(localized: "Reading the TV's apps and settings…")
        let debloater = Debloater(tv: adb)
        let inv = try await debloater.inspect(properties: await adb.properties)
        inventory = inv
        profile = nil; match = nil
        candidates = ProfileMatcher.rank(inv.properties, installed: inv.installed, disabled: inv.disabled, in: profiles)
        // A profile tested with Purio TV on this exact firmware is used as before; a community list is the person's choice.
        if let first = candidates.first, first.kind == .tested { try await use(first); return }
        message = candidates.isEmpty ? String(localized: "No list for this TV yet.") : String(localized: "Choose the list for this TV.")
    }

    /// The person picked one of `candidates`.
    func choose(_ candidate: ProfileMatch) { run { try await self.use(candidate) } }

    private func use(_ candidate: ProfileMatch) async throws {
        guard adb != nil, let inv = inventory else { throw RemoteFailure.message(String(localized: "Connect to the TV first")) }
        let match = candidate.profile
        profile = match
        self.match = candidate
        installLauncher = homeScreenAvailable
        // The recovery record is written when the person applies, before the first change (saveRecord).
        keep = []
        dock = match.manifest.dockCandidates.filter { inv.installed.contains($0) }.prefix(5).map { $0 }
        note(String(localized: "Recognised \(match.manifest.name)."))
        step = .choose
    }

    /// Entries the user can choose: installed, still enabled, and not protected.
    var choices: [DebloatList.Entry] {
        guard let profile, let inventory else { return [] }
        return profile.list.entries.filter { inventory.installed.contains($0.package) && !inventory.disabled.contains($0.package)
            && !profile.list.neverDisable.contains($0.package) && !DebloatRules.isCore($0.package)
            && !(match?.kind == .closest && DebloatRules.isCVTELauncher($0.package)) }
    }
    /// Whether setup may install the new Home screen here: the list allows it, and the TV is neither a Fire TV nor a
    /// CVTE board (their Home needs a procedure this app doesn't have).
    var homeScreenAvailable: Bool { homeScreenBlock == nil }
    enum HomeScreenBlock { case fireOS, cvte, debloatOnly, customBuild, noConfig }
    var homeScreenBlock: HomeScreenBlock? {
        guard let profile, let inventory else { return .noConfig }
        if (inventory.properties["ro.product.manufacturer"] ?? "").localizedCaseInsensitiveContains("amazon") { return .fireOS }
        if inventory.installed.contains(where: { $0.hasPrefix("com.cvte.") }) { return .cvte }
        if profile.offersHomeScreen { return nil }
        switch profile.manifest.homeScreenNote {
        case "fireOS": return .fireOS
        case "cvte", "special": return .cvte
        case "customBuild": return .customBuild
        case "debloatOnly": return .debloatOnly
        default: return .noConfig
        }
    }
    var protectedCount: Int { profile?.list.neverDisable.filter { inventory?.installed.contains($0) == true }.count ?? 0 }
    var alreadyHandled: Int { (profile?.list.entries.count ?? 0) - choices.count }

    // MARK: review and apply

    func review() {
        guard let adb, let profile, let inventory else { return }
        run {
            self.message = String(localized: "Running the safety checks…")
            let overrides = DebloatOverrides()
            let chosen = self.choices.map(\.package).filter { !self.keep.contains($0) }
            self.plan = try await Debloater(tv: adb).plan(chosen, list: profile.list, inventory: inventory, overrides: overrides)
            self.understood = false
            self.step = .review
        }
    }

    func apply() {
        guard let adb, let profile, let plan else { return }
        let wantsHome = installLauncher && homeScreenAvailable
        let apk = wantsHome ? launcherAPK : nil
        if wantsHome && apk == nil { error = String(localized: "This build doesn't include the Home screen. Run scripts/bundle-launcher.sh and rebuild."); return }
        step = .apply; log = []; progress = 0; result = nil
        let passwords = wifiPasswords
        run {
            var adb = adb
            try await self.saveRecord(profile: profile, on: adb)
            // Wi-Fi the setup wizard saved goes when the wizard is disabled: save it again as the shell's first.
            if !plan.wifiToResave.isEmpty {
                adb = try await self.resaveWifi(plan.wifiToResave, passwords: passwords, on: adb)
                self.wifiPasswords = [:]; self.wifiConfirm = [:]
            }
            let debloater = Debloater(tv: adb)
            // Group by group, as upstream's tested runs did, stopping if the TV stops answering.
            var disabled = [String](), still = [String]()
            let groups = profile.list.groups.map { g in profile.list.entries.filter { $0.group == g }.map(\.package).filter(plan.disable.contains) }.filter { !$0.isEmpty }
            let total = Double(max(1, plan.disable.count)) + (apk == nil ? 0 : 6)
            for (i, group) in groups.enumerated() {
                try Task.checkCancellation()
                self.note(String(localized: "Disabling group \(i + 1) of \(groups.count): \(group.count) apps"))
                let r = try await debloater.apply(DebloatPlan(disable: group, skipped: [], notes: []))
                disabled += r.disabled; still += r.stillEnabled
                self.progress = Double(disabled.count + still.count) / total
                _ = try await adb.shell("echo ok", timeout: 15)   // the TV still answers after this group
                if r.stoppedEarly { throw RemoteFailure.message(String(localized: "The TV stopped answering during group \(i + 1). Reconnect and review again; nothing after it was changed.")) }
            }
            self.result = ApplyResult(disabled: disabled, stillEnabled: still, stoppedEarly: false)
            self.note(still.isEmpty ? String(localized: "Disabled \(disabled.count) apps.") : String(localized: "Disabled \(disabled.count) apps; \(still.count) stayed enabled."))
            if let apk {
                let theme = try profile.themeConfig(dock: self.dock)
                let base = self.progress
                self.homeComponent = try await LauncherInstaller(tv: adb).install(apk: apk, options: profile.manifest.launcher, theme: theme,
                                                                                  listedStock: profile.manifest.stockLauncher) { step, fraction in
                    Task { @MainActor in
                        self.message = step.title
                        let index = Double(LauncherStep.allCases.firstIndex(of: step) ?? 0)
                        self.progress = min(1, base + (index + fraction) / Double(LauncherStep.allCases.count) * (1 - base))
                    }
                }
                self.note(String(localized: "New Home screen installed and set as Home."))
            }
            // Nothing changed (every app kept, no new Home): nothing a restart could undo, so no restart.
            if !disabled.isEmpty || apk != nil { try await self.restartAndCheck(disabledBySetup: disabled) }
            self.progress = 1
            self.step = .test
        }
    }

    /// What the restart at the end of apply found; shown on the test step. nil: not run yet, or all well.
    @Published private(set) var restartProblem: String?
    @Published private(set) var restartNote: String?
    @Published private(set) var restartChecked = false

    /// Restarts the TV once and checks Home and the disabled apps, while network debugging is still on and Undo can
    /// still reach the TV (PROMPT.md: wait before the reboot, then compare). Android writes package state and the Home
    /// choice to disk about ten seconds after a change (WRITE_SETTINGS_DELAY), and `sync` only flushes what is already
    /// written: rebooting sooner boots the old state (the E2E run of 12 Nov 2026 came back on the stock launcher after
    /// a 5 s wait). So wait 20 s, then sync. A one-time minute or two per setup; nothing runs afterwards.
    private func restartAndCheck(disabledBySetup: [String]) async throws {
        guard let adb, let target = TVAddress(address) else { return }
        restartProblem = nil; restartNote = nil; restartChecked = false
        note(String(localized: "Restarting the TV to check that everything holds. This takes a minute or two."))
        try await Task.sleep(for: .seconds(20))
        _ = try? await adb.shell("sync", timeout: 30)
        _ = try? await adb.shell("reboot", timeout: 5)
        await adb.close()
        try await Task.sleep(for: .seconds(25))
        var client: AdbClient?
        for _ in 0..<24 {   // about four minutes
            try Task.checkCancellation()
            let fresh = AdbClient(host: target.host, port: target.port, key: try AdbKey.loadOrCreate())
            if (try? await fresh.connect(name: "Purio TV@iPhone", approvalTimeout: 60) { Task { @MainActor in self.waitingForApproval = true } }) != nil {
                client = fresh; break
            }
            try await Task.sleep(for: .seconds(8))
        }
        waitingForApproval = false
        guard let client else {
            restartProblem = String(localized: "The TV didn't let this phone back in after restarting, so it couldn't be checked. Look at the TV: if Home opens and the checks below pass, all is well. If not, turn network debugging on again and use Undo TV setup.")
            return
        }
        self.adb = client
        for _ in 0..<30 {   // until Android says the boot finished
            if (try? await client.run("getprop sys.boot_completed", timeout: 10))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { break }
            try await Task.sleep(for: .seconds(3))
        }
        try await Task.sleep(for: .seconds(5))
        let home = (try await client.run(DebloatRules.homeQuery)).split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let enabled = Pattern.packageNames(try await client.run("pm list packages -e --user 0"))
        let check = RestartCheck.judge(home: home, enabled: enabled, disabledBySetup: disabledBySetup,
                                       expectedHome: homeComponent == nil ? nil : LauncherInstaller.package)
        if !check.homeOK {
            restartProblem = String(localized: "After restarting, Home went to \(home.isEmpty ? "nothing" : home) instead of a working Home screen. Restore the TV now, while this phone can still reach it.")
        }
        if !check.reEnabled.isEmpty {
            restartNote = String(localized: "The TV turned \(check.reEnabled.count) apps back on by itself when it restarted (its firmware does this at every start): \(check.reEnabled.joined(separator: ", ")).")
        }
        restartChecked = check.homeOK
        note(check.homeOK ? String(localized: "Restarted and checked: Home works.") : restartProblem ?? "")
    }

    /// Saves how the TV is before this run changes anything: one record per TV, which a later run (another list,
    /// setup again) only extends, so the state before the very first setup is what Undo puts back. Nothing changes on
    /// the TV if this fails.
    private func saveRecord(profile: DebloatProfile, on adb: AdbClient) async throws {
        guard let inventory else { throw RemoteFailure.message(String(localized: "Connect to the TV first")) }
        let debloater = Debloater(tv: adb)
        let identity = try await debloater.identity()
        let accessibility = try await debloater.accessibilitySettings()
        let host = TVAddress(address)?.host ?? address
        let (url, existing, legacy) = RecoveryStore.forTV(identity, host: host)
        let record = debloater.record(profile.list, listName: profile.id, host: host, inventory: inventory, existing: existing,
                                      tv: identity, accessibility: accessibility)
        try RecoveryStore.save(record, to: url)
        for old in legacy { try? FileManager.default.removeItem(at: old) }   // folded into this TV's record
        recordURL = url
        note(String(localized: "Recovery record saved."))
    }

    /// Puts back what the recovery record holds (any time, also from the test step).
    func restore(_ record: RecoveryRecord, stock: String?) {
        guard let adb else { return }
        run {
            self.note(String(localized: "Restoring the TV…"))
            let report = try await Debloater(tv: adb).restore(record, stock: stock ?? "com.google.android.tvlauncher")
            self.note(RestoreText.summary(report))
            if report.complete { self.restores += 1 }
        }
    }

    // MARK: finish

    /// Every Wi-Fi network the wizard owns that needs a password has one typed in.
    var wifiReady: Bool {
        plan?.wifiToResave.allSatisfy { !$0.needsPassword || (!(wifiPasswords[$0.ssid] ?? "").isEmpty && wifiPasswords[$0.ssid] == wifiConfirm[$0.ssid]) } ?? true
    }

    /// Saves each network again, waits for the TV (it can drop off Wi-Fi for a moment), and checks the copies are
    /// there and no longer the wizard's. Nothing else has changed yet if this fails.
    private func resaveWifi(_ networks: [WifiNetwork], passwords: [String: String], on adb: AdbClient) async throws -> AdbClient {
        guard let target = TVAddress(address) else { throw RemoteFailure.message(String(localized: "Enter the TV's IP address, for example 192.168.1.20")) }
        note(String(localized: "Saving the TV's Wi-Fi again, so it stays when the setup wizard is off…"))
        for network in networks {
            _ = try? await adb.shell(DebloatRules.resaveWifiCommand(network, password: passwords[network.ssid] ?? ""), timeout: 15)
        }
        try await Task.sleep(for: .seconds(6))
        var client = adb
        var after: [WifiNetwork]?
        for attempt in 1...8 {
            if let dump = try? await client.run("dumpsys wifi", timeout: 30), let parsed = DebloatRules.wifiNetworks(dump) { after = parsed; break }
            if attempt == 8 { break }
            // The connection went with the old network: reconnect with the approved key (no prompt on the TV).
            await client.close()
            try await Task.sleep(for: .seconds(5))
            let fresh = AdbClient(host: target.host, port: target.port, key: try AdbKey.loadOrCreate())
            if (try? await fresh.connect(name: "Purio TV@iPhone", approvalTimeout: 10)) != nil { client = fresh; self.adb = fresh }
        }
        let names = networks.map(\.ssid).joined(separator: ", ")
        guard let after else {
            throw RemoteFailure.message(String(localized: "The TV didn't come back after saving its Wi-Fi again. On the TV, join \(names) in Settings › Network & Internet, then connect again. Nothing else was changed."))
        }
        let missing = networks.filter { n in !after.contains { $0.ssid == n.ssid && !$0.owner.contains("setupwraith") } }
        guard missing.isEmpty else {
            throw RemoteFailure.message(String(localized: "Couldn't save \(missing.map(\.ssid).joined(separator: ", ")) again (check the password). On the TV, join it in Settings › Network & Internet, then review again. Nothing else was changed."))
        }
        note(String(localized: "Wi-Fi saved again: \(names)."))
        return client
    }

    /// The last step of a setup (DebuggingSwitch).
    func turnOffDebugging() {
        guard let target = TVAddress(address) else { return }
        debuggingClosed = nil
        run {
            let client = self.adb
            self.adb = nil
            self.debuggingClosed = try await DebuggingSwitch.turnOff(client, target: target)
        }
    }

    func checkDebuggingClosed() {
        guard let target = TVAddress(address) else { return }
        cancel()
        debuggingClosed = nil
        Task {
            debuggingClosed = await PortProbe.refuses(host: target.host, port: target.port)
        }
    }
}

/// The last ADB command of a setup or an update: switches debugging off on the TV (adbd stops, so the connection
/// drops), then checks the port refuses connections. Saved "Always allow" approvals stay until revoked in the TV's menu.
enum DebuggingSwitch {
    static func turnOff(_ current: AdbClient?, target: TVAddress) async throws -> Bool? {
        // The link may have gone idle while the user tested the TV: reconnect with the approved key (no prompt).
        var client = current
        if let open = client, (try? await open.shell("echo ok", timeout: 5)) == nil { await open.close(); client = nil }
        if client == nil {
            let fresh = AdbClient(host: target.host, port: target.port, key: try AdbKey.loadOrCreate())
            do { _ = try await fresh.connect(name: "Purio TV@iPhone", approvalTimeout: 15) }
            catch {
                await fresh.close()
                throw RemoteFailure.message(String(localized: "The TV is no longer connected. Turn debugging off in the TV's menus."))
            }
            client = fresh
        }
        guard let client else { return nil }
        _ = try? await client.shell("settings put global adb_wifi_enabled 0; settings put global adb_enabled 0", timeout: 8)
        await client.close()
        try? await Task.sleep(for: .seconds(2))
        return await PortProbe.refuses(host: target.host, port: target.port)
    }
}

/// "Update Home screen" on the TV tab: installs the newer launcher this app carries over the one on the TV
/// (`pm install -r`), keeping its config.json, wallpaper, order and settings. Offered only when the TV's launcher
/// reports an older versionCode (LauncherVersion); checked again over ADB before anything is installed.
@MainActor final class HomeUpdateFlow: ObservableObject {
    enum Step { case start, connecting, updating, done }
    /// The bundled launcher's versionCode (tvhome.json from scripts/bundle-launcher.sh); nil in a build without it.
    static let bundledVersion: Int? = LauncherVersion.bundled(
        Bundle.main.url(forResource: "tvhome", withExtension: "json", subdirectory: "Launcher").flatMap { try? Data(contentsOf: $0) })

    @Published var step: Step = .start
    @Published var address: String
    @Published private(set) var busy = false
    @Published private(set) var waitingForApproval = false
    @Published private(set) var message = ""
    @Published var error: String?
    @Published private(set) var progress: Double = 0
    /// True when the TV already had this version (nothing installed).
    @Published private(set) var alreadyCurrent = false
    @Published private(set) var debuggingClosed: Bool?
    private var adb: AdbClient?
    private var task: Task<Void, Never>?

    init(host: String) { address = host }

    func cancel() {
        task?.cancel(); task = nil
        busy = false; waitingForApproval = false
        if let adb { Task { await adb.close() } }
        adb = nil
    }

    private func run(_ work: @escaping () async throws -> Void) {
        task?.cancel()
        error = nil; busy = true
        task = Task {
            do { try await work() }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
            self.busy = false; self.waitingForApproval = false
        }
    }

    func update() {
        guard let target = TVAddress(address) else { error = String(localized: "Enter the TV's IP address, for example 192.168.1.20"); return }
        guard let apk = DebloatFlow.bundledAPK, let bundled = Self.bundledVersion else {
            error = String(localized: "This build doesn't include the Home screen. Run scripts/bundle-launcher.sh and rebuild."); return
        }
        step = .connecting; progress = 0; alreadyCurrent = false; debuggingClosed = nil
        run {
            self.message = String(localized: "Connecting to \(target.host)…")
            if let old = self.adb { await old.close() }
            let client = AdbClient(host: target.host, port: target.port, key: try AdbKey.loadOrCreate())
            self.adb = client
            _ = try await client.connect(name: "Purio TV@iPhone", approvalTimeout: 120) {
                Task { @MainActor in self.waitingForApproval = true; self.message = String(localized: "On the TV, choose “Always allow” and Allow.") }
            }
            self.waitingForApproval = false
            // The profile decides the remote helpers and permissions, exactly as setup installed them.
            let properties = try await Debloater(tv: client).profileProperties(await client.properties)
            // Only a TV whose Home is the new Home screen: after an undo the stock launcher is Home again, and an update
            // must not take it over (nor disable it) without a setup and its recovery record.
            let home = try await client.shell(DebloatRules.homeQuery, timeout: 30).output.split(separator: "\n").last
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard home.hasPrefix(LauncherInstaller.package + "/") else {
                throw RemoteFailure.message(String(localized: "The TV's Home is its own Home screen again, so there's nothing to update. Run setup to bring the new one back. Nothing was changed."))
            }
            // A tested profile by exact match, or the list applied last in this TV's recovery record.
            let profiles = DebloatFlow.loadProfiles()
            let identity = try await Debloater(tv: client).identity()
            let used = RecoveryStore.all().first { saved in saved.record.tv.map { $0.sameTV(as: identity) && $0.key != nil && $0.key == identity.key }
                ?? (saved.record.host == target.host) }.flatMap { saved in profiles.first { $0.id == saved.record.lastList } }
            guard let profile = DebloatProfile.match(properties, in: profiles) ?? used else {
                throw RemoteFailure.message(String(localized: "This phone didn't set up this TV's Home screen, so it can't update it from here. Nothing was changed."))
            }
            let installer = LauncherInstaller(tv: client)
            guard let installed = try await installer.installedVersion() else {
                throw RemoteFailure.message(String(localized: "The new Home screen isn't on this TV. Use Run setup instead. Nothing was changed."))
            }
            if installed >= bundled { self.alreadyCurrent = true; self.step = .done; return }
            self.step = .updating
            _ = try await installer.install(apk: apk, options: profile.manifest.launcher, theme: nil, listedStock: profile.manifest.stockLauncher) { step, fraction in
                Task { @MainActor in
                    self.message = step.title
                    let index = Double(LauncherStep.allCases.firstIndex(of: step) ?? 0)
                    self.progress = min(1, (index + fraction) / Double(LauncherStep.allCases.count))
                }
            }
            let now = try await installer.installedVersion()
            guard now == bundled else {
                throw RemoteFailure.message(String(localized: "The TV still reports the old Home screen after the update. Try again."))
            }
            self.progress = 1
            self.step = .done
        }
    }

    func turnOffDebugging() {
        guard let target = TVAddress(address) else { return }
        debuggingClosed = nil
        run {
            let client = self.adb
            self.adb = nil
            self.debuggingClosed = try await DebuggingSwitch.turnOff(client, target: target)
        }
    }
}

private final class ProbeOnce: @unchecked Sendable { var done = false }

/// Whether a TCP port refuses connections (true), accepts them (false), or didn't answer (nil, e.g. TV asleep).
enum PortProbe {
    static func refuses(host: String, port: UInt16) async -> Bool? {
        await withCheckedContinuation { (result: CheckedContinuation<Bool?, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let queue = DispatchQueue(label: "tvremote.probe")
            let once = ProbeOnce()
            let finish: (Bool?) -> Void = { value in
                queue.async { guard !once.done else { return }; once.done = true; connection.cancel(); result.resume(returning: value) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(false)
                case .waiting(let e), .failed(let e):
                    if case .posix(let code) = e, code == .ECONNREFUSED { finish(true) } else { finish(nil) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }
}
