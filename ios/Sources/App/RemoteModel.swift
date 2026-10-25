import SwiftUI
import Security

@MainActor final class RemoteModel: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "tvHost") ?? "192.168.1.100"
    @Published var status = "Preparing secure pairing…"
    @Published var ready = false
    @Published var preparing = true
    @Published var showingPIN = false
    @Published var error = ""
    @Published var volume = "Volume"
    @Published var powerOn: Bool?
    @Published var waking = false
    @Published var foregroundPackage = ""
    private var identity: ClientIdentity?
    private var session: TVSession?
    private var active = false
    private var pairing = false
    private var attempt = 0
    private var retry: DispatchWorkItem?
    private var token = 0
    private var pressed = Set<TVKey>()
    private var wakeRequest = WakeRequest()
    private var wakeTimeout: DispatchWorkItem?
    private var wakeSend: DispatchWorkItem?
    private static let pinService = "PersonalTVRemote.TVPin.v1"

    func activate() {
        guard !active else { return }
        active = true
        if identity == nil && preparing {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try ClientIdentity.loadOrCreate() }
                DispatchQueue.main.async {
                    self.preparing = false
                    switch result {
                    case .success(let identity):
                        self.identity = identity
                        if self.active { self.connect() }
                    case .failure(let error): self.status = "Pairing identity unavailable"; self.error = error.localizedDescription
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
        ready = false; powerOn = nil
        if pairing { pairing = false; showingPIN = false }
    }

    @discardableResult func saveHost(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else {
            error = "Enter the TV’s IPv4 address, for example 192.168.1.100"; return false
        }
        deactivate()
        host = value; UserDefaults.standard.set(value, forKey: "tvHost")
        foregroundPackage = ""; attempt = 0; active = true; connect(); return true
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
        guard status == errSecSuccess else { throw RemoteFailure.message("Could not save TV pairing (\(status))") }
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
                self.showingPIN = true; self.status = "Enter the code on your TV"
            case .paired(let pin):
                do { try self.savePin(pin) }
                catch { self.error = error.localizedDescription; return }
                self.pairing = false; self.showingPIN = false; self.error = ""; self.attempt = 0
                self.connect()
            case .connected:
                self.ready = true; self.status = "Connected"; self.attempt = 0; self.error = ""
            case .power(let on):
                self.powerOn = on
                if on { self.cancelWake() }
                else if self.waking { self.scheduleWake() }
                self.status = on ? "Connected" : (self.waking ? "Waking TV…" : "Standby")
            case .foreground(let package):
                self.foregroundPackage = package
            case .volume(let current, let max, let muted):
                self.volume = muted ? "Muted" : (max == 100 ? "Volume \(current)" : "Volume \(current)/\(max)")
            case .error(let message):
                self.ready = false; self.pressed.removeAll(); self.error = message
                if self.pairing { self.status = "Pairing needs attention" }
                else { self.status = self.waking ? "Waking TV…" : "Reconnecting…"; self.scheduleReconnect() }
            }
        }
        return result
    }

    func connect() {
        guard active && !pairing && !preparing else { return }
        guard let pin = pin() else { status = "Pair your TV to get started"; ready = false; return }
        status = waking ? "Waking TV…" : "Connecting…"
        newSession()?.connect(pin: pin)
    }
    private func scheduleReconnect() {
        guard active && !pairing else { return }
        retry?.cancel()
        let delay = min(15.0, pow(2.0, Double(min(attempt, 4))))
        attempt += 1
        let task = DispatchWorkItem { [weak self] in self?.connect() }
        retry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    func beginPairing() {
        guard active && !preparing else { return }
        cancelWake()
        pairing = true; showingPIN = false; error = ""; status = "Showing a code on your TV…"
        newSession()?.pair()
    }
    func submit(_ code: String) { error = ""; session?.submit(code: code) }
    func cancelPairing() {
        guard pairing else { return }
        pairing = false; showingPIN = false; token += 1
        session?.disconnect(); session = nil
        error = ""; connect()
    }
    func tap(_ key: TVKey) { if ready { session?.key(key) } }
    func power() {
        guard active && !preparing && !pairing && !waking else { return }
        if ready && powerOn != false { session?.key(.power); return }
        guard pin() != nil else { error = "Pair the TV while it is on before using wake."; return }
        waking = true; error = ""; status = "Waking TV…"
        wakeRequest.begin()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.waking else { return }
            let underlyingError = self.error
            self.cancelWake()
            self.status = self.ready ? "Standby" : "TV unavailable"
            self.error = underlyingError.isEmpty ? "Could not wake the TV. Check Ethernet and enable Network Standby / Quick Start on the TV." : underlyingError
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
        pressed.insert(key); session?.key(key, direction: 1)
    }
    func release(_ key: TVKey) {
        guard pressed.remove(key) != nil else { return }
        session?.key(key, direction: 2)
    }
    private func releaseAll() { for key in Array(pressed) { release(key) } }
    func launch(_ url: String) { if ready { session?.launch(url) } }

    var currentAppName: String {
        if powerOn == false { return "Standby" }
        if !ready { return "On TV" }
        return TVSession.appName(for: foregroundPackage) ?? (foregroundPackage.isEmpty ? "Waiting for TV…" : "Another app")
    }
}
