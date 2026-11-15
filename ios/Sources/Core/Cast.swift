import Foundation
import Network

// Show on TV: a minimal Google Cast v2 sender, no SDK. The TV's built-in Cast player (the Default Media Receiver)
// plays what the phone serves (MediaServer.swift). Frames are a 4-byte big-endian length and a protobuf
// CastMessage carrying a JSON payload, over TLS on port 8009. Proven on the TCL on 15 Nov 2026 (docs/cast.md).

public enum CastNamespace {
    public static let connection = "urn:x-cast:com.google.cast.tp.connection"
    public static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    public static let receiver = "urn:x-cast:com.google.cast.receiver"
    public static let media = "urn:x-cast:com.google.cast.media"
}

/// One CastMessage (cast_channel.proto): protocol version 0, string payload.
public struct CastMessage: Equatable {
    public var source: String
    public var destination: String
    public var namespace: String
    public var payload: String

    public init(source: String, destination: String, namespace: String, payload: String) {
        self.source = source; self.destination = destination; self.namespace = namespace; self.payload = payload
    }
    public init(source: String, destination: String, namespace: String, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        self.init(source: source, destination: destination, namespace: namespace, payload: String(decoding: data, as: UTF8.self))
    }

    /// The protobuf body, without the length prefix.
    public var body: Data {
        Wire.int(1, 0) + Wire.string(2, source) + Wire.string(3, destination) + Wire.string(4, namespace)
            + Wire.int(5, 0) + Wire.string(6, payload)
    }
    /// What goes on the wire: the body behind its 4-byte big-endian length.
    public var framed: Data {
        let body = body
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }
    public static func decode(_ body: Data) throws -> CastMessage {
        var source = "", destination = "", namespace = "", payload = ""
        for field in try Wire.fields(body) {
            switch field.number {
            case 2: source = String(decoding: field.bytes ?? Data(), as: UTF8.self)
            case 3: destination = String(decoding: field.bytes ?? Data(), as: UTF8.self)
            case 4: namespace = String(decoding: field.bytes ?? Data(), as: UTF8.self)
            case 6: payload = String(decoding: field.bytes ?? Data(), as: UTF8.self)
            default: break
            }
        }
        return CastMessage(source: source, destination: destination, namespace: namespace, payload: payload)
    }
    public var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
    }
    public var type: String { json["type"] as? String ?? "" }
}

/// Splits the incoming byte stream into CastMessage bodies.
public struct CastFrameDecoder {
    private var buffer = Data()
    private let maxFrameSize: Int
    public init(maxFrameSize: Int = 65536) { self.maxFrameSize = maxFrameSize }
    public mutating func append(_ incoming: Data) throws -> [Data] {
        buffer.append(incoming)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let header = [UInt8](buffer.prefix(4))
            let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard length <= maxFrameSize else { throw RemoteFailure.message("Cast frame too large") }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}

public struct CastMediaStatus: Equatable {
    /// IDLE, BUFFERING, PLAYING or PAUSED.
    public var playerState: String
    public var currentTime: Double
    public var duration: Double?
    /// FINISHED, ERROR, INTERRUPTED or CANCELLED when idle.
    public var idleReason: String?
    public var playing: Bool { playerState == "PLAYING" || playerState == "BUFFERING" }
}

/// The sender's side of one Cast session, as a pure state machine: it takes commands and the TV's messages and
/// returns what to send and what happened. No sockets, so every step is unit-tested (CastTests).
public struct CastController {
    public enum State: Equatable { case idle, launching, ready, stopped, failed(String) }
    public enum Event: Equatable {
        case ready
        case media(CastMediaStatus)
        case loadFailed
        /// The player went away on the TV (another app, the Home key, or Stop): the next load launches it again.
        case receiverGone
        case failed(String)
    }
    public struct Load: Equatable {
        public var url: String, contentType: String, title: String
        public init(url: String, contentType: String, title: String) { self.url = url; self.contentType = contentType; self.title = title }
    }
    public static let mediaReceiver = "CC1AD845"
    public let sender: String
    public private(set) var state: State = .idle
    public private(set) var transport: String?
    public private(set) var session: String?
    public private(set) var mediaSession: Int?
    public private(set) var pending: Load?
    private var requestId = 0

    public init(sender: String = "sender-purio") { self.sender = sender }

    public mutating func start() -> [CastMessage] {
        state = .launching
        return [message("receiver-0", CastNamespace.connection, ["type": "CONNECT"]),
                request("receiver-0", CastNamespace.receiver, ["type": "LAUNCH", "appId": Self.mediaReceiver])]
    }

