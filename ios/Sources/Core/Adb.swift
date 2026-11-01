import Foundation
import Network
import Security
import CryptoKit

/// A small Android Debug Bridge client: enough to inspect a TV, disable packages, push and install an APK and restore
/// it all, from the iPhone with no computer. Speaks the plain TCP transport (network debugging, usually port 5555);
/// the newer Wireless debugging pairing is a later phase. Reference: AOSP packages/modules/adb/protocol.txt.
public enum Adb {
    public static let cnxn: UInt32 = 0x4e58_4e43, auth: UInt32 = 0x4854_5541, open: UInt32 = 0x4e45_504f
    public static let okay: UInt32 = 0x5941_4b4f, clse: UInt32 = 0x4553_4c43, wrte: UInt32 = 0x4554_5257
    public static let version: UInt32 = 0x0100_0001
    public static let maxData: UInt32 = 256 * 1024
    static let authToken: UInt32 = 1, authSignature: UInt32 = 2, authPublicKey: UInt32 = 3

    public struct Message: Equatable {
        public let command: UInt32, arg0: UInt32, arg1: UInt32, payload: Data
        public init(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data = Data()) {
            self.command = command; self.arg0 = arg0; self.arg1 = arg1; self.payload = payload
        }
    }

    static func le(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func readLE(_ bytes: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[bytes.startIndex + offset + i]) << (8 * i) }
        return value
    }

    /// 24-byte header (command, arg0, arg1, length, byte sum, command ^ 0xffffffff), then the payload.
    public static func encode(_ m: Message) -> Data {
        let sum = m.payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        return le(m.command) + le(m.arg0) + le(m.arg1) + le(UInt32(m.payload.count)) + le(sum) + le(m.command ^ 0xffff_ffff) + m.payload
    }

    public struct Decoder {
        private var buffer = Data()
        public init() {}
        public mutating func append(_ data: Data) throws -> [Message] {
            buffer.append(data)
            var out = [Message]()
            while buffer.count >= 24 {
                let header = Data(buffer.prefix(24))
                let command = readLE(header, 0), length = readLE(header, 12), magic = readLE(header, 20)
                guard magic == command ^ 0xffff_ffff else { throw RemoteFailure.message(String(localized: "The TV sent an invalid debugging message")) }
                guard length <= Adb.maxData * 4 else { throw RemoteFailure.message(String(localized: "The TV sent an oversized debugging message")) }
                guard buffer.count >= 24 + Int(length) else { break }
                out.append(Message(command, readLE(header, 4), readLE(header, 8), Data(buffer.dropFirst(24).prefix(Int(length)))))
                buffer = Data(buffer.dropFirst(24 + Int(length)))
            }
            return out
        }
    }

    /// The TV's identity from the CNXN banner, e.g. "device::ro.product.name=…;ro.product.model=…;features=…".
    public static func bannerProperties(_ payload: Data) -> [String: String] {
        let text = String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
        guard let range = text.range(of: "::") else { return [:] }
        var props = [String: String]()
        for item in text[range.upperBound...].split(separator: ";") {
            let parts = item.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { props[String(parts[0])] = String(parts[1]) }
        }
        return props
    }
}

/// The iPhone's ADB key: RSA-2048 in the Keychain, never leaves the device. The TV shows "Allow USB debugging?" for
/// it once; "Always allow" keeps it authorized.
public struct AdbKey {
    public let privateKey: SecKey
    private static let tag = Data("com.guilhermeramalho.TVRemote.adb.v1".utf8)

    public init(privateKey: SecKey) { self.privateKey = privateKey }

