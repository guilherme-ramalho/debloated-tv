import Foundation
import Network
import Security
import CryptoKit

/// The phone editor link (docs/launcher-editor-contract.md, version 2). A fresh 32-byte key travels to the TV inside
/// tvhome://phone-edit?k=…, sent through the already paired Android TV Remote connection, so the editor needs no
/// pairing of its own: only a phone the TV's remote service trusts can deliver the key.
public enum EditorLink {
    public static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw RemoteFailure.message("Could not create a TV editor key") }
        return Data(bytes)
    }
    public static func newKey() throws -> Data { try random(32) }
    /// Names a key without revealing it (HKDF-SHA256, 8 bytes). Sent in the hello so a TV listener started for an
    /// older link turns the connection away at once; EditorCrypto.keyId on the TV.
    public static func keyId(_ key: Data) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: Data(), info: Data("tvhome-editor v2 key-id".utf8),
                               outputByteCount: 8).withUnsafeBytes { Data($0) }
    }
    public static func url(key: Data) -> String {
        "tvhome://phone-edit?k=" + key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// One direction of an editor session: AES-256-GCM with an HKDF-SHA256 key and an in-order counter nonce.
/// Mirrors EditorCrypto.Channel in the launcher; EditorCipherTests checks both against the same vector.
public struct EditorCipher {
    public static let phoneToTV = "tvhome-editor v2 phone-to-tv"
    public static let tvToPhone = "tvhome-editor v2 tv-to-phone"
    let key: SymmetricKey
    private var counter: UInt64 = 0
    public init(sessionKey: Data, phoneNonce: Data, tvNonce: Data, info: String) throws {
        guard sessionKey.count == 32, phoneNonce.count == 16, tvNonce.count == 16 else { throw RemoteFailure.message("Invalid TV editor key") }
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sessionKey), salt: phoneNonce + tvNonce,
                                     info: Data(info.utf8), outputByteCount: 32)
    }
    static func nonce(_ counter: UInt64) -> Data { Data(repeating: 0, count: 4) + withUnsafeBytes(of: counter.bigEndian) { Data($0) } }
    public mutating func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: Self.nonce(counter)))
        guard let combined = box.combined else { throw RemoteFailure.message("Could not encrypt the TV editor message") }
        counter += 1
        return combined
    }
    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 28, Data(frame.prefix(12)) == Self.nonce(counter) else { throw RemoteFailure.message("TV editor message out of order") }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: frame), using: key)
        counter += 1
        return plain
    }
}

/// Guards a continuation that several connection callbacks may try to finish; touched only on the socket's queue.
private final class EditorOnce: @unchecked Sendable { var done = false }

/// Plain TCP with length-prefixed frames; everything after the hello is sealed by EditorCipher.
final class EditorSocket: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tvremote.editor", qos: .userInitiated)
    private let connection: NWConnection
    private var decoder = FrameDecoder(maxFrameSize: 4_194_304)
    private var closed = false
    /// Called on the main queue, in arrival order.
    var frame: ((Data) -> Void)?
    var failed: ((String) -> Void)?

    private init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
    }

    /// Connects, retrying while the TV starts its short-lived listener.
    static func connect(host: String, port: UInt16, within seconds: Double) async throws -> EditorSocket {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            try Task.checkCancellation()
            let socket = EditorSocket(host: host, port: port)
            if await socket.start(timeout: min(3, max(0.5, deadline.timeIntervalSinceNow))) { return socket }
            socket.close()
            try await Task.sleep(nanoseconds: 400_000_000)
        } while Date() < deadline
        throw RemoteFailure.message("TV Home did not answer. Check that the TV launcher is up to date.")
    }

    private func start(timeout: Double) async -> Bool {
        await withCheckedContinuation { (result: CheckedContinuation<Bool, Never>) in
            let once = EditorOnce()
            let finish: (Bool) -> Void = { ok in guard !once.done else { return }; once.done = true; result.resume(returning: ok) }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .waiting, .failed, .cancelled: finish(false)   // refused while the TV is still starting: retry
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    func beginReceiving() {
        queue.async { [self] in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled, .waiting: self?.fail("TV Home closed the editor")
                default: break
                }
            }
            receive()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.decoder.append(data) {
                        let callback = self.frame
                        DispatchQueue.main.async { callback?(message) }
                    }
                } catch { self.fail("TV Home sent an invalid message"); return }
            }
            if error != nil || complete { self.fail("TV Home closed the editor"); return }
            self.receive()
        }
    }

    func send(_ payload: Data) {
        queue.async { [self] in
            guard !closed else { return }
            connection.send(content: Wire.varint(UInt64(payload.count)) + payload, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.queue.async { self?.fail("TV editor connection was interrupted") } }
            })
        }
    }

    func close() { queue.async { [self] in finish() } }
    private func finish() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        frame = nil; failed = nil
    }
    private func fail(_ reason: String) {
        guard !closed else { return }
        let callback = failed
        finish()
        DispatchQueue.main.async { callback?(reason) }
    }
}

/// An editing session with TV Home, open only while the TV tab is on screen.
/// The caller sends EditorLink.url(key:) through the remote connection first; the TV then listens briefly for this key.
@MainActor public final class LauncherClient {
    public enum Event { case disconnected(String) }
    public var event: ((Event) -> Void)?
    private static let port: UInt16 = 9764
    private static let magic = Data("TVH2".utf8)
    private var socket: EditorSocket?
    private var outgoing: EditorCipher?
    private var incoming: EditorCipher?
    private var generation = 0
    private var socketID = 0
    private var hello: CheckedContinuation<Data, Error>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var keepalive: Task<Void, Never>?
    public init() {}

