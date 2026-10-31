import Foundation
import Security

public enum TVPairingStore {
    public static func pin(host: String, service: String = "PersonalTVRemote.TVPin.v1") -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: host, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    public static func save(_ data: Data, host: String, service: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: host]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw RemoteFailure.message("Could not save TV pairing") }
    }
}

/// One ephemeral, paired connection per Siri request/quick action. No queued commands or toggle retries.
@MainActor public final class CommandRunner {
    private var session: TVSession?
    private var power: Bool?
    private var muted: Bool?
    private var waiter: CheckedContinuation<Void, Error>?
    private var waitForOn = false
    private var timeout: Task<Void, Never>?
    public init() {}
    public func cancel() { finishWait(RemoteFailure.message("Action cancelled")); session?.disconnect(); session = nil }
    private func finishWait(_ error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        guard let waiter else { return }; self.waiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
    private func wait(seconds: UInt64, onOnly: Bool = false, start: () -> Void) async throws {
        try Task.checkCancellation()
        waitForOn = onOnly
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiter = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
                    self?.finishWait(RemoteFailure.message("TV connection timed out"))
                }
                start()
                if Task.isCancelled { finishWait(CancellationError()) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }
    public func run(_ steps: [ActionStep], host: String, apps: [RemoteApp], inputs: [TVInput] = [], progress: ((Int) -> Void)? = nil) async throws {
        guard (1...12).contains(steps.count), let pin = TVPairingStore.pin(host: host) else { throw RemoteFailure.message("Open TV Remote and pair the TV first") }
        try Task.checkCancellation()
        let identity = try ClientIdentity.loadOrCreate()
        let session = TVSession(host: host, identity: identity); self.session = session
        defer { timeout?.cancel(); self.session?.disconnect(); self.session = nil }
        power = nil; muted = nil
        session.event = { [weak self] event in
            guard let self else { return }
            switch event {
            case .power(let on): self.power = on; if !self.waitForOn || on { self.finishWait() }
            case .volume(_, _, let muted): self.muted = muted
            case .error(let error): self.finishWait(RemoteFailure.message(error))
            default: break
            }
        }
        try await wait(seconds: 15) { session.connect(pin: pin) }
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            switch step.kind {
            case .wake:
                if power == false {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    if power == false {
                        try await session.writeKey(.power)
                        if power != true { try await wait(seconds: 10, onOnly: true, start: {}) }
                    }
                }
            case .sleep: if power == true { try await session.writeKey(.power) }
            case .openApp:
                guard power == true, let app = apps.first(where: { $0.id == step.argument }) else { throw RemoteFailure.message("Wake the TV and choose an available app") }
                try await session.writeLaunch(app.launchURL)
            case .input:
                guard power == true, let input = inputs.first(where: { $0.id == step.argument }) else { throw RemoteFailure.message("Connect the TV editor and assign this input first") }
                try await session.writeLaunch(input.launchURL)
            case .home: try await session.writeKey(.home)
            case .pause: try await session.writeKey(.pause)
            case .playPause: try await session.writeKey(.playPause)
            case .volumeUp: try await session.writeKey(.volumeUp)
            case .volumeDown: try await session.writeKey(.volumeDown)
            case .mute:
                if muted == nil { try await Task.sleep(nanoseconds: 300_000_000) }
                guard let muted else { throw RemoteFailure.message("Could not read the TV’s mute state") }
                if !muted { try await session.writeKey(.mute) }
            }
            progress?(index + 1)
            if index < steps.count - 1 { try await Task.sleep(nanoseconds: 350_000_000) }
        }
    }
    public func diagnose(host: String) async throws {
        // An empty quick action is never allowed; this action requests no state-changing command.
        guard let pin = TVPairingStore.pin(host: host) else { throw RemoteFailure.message("Pair the TV first") }
        let result = TVSession(host: host, identity: try ClientIdentity.loadOrCreate()); session = result
        defer { result.disconnect(); session = nil }
        result.event = { [weak self] event in
            switch event {
            case .power: self?.finishWait()
            case .error(let error): self?.finishWait(RemoteFailure.message(error))
            default: break
            }
        }
        try await wait(seconds: 15) { result.connect(pin: pin) }
    }
}
