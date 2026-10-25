import Foundation
import Security
import CryptoKit

public struct TVPlayback: Decodable, Equatable {
    public let access: Bool
    public let kind: String
    public let packageName: String
    public let source: String
    public let title: String
    public let playback: String
    public let input: String
    enum CodingKeys: String, CodingKey { case access, kind, source, title, playback, input; case packageName = "package" }
    public var mediaTitle: String? { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title }
    public static func decode(_ data: Data) throws -> TVPlayback {
        let state = try JSONDecoder().decode(TVPlayback.self, from: data)
        guard ["app", "hdmi", "input", "home", "none"].contains(state.kind),
              ["playing", "paused", "buffering", "unknown"].contains(state.playback),
              state.packageName.count <= 180, state.source.count <= 512, state.title.count <= 512, state.input.count <= 512 else {
            throw RemoteFailure.message("Invalid playback information")
        }
        return state
    }
}

/// Independent, mutually authenticated read-only metadata connection. No control commands use this channel.
public final class PlaybackSession {
    public enum Event { case code, paired(Data), state(TVPlayback), error(String) }
    public var event: ((Event) -> Void)?
    private let host: String
    private let identity: ClientIdentity
    private var channel: TVConnection?
    private var generation = 0
    private var pairing = false
    private var tlsReady = false
    private var timer: DispatchSourceTimer?
    private var foreground = ""
    private var visible = false
    public init(host: String, identity: ClientIdentity) { self.host = host; self.identity = identity }
    public func connect(pin: Data) { open(pin: pin, pairing: false) }
    public func pair() { open(pin: nil, pairing: true) }
    public func disconnect() { generation += 1; timer?.cancel(); timer = nil; channel?.close(); channel = nil; tlsReady = false }
    public func watch(package: String, visible: Bool) {
        foreground = package; self.visible = visible
        if tlsReady && !pairing { send(["type":"watch", "package":package, "visible":visible]) }
    }
    public func submit(_ code: String) {
        guard pairing, let certificate = channel?.peerCertificate, let key = SecCertificateCopyKey(certificate) else { return }
        do { send(["type":"proof", "proof":try ClientIdentity.secret(code: code, client: identity.publicKey, server: key).base64EncodedString()]) }
        catch { event?(.error(error.localizedDescription)) }
    }
    private func send(_ value: [String:Any]) { if let data = try? JSONSerialization.data(withJSONObject: value) { channel?.send(data) } }
    private func open(pin: Data?, pairing: Bool) {
        disconnect(); self.pairing = pairing
        let token = generation
        let connection = TVConnection(host: host, port: 9765, identity: identity, pin: pin, allowUnpaired: pairing)
        channel = connection
        connection.ready = { [weak self] in DispatchQueue.main.async {
            guard let self, token == self.generation else { return }
            self.tlsReady = true
            self.send(pairing ? ["type":"pair"] : ["type":"watch", "package":self.foreground, "visible":self.visible])
            guard !pairing else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 20, repeating: 20)
            timer.setEventHandler { [weak self] in self?.send(["type":"ping"]) }
            self.timer = timer; timer.resume()
        } }
        connection.frame = { [weak self] data in DispatchQueue.main.async {
            guard let self, token == self.generation else { return }
            do {
                let object = try JSONSerialization.jsonObject(with: data) as? [String:Any]
                switch object?["type"] as? String {
                case "code": self.event?(.code)
                case "paired":
                    guard self.pairing, let cert = self.channel?.peerCertificate else { return }
                    let fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(cert) as Data))
                    self.disconnect(); self.event?(.paired(fingerprint))
                case "state": self.event?(.state(try TVPlayback.decode(data)))
                case "error": self.event?(.error(object?["message"] as? String ?? "Playback information unavailable"))
                case "pong": break
                default: throw RemoteFailure.message("Unknown playback response")
                }
            } catch { self.disconnect(); self.event?(.error(error.localizedDescription)) }
        } }
        connection.failed = { [weak self] reason in DispatchQueue.main.async {
            guard let self, token == self.generation else { return }
            self.disconnect(); self.event?(.error(reason))
        } }
        connection.start()
    }
}
