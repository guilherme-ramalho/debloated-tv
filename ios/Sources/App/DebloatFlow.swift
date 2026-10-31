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

/// "192.168.0.13" or "192.168.0.13:15555" (an emulator forwarded from a Mac).
struct TVAddress: Equatable {
    var host: String
    var port: UInt16
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard let first = parts.first, !first.isEmpty, parts.count <= 2 else { return nil }
        host = String(first)
        if parts.count == 2 { guard let p = UInt16(parts[1]), p > 0 else { return nil }; port = p } else { port = 5555 }
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
    @Published var setupwraithOnEthernet = false
    @Published var installLauncher = true
    @Published var dock: [String] = []
    @Published private(set) var progress: Double = 0
    @Published private(set) var log: [String] = []
    @Published private(set) var result: ApplyResult?
    @Published private(set) var recordURL: URL?
    @Published private(set) var homeComponent: String?
    @Published var debuggingClosed: Bool?

    let profiles: [DebloatProfile]
    private var adb: AdbClient?
    private var task: Task<Void, Never>?

    init(host: String) {
        address = host
        profiles = Bundle.main.url(forResource: "Profiles", withExtension: nil).map { DebloatProfile.loadAll($0, includeDevelopment: Self.isDevelopmentBuild) } ?? []
    }

    /// Debug builds (Cmd+R in Xcode) include development-only profiles; Release (Archive, TestFlight, App Store) never does.
    static var isDevelopmentBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    var launcherAPK: Data? {
        Bundle.main.url(forResource: "tvhome", withExtension: "apk", subdirectory: "Launcher").flatMap { try? Data(contentsOf: $0) }
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
        guard let target = TVAddress(address) else { error = "Enter the TV's IP address, for example 192.168.0.13"; return }
        run {
            self.message = "Connecting to \(target.host)…"
            let client = AdbClient(host: target.host, port: target.port, key: try AdbKey.loadOrCreate())
            self.adb = client
            let props = try await client.connect(name: "Debloated TV@iPhone", approvalTimeout: 120) {
                Task { @MainActor in self.waitingForApproval = true; self.message = "On the TV, choose “Always allow” and Allow." }
            }
            self.waitingForApproval = false
            self.note("Connected to \(props["ro.product.model"] ?? "the TV")")
            self.step = .inspect
            try await self.inspectNow()
        }
    }

    func inspect() { run { try await self.inspectNow() } }

    private func inspectNow() async throws {
        guard let adb else { throw RemoteFailure.message("Connect to the TV first") }
        message = "Reading the TV's apps and settings…"
        let debloater = Debloater(tv: adb)
        let inv = try await debloater.inspect(properties: await adb.properties)
        inventory = inv
        guard let match = DebloatProfile.match(inv.properties, in: profiles) else {
            profile = nil
            message = "No tested profile for this TV yet."
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
        note("Recognised \(match.manifest.name). Recovery record saved.")
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
            self.message = "Running the safety checks…"
            var overrides = DebloatOverrides(); overrides.setupwraithOnEthernet = self.setupwraithOnEthernet
            let chosen = self.choices.map(\.package).filter { !self.keep.contains($0) }
            self.plan = try await Debloater(tv: adb).plan(chosen, list: profile.list, inventory: inventory, overrides: overrides)
            self.understood = false
            self.step = .review
        }
    }

    func apply() {
        guard let adb, let profile, let plan else { return }
        let apk = installLauncher ? launcherAPK : nil
        if installLauncher && apk == nil { error = "This build doesn't include the Home screen. Run scripts/bundle-launcher.sh and rebuild."; return }
        step = .apply; log = []; progress = 0; result = nil
        run {
            let debloater = Debloater(tv: adb)
            // Group by group, as upstream's tested runs did, stopping if the TV stops answering.
            var disabled = [String](), still = [String]()
            let groups = profile.list.groups.map { g in profile.list.entries.filter { $0.group == g }.map(\.package).filter(plan.disable.contains) }.filter { !$0.isEmpty }
            let total = Double(max(1, plan.disable.count)) + (apk == nil ? 0 : 6)
            for (i, group) in groups.enumerated() {
                try Task.checkCancellation()
                self.note("Disabling group \(i + 1) of \(groups.count): \(group.count) apps")
                let r = try await debloater.apply(DebloatPlan(disable: group, skipped: [], notes: []))
                disabled += r.disabled; still += r.stillEnabled
                self.progress = Double(disabled.count + still.count) / total
                _ = try await adb.shell("echo ok", timeout: 15)   // the TV still answers after this group
                if r.stoppedEarly { throw RemoteFailure.message("The TV stopped answering during group \(i + 1). Reconnect and review again; nothing after it was changed.") }
            }
            self.result = ApplyResult(disabled: disabled, stillEnabled: still, stoppedEarly: false)
            self.note("Disabled \(disabled.count) apps" + (still.isEmpty ? "." : "; \(still.count) stayed enabled."))
            if let apk {
                let theme = try profile.themeConfig(dock: self.dock)
                let base = self.progress
                self.homeComponent = try await LauncherInstaller(tv: adb).install(apk: apk, options: profile.manifest.launcher, theme: theme) { step, fraction in
                    Task { @MainActor in
                        self.message = step.rawValue
                        let index = Double(LauncherStep.allCases.firstIndex(of: step) ?? 0)
                        self.progress = min(1, base + (index + fraction) / Double(LauncherStep.allCases.count) * (1 - base))
                    }
                }
                self.note("New Home screen installed and set as Home.")
            }
            self.progress = 1
            self.step = .test
        }
    }

    /// Puts back what the recovery record holds (any time, also from the test step).
    func restore(_ record: RecoveryRecord, stock: String?) {
        guard let adb else { return }
        run {
            self.note("Restoring the TV…")
            let still = try await Debloater(tv: adb).restore(record, stock: stock ?? "com.google.android.tvlauncher")
            self.note("Restored. \(still.count) apps remain disabled because they were off before setup.")
        }
    }

    // MARK: finish

    /// After the user turns debugging off: the port should refuse connections.
    func checkDebuggingClosed() {
        guard let target = TVAddress(address) else { return }
        cancel()
        debuggingClosed = nil
        Task {
            debuggingClosed = await PortProbe.refuses(host: target.host, port: target.port)
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
