import Foundation
import Network

/// What kind of TV a device on the network is, told by the ports it answers on (port knocking, as couch-tv does),
/// and what Purio can do on it. Mirrored in Android's TvKind.kt.
public enum TVKind: String, Sendable, Equatable, CaseIterable {
    case androidTV, roku, lg, samsung, chromecast

    /// The system's own name, shown as is in every language.
    public var label: String {
        switch self {
        case .androidTV: "Android TV"
        case .roku: "Roku"
        case .lg: "LG webOS"
        case .samsung: "Samsung"
        case .chromecast: "Chromecast"
        }
    }
}

/// What Purio can do on a TV of that kind today.
public enum TVSupport: Sendable, Equatable {
    /// Android TV / Google TV: remote, TV setup, and Show on TV when Chromecast built-in answers.
    case full(showOnTV: Bool)
    /// Roku, LG, Samsung: the remote comes next (no server needed); nothing yet.
    case remoteComing
    /// A Chromecast with no remote service: nothing yet.
    case notYet

    public var canPair: Bool { if case .full = self { true } else { false } }
}

public enum TVPorts {
    public static let androidRemote: UInt16 = 6466
    public static let cast: UInt16 = 8009
    public static let roku: UInt16 = 8060
    public static let lg: [UInt16] = [3000, 3001]
    public static let samsung: [UInt16] = [8001, 8002]
    /// Every port knocked on, each once per TV while the Connect screen is open. ADB (5555) is never knocked.
    public static let all: [UInt16] = [androidRemote, cast, roku] + lg + samsung

    /// The kind, from the ports that accepted a connection. The remote services win over Cast, which many TVs have too.
    public static func kind(open: Set<UInt16>) -> TVKind? {
        if open.contains(androidRemote) { return .androidTV }
        if open.contains(roku) { return .roku }
        if !open.isDisjoint(with: lg) { return .lg }
        if !open.isDisjoint(with: samsung) { return .samsung }
        if open.contains(cast) { return .chromecast }
        return nil
    }

    public static func support(_ kind: TVKind, open: Set<UInt16>) -> TVSupport {
        switch kind {
        case .androidTV: .full(showOnTV: open.contains(cast))
        case .roku, .lg, .samsung: .remoteComing
        case .chromecast: .notYet
        }
    }
}

/// One service announced on the network (Bonjour). The same TV often announces several; they're merged by address.
public struct TVSighting: Sendable, Equatable {
    public enum Service: String, Sendable, CaseIterable {
        case androidTV = "_androidtvremote2._tcp"
        case cast = "_googlecast._tcp"
        case airPlay = "_airplay._tcp"
    }
    public let service: Service
    /// The Bonjour service name.
    public let name: String
    public var host: String?
    /// Its TXT record, lowercased keys.
    public let txt: [String: String]

    public init(service: Service, name: String, host: String? = nil, txt: [String: String] = [:]) {
        self.service = service; self.name = name; self.host = host
        self.txt = Dictionary(txt.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    public var id: String { service.rawValue + "/" + name }

    /// Worth resolving and knocking on: Android TVs; Cast devices with video out that aren't groups (not speakers);
    /// AirPlay devices made by someone other than Apple (LG, Samsung, Roku and other TVs; speakers fail the knock).
    public var worthChecking: Bool {
        switch service {
        case .androidTV: return true
        case .cast:
            guard let ca = txt["ca"].flatMap({ Int($0) }) else { return false }
            return ca & 1 != 0 && ca & 32 == 0                                   // video out, not a group
        case .airPlay:
            guard let maker = txt["manufacturer"], !maker.isEmpty else { return false }   // Apple's own devices omit it
            return !maker.lowercased().contains("apple")
        }
    }

    /// The name people gave the device: Cast service names are IDs, its TXT `fn` is the name.
    public var displayName: String {
        if service == .cast, let fn = txt["fn"], !fn.isEmpty { return fn }
        return name
    }
}

/// A TV for the Connect screen.
public struct DiscoveredTV: Identifiable, Equatable, Sendable {
    public let id: String
    /// The TV's own name ("Living Room TV").
    public let name: String
    /// Its IPv4 address once resolved; nil while resolving.
    public var host: String?
    public let kind: TVKind
    /// nil while its ports are being checked.
    public var support: TVSupport?

    public init(id: String, name: String, host: String?, kind: TVKind = .androidTV, support: TVSupport? = nil) {
        self.id = id; self.name = name; self.host = host; self.kind = kind; self.support = support
    }
}

public enum TVSightings {
    /// The Connect list: every Android TV as soon as it's seen; other TVs once their ports say what they are.
    /// Services from one address become one row (the Android TV's name wins, then AirPlay's, then Cast's).
    public static func merge(_ sightings: [TVSighting], probes: [String: Set<UInt16>]) -> [DiscoveredTV] {
        var rows: [DiscoveredTV] = []
        let android = sightings.filter { $0.service == .androidTV }
        let androidHosts = Set(android.compactMap(\.host))
        for s in android {
            let support = s.host.flatMap { probes[$0] }.map { TVPorts.support(.androidTV, open: $0) }
            rows.append(DiscoveredTV(id: s.id, name: s.name, host: s.host, kind: .androidTV, support: support))
        }
        let others = sightings.filter { s in
            s.service != .androidTV && s.worthChecking && s.host.map { !androidHosts.contains($0) } == true
        }
        for (host, group) in Dictionary(grouping: others, by: { $0.host ?? "" }) {
            guard let open = probes[host], let kind = TVPorts.kind(open: open) else { continue }
            let named = group.first { $0.service == .airPlay } ?? group.min { $0.name < $1.name }!
            rows.append(DiscoveredTV(id: "host/" + host, name: named.displayName, host: host, kind: kind,
                                     support: TVPorts.support(kind, open: open)))
        }
        return rows.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

/// Opens a TCP connection to each port and closes it as soon as it's accepted: no data is sent, so nothing shows
/// on the TV. A closed port refuses at once on a home network; a silent one gives up after `timeout`.
public enum PortKnock {
    public static func openPorts(host: String, ports: [UInt16] = TVPorts.all, timeout: TimeInterval = 1.5) async -> Set<UInt16> {
        await withTaskGroup(of: UInt16?.self) { group in
            for port in ports { group.addTask { await isOpen(host: host, port: port, timeout: timeout) ? port : nil } }
            var open = Set<UInt16>()
            for await port in group { if let port { open.insert(port) } }
            return open
        }
    }

    public static func isOpen(host: String, port: UInt16, timeout: TimeInterval = 1.5) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        let once = Once()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                let finish: @Sendable (Bool) -> Void = { open in
                    guard once.claim() else { return }
                    connection.cancel()
                    done.resume(returning: open)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    case .failed, .waiting, .cancelled: finish(false)
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .utility))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(false) }
            }
        } onCancel: { connection.cancel() }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}