    /// Shows a photo or starts a video. Before the player is up the newest load waits and goes out when it is.
    public mutating func load(_ item: Load) -> [CastMessage] {
        switch state {
        case .ready:
            pending = nil
            return [loadMessage(item)]
        case .launching:
            pending = item
            return []
        case .idle, .stopped, .failed:
            pending = item
            return start()
        }
    }
    public mutating func play() -> [CastMessage] { mediaCommand(["type": "PLAY"]) }
    public mutating func pause() -> [CastMessage] { mediaCommand(["type": "PAUSE"]) }
    public mutating func seek(to seconds: Double) -> [CastMessage] { mediaCommand(["type": "SEEK", "currentTime": max(0, seconds)]) }
    public mutating func heartbeat() -> [CastMessage] { [message("receiver-0", CastNamespace.heartbeat, ["type": "PING"])] }

    /// Closes the player on the TV (it returns to Home) and ends the session.
    public mutating func stop() -> [CastMessage] {
        defer { state = .stopped; transport = nil; session = nil; mediaSession = nil; pending = nil }
        guard let session else { return [] }
        var out = [request("receiver-0", CastNamespace.receiver, ["type": "STOP", "sessionId": session])]
        if let transport { out.append(message(transport, CastNamespace.connection, ["type": "CLOSE"])) }
        return out
    }

    public mutating func receive(_ incoming: CastMessage) -> (send: [CastMessage], events: [Event]) {
        let json = incoming.json
        let type = json["type"] as? String ?? ""
        switch (incoming.namespace, type) {
        case (CastNamespace.heartbeat, "PING"):
            return ([message(incoming.source, CastNamespace.heartbeat, ["type": "PONG"])], [])
        case (CastNamespace.receiver, "RECEIVER_STATUS"):
            return receiverStatus(json)
        case (CastNamespace.receiver, "LAUNCH_ERROR"):
            let reason = String(localized: "The TV couldn't start its player. Try again.")
            state = .failed(reason)
            return ([], [.failed(reason)])
        case (CastNamespace.media, "MEDIA_STATUS"):
            guard let status = (json["status"] as? [[String: Any]])?.first else { return ([], []) }
            if let id = status["mediaSessionId"] as? Int { mediaSession = id }
            let media = status["media"] as? [String: Any]
            return ([], [.media(CastMediaStatus(playerState: status["playerState"] as? String ?? "IDLE",
                                                currentTime: (status["currentTime"] as? NSNumber)?.doubleValue ?? 0,
                                                duration: (media?["duration"] as? NSNumber)?.doubleValue,
                                                idleReason: status["idleReason"] as? String))])
        case (CastNamespace.media, "LOAD_FAILED"), (CastNamespace.media, "LOAD_CANCELLED"), (CastNamespace.media, "INVALID_REQUEST"):
            return ([], [.loadFailed])
        case (CastNamespace.connection, "CLOSE") where incoming.source == transport:
            return playerGone()
        default:
            return ([], [])
        }
    }

