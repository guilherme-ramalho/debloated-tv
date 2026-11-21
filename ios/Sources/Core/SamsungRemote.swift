import Foundation

/// Samsung Tizen (2016 and later): the remote is a WebSocket on 8002 (TLS). The first time the TV asks to allow
/// this phone and then gives a token, kept as the credential. Keys are `ms.remote.control` messages (Click, or
/// Press/Release for a hold), typing is SendInputString, the app list comes over the same socket and apps open
/// through the TV's REST API on 8001 (the socket's own launch is ignored by some TVs). The power state is one GET
/// on 8001 when connecting; nothing is polled. Samsung pushes no volume or app-on-screen, so the remote shows none.
public final class SamsungRemote: BrandRemote, @unchecked Sendable {
    public let kind = TVKind.samsung
    public var event: ((BrandEvent) -> Void)?
    private let socketBase: URL
    private let rest: URL
    private let name: String
    private let session: URLSession
    private var link: WebSocketLink?
    private var generation = 0
    private var ready = false
    private var token: String?
    private var appsWaiting: [CheckedContinuation<[BrandApp], Error>] = []
    private var cachedApps: [BrandApp]?
    private var playing = true

    /// `socketBase` and `rest` for tests.
    public init(host: String, name: String = RemoteClientName.current(), socketBase: URL? = nil, rest: URL? = nil) {
        self.socketBase = socketBase ?? URL(string: "wss://\(host):8002")!
        self.rest = rest ?? URL(string: "http://\(host):8001/")!
        self.name = name
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        session = URLSession(configuration: configuration)
    }

    static func code(_ key: TVKey) -> String? {
        switch key {
        case .home: "KEY_HOME"
        case .back: "KEY_RETURN"
        case .up: "KEY_UP"
        case .down: "KEY_DOWN"
        case .left: "KEY_LEFT"
        case .right: "KEY_RIGHT"
        case .select: "KEY_ENTER"
        case .volumeUp: "KEY_VOLUP"
        case .volumeDown: "KEY_VOLDOWN"
        case .mute: "KEY_MUTE"
        case .power: "KEY_POWER"
        case .play: "KEY_PLAY"
        case .pause: "KEY_PAUSE"
        case .rewind: "KEY_REWIND"
        case .fastForward: "KEY_FF"
        case .captions: "KEY_CAPTION"
        case .settings: "KEY_MENU"
        case .inputs: "KEY_SOURCE"
        case .channelUp: "KEY_CHUP"
        case .channelDown: "KEY_CHDOWN"
        case .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9: key.digit.map { "KEY_\($0)" }
        case .playPause, .delete: nil
        }
    }
    public func supports(_ key: TVKey) -> Bool { kind.supports(key) }

    var socketURL: URL {
        var components = URLComponents(url: socketBase.appendingPathComponent("api/v2/channels/samsung.remote.control"), resolvingAgainstBaseURL: false)!
        // Encoded strictly, as Samsung's own apps do: a "+" in the base64 name would otherwise reach the TV as a space.
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        var query = "name=" + encode(Data(name.utf8).base64EncodedString())
        if let token { query += "&token=" + encode(token) }
        components.percentEncodedQuery = query
        return components.url!
    }

    public func connect(credential: Data?) {
        disconnect()
        token = credential.flatMap { String(data: $0, encoding: .utf8) }
        let gen = generation
        let link = WebSocketLink(url: socketURL)
        self.link = link
        link.onOpen = { [weak self] in
            // Without a token the TV now shows "Allow"; with one it answers at once.
            if let self, gen == self.generation, self.token == nil { self.event?(.approvalNeeded) }
        }
        link.onText = { [weak self] text in
            guard let self, gen == self.generation, let message = JSON.object(text) else { return }
            self.handle(message)
        }
        link.onClose = { [weak self] reason in
            guard let self, gen == self.generation else { return }
            let wasReady = self.ready
            self.disconnect()
            self.event?(.error(wasReady ? String(localized: "The TV closed the remote connection.") : (reason ?? String(localized: "Couldn't reach the TV. Check that it's on and on the same Wi-Fi as this iPhone."))))
        }
        link.open()
    }

