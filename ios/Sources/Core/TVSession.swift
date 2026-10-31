import Foundation
import Security
import CryptoKit

public final class TVSession {
    public static func appName(for package: String) -> String? {
        ["com.google.android.youtube.tv":"YouTube", "com.netflix.ninja":"Netflix", "com.amazon.amazonvideo.livingroom":"Prime Video", "com.disney.disneyplus":"Disney+", "com.wbd.stream":"HBO Max", "com.hbo.hbonow":"HBO Max", "com.crunchyroll.crunchyroid":"Crunchyroll", "com.spotify.tv.android":"Spotify"][package]
    }
    static func foregroundPackage(in body: Data) throws -> String? {
        guard let info = try Wire.fields(body).first(where: { $0.number == 1 })?.bytes,
              let package = try Wire.fields(info).first(where: { $0.number == 12 })?.bytes,
              let value = String(data: package, encoding: .utf8), value.count <= 180 else { return nil }
        return value
    }
    public enum Event {
        case pairingCodeNeeded
        case paired(Data)
        case connected
        case power(Bool)
        case foreground(String)
        case volume(Int, Int, Bool)
        case error(String)
    }
    public var event: ((Event) -> Void)?
    /// When the TV last sent anything (it pings every few seconds). Lets the app spot a socket that died while the
    /// phone slept but has not reported it yet.
    public private(set) var lastInbound = Date.distantPast
    private let host: String
    private let identity: ClientIdentity
    private var channel: TVConnection?
    private var pairMode = false
    private var waitingCode = false
    private var secretSent = false
    private var negotiated: UInt64 = 615 // ping, keys, IME app identity, power, volume, app links
    private var imeCounter: UInt64 = 0
    private var fieldCounter: UInt64 = 0
    private var currentGeneration = 0

    public init(host: String, identity: ClientIdentity) { self.host = host; self.identity = identity }