    private mutating func receiverStatus(_ json: [String: Any]) -> (send: [CastMessage], events: [Event]) {
        let apps = (json["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
        let player = apps.first { $0["appId"] as? String == Self.mediaReceiver }
        guard let player, let newTransport = player["transportId"] as? String, let newSession = player["sessionId"] as? String else {
            return state == .ready ? playerGone() : ([], [])
        }
        guard state == .launching || newTransport != transport else { return ([], []) }
        state = .ready; transport = newTransport; session = newSession; mediaSession = nil
        var out = [message(newTransport, CastNamespace.connection, ["type": "CONNECT"])]
        if let pending { out.append(loadMessage(pending)); self.pending = nil }
        return (out, [.ready])
    }
    private mutating func playerGone() -> (send: [CastMessage], events: [Event]) {
        guard state == .ready else { return ([], []) }
        state = .idle; transport = nil; session = nil; mediaSession = nil
        return ([], [.receiverGone])
    }
    private mutating func loadMessage(_ item: Load) -> CastMessage {
        mediaSession = nil
        return request(transport ?? "", CastNamespace.media, [
            "type": "LOAD", "sessionId": session ?? "", "autoplay": true, "currentTime": 0,
            "media": ["contentId": item.url, "contentType": item.contentType, "streamType": "BUFFERED",
                      "metadata": ["metadataType": 0, "title": item.title]]])
    }
    private mutating func mediaCommand(_ json: [String: Any]) -> [CastMessage] {
        guard state == .ready, let transport, let mediaSession else { return [] }
        var json = json; json["mediaSessionId"] = mediaSession
        return [request(transport, CastNamespace.media, json)]
    }
    private mutating func request(_ destination: String, _ namespace: String, _ json: [String: Any]) -> CastMessage {
        requestId += 1
        var json = json; json["requestId"] = requestId
        return message(destination, namespace, json)
    }
    private func message(_ destination: String, _ namespace: String, _ json: [String: Any]) -> CastMessage {
        CastMessage(source: sender, destination: destination, namespace: namespace, json: json)
    }
}

/// Decides which photo goes to the TV while you swipe: only one you stop on for `settle` seconds, and never the
/// same one twice in a row. A fast swipe through twenty photos sends one (CST-03).
public struct CastFollower {
    public let settle: TimeInterval
    public private(set) var shown: String?
    private var focus: (id: String, at: Date)?
    public init(settle: TimeInterval = 0.35) { self.settle = settle }
    public mutating func focused(_ id: String, now: Date = Date()) { focus = (id, now) }
    /// The item to send now, if the focus has settled on a new one.
    public mutating func due(now: Date = Date()) -> String? {
        guard let focus, now.timeIntervalSince(focus.at) >= settle - 0.001, focus.id != shown else { return nil }
        shown = focus.id
        return focus.id
    }
    /// The TV dropped what it showed (player closed): the focused item goes out again.
    public mutating func forget() { shown = nil }
}

/// A Cast session with the TV: the controller above over a TLS connection, with the heartbeat Cast requires every
/// 5 seconds. Runs only while Show on TV is open; close() ends everything. Callbacks arrive on the main queue.
public final class CastSession {
    public var event: ((CastController.Event) -> Void)?
    private let queue = DispatchQueue(label: "tvremote.cast", qos: .userInitiated)
    private var controller = CastController()
    private var connection: NWConnection?
    private var decoder = CastFrameDecoder()
    private var heartbeat: DispatchSourceTimer?
    private var connected = false
    private var outbox: [CastMessage] = []
    private let host: String

    public init(host: String) { self.host = host }

    public func load(_ item: CastController.Load) { run { $0.load(item) } }
    public func play() { run { $0.play() } }
    public func pause() { run { $0.pause() } }
    public func seek(to seconds: Double) { run { $0.seek(to: seconds) } }

    /// Closes the TV's player and the connection.
    public func stop() {
        queue.async { [self] in
            let out = controller.stop()
            guard let connection, connected else { finish(); return }
            for message in out { connection.send(content: message.framed, completion: .idempotent) }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.finish() }
            })
        }
    }

    private func run(_ step: @escaping (inout CastController) -> [CastMessage]) {
        queue.async { [self] in
            let out = step(&controller)
            if connection == nil { open() }
            send(out)
        }
    }
    private func send(_ messages: [CastMessage]) {
        guard connected, let connection else { outbox += messages; return }
        for message in messages {
            connection.send(content: message.framed, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.queue.async { self?.fail(String(localized: "The connection to the TV was interrupted.")) } }
            })
        }
    }
    private func open() {
        // Cast devices present a self-signed certificate that changes over time, and senders aren't asked for one;
        // the session carries only commands and links to this phone's own server, so the TLS is for privacy.
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true; tcp.connectionTimeout = 8
        let c = NWConnection(host: NWEndpoint.Host(host), port: 8009, using: NWParameters(tls: tls, tcp: tcp))
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connected = true
                let waiting = self.outbox; self.outbox = []
                self.send(waiting)
                self.receive()
                self.startHeartbeat()
            case .failed(let error), .waiting(let error):
                self.fail(Self.reason(for: error))
            default: break
            }
        }
        c.start(queue: queue)
    }
    /// A refused connection means nothing listens for Cast on the TV; anything else means the TV wasn't reached.
    static func reason(for error: NWError) -> String {
        if case .posix(let code) = error, code == .ECONNREFUSED {
            return String(localized: "This TV can't show photos from Purio. It needs Chromecast built in (most Google TV and Android TV sets have it).")
        }
        return String(localized: "Couldn't reach the TV. Check that it's on and on the same Wi-Fi as this iPhone.")
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, self.connection != nil else { return }
            if let data, !data.isEmpty {
                do {
                    for body in try self.decoder.append(data) {
                        let (out, events) = self.controller.receive(try CastMessage.decode(body))
                        self.send(out)
                        for event in events { self.deliver(event) }
                    }
                } catch { self.fail(String(localized: "The TV sent something unexpected. Try again.")); return }
            }
            if error != nil || complete { self.deliver(.receiverGone); self.finish(); return }
            self.receive()
        }
    }
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in guard let self else { return }; self.send(self.controller.heartbeat()) }
        timer.resume()
        heartbeat = timer
    }
    private func deliver(_ event: CastController.Event) {
        let callback = event
        DispatchQueue.main.async { [weak self] in self?.event?(callback) }
    }
    private func fail(_ reason: String) {
        guard connection != nil else { return }
        deliver(.failed(reason))
        finish()
    }
    private func finish() {
        heartbeat?.cancel(); heartbeat = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        connected = false; outbox = []; decoder = CastFrameDecoder()
        controller = CastController()
    }
}