    public func disconnect() {
        generation += 1
        link?.close(); link = nil
        ready = false
        for waiting in appsWaiting { waiting.resume(throwing: RemoteFailure.message(String(localized: "The TV closed the remote connection."))) }
        appsWaiting = []
        cachedApps = nil
    }

    private func handle(_ message: [String: Any]) {
        let data = message["data"] as? [String: Any]
        switch message["event"] as? String {
        case "ms.channel.connect":
            ready = true
            if let new = data?["token"] as? String, new != token {
                token = new
                event?(.approved(Data(new.utf8)))
            }
            event?(.connected)
            readPower()
        case "ms.channel.unauthorized":
            disconnect()
            event?(.error(String(localized: "The TV didn't allow this phone. Press Allow on the TV when it asks (or allow it in Settings › General › External Device Manager › Device Connection Manager).")))
        case "ms.channel.timeOut":
            disconnect()
            event?(.error(String(localized: "Nobody pressed Allow on the TV in time. Try again.")))
        case "ed.installedApp.get":
            let list = (data?["data"] as? [[String: Any]] ?? []).compactMap { app -> BrandApp? in
                guard let id = app["appId"] as? String, let name = app["name"] as? String else { return nil }
                return BrandApp(id: id, name: name)
            }
            cachedApps = list
            let waiting = appsWaiting; appsWaiting = []
            waiting.forEach { $0.resume(returning: list) }
        default: break
        }
    }

    private func readPower() {
        let gen = generation
        Task { @MainActor in
            guard let (data, _) = try? await self.session.data(from: self.rest.appendingPathComponent("api/v2/")), gen == self.generation,
                  let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let state = (info["device"] as? [String: Any])?["PowerState"] as? String else { return }
            self.event?(.power(state.lowercased() == "on"))
        }
    }

    private func remote(_ code: String, _ cmd: String) {
        link?.send(json: ["method": "ms.remote.control",
                          "params": ["Cmd": cmd, "DataOfCmd": code, "Option": "false", "TypeOfRemote": "SendRemoteKey"]])
    }

    public func key(_ key: TVKey, direction: UInt64) {
        guard ready else { return }
        if key == .playPause { playing.toggle(); remote(playing ? "KEY_PLAY" : "KEY_PAUSE", "Click"); return }
        guard let code = Self.code(key) else { return }
        remote(code, direction == 1 ? "Press" : direction == 2 ? "Release" : "Click")
    }
    public func writeKey(_ key: TVKey) async throws {
        guard ready else { throw RemoteFailure.message(String(localized: "TV is not ready")) }
        self.key(key, direction: 3)
    }

    public func apps() async throws -> [BrandApp] {
        if let cachedApps { return cachedApps }
        guard ready, let link else { throw RemoteFailure.message(String(localized: "TV is not ready")) }
        let gen = generation
        return try await withCheckedThrowingContinuation { continuation in
            appsWaiting.append(continuation)
            if appsWaiting.count == 1 {
                link.send(json: ["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, gen == self.generation, !self.appsWaiting.isEmpty else { return }
                let waiting = self.appsWaiting; self.appsWaiting = []
                waiting.forEach { $0.resume(throwing: RemoteFailure.message(String(localized: "The TV didn't answer."))) }
            }
        }
    }

    public func launch(_ app: BrandApp) async throws {
        var request = URLRequest(url: rest.appendingPathComponent("api/v2/applications/\(app.id)"))
        request.httpMethod = "POST"
        if let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
           String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true" { return }
        guard ready, let link else { throw RemoteFailure.message(String(localized: "TV is not ready")) }
        link.send(json: ["method": "ms.channel.emit",
                         "params": ["event": "ed.apps.launch", "to": "host", "data": ["appId": app.id, "action_type": "DEEP_LINK"]]])
    }

    /// Samsung's keyboard takes the whole text and replaces the field with it.
    public func writeText(_ text: String) async throws {
        guard ready, let link else { throw RemoteFailure.message(String(localized: "TV is not ready")) }
        link.send(json: ["method": "ms.remote.control",
                         "params": ["Cmd": Data(text.utf8).base64EncodedString(), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"]])
        link.send(json: ["method": "ms.remote.control", "params": ["TypeOfRemote": "SendInputEnd"]])
    }

    public func alive() async -> Bool {
        guard ready else { return false }
        return (try? await session.data(from: rest.appendingPathComponent("api/v2/"))) != nil
    }
}
