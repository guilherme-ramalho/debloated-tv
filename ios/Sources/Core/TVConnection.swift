import Foundation
import Network
import Security
import CryptoKit

/// One framed, certificate-bound TLS connection. All callbacks run on its serial queue.
public final class TVConnection {
    public var ready: (() -> Void)?
    public var frame: ((Data) -> Void)?
    public var failed: ((String) -> Void)?
    public private(set) var peerCertificate: SecCertificate?
    private let queue = DispatchQueue(label: "tvremote.transport", qos: .userInitiated)
    private var connection: NWConnection?
    private var decoder: FrameDecoder
    private var closed = false
    private var tlsReady = false
    private var validationFailure: String?
    private let host: String
    private let port: UInt16
    private let identity: ClientIdentity
    private let pin: Data?
    private let allowUnpaired: Bool

    public init(host: String, port: UInt16, identity: ClientIdentity, pin: Data?, allowUnpaired: Bool = false, maxFrameSize: Int = 65536) {
        self.host = host; self.port = port; self.identity = identity
        self.pin = pin; self.allowUnpaired = allowUnpaired
        decoder = FrameDecoder(maxFrameSize: maxFrameSize)
    }

    public func start() {
        queue.async { [self] in
            guard connection == nil && !closed else { return }
            let tls = NWProtocolTLS.Options()
            guard let local = sec_identity_create(identity.identity) else { fail("Could not use pairing identity"); return }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
                guard let self else { complete(false); return }
                let trust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first else {
                    let reason = "Could not read the TV’s secure identity. Try connecting again."
                    self.validationFailure = reason
                    complete(false)
                    self.queue.async { self.fail(reason) }
                    return
                }
                let fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
                let accepted = self.pin.map { $0 == fingerprint } ?? self.allowUnpaired
                if accepted { self.peerCertificate = certificate }
                complete(accepted)
                if !accepted {
                    print("TVRemote: paired TV certificate mismatch")
                    let reason = "The TV’s saved pairing identity no longer matches. Open Connection settings and pair this TV again."
                    self.validationFailure = reason
                    self.queue.async { self.fail(reason) }
                }
            }, queue)
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = allowUnpaired ? 30 : 8
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
            let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                 using: NWParameters(tls: tls, tcp: tcp))
            connection = c
            c.stateUpdateHandler = { [weak self] state in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.tlsReady = true; self.ready?(); self.receive()
                case .waiting: break // Allow the Local Network permission dialog or a changing Wi-Fi path to settle.
                case .failed: self.fail(self.validationFailure ?? "Could not connect to the paired TV. Check Wi-Fi, TV power, and Local Network access.")
                case .cancelled: self.fail("Connection closed")
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + (allowUnpaired ? 35 : 10)) { [weak self] in
                guard let self, !self.closed, !self.tlsReady else { return }
                self.fail(self.validationFailure ?? "TV connection timed out")
            }
        }
    }

    public func send(_ payload: Data) {
        queue.async { [weak self] in
            guard let self, !self.closed, self.tlsReady else { return }
            let data = Wire.varint(UInt64(payload.count)) + payload
            self.connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.fail("TV connection was interrupted") }
            })
        }
    }

    public func write(_ payload: Data) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, !self.closed, self.tlsReady, let connection = self.connection else {
                    result.resume(throwing: RemoteFailure.message("TV connection is not ready")); return
                }
                connection.send(content: Wire.varint(UInt64(payload.count)) + payload, completion: .contentProcessed { error in
                    if let error { result.resume(throwing: error) } else { result.resume() }
                })
            }
        }
    }

    public func close() { queue.async { [weak self] in self?.finish() } }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do { for message in try self.decoder.append(data) { self.frame?(message) } }
                catch { self.fail("The TV sent an invalid remote-protocol message"); return }
            }
            if error != nil || complete { self.fail("TV connection closed"); return }
            self.receive()
        }
    }
    private func finish() {
        guard !closed else { return }
        closed = true
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        ready = nil; frame = nil; failed = nil
    }
    private func fail(_ reason: String) {
        guard !closed else { return }
        let callback = failed
        finish()
        callback?(reason)
    }
}
