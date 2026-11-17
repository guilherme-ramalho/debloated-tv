import Foundation

/// Roku's External Control Protocol: plain HTTP on port 8060, no pairing. Keys are `POST keypress|keydown|keyup/<Key>`,
/// typing is `keypress/Lit_<char>`, apps are `query/apps` and `launch/<id>`, the state is `query/device-info`
/// (power-mode) and `query/active-app`. Nothing is polled: the state is read on connect and after a key that
/// changes the app on screen. A Roku whose "Control by mobile apps" limits network access answers 403.
public final class RokuRemote: BrandRemote, @unchecked Sendable {
    public let kind = TVKind.roku
    public var event: ((BrandEvent) -> Void)?
    private let base: URL
    private let session: URLSession
    private var generation = 0
    private var cachedApps: [BrandApp]?
    private var sent = ""
    private var powerOn: Bool?
    /// The credential Roku "pairing" saves: there is no key, only the note that this TV was chosen.
    public static let credential = Data("roku".utf8)

    public init(host: String, base: URL? = nil) {
        self.base = base ?? URL(string: "http://\(host):\(TVPorts.roku)/")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    static func keyName(_ key: TVKey) -> String? {
        switch key {
        case .home: "Home"
        case .back: "Back"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .select: "Select"
        case .delete: "Backspace"
        case .volumeUp: "VolumeUp"
        case .volumeDown: "VolumeDown"
        case .mute: "VolumeMute"
        case .power: "Power"
        case .playPause, .play, .pause: "Play"
        case .rewind: "Rev"
        case .fastForward: "Fwd"
        case .settings: "Info"
        case .captions, .inputs: nil
        }
    }
    public func supports(_ key: TVKey) -> Bool { kind.supports(key) }

    public func connect(credential: Data?) {
        generation += 1
        let token = generation
        Task { @MainActor in
            do {
                let info = try await self.get("query/device-info")
                guard token == self.generation else { return }
                let on = Self.tag("power-mode", in: info).map { $0 == "PowerOn" }
                if credential == nil { self.event?(.approved(Self.credential)) }
                self.event?(.connected)
                if let on { self.powerOn = on; self.event?(.power(on)) }
                await self.readActiveApp(token)
            } catch {
                guard token == self.generation else { return }
                self.event?(.error(Self.message(for: error)))
            }
        }
    }
    public func disconnect() { generation += 1; cachedApps = nil; sent = ""; last = nil }

    /// Commands go out one at a time, in order: a key's release must never overtake its press.
    private var last: Task<Void, Never>?
    @discardableResult private func chain(_ work: @escaping @MainActor () async throws -> Void) -> Task<Result<Void, Error>, Never> {
        let previous = last
        let task = Task { @MainActor () -> Result<Void, Error> in
            await previous?.value
            do { try await work(); return .success(()) } catch { return .failure(error) }
        }
        last = Task { _ = await task.value }
        return task
    }
    private func enqueue(_ work: @escaping @MainActor () async throws -> Void) async throws { try await chain(work).value.get() }

    public func key(_ key: TVKey, direction: UInt64) {
        let task = chain { try await self.send(key, direction: direction) }
        Task { @MainActor in if case .failure(let error) = await task.value { self.event?(.error(Self.message(for: error))) } }
    }
    public func writeKey(_ key: TVKey) async throws { try await enqueue { try await self.send(key, direction: 3) } }

    private func send(_ key: TVKey, direction: UInt64) async throws {
        guard var name = Self.keyName(key) else { return }
        if key == .power, let powerOn { name = powerOn ? "PowerOff" : "PowerOn" }
        let verb = direction == 1 ? "keydown" : direction == 2 ? "keyup" : "keypress"
        try await post("\(verb)/\(name)")
        if key == .power, direction != 1, let on = powerOn { powerOn = !on; event?(.power(!on)) }
        if direction != 1, [.home, .back].contains(key) { refreshSoon() }
    }

    public func apps() async throws -> [BrandApp] {
        if let cachedApps { return cachedApps }
        let xml = try await get("query/apps")
        let apps = Self.apps(in: xml)
        cachedApps = apps
        return apps
    }
    public func launch(_ app: BrandApp) async throws {
        try await enqueue { try await self.post("launch/\(app.id)") }
        refreshSoon()
    }

    /// Roku types one character at a time and deletes with Backspace.
    public func writeText(_ text: String) async throws {
        let edit = TVSession.typingEdit(from: sent, to: text)
        sent = text
        try await enqueue {
            for _ in 0..<edit.deletes { try await self.post("keypress/Backspace") }
            for character in edit.insert {
                let encoded = String(character).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                try await self.post("keypress/Lit_\(encoded)")
            }
        }
    }

    public func alive() async -> Bool { (try? await get("query/device-info")) != nil }

    // MARK: reading

    private func refreshSoon() {
        let token = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            await self.readActiveApp(token)
        }
    }
    private func readActiveApp(_ token: Int) async {
        guard let xml = try? await get("query/active-app"), token == generation else { return }
        if let name = Self.tag("app", in: xml) { event?(.foreground(name)) }
    }

    static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)"), let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex),
              let start = xml.range(of: ">", range: open.upperBound..<close.lowerBound) else { return nil }
        return unescape(String(xml[start.upperBound..<close.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func apps(in xml: String) -> [BrandApp] {
        var apps: [BrandApp] = []
        var rest = xml[...]
        while let open = rest.range(of: "<app "), let end = rest.range(of: "</app>", range: open.upperBound..<rest.endIndex) {
            let element = rest[open.lowerBound..<end.upperBound]
            if let idStart = element.range(of: "id=\""), let idEnd = element.range(of: "\"", range: idStart.upperBound..<element.endIndex),
               let body = element.range(of: ">", range: idEnd.upperBound..<element.endIndex) {
                let id = String(element[idStart.upperBound..<idEnd.lowerBound])
                let name = unescape(String(element[body.upperBound..<element.index(element.endIndex, offsetBy: -6)]))
                if !id.isEmpty, !name.isEmpty { apps.append(BrandApp(id: id, name: name)) }
            }
            rest = rest[end.upperBound...]
        }
        return apps
    }
    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: HTTP

    enum Failure: Error { case limited, status(Int) }

    private func get(_ path: String) async throws -> String {
        let (data, response) = try await session.data(from: base.appendingPathComponent(path))
        try Self.check(response)
        return String(decoding: data, as: UTF8.self)
    }
    private func post(_ path: String) async throws {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
    }
    private static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
        if status == 403 { throw Failure.limited }
        if !(200..<300).contains(status) { throw Failure.status(status) }
    }
    static func message(for error: Error) -> String {
        if case Failure.limited = error {
            return String(localized: "The Roku refuses this phone. On the Roku: Settings › System › Advanced system settings › Control by mobile apps › Network access: Enabled (or Permissive).")
        }
        return String(localized: "Couldn't reach the TV. Check that it's on and on the same Wi-Fi as this iPhone.")
    }
}
