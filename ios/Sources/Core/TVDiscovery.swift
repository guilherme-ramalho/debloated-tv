import Foundation
import Combine
import Network

/// Finds Android TVs and Google TVs on the local network: their remote service announces itself over Bonjour as
/// `_androidtvremote2._tcp`, the way Google's own remote app finds them. Runs only while a screen asks for it (start
/// on appear, stop on disappear), so nothing searches in the background.
public struct DiscoveredTV: Identifiable, Equatable {
    public let id: String
    /// The TV's own name ("Living Room TV").
    public let name: String
    /// Its IPv4 address once resolved; nil while resolving.
    public var host: String?
}

@MainActor public final class TVDiscovery: ObservableObject {
    public static let service = "_androidtvremote2._tcp"
    @Published public private(set) var tvs: [DiscoveredTV] = []
    @Published public private(set) var searching = false
    /// iOS refused Local Network access, so nothing can be found until the user allows it.
    @Published public private(set) var blocked = false
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]

    public init() {}

    public func start() {
        stop()
        searching = true; blocked = false; tvs = []
        let browser = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: .tcp)
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
            Task { @MainActor in self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel(); browser = nil
        resolving.values.forEach { $0.cancel() }; resolving = [:]
        searching = false
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var next: [DiscoveredTV] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            let known = tvs.first { $0.id == name }
            next.append(DiscoveredTV(id: name, name: name, host: known?.host))
            if known?.host == nil && resolving[name] == nil { resolve(name, result.endpoint) }
        }
        tvs = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Bonjour gives a name; a short connection to the service reveals its IPv4 address. It closes right away.
    private func resolve(_ name: String, _ endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint, let address = Self.ipv4(host),
                       let index = self.tvs.firstIndex(where: { $0.id == name }) {
                        self.tvs[index].host = address
                    }
                    connection.cancel(); self.resolving[name] = nil
                case .failed, .cancelled:
                    self.resolving[name] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { connection.cancel() }
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