    /// Call session methods from the main queue; transport callbacks are handed back to it.
    public func pair() { open(port: 6467, pin: nil, pairing: true) }
    public func connect(pin: Data) { open(port: 6466, pin: pin, pairing: false) }
    public func disconnect() {
        currentGeneration += 1
        channel?.close(); channel = nil
        waitingCode = false; secretSent = false; commandReady = false
    }
    private func open(port: UInt16, pin: Data?, pairing: Bool) {
        disconnect()
        pairMode = pairing
        let token = currentGeneration
        let connection = TVConnection(host: host, port: port, identity: identity, pin: pin, allowUnpaired: pairing)
        channel = connection
        connection.ready = { [weak self] in DispatchQueue.main.async {
            guard let self, token == self.currentGeneration else { return }
            if pairing {
                self.sendPair(10, Wire.string(1, "atvremote") + Wire.string(2, "Personal iPhone Remote"))
            }
        } }
        connection.frame = { [weak self] frame in DispatchQueue.main.async {
            guard let self, token == self.currentGeneration else { return }
            self.lastInbound = Date()
            do { try self.receive(frame) } catch { self.event?(.error(error.localizedDescription)); self.disconnect() }
        } }
        connection.failed = { [weak self] reason in DispatchQueue.main.async {
            guard let self, token == self.currentGeneration else { return }
            self.disconnect(); self.event?(.error(reason))
        } }
        connection.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + (pairing ? 90 : 15)) { [weak self] in
            guard let self, token == self.currentGeneration else { return }
            if self.pairMode || !self.commandReady {
                self.disconnect(); self.event?(.error(pairing ? "Pairing expired. Start pairing again." : "The TV did not complete the remote handshake."))
            }
        }
    }

    public func submit(code: String) {
        guard pairMode && waitingCode, let certificate = channel?.peerCertificate,
              let server = SecCertificateCopyKey(certificate) else { event?(.error("Start pairing before entering the TV code")); return }
        do {
            let secret = try ClientIdentity.secret(code: code, client: identity.publicKey, server: server)
            secretSent = true
            sendPair(40, Wire.bytes(1, secret))
        } catch { event?(.error(error.localizedDescription)) }
    }

    private var commandReady = false
    public func key(_ key: TVKey, direction: UInt64 = 3) {
        guard commandReady && !pairMode else { return }
        channel?.send(Wire.bytes(10, Wire.int(1, key.rawValue) + Wire.int(2, direction)))
    }
    public func launch(_ url: String) {
        guard commandReady && !pairMode, !url.isEmpty else { return }
        channel?.send(Wire.bytes(90, Wire.string(1, url)))
    }
    public func writeKey(_ key: TVKey) async throws {
        guard commandReady, !pairMode, let channel else { throw RemoteFailure.message("TV is not ready") }
        try await channel.write(Wire.bytes(10, Wire.int(1, key.rawValue) + Wire.int(2, 3)))
    }
    public func writeLaunch(_ url: String) async throws {
        guard commandReady, !pairMode, let channel, !url.isEmpty, url.utf8.count <= 2048 else { throw RemoteFailure.message("Invalid app or input link") }
        try await channel.write(Wire.bytes(90, Wire.string(1, url)))
    }
    static func textMessage(_ text: String, imeCounter: UInt64, fieldCounter: UInt64) throws -> Data {
        guard !text.isEmpty, text.utf16.count <= 4096 else { throw RemoteFailure.message("Enter between 1 and 4096 characters") }
        let end = UInt64(text.utf16.count - 1)
        let object = Wire.int(1, end) + Wire.int(2, end) + Wire.string(3, text)
        let edit = Wire.int(1, 1) + Wire.bytes(2, object)
        return Wire.bytes(21, Wire.int(1, imeCounter) + Wire.int(2, fieldCounter) + Wire.bytes(3, edit))
    }
    public func writeText(_ text: String) async throws {
        guard commandReady, !pairMode, negotiated & 4 != 0, let channel else { throw RemoteFailure.message("The TV does not accept keyboard input") }
        try await channel.write(Self.textMessage(text, imeCounter: imeCounter, fieldCounter: fieldCounter))
    }
    private func sendPair(_ field: Int, _ body: Data) {
        channel?.send(Wire.int(1, 2) + Wire.int(2, 200) + Wire.bytes(field, body))
    }
    private func receive(_ payload: Data) throws {
        let fields = try Wire.fields(payload)
        if pairMode {
            guard fields.first(where: { $0.number == 2 })?.integer == 200 else {
                throw RemoteFailure.message("The TV rejected pairing. Start again and enter the current TV code.")
            }
            if fields.contains(where: { $0.number == 11 }) {
                sendPair(20, Wire.bytes(1, Wire.int(1, 3) + Wire.int(2, 6)) + Wire.int(3, 1))
            } else if fields.contains(where: { $0.number == 20 }) {
                sendPair(30, Wire.bytes(1, Wire.int(1, 3) + Wire.int(2, 6)) + Wire.int(2, 1))
            } else if fields.contains(where: { $0.number == 31 }) {
                waitingCode = true; event?(.pairingCodeNeeded)
            } else if fields.contains(where: { $0.number == 41 }) && secretSent {
                guard let certificate = channel?.peerCertificate else { throw RemoteFailure.message("Missing TV certificate") }
                let pin = Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
                disconnect(); event?(.paired(pin))
            }
            return
        }
        for field in fields {
            guard let body = field.bytes else { continue }
            switch field.number {
            case 1:
                negotiated = try Wire.number(1, in: body) & 615
                guard negotiated & 2 != 0 else { throw RemoteFailure.message("This TV does not support remote key commands") }
                let info = Wire.string(1, "iPhone") + Wire.string(2, "Personal") + Wire.int(3, 1)
                    + Wire.string(4, "1") + Wire.string(5, "com.guilhermeramalho.TVRemote") + Wire.string(6, "1.0")
                channel?.send(Wire.bytes(1, Wire.int(1, negotiated) + Wire.bytes(2, info)))
            case 2: channel?.send(Wire.bytes(2, Wire.int(1, negotiated)))
            case 8: channel?.send(Wire.bytes(9, Wire.int(1, try Wire.number(1, in: body))))
            case 40:
                if !commandReady {
                    commandReady = true
                    event?(.connected)
                }
                event?(.power(try Wire.number(1, in: body) != 0))
            case 20:
                if let value = try Self.foregroundPackage(in: body) { event?(.foreground(value)) }
            case 21:
                imeCounter = try Wire.number(1, in: body)
                fieldCounter = try Wire.number(2, in: body)
            case 50:
                event?(.volume(Int(try Wire.number(7, in: body)), Int(try Wire.number(6, in: body)), try Wire.number(8, in: body) != 0))
            case 3: throw RemoteFailure.message("The TV rejected a remote command")
            default: break
            }
        }
    }
}
