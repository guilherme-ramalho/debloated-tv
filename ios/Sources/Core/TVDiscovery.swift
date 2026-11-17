import Foundation
import Combine
import Network

/// Finds TVs on the local network the way their own apps do, over Bonjour: Android TVs and Google TVs announce
/// `_androidtvremote2._tcp`; Chromecasts `_googlecast._tcp`; LG, Samsung, Roku and other TVs with AirPlay
/// `_airplay._tcp`. Each address is then knocked on (TVKind.swift) to tell what it is and what Purio can do there.
/// Runs only while a screen asks for it (start on appear, stop on disappear), so nothing searches in the background.
@MainActor public final class TVDiscovery: ObservableObject {
    public static let service = TVSighting.Service.androidTV.rawValue
    @Published public private(set) var tvs: [DiscoveredTV] = []
    @Published public private(set) var searching = false
    /// iOS refused Local Network access, so nothing can be found until the user allows it.
    @Published public private(set) var blocked = false
    private var browsers: [NWBrowser] = []
    private var sightings: [String: TVSighting] = [:]
    private var resolving: [String: NWConnection] = [:]
    private var probes: [String: Set<UInt16>] = [:]
    private var probing: [String: Task<Void, Never>] = [:]

    public init() {}

    public func start() {
        stop()
        searching = true; blocked = false; tvs = []; sightings = [:]; probes = [:]
        // The end-to-end suite works on an emulator only: it must never open a connection to a real TV on the network.
        if ProcessInfo.processInfo.arguments.contains("-e2eNoDiscovery") { searching = false; return }
        for service in TVSighting.Service.allCases {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: service.rawValue, domain: nil), using: .tcp)
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .failed(let error), .waiting(let error):
                        if case .dns(let code) = error, code == -65570 { self.blocked = true }   // kDNSServiceErr_PolicyDenied
                    case .ready: self.blocked = false
                    default: break
                    }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.update(service, results) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    /// UI tests: a fixed list instead of the network.
    public func show(_ tvs: [DiscoveredTV]) { stop(); self.tvs = tvs }

    public func stop() {
        browsers.forEach { $0.cancel() }; browsers = []
        resolving.values.forEach { $0.cancel() }; resolving = [:]
        probing.values.forEach { $0.cancel() }; probing = [:]
        searching = false
    }

    private func update(_ service: TVSighting.Service, _ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata { txt = record.dictionary }
            var sighting = TVSighting(service: service, name: name, txt: txt)
            seen.insert(sighting.id)
            sighting.host = sightings[sighting.id]?.host
            sightings[sighting.id] = sighting
            if sighting.worthChecking && sighting.host == nil && resolving[sighting.id] == nil { resolve(sighting.id, result.endpoint) }
        }
        for (id, sighting) in sightings where sighting.service == service && !seen.contains(id) { sightings[id] = nil }
        publish()
    }

    private func publish() {
        let next = TVSightings.merge(Array(sightings.values), probes: probes)
        if next != tvs { tvs = next }
    }

    /// Bonjour gives a name; a short connection to the service reveals its IPv4 address. It closes right away.
    private func resolve(_ id: String, _ endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint, let address = Self.ipv4(host),
                       self.sightings[id] != nil {
                        self.sightings[id]?.host = address
                        self.knock(address)
                        self.publish()
                    }
                    connection.cancel(); self.resolving[id] = nil
                case .failed, .cancelled:
                    self.resolving[id] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { connection.cancel() }
    }

    /// Once per address while searching.
    private func knock(_ host: String) {
        guard probes[host] == nil, probing[host] == nil else { return }
        probing[host] = Task { [weak self] in
            let open = await PortKnock.openPorts(host: host)
            guard !Task.isCancelled, let self else { return }
            self.probes[host] = open
            self.probing[host] = nil
            self.publish()
        }
    }

    static func ipv4(_ host: NWEndpoint.Host) -> String? {
        guard case let .ipv4(address) = host else { return nil }
        let text = "\(address)".split(separator: "%").first.map(String.init) ?? ""
        return TVAddress.isIPv4(text) ? text : nil
    }
}

extension TVAddress {
    /// Four numbers 0–255 separated by dots.
    public static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && Int(part).map { (0...255).contains($0) } == true
        }
    }
    /// What a person typed into an address field, tidied: keyboards in many regions type a comma for the dot.
    public static func typed(_ text: String) -> String {
        text.replacingOccurrences(of: ",", with: ".").filter { !$0.isWhitespace }
    }
}
