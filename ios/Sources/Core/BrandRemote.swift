import Foundation
import Network

/// The remote for a TV that isn't an Android TV: Roku (ECP), LG (webOS SSAP) and Samsung (Tizen). The app drives
/// it the way it drives TVSession: connect, keys, apps, typing, and events back on the main queue. Each brand's
/// details are in its own file; docs/tv-brands.md has the protocols and where they come from.
public enum BrandEvent: Equatable {
    /// The TV shows a prompt asking to allow this phone: press Allow / Accept with the TV's own remote.
    case approvalNeeded
    /// Allowed. Keep `credential` (the Keychain): next time no prompt.
    case approved(Data)
    case connected
    case power(Bool)
    /// The app on screen, by its name on the TV.
    case foreground(String)
    case volume(Int, Int, Bool)
    case error(String)
}

/// An app on the TV, as the TV lists it.
public struct BrandApp: Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Call from the main queue; events come back on it.
public protocol BrandRemote: AnyObject {
    var kind: TVKind { get }
    var event: ((BrandEvent) -> Void)? { get set }
    /// Opens the connection. With no credential the TV asks to allow this phone (not Roku).
    func connect(credential: Data?)
    func disconnect()
    /// direction: 1 pressed, 2 released, 3 tap (as TVSession).
    func key(_ key: TVKey, direction: UInt64)
    /// Whether this TV has a button for the key at all (the remote hides the ones it doesn't).
    func supports(_ key: TVKey) -> Bool
    func writeKey(_ key: TVKey) async throws
    /// The apps installed on the TV (read once per connection and kept).
    func apps() async throws -> [BrandApp]
    func launch(_ app: BrandApp) async throws
    /// The field on the TV becomes `text` (the whole value, as typed so far).
    func writeText(_ text: String) async throws
    /// A cheap round trip: true if the TV answers now.
    func alive() async -> Bool
}

extension BrandRemote {
    /// Opens the TV's app with this name (the remote's app buttons, quick actions). False when it isn't on the TV.
    @discardableResult public func launch(named name: String) async throws -> Bool {
        guard let app = BrandApps.match(name, in: try await apps()) else { return false }
        try await launch(app)
        return true
    }
}

public enum BrandRemotes {
    /// The remote for a Roku, LG or Samsung TV; nil for Android TVs (TVSession) and Chromecasts (no remote).
    public static func make(_ kind: TVKind, host: String) -> BrandRemote? {
        switch kind {
        case .roku: RokuRemote(host: host)
        case .lg: LGRemote(host: host)
        case .samsung: SamsungRemote(host: host)
        case .androidTV, .chromecast: nil
        }
    }
}

extension TVKind {
    /// Whether this kind of TV has a button for the key (the remote hides the ones it doesn't).
    public func supports(_ key: TVKey) -> Bool {
        switch self {
        case .roku: RokuRemote.keyName(key) != nil
        case .samsung: key == .playPause || SamsungRemote.code(key) != nil
        case .androidTV, .lg, .chromecast: true
        }
    }
}

public enum BrandApps {
    /// Names apps go by on different TVs ("Prime Video" is "Amazon Prime Video" on some, "Max" was "HBO Max").
    static let aliases: [String: [String]] = [
        "primevideo": ["amazonprimevideo", "amazonvideo", "primevideo", "amazon"],
        "hbomax": ["max", "hbomax", "hbo"],
        "disney": ["disney", "disneyplus"],
        "appletv": ["appletv", "appletvplus"],
        "youtube": ["youtube"],
    ]
    static func plain(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "+", with: "plus").filter { $0.isLetter || $0.isNumber }
    }
    /// The TV's app for a name: the same name first, then a known other name, then a name that starts with it
    /// ("YouTube" for "YouTube TV" only when there's no plain "YouTube").
    public static func match(_ name: String, in apps: [BrandApp]) -> BrandApp? {
        let wanted = plain(name)
        guard !wanted.isEmpty else { return nil }
        if let same = apps.first(where: { plain($0.name) == wanted }) { return same }
        let names = aliases.first { key, values in key == wanted || values.contains(wanted) }.map { [$0.key] + $0.value } ?? []
        if let alias = apps.first(where: { names.contains(plain($0.name)) }) { return alias }
        return apps.filter { plain($0.name).hasPrefix(wanted) }.min { $0.name.count < $1.name.count }
    }
}

/// Repeats a held key for TVs whose protocol has no press-and-hold (LG): once at once, then every 0.2 s.
final class KeyRepeater: @unchecked Sendable {
    private var timers: [TVKey: DispatchSourceTimer] = [:]
    func press(_ key: TVKey, tap: @escaping (TVKey) -> Void) {
        guard timers[key] == nil else { return }
        tap(key)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.45, repeating: 0.2)
        timer.setEventHandler { tap(key) }
        timer.resume()
        timers[key] = timer
    }
    func release(_ key: TVKey) { timers.removeValue(forKey: key)?.cancel() }
    func releaseAll() { timers.values.forEach { $0.cancel() }; timers = [:] }
}

/// A text WebSocket to a TV on the home network (LG and Samsung remotes), on Network's own WebSocket support.
/// With TLS it accepts the TV's self-signed certificate, as the Cast sender does: TVs have no certificate a phone
/// could check. Callbacks come on the main queue.
final class WebSocketLink: @unchecked Sendable {
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    /// The reason, or nil when closed on purpose.
    var onClose: ((String?) -> Void)?
    private(set) var lastInbound = Date.distantPast
    private let connection: NWConnection
    private var closed = false
    private var opened = false

    init(url: URL, timeout: Int = 6) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true; tcp.connectionTimeout = timeout
        var tls: NWProtocolTLS.Options?
        if url.scheme == "wss" {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in complete(true) }, .main)
            tls = options
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 8 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    func open() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.opened = true
                self.onOpen?()
                self.receive()
            case .failed(let error): self.fail(error.localizedDescription)
            case .waiting(let error) where !self.opened: self.fail(error.localizedDescription)
            default: break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ text: String) {
        guard !closed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error.localizedDescription) }
        })
    }
    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json), let text = String(data: data, encoding: .utf8) else { return }
        send(text)
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(reason)
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.closed else { return }
            if let error { self.fail(error.localizedDescription); return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { self.fail(String(localized: "The TV closed the remote connection.")); return }
            if let data, metadata?.opcode == .text || metadata == nil, let text = String(data: data, encoding: .utf8) {
                self.lastInbound = Date()
                self.onText?(text)
            } else if data != nil { self.lastInbound = Date() }
            self.receive()
        }
    }
}

/// JSON helpers for the brand protocols.
enum JSON {
    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