    public func close() {
        generation += 1
        socket?.close(); socket = nil; outgoing = nil; incoming = nil
        keepalive?.cancel(); keepalive = nil
        hello?.resume(throwing: CancellationError()); hello = nil
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }; pending.removeAll()
        for timeout in timeouts.values { timeout.cancel() }; timeouts.removeAll()
    }

    /// Connects and completes the hello, retrying until `seconds` pass: the TV's listener may still be starting, or
    /// one left from an earlier link may answer first and turn this key away.
    public func open(host: String, key: Data, within seconds: Double = 10) async throws {
        close()
        let token = generation
        let deadline = Date().addingTimeInterval(seconds)
        var lastError: Error = RemoteFailure.message("TV Home did not answer. Check that the TV launcher is up to date.")
        repeat {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            do {
                try await attempt(host: host, key: key, token: token, until: deadline)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                dropSocket()
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        } while Date() < deadline
        throw lastError
    }

    private func attempt(host: String, key: Data, token: Int, until deadline: Date) async throws {
        let socket = try await EditorSocket.connect(host: host, port: Self.port, within: max(1, deadline.timeIntervalSinceNow))
        guard generation == token else { socket.close(); throw CancellationError() }
        socketID += 1
        let id = socketID
        self.socket = socket
        socket.frame = { [weak self] data in MainActor.assumeIsolated {
            guard let self, self.generation == token, self.socketID == id else { return }
            self.received(data, token: token)
        } }
        socket.failed = { [weak self] reason in MainActor.assumeIsolated {
            guard let self, self.generation == token, self.socketID == id else { return }
            if let waiting = self.hello { self.hello = nil; waiting.resume(throwing: RemoteFailure.message(reason)); return }
            self.close(); self.event?(.disconnected(reason))
        } }
        socket.beginReceiving()
        let phoneNonce = try EditorLink.random(16)
        socket.send(Self.magic + phoneNonce + EditorLink.keyId(key))
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            hello = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.generation == token, self.socketID == id, let waiting = self.hello else { return }
                self.hello = nil
                waiting.resume(throwing: RemoteFailure.message("TV Home did not answer the editor"))
            }
        }
        guard generation == token, socketID == id else { throw CancellationError() }
        guard reply.count == 20, Data(reply.prefix(4)) == Self.magic else {
            throw RemoteFailure.message("TV Home answered with an older editor. Update the TV launcher.")
        }
        let tvNonce = Data(reply.dropFirst(4))
        outgoing = try EditorCipher(sessionKey: key, phoneNonce: phoneNonce, tvNonce: tvNonce, info: EditorCipher.phoneToTV)
        incoming = try EditorCipher(sessionKey: key, phoneNonce: phoneNonce, tvNonce: tvNonce, info: EditorCipher.tvToPhone)
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, self.generation == token else { return }
                self.send(["type": "ping"])
            }
        }
    }

    /// Ends a failed attempt without ending the open() that is still retrying.
    private func dropSocket() {
        socketID += 1
        socket?.close(); socket = nil; outgoing = nil; incoming = nil
        hello?.resume(throwing: CancellationError()); hello = nil
    }

    private func send(_ object: [String: Any]) {
        guard let socket, var cipher = outgoing, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do { let sealed = try cipher.seal(data); outgoing = cipher; socket.send(sealed) }
        catch { close(); event?(.disconnected(error.localizedDescription)) }
    }

    private func received(_ data: Data, token: Int) {
        guard generation == token else { return }
        if let waiting = hello { hello = nil; waiting.resume(returning: data); return }
        guard var cipher = incoming else { return }
        do {
            let plain = try cipher.open(data); incoming = cipher
            guard let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw RemoteFailure.message("Invalid TV editor response") }
            switch object["type"] as? String {
            case "response":
                guard let id = object["id"] as? String, let continuation = pending.removeValue(forKey: id) else { return }
                timeouts.removeValue(forKey: id)?.cancel()
                if object["ok"] as? Bool == true {
                    do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: object["result"] ?? [:], options: [.fragmentsAllowed])) }
                    catch { continuation.resume(throwing: error); throw error }
                } else { continuation.resume(throwing: RemoteFailure.message(object["error"] as? String ?? "The TV rejected this change")) }
            case "error": close(); event?(.disconnected(object["message"] as? String ?? "TV editor error"))
            case "pong": break
            default: throw RemoteFailure.message("Unsupported TV editor response")
            }
        } catch { close(); event?(.disconnected(error.localizedDescription)) }
    }

    public func request<T: Decodable>(_ operation: String, payload: [String: Any] = [:], as: T.Type) async throws -> T {
        guard socket != nil, outgoing != nil else { throw RemoteFailure.message("TV Home is not connected") }
        let id = UUID().uuidString
        let response: Data = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { result in
                pending[id] = result
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    self?.pending.removeValue(forKey: id)?.resume(throwing: RemoteFailure.message("TV Home took too long to answer. Refresh before retrying a change."))
                    self?.timeouts.removeValue(forKey: id)
                }
                send(["type": "request", "id": id, "operation": operation, "payload": payload])
                if Task.isCancelled { cancelRequest(id) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancelRequest(id) } })
        return try JSONDecoder().decode(T.self, from: response)
    }
    private func cancelRequest(_ id: String) { timeouts.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