    public static func loadOrCreate() throws -> AdbKey {
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
                                    kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecReturnRef as String: true]
        var found: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let found { return AdbKey(privateKey: found as! SecKey) }
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag,
                                            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() as Error? ?? RemoteFailure.message(String(localized: "Could not create the TV debugging key"))
        }
        return AdbKey(privateKey: key)
    }

    /// adb signs the 20-byte token as if it were a SHA-1 digest (PKCS#1 v1.5 with the SHA-1 DigestInfo).
    public func sign(token: Data) throws -> Data {
        guard token.count == 20 else { throw RemoteFailure.message(String(localized: "The TV sent an unexpected authorization token")) }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() as Error? ?? RemoteFailure.message(String(localized: "Could not sign the TV's authorization request"))
        }
        return signature
    }

    /// The public key as the TV stores it in /data/misc/adb/adb_keys: base64 of Android's RSAPublicKey struct, a name.
    public func publicKeyLine(name: String) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw RemoteFailure.message(String(localized: "Invalid TV debugging key")) }
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() as Error? ?? RemoteFailure.message(String(localized: "Could not export the TV debugging key"))
        }
        var offset = 0
        let sequence = try DER.read(Array(pkcs1), &offset)
        var position = 0
        let bytes = Array(sequence.1)
        let modulus = try DER.read(bytes, &position), exponent = try DER.read(bytes, &position)
        let e = exponent.1.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Data((try Self.androidEncoding(modulus: modulus.1, exponent: e).base64EncodedString() + " " + name).utf8) + Data([0])
    }

    /// Android's struct { len = 64; n0inv; n[64] (LE words); rr[64]; exponent } for a 2048-bit modulus (big-endian bytes).
    public static func androidEncoding(modulus: Data, exponent: UInt32) throws -> Data {
        var be = Array(modulus)
        while be.count > 256 && be.first == 0 { be.removeFirst() }
        guard be.count == 256 else { throw RemoteFailure.message(String(localized: "The TV debugging key must be RSA-2048")) }
        // Little-endian 32-bit words.
        var n = [UInt32](repeating: 0, count: 64)
        for i in 0..<64 {
            let base = 255 - i * 4
            n[i] = UInt32(be[base]) | UInt32(be[base - 1]) << 8 | UInt32(be[base - 2]) << 16 | UInt32(be[base - 3]) << 24
        }
        // n0inv = -1 / n[0] mod 2^32 (Newton's iteration doubles the correct low bits each step).
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- n[0] &* inv) }
        let n0inv = 0 &- inv
        // rr = (2^2048)^2 mod n, by doubling 4096 times.
        var r = [UInt32](repeating: 0, count: 65); r[0] = 1
        let n65 = n + [0]
        for _ in 0..<4096 {
            var carry: UInt32 = 0
            for i in 0..<65 { let v = r[i]; r[i] = v << 1 | carry; carry = v >> 31 }
            if !less(r, n65) { subtract(&r, n65) }
        }
        var out = Adb.le(64) + Adb.le(n0inv)
        for w in n { out += Adb.le(w) }
        for i in 0..<64 { out += Adb.le(r[i]) }
        return out + Adb.le(exponent)
    }
    private static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }
    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = (d >> 63) & 1
        }
    }
}

/// Guards a continuation several connection callbacks may try to finish; touched only on the connection's queue.
private final class AdbOnce: @unchecked Sendable { var done = false }

