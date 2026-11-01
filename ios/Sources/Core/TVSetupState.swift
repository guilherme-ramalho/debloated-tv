import Foundation
import Combine

/// "192.168.0.13", "192.168.0.13:15555" or "mac.local:15555" (an emulator shared from a Mac). Port 5555 by default.
public struct TVAddress: Equatable {
    public var host: String
    public var port: UInt16
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty, parts.count <= 2, !first.contains(where: \.isWhitespace) else { return nil }
        host = String(first)
        if parts.count == 2 { guard let p = UInt16(parts[1]), p > 0 else { return nil }; port = p } else { port = 5555 }
    }
}

/// What the app knows about each TV's setup, keyed by the TV's address: whether our Home screen is on it, whether its
/// model has a tested profile, and what the last setup did. Drives the TV tab (setup card or editor) and the one-time
/// offer after pairing. Only facts the app saw itself are stored, on the phone; nothing leaves it.
public struct TVSetupInfo: Codable, Equatable {
    public var homeInstalled = false
    /// nil until a setup connection has read the TV's model.
    public var supported: Bool?
    public var model = ""
    public var detail = ""
    public var profile = ""
    public var disabledCount: Int?
    /// The one-time "set up your TV" sheet after pairing was shown.
    public var offered = false
    public init(homeInstalled: Bool = false, supported: Bool? = nil, model: String = "", detail: String = "",
                profile: String = "", disabledCount: Int? = nil, offered: Bool = false) {
        self.homeInstalled = homeInstalled; self.supported = supported; self.model = model; self.detail = detail
        self.profile = profile; self.disabledCount = disabledCount; self.offered = offered
    }
}

@MainActor public final class TVSetupStatus: ObservableObject {
    public static let homePackage = "com.gathin.tvhome"
    @Published private var all: [String: TVSetupInfo]
    /// The TV the one-time offer is showing for.
    @Published public var offerFor: String?
    /// Set to open the setup flow from the TV tab.
    @Published public var openSetup = false
    private let defaults: UserDefaults
    private let offerDelay: Duration
    static let key = "tvSetupStatus.v1"

    public init(defaults: UserDefaults = .standard, offerDelay: Duration = .milliseconds(1500)) {
        self.defaults = defaults
        self.offerDelay = offerDelay
        all = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: TVSetupInfo].self, from: $0) } ?? [:]
    }

    public func info(_ host: String) -> TVSetupInfo { all[host] ?? TVSetupInfo() }

    public func update(_ host: String, _ change: (inout TVSetupInfo) -> Void) {
        guard !host.isEmpty else { return }
        var value = info(host)
        change(&value)
        guard value != all[host] else { return }
        all[host] = value
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }

    /// The TV showed our Home screen, or its editor answered.
    public func sawHome(_ host: String) { update(host) { $0.homeInstalled = true } }

    /// Undo put the stock launcher back.
    public func restored(_ host: String) { update(host) { $0.homeInstalled = false; $0.disabledCount = nil } }

    /// Right after a new pairing: offer setup once, unless this TV already has the new Home screen. Waits for the
    /// pairing sheet to close and for the TV to report what's on screen; if that's our Home screen, nothing is offered.
    public func offerAfterPairing(_ host: String) {
        let current = info(host)
        guard !host.isEmpty, !current.offered, !current.homeInstalled else { return }
        update(host) { $0.offered = true }
        let delay = offerDelay
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !self.info(host).homeInstalled else { return }
            self.offerFor = host
        }
    }

    /// Records what a setup connection learned about the TV.
    public func inspected(_ host: String, properties: [String: String], profile: DebloatProfile?) {
        update(host) {
            $0.supported = profile != nil
            $0.profile = profile?.manifest.name ?? ""
            let brand = (properties["ro.product.manufacturer"] ?? "").trimmingCharacters(in: .whitespaces)
            let model = (properties["ro.product.model"] ?? "").trimmingCharacters(in: .whitespaces)
            $0.model = model.isEmpty ? String(localized: "Unknown model") : (brand.isEmpty || model.localizedCaseInsensitiveContains(brand) ? model : "\(brand) \(model)")
            $0.detail = [properties["ro.product.device"], properties["ro.build.version.release"].map { String(localized: "Android \($0)") }]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
}

/// Asking for a TV model to be supported, without an account or a server of our own.
public enum ModelRequest {
    /// A prefilled web form (e.g. Google Forms) that takes the details without sign-in. nil: share the details instead.
    public static let formURL: String? = nil
    public static let addTVGuide = URL(string: "https://github.com/guilherme-ramalho/debloated-tv/tree/main/ios/Resources/Profiles")!

    public static func text(_ info: TVSetupInfo) -> String {
        String(localized: "Debloated TV: please add support for this TV.\nModel: \(info.model)\nDetails: \(info.detail)")
    }
    public static func url(_ info: TVSetupInfo, form: String? = formURL) -> URL? {
        guard let base = form, var parts = URLComponents(string: base), parts.scheme == "https" else { return nil }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "model", value: info.model), URLQueryItem(name: "details", value: info.detail)]
        return parts.url
    }
}
