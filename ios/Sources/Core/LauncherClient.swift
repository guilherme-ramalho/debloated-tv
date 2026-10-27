import Foundation
import Security
import CryptoKit

/// Explicit editing session, separate from the always-available built-in TV remote connection.
/// The TV-side adapter is an upcoming launcher update; unavailable TVs never produce simulated results.
@MainActor public final class LauncherClient {
    public enum Event { case code, paired(Data), disconnected(String) }
    public var event: ((Event) -> Void)?
    private var connection: TVConnection?
    private var generation = 0
    private var pairing = false
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var keepalive: Task<Void, Never>?
    private var opening: CheckedContinuation<Void, Error>?
    public init() {}
    public func close() {
        generation += 1; connection?.close(); connection = nil; keepalive?.cancel(); keepalive = nil
        opening?.resume(throwing: CancellationError()); opening = nil
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }; pending.removeAll()
        for timeout in timeouts.values { timeout.cancel() }; timeouts.removeAll()
    }
    private func send(_ object: [String: Any]) { if let data = try? JSONSerialization.data(withJSONObject: object) { connection?.send(data) } }
    public func open(host: String, identity: ClientIdentity, pin: Data?, pair: Bool = false) async throws {
        close(); pairing = pair
        let token = generation
        let channel = TVConnection(host: host, port: 9764, identity: identity, pin: pin, allowUnpaired: pair, maxFrameSize: 4_194_304)
        connection = channel
        channel.ready = { [weak self] in Task { @MainActor in
            guard let self, self.generation == token else { return }
            if pair { self.send(["type":"pair"]) }
            self.opening?.resume(); self.opening = nil
            guard !pair else { return }
            self.keepalive = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    guard let self, self.generation == token else { return }; self.send(["type":"ping"])
                }
            }
        } }
        channel.frame = { [weak self] data in Task { @MainActor in
            guard let self, self.generation == token else { return }
            do {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteFailure.message("Invalid TV editor response") }
                switch object["type"] as? String {
                case "code": guard self.pairing else { return }; self.event?(.code)
                case "paired":
                    guard self.pairing, let certificate = channel.peerCertificate else { return }
                    let fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
                    self.close(); self.event?(.paired(fingerprint))
                case "response":
                    guard let id = object["id"] as? String, let continuation = self.pending.removeValue(forKey: id) else { return }
                    self.timeouts.removeValue(forKey: id)?.cancel()
                    if object["ok"] as? Bool == true {
                        do { let result = try JSONSerialization.data(withJSONObject: object["result"] ?? [:], options: [.fragmentsAllowed]); continuation.resume(returning: result) }
                        catch { continuation.resume(throwing: error); throw error }
                    } else { continuation.resume(throwing: RemoteFailure.message(object["error"] as? String ?? "The TV rejected this change")) }
                case "error": self.event?(.disconnected(object["message"] as? String ?? "TV editor error"))
                case "pong": break
                default: throw RemoteFailure.message("Unsupported TV editor response")
                }
            } catch { self.close(); self.event?(.disconnected(error.localizedDescription)) }
        } }
        channel.failed = { [weak self] reason in Task { @MainActor in
            guard let self, self.generation == token else { return }
            self.close(); self.event?(.disconnected(reason))
        } }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                opening = result; channel.start()
                if Task.isCancelled { close() }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.close() } })
    }
    public func submit(code: String, identity: ClientIdentity) throws {
        guard pairing, let certificate = connection?.peerCertificate, let server = SecCertificateCopyKey(certificate) else { throw RemoteFailure.message("Start TV Home pairing first") }
        let proof = try ClientIdentity.secret(code: code, client: identity.publicKey, server: server)
        send(["type":"proof", "proof":proof.base64EncodedString()])
    }
    public func request<T: Decodable>(_ operation: String, payload: [String: Any] = [:], as: T.Type) async throws -> T {
        guard connection != nil, !pairing else { throw RemoteFailure.message("Connect the TV editor first") }
        let id = UUID().uuidString
        let response: Data = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { result in
                pending[id] = result
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    self?.pending.removeValue(forKey: id)?.resume(throwing: RemoteFailure.message("TV editor request timed out. Refresh before retrying a change."))
                    self?.timeouts.removeValue(forKey: id)
                }
                send(["type":"request", "id":id, "operation":operation, "payload":payload])
                if Task.isCancelled { cancelRequest(id) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancelRequest(id) } })
        return try JSONDecoder().decode(T.self, from: response)
    }
    private func cancelRequest(_ id: String) { timeouts.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
