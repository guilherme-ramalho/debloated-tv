import SwiftUI
import Network

/// Saved recovery records, one per TV and profile. They're the only way to undo a setup exactly, so they live in
/// Application Support (backed up with the iPhone) and can be exported.
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
    @Published var keep: Set<String> = []
    @Published private(set) var plan: DebloatPlan?
    @Published var understood = false
    /// Passwords typed for the Wi-Fi networks the setup wizard owns (plan.wifiToResave). Kept only until they're
    /// sent; never saved.
    @Published var wifiPasswords: [String: String] = [:]
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
        Bundle.main.url(forResource: "Profiles", withExtension: nil).map { DebloatProfile.loadAll($0, includeDevelopment: isDevelopmentBuild) } ?? []
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
        guard let match = DebloatProfile.match(inv.properties, in: profiles) else {
            profile = nil
            message = String(localized: "No tested profile for this TV yet.")
            return
        }
        profile = match
        // Save how things are before any change. A record from an earlier run keeps its original states.
        let serial = (try? await adb.shell("getprop ro.serialno", timeout: 15).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let url = RecoveryStore.url(profile: match.id, tv: serial.isEmpty ? (TVAddress(address)?.host ?? address) : serial)
        let record = debloater.record(match.list, listName: match.id, host: TVAddress(address)?.host ?? address, inventory: inv, existing: RecoveryStore.load(url))
        try RecoveryStore.save(record, to: url)
        recordURL = url
        keep = []
        dock = match.manifest.dockCandidates.filter { inv.installed.contains($0) }.prefix(5).map { $0 }
        note(String(localized: "Recognised \(match.manifest.name). Recovery record saved."))
        step = .choose
    }

    /// Entries the user can choose: installed, still enabled, and not protected.
    var choices: [DebloatList.Entry] {
        guard let profile, let inventory else { return [] }
        return profile.list.entries.filter { inventory.installed.contains($0.package) && !inventory.disabled.contains($0.package)
            && !profile.list.neverDisable.contains($0.package) && !DebloatRules.isCore($0.package) }
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
        let apk = installLauncher ? launcherAPK : nil
        if installLauncher && apk == nil { error = String(localized: "This build doesn't include the Home screen. Run scripts/bundle-launcher.sh and rebuild."); return }
        step = .apply; log = []; progress = 0; result = nil
        let passwords = wifiPasswords
        run {
            var adb = adb
            // Wi-Fi the setup wizard saved goes when the wizard is disabled: save it again as the shell's first.
            if !plan.wifiToResave.isEmpty {
                adb = try await self.resaveWifi(plan.wifiToResave, passwords: passwords, on: adb)
                self.wifiPasswords = [:]
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
                self.homeComponent = try await LauncherInstaller(tv: adb).install(apk: apk, options: profile.manifest.launcher, theme: theme) { step, fraction in
                    Task { @MainActor in
                        self.message = step.title
                        let index = Double(LauncherStep.allCases.firstIndex(of: step) ?? 0)
                        self.progress = min(1, base + (index + fraction) / Double(LauncherStep.allCases.count) * (1 - base))
                    }
                }
                self.note(String(localized: "New Home screen installed and set as Home."))
            }
            self.progress = 1
            self.step = .test
        }
    }

    /// Puts back what the recovery record holds (any time, also from the test step).
    func restore(_ record: RecoveryRecord, stock: String?) {
        guard let adb else { return }
        run {
            self.note(String(localized: "Restoring the TV…"))
            let still = try await Debloater(tv: adb).restore(record, stock: stock ?? "com.google.android.tvlauncher")
            self.note(String(localized: "Restored. \(still.count) apps remain disabled because they were off before setup."))
            self.restores += 1
        }
    }

    // MARK: finish

    /// Every Wi-Fi network the wizard owns that needs a password has one typed in.
    var wifiReady: Bool { plan?.wifiToResave.allSatisfy { !$0.needsPassword || !(wifiPasswords[$0.ssid] ?? "").isEmpty } ?? true }

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
            guard let profile = DebloatProfile.match(properties, in: DebloatFlow.loadProfiles()) else {
                throw RemoteFailure.message(String(localized: "There's no tested profile for this TV, so its Home screen can't be updated from here. Nothing was changed."))
            }
            let installer = LauncherInstaller(tv: client)
            guard let installed = try await installer.installedVersion() else {
                throw RemoteFailure.message(String(localized: "The new Home screen isn't on this TV. Use Run setup instead. Nothing was changed."))
            }
            if installed >= bundled { self.alreadyCurrent = true; self.step = .done; return }
            self.step = .updating
            _ = try await installer.install(apk: apk, options: profile.manifest.launcher, theme: nil) { step, fraction in
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
