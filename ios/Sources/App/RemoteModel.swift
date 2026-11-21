import SwiftUI
import Security

@MainActor final class RemoteModel: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "tvHost") ?? "192.168.1.100"
    @Published var status = String(localized: "Preparing secure pairing…")
    @Published var ready = false
    @Published private(set) var hasSavedPairing = false
    /// Counts new pairings, so the app can offer TV setup once right after one.
    @Published private(set) var pairings = 0
    @Published var preparing = true
    @Published var showingPIN = false
    @Published var error = ""
    @Published var volume = "Volume"
    /// The TV's mute state as it last reported it (the mute button shows what a tap would do).
    @Published var muted = false
    @Published var powerOn: Bool?
    @Published var waking = false
    @Published var foregroundPackage = ""
    private var identity: ClientIdentity?
    private var session: TVSession?
    /// The remote of a Roku, LG or Samsung TV (BrandRemote); nil for Android TVs, which use `session`.
    private var brand: BrandRemote?
    /// The app on screen on a Roku / LG TV, by its name there (Android TVs report a package instead).
    @Published private(set) var brandApp = ""
    private var active = false
    /// True from "Pair TV" until the code is accepted or pairing is cancelled; drives the pairing sheet.
    @Published private(set) var pairing = false
    private var attempt = 0
    private var retry: DispatchWorkItem?
    private var token = 0
    private var pressed = Set<TVKey>()
    private var wakeRequest = WakeRequest()
    private var wakeTimeout: DispatchWorkItem?
    private var wakeSend: DispatchWorkItem?
    private static let pinService = TVPairingStore.service
    private var autoReconnect = true
    func setAutoReconnect(_ value: Bool) { autoReconnect = value; if !value { retry?.cancel(); retry = nil } }
    func sendText(_ text: String) async throws {
        if let brand, ready { try await brand.writeText(text); return }
        guard ready, let session else { throw RemoteFailure.message(String(localized: "Connect the TV before sending text")) }
        try await session.writeText(text)
    }

    /// What kind of TV the saved one is, as chosen on Connect (Android TV unless it said otherwise).
    var kind: TVKind { Self.kind(of: host) }
    static func kind(of host: String) -> TVKind {
        (UserDefaults.standard.dictionary(forKey: "tvKinds") as? [String: String])?[host].flatMap(TVKind.init(rawValue:)) ?? .androidTV
    }
    private static func save(kind: TVKind, for host: String) {
        var kinds = (UserDefaults.standard.dictionary(forKey: "tvKinds") as? [String: String]) ?? [:]
        kinds[host] = kind == .androidTV ? nil : kind.rawValue
        UserDefaults.standard.set(kinds, forKey: "tvKinds")
    }
    /// Whether the remote on screen has this key on this TV (Roku has no subtitles or input button, for one).
    func supports(_ key: TVKey) -> Bool { kind.supports(key) }
    static func makeBrand(_ kind: TVKind, host: String) -> BrandRemote? { BrandRemotes.make(kind, host: host) }

    func activate() {
        guard !active else { return }
        active = true; hasSavedPairing = pin() != nil
        if kind != .androidTV { preparing = false; attempt = 0; connect(); return }
        if identity == nil && preparing {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try ClientIdentity.loadOrCreate() }
                DispatchQueue.main.async {
                    self.preparing = false
                    switch result {
                    case .success(let identity):
                        self.identity = identity
                        if self.active { self.connect() }
                    case .failure(let error):
                        self.status = String(localized: "Pairing identity unavailable"); self.error = error.localizedDescription
                        print("TVRemote: pairing identity unavailable: \(error)")
                    }
                }
            }
        } else if identity != nil { attempt = 0; connect() }
    }

    func deactivate() {
        active = false
        cancelWake()
        releaseAll()
        retry?.cancel(); retry = nil
        token += 1
        session?.disconnect(); session = nil
        brand?.disconnect(); brand = nil
        ready = false; powerOn = nil
        if pairing { pairing = false; showingPIN = false; approving = false }
    }

    /// The TV's own name, as found on the network, for the host; the address when there's none.
    var tvName: String { (UserDefaults.standard.dictionary(forKey: "tvNames") as? [String: String])?[host] ?? host }

    /// Picks a TV (found on the network or typed) and starts pairing with it.
    func pair(with host: String, name: String?, kind: TVKind = .androidTV) {
        Self.save(kind: kind, for: TVAddress.typed(host))
        if let name, !name.isEmpty {
            var names = (UserDefaults.standard.dictionary(forKey: "tvNames") as? [String: String]) ?? [:]
            names[host] = String(name.prefix(80))
            UserDefaults.standard.set(names, forKey: "tvNames")
        }
        if saveHost(host) { beginPairing() }
    }

    @discardableResult func saveHost(_ value: String) -> Bool {
        let value = TVAddress.typed(value)
        if value.contains(":") {
            error = String(localized: "Enter only the IP here, without a port. The remote always uses the TV’s own ports; a port like :15555 is only for Settings › Debloat & new Home.")
            return false
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else {
            error = String(localized: "Enter the TV’s IPv4 address, for example 192.168.1.100"); return false
        }
        deactivate()
        host = value; UserDefaults.standard.set(value, forKey: "tvHost")
        foregroundPackage = ""; brandApp = ""; attempt = 0; active = true; hasSavedPairing = pin() != nil
        if kind != .androidTV { preparing = false }
        connect(); return true
    }

    private func pin() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.pinService, kSecAttrAccount as String: host,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    private func savePin(_ data: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.pinService, kSecAttrAccount as String: host]
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw RemoteFailure.message(String(localized: "Could not save TV pairing (\(status))")) }
        hasSavedPairing = true
    }

    private func newSession() -> TVSession? {
        guard active, let identity else { return nil }
        wakeSend?.cancel(); wakeSend = nil
        retry?.cancel(); retry = nil
        releaseAll(); ready = false; powerOn = nil; foregroundPackage = ""
        token += 1
        let generation = token
        session?.disconnect()
        let result = TVSession(host: host, identity: identity)
        session = result
        result.event = { [weak self] event in
            guard let self, generation == self.token else { return }
            switch event {
            case .pairingCodeNeeded:
                self.showingPIN = true; self.status = String(localized: "Enter the code on your TV")
            case .paired(let pin):
                do { try self.savePin(pin) }
                catch { self.error = error.localizedDescription; return }
                self.pairing = false; self.showingPIN = false; self.error = ""; self.attempt = 0
                self.pairings += 1
                self.connect()
            case .connected:
                self.ready = true; self.status = String(localized: "Connected"); self.attempt = 0; self.error = ""
            case .power(let on):
                self.powerOn = on
                if on { self.cancelWake() }
                else if self.waking { self.scheduleWake() }
                self.status = on ? String(localized: "Connected") : (self.waking ? String(localized: "Waking TV…") : String(localized: "Standby"))
            case .foreground(let package):
                self.foregroundPackage = package
            case .volume(let current, let max, let muted):
                self.muted = muted
                self.volume = muted ? String(localized: "Muted") : (max == 100 ? String(localized: "Volume \(current)") : String(localized: "Volume \(current)/\(max)"))
            case .error(let message):
                self.ready = false; self.pressed.removeAll(); self.error = message
                if self.pairing { self.status = String(localized: "Pairing needs attention") }
                else { self.status = self.waking ? String(localized: "Waking TV…") : String(localized: "Reconnecting…"); self.scheduleReconnect() }
            }
        }
        return result
    }

    func connect() {
        guard active && !pairing && !preparing else { return }
        guard let pin = pin() else { hasSavedPairing = false; status = String(localized: "Pair your TV to get started"); ready = false; return }
        hasSavedPairing = true
        status = waking ? String(localized: "Waking TV…") : String(localized: "Connecting…")
        if kind != .androidTV { newBrand()?.connect(credential: pin); return }
        newSession()?.connect(pin: pin)
    }

    /// True while a Roku/LG/Samsung TV shows its "Allow" prompt (instead of a code).
    @Published private(set) var approving = false

    private func newBrand() -> BrandRemote? {
        guard active else { return nil }
        retry?.cancel(); retry = nil
        releaseAll(); ready = false; powerOn = nil; brandApp = ""
        token += 1
        let generation = token
        session?.disconnect(); session = nil
        brand?.disconnect()
        guard let result = Self.makeBrand(kind, host: host) else { return nil }
        brand = result
        result.event = { [weak self] event in
            guard let self, generation == self.token else { return }
            switch event {
            case .approvalNeeded:
                self.approving = true; self.status = String(localized: "Allow Purio on your TV")
            case .approved(let credential):
                do { try self.savePin(credential) } catch { self.error = error.localizedDescription; return }
                if self.pairing { self.pairings += 1 }
                self.pairing = false; self.approving = false; self.error = ""; self.attempt = 0
            case .connected:
                self.pairing = false; self.approving = false
                self.ready = true; self.status = String(localized: "Connected"); self.attempt = 0; self.error = ""
            case .power(let on):
                self.powerOn = on
                self.status = on ? String(localized: "Connected") : String(localized: "Standby")
            case .foreground(let name):
                self.brandApp = name
            case .volume(let current, let max, let muted):
                self.muted = muted
                self.volume = muted ? String(localized: "Muted") : (max == 100 ? String(localized: "Volume \(current)") : String(localized: "Volume \(current)/\(max)"))
            case .error(let message):
                self.ready = false; self.pressed.removeAll(); self.error = message
                if self.pairing { self.approving = false; self.status = String(localized: "Pairing needs attention") }
                else { self.status = String(localized: "Reconnecting…"); self.scheduleReconnect() }
            }
        }
        return result
    }
    private func scheduleReconnect() {
        guard active && !pairing && autoReconnect else { return }
        retry?.cancel()
        let delay = min(15.0, pow(2.0, Double(min(attempt, 4))))
        attempt += 1
        let task = DispatchWorkItem { [weak self] in self?.connect() }
        retry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    func beginPairing() {
        if kind != .androidTV, active {
            cancelWake()
            pairing = true; showingPIN = false; approving = false; error = ""; status = String(localized: "Connecting…")
            newBrand()?.connect(credential: nil)
            return
        }
        guard active && !preparing else { return }
        cancelWake()
        // Without an identity (the Keychain refused to create or return it) there is nothing to pair with: say so
        // instead of waiting for a code that can't come.
        guard identity != nil else {
            if error.isEmpty { error = String(localized: "Pairing identity unavailable. Restart the app; if it persists, reinstall it.") }
            status = String(localized: "Pairing identity unavailable"); return
        }
        pairing = true; showingPIN = false; error = ""; status = String(localized: "Showing a code on your TV…")
        newSession()?.pair()
    }
    func submit(_ code: String) { error = ""; session?.submit(code: code) }
    func cancelPairing() {
        guard pairing else { return }
        pairing = false; showingPIN = false; approving = false; token += 1
        session?.disconnect(); session = nil
        brand?.disconnect(); brand = nil
        error = ""; connect()
    }
    func tap(_ key: TVKey) {
        guard ready else { return }
        if let brand { brand.key(key, direction: 3) } else { session?.key(key) }
    }
    func power() {
        guard active && !preparing && !pairing && !waking else { return }
        if let brand {
            // Roku turns on over the network; LG and Samsung only turn off (on needs Wake-on-LAN, not allowed on iOS yet).
            if ready && (powerOn != false || kind == .roku) { brand.key(.power, direction: 3) }
            else if !ready { error = String(localized: "Turn the TV on with its own remote; Purio connects when it's on."); attempt = 0; connect() }
            return
        }
        if ready && powerOn != false { session?.key(.power); return }
        guard pin() != nil else { error = String(localized: "Pair the TV while it is on before using wake."); return }
        waking = true; error = ""; status = String(localized: "Waking TV…")
        wakeRequest.begin()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.waking else { return }
            let underlyingError = self.error
            self.cancelWake()
            self.status = self.ready ? String(localized: "Standby") : String(localized: "TV unavailable")
            self.error = underlyingError.isEmpty ? String(localized: "Could not wake the TV. Check Ethernet and enable Network Standby / Quick Start on the TV.") : underlyingError
        }
        wakeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        // Refresh the TV's reported power state before sending a single toggle.
        attempt = 0; connect()
    }
    private func cancelWake() {
        wakeRequest.cancel(); wakeTimeout?.cancel(); wakeTimeout = nil; waking = false
        wakeSend?.cancel(); wakeSend = nil
    }
    private func scheduleWake() {
        guard wakeSend == nil else { return }
        let generation = token
        let send = DispatchWorkItem { [weak self] in
            guard let self, generation == self.token else { return }
            self.wakeSend = nil
            guard self.active, self.waking, self.ready, self.powerOn == false,
                  let key = self.wakeRequest.consume(powerIsOn: false) else { return }
            self.session?.key(key)
        }
        wakeSend = send
        // TCL's virtual input bridge becomes usable after RemoteStart is reported.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: send)
    }
    func press(_ key: TVKey) {
        guard ready && !pressed.contains(key) else { return }
        pressed.insert(key)
        if let brand { brand.key(key, direction: 1) } else { session?.key(key, direction: 1) }
    }
    func release(_ key: TVKey) {
        guard pressed.remove(key) != nil else { return }
        if let brand { brand.key(key, direction: 2) } else { session?.key(key, direction: 2) }
    }
    private func releaseAll() { for key in Array(pressed) { release(key) } }
    func launch(_ url: String) { if ready { session?.launch(url) } }
    /// An app button: its link on Android TVs, its name among the TV's own apps on Roku, LG and Samsung.
    func open(_ app: RemoteApp) {
        guard ready else { return }
        guard let brand else { session?.launch(app.launchURL); return }
        Task {
            do { if try await brand.launch(named: app.name) == false { error = String(localized: "\(app.name) isn't on this TV.") } }
            catch { self.error = error.localizedDescription }
        }
    }
    /// Every app a Roku, LG or Samsung TV reports (All apps); nil on Android TV, where Purio's Home lists them.
    func brandApps() async throws -> [BrandApp]? {
        guard let brand else { return nil }
        return try await brand.apps()
    }
    func launch(_ app: BrandApp) {
        guard ready, let brand else { return }
        Task { do { try await brand.launch(app) } catch { self.error = error.localizedDescription } }
    }
    /// Opens an app by name on any TV (quick actions, Siri): false when the TV doesn't have it.
    func open(named name: String, link: String) async throws -> Bool {
        if let brand { return try await brand.launch(named: name) }
        try await sendLink(link); return true
    }
    /// True when the remote is connected and the TV has spoken recently. After the phone sleeps, a dead socket can
    /// still look connected for a while; the TV pings every few seconds, so silence means it no longer hears us.
    var remoteLooksAlive: Bool {
        if brand != nil { return ready }
        guard ready, let session else { return false }
        return Date().timeIntervalSince(session.lastInbound) < 12
    }
    /// Reconnects the remote first if it went quiet (up to 10 s). False if it still isn't answering.
    func freshen() async -> Bool {
        if let brand, ready, await brand.alive() { return true }
        if brand == nil, remoteLooksAlive { return true }
        attempt = 0; connect()
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if remoteLooksAlive { return true }
        }
        return false
    }
    /// Sends an app link through the paired remote connection and waits until it is written (TV Home editor key).
    func sendLink(_ url: String) async throws {
        guard ready, let session else { throw RemoteFailure.message(String(localized: "Connect the TV first")) }
        try await session.writeLaunch(url)
    }

    var currentAppName: String? {
        guard ready, powerOn != false else { return nil }
        if brand != nil { return brandApp.isEmpty ? nil : brandApp }
        return TVSession.appName(for: foregroundPackage)
    }
}