/// One ADB connection. Use it from one task at a time: calls are serialized and a second concurrent call throws.
public actor AdbClient {
    public struct ShellResult { public let output: String; public let status: Int }
    public enum State { case connecting, waitingForApproval, connected, closed }

    private let host: String, port: UInt16, key: AdbKey
    private let queue = DispatchQueue(label: "tvremote.adb")
    private var connection: NWConnection?
    private var decoder = Adb.Decoder()
    private var inbox: [Adb.Message] = []
    private var waiter: CheckedContinuation<Adb.Message, Error>?
    private var waiterTimeout: Task<Void, Never>?
    private var waiterToken = 0
    private var failure: Error?
    private var nextLocalID: UInt32 = 1
    private var busy = false
    private var remoteMaxData = Int(Adb.maxData)
    public private(set) var state: State = .closed
    public private(set) var properties: [String: String] = [:]
    /// Optional step-by-step trace of the connection, for diagnostics.
    private var log: (@Sendable (String) -> Void)?
    public func setLog(_ log: (@Sendable (String) -> Void)?) { self.log = log }

    public init(host: String, port: UInt16 = 5555, key: AdbKey) { self.host = host; self.port = port; self.key = key }

    // MARK: transport

    private func received(_ data: Data) {
        do { for m in try decoder.append(data) { deliver(m) } } catch { fail(error) }
    }
    private func deliver(_ m: Adb.Message) {
        if let waiting = waiter { waiter = nil; waiterTimeout?.cancel(); waiting.resume(returning: m) } else { inbox.append(m) }
    }
    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error; state = .closed
        connection?.cancel(); connection = nil
        if let waiting = waiter { waiter = nil; waiterTimeout?.cancel(); waiting.resume(throwing: error) }
    }
    private func next(timeout seconds: Double) async throws -> Adb.Message {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if let failure { throw failure }
        waiterToken += 1
        let token = waiterToken
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            waiterTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.timedOut(token)
            }
        }
    }
    private func timedOut(_ token: Int) {
        guard token == waiterToken, let waiting = waiter else { return }
        waiter = nil
        waiting.resume(throwing: RemoteFailure.message(String(localized: "The TV stopped answering")))
    }
    private func send(_ m: Adb.Message) {
        connection?.send(content: Adb.encode(m), completion: .contentProcessed { [weak self] error in
            if let error { Task { await self?.fail(error) } }
        })
    }
    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, complete, error in
            Task {
                guard let self else { return }
                if let data, !data.isEmpty { await self.received(data) }
                if let error { await self.fail(error); return }
                if complete { await self.fail(RemoteFailure.message(String(localized: "The TV closed the debugging connection"))); return }
                await self.receiveLoop()
            }
        }
    }

    // MARK: connect and authorize

    /// Connects and authorizes. If the TV doesn't know this iPhone yet, `approval` is called while the TV shows
    /// "Allow USB debugging?", and the call waits up to `approvalTimeout` for the user to accept it.
    public func connect(name: String = "debloated-tv@iPhone", approvalTimeout: Double = 90,
                        approval: @escaping @Sendable () -> Void = {}) async throws -> [String: String] {
        close()
        failure = nil; decoder = Adb.Decoder(); inbox = []; state = .connecting
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.connectionTimeout = 8
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 15
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
        connection = c
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            let once = AdbOnce()
            c.stateUpdateHandler = { state in
                let finish: (Error?) -> Void = { error in
                    guard !once.done else { return }; once.done = true
                    if let error { result.resume(throwing: error) } else { result.resume() }
                }
                switch state {
                case .ready: finish(nil)
                case .failed(let e), .waiting(let e):
                    finish(RemoteFailure.message(String(localized: "Couldn't reach the TV's debugging port \(Int(self.port)). Check that network debugging is on. (\(e.localizedDescription))")))
                case .cancelled: finish(RemoteFailure.message(String(localized: "Connection cancelled")))
                default: break
                }
            }
            c.start(queue: queue)
        }
        c.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state { Task { await self?.fail(e) } }
        }
        log?("TCP connected to \(host):\(port)")
        receiveLoop()
        send(Adb.Message(Adb.cnxn, Adb.version, Adb.maxData, Data("host::debloated-tv".utf8) + Data([0])))
        log?("sent CNXN")
        var signed = false, offered = false
        while true {
            let m = try await next(timeout: offered ? approvalTimeout : 10)
            log?("received \(String(decoding: Adb.le(m.command), as: UTF8.self)) arg0=\(m.arg0) arg1=\(m.arg1) \(m.payload.count) bytes")
            switch m.command {
            case Adb.cnxn:
                remoteMaxData = max(4096, min(Int(m.arg1), Int(Adb.maxData)))
                properties = Adb.bannerProperties(m.payload)
                state = .connected
                return properties
            case Adb.auth where m.arg0 == Adb.authToken:
                if !signed {
                    signed = true
                    send(Adb.Message(Adb.auth, Adb.authSignature, 0, try key.sign(token: m.payload)))
                } else if !offered {
                    offered = true; state = .waitingForApproval
                    send(Adb.Message(Adb.auth, Adb.authPublicKey, 0, try key.publicKeyLine(name: name)))
                    log?("signature not known to the TV; sent the public key, waiting for approval on the TV")
                    approval()
                } else {
                    throw RemoteFailure.message(String(localized: "The TV refused this iPhone. Accept \"Allow USB debugging?\" on the TV and try again."))
                }
            default: continue
            }
        }
    }

    public func close() {
        if let connection { connection.cancel() }
        connection = nil; state = .closed; failure = CancellationError()
        if let waiting = waiter { waiter = nil; waiterTimeout?.cancel(); waiting.resume(throwing: CancellationError()) }
    }

    // MARK: streams

    private func begin() throws {
        guard state == .connected else { throw RemoteFailure.message(String(localized: "Not connected to the TV")) }
        guard !busy else { throw RemoteFailure.message(String(localized: "Another TV command is still running")) }
        busy = true
    }

    private func openStream(_ service: String) async throws -> (local: UInt32, remote: UInt32) {
        let local = nextLocalID; nextLocalID &+= 1
        send(Adb.Message(Adb.open, local, 0, Data(service.utf8) + Data([0])))
        while true {
            let m = try await next(timeout: 15)
            if m.command == Adb.okay && m.arg1 == local { return (local, m.arg0) }
            if m.command == Adb.clse && m.arg1 == local { throw RemoteFailure.message(String(localized: "The TV refused \(String(service.split(separator: ":").first ?? "the request"))")) }
        }
    }

    /// Runs a shell command and returns its output and exit status.
    public func shell(_ command: String, timeout: Double = 60) async throws -> ShellResult {
        try begin(); defer { busy = false }
        let marker = "__DTV_EXIT__"
        let stream = try await openStream("shell:" + command + "; echo " + marker + "$?")
        var output = Data()
        var closed = false
        while !closed {
            let m = try await next(timeout: timeout)
            guard m.arg1 == stream.local else { continue }
            switch m.command {
            case Adb.wrte:
                output.append(m.payload)
                send(Adb.Message(Adb.okay, stream.local, stream.remote))
            case Adb.clse:
                closed = true
                send(Adb.Message(Adb.clse, stream.local, stream.remote))
            default: break
            }
        }
        var text = String(decoding: output, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var status = -1
        if let range = text.range(of: marker, options: .backwards) {
            status = Int(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            text = String(text[..<range.lowerBound])
        }
        return ShellResult(output: text, status: status)
    }

    /// Sends a file with the sync service ("adb push"). Each WRTE waits for the TV's OKAY before the next one.
    public func push(_ data: Data, to path: String, mode: UInt32 = 0o644, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try begin(); defer { busy = false }
        let stream = try await openStream("sync:")
        func write(_ payload: Data) async throws {
            send(Adb.Message(Adb.wrte, stream.local, stream.remote, payload))
            while true {
                let m = try await next(timeout: 30)
                guard m.arg1 == stream.local else { continue }
                if m.command == Adb.okay { return }
                if m.command == Adb.clse { throw RemoteFailure.message(String(localized: "The TV closed the file transfer")) }
                if m.command == Adb.wrte {   // an early FAIL
                    send(Adb.Message(Adb.okay, stream.local, stream.remote))
                    throw RemoteFailure.message(String(localized: "The TV refused the file: ") + Self.syncFailure(m.payload))
                }
            }
        }
        func packet(_ id: String, _ value: UInt32, _ body: Data = Data()) -> Data { Data(id.utf8) + Adb.le(value) + body }
        let header = Data("\(path),\(mode | 0o100000)".utf8)
        try await write(packet("SEND", UInt32(header.count), header))
        let chunk = min(64 * 1024, remoteMaxData - 8)
        var offset = 0
        while offset < data.count {
            let piece = data.subdata(in: offset..<min(data.count, offset + chunk))
            try await write(packet("DATA", UInt32(piece.count), piece))
            offset += piece.count
            progress?(Double(offset) / Double(max(1, data.count)))
        }
        try await write(packet("DONE", UInt32(Date().timeIntervalSince1970)))
        var reply = Data()
        while reply.count < 8 {
            let m = try await next(timeout: 30)
            guard m.arg1 == stream.local else { continue }
            if m.command == Adb.wrte { reply.append(m.payload); send(Adb.Message(Adb.okay, stream.local, stream.remote)) }
            if m.command == Adb.clse { break }
        }
        send(Adb.Message(Adb.clse, stream.local, stream.remote))
        guard reply.count >= 8, String(decoding: reply.prefix(4), as: UTF8.self) == "OKAY" else {
            throw RemoteFailure.message(String(localized: "The TV refused the file: ") + Self.syncFailure(reply))
        }
    }

    static func syncFailure(_ reply: Data) -> String {
        guard reply.count >= 8, String(decoding: reply.prefix(4), as: UTF8.self) == "FAIL" else { return "unexpected reply" }
        return String(decoding: reply.dropFirst(8), as: UTF8.self)
    }
}
