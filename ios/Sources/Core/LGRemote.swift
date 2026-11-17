import Foundation

/// LG webOS: SSAP, JSON over a WebSocket on port 3001 (TLS, newer firmware) or 3000 (plain, older). The first time
/// the TV asks to accept this phone and then gives a client key, kept as the credential. The state comes pushed
/// (subscriptions: app on screen, volume, power), so nothing is polled. Arrows, OK, Back and the other buttons
/// go over a second WebSocket the TV hands out (the pointer socket). Registration manifest: LG's own signed one,
/// as every LG remote library sends it (aiowebostv, Apache 2.0).
public final class LGRemote: BrandRemote, @unchecked Sendable {
    public let kind = TVKind.lg
    public var event: ((BrandEvent) -> Void)?
    private let urls: [URL]
    private var link: WebSocketLink?
    private var pointer: WebSocketLink?
    private var generation = 0
    private var registered = false
    /// The SSAP socket that answered is the TLS one (3001).
    private var secure = false
    private var clientKey: String?
    private var nextID = 0
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var launchPoints: [BrandApp]?
    private var muted = false
    private var playing = true
    private var sent = ""
    private let repeater = KeyRepeater()

    /// `urls` for tests; a TV is tried on 3001 (TLS) first, then 3000.
    public init(host: String, urls: [URL]? = nil) {
        self.urls = urls ?? [URL(string: "wss://\(host):3001")!, URL(string: "ws://\(host):3000")!]
    }

    static func button(_ key: TVKey) -> String? {
        switch key {
        case .home: "HOME"
        case .back: "BACK"
        case .up: "UP"
        case .down: "DOWN"
        case .left: "LEFT"
        case .right: "RIGHT"
        case .select: "ENTER"
        case .play: "PLAY"
        case .pause: "PAUSE"
        case .rewind: "REWIND"
        case .fastForward: "FASTFORWARD"
        case .captions: "CC"
        case .settings: "MENU"
        case .inputs: "INPUT_HUB"
        case .volumeUp, .volumeDown, .mute, .power, .playPause, .delete: nil
        }
    }
    public func supports(_ key: TVKey) -> Bool { true }

    public func connect(credential: Data?) {
        disconnect()
        clientKey = credential.flatMap { String(data: $0, encoding: .utf8) }
        open(urls, generation: generation)
    }

    private func open(_ remaining: [URL], generation token: Int) {
        guard let url = remaining.first else { return }
        let link = WebSocketLink(url: url)
        self.link = link
        var answered = false
        link.onOpen = { [weak self] in
            guard let self, token == self.generation else { return }
            answered = true
            self.secure = url.scheme == "wss"
            link.send(json: self.registration())
        }
        link.onText = { [weak self] text in
            guard let self, token == self.generation, let message = JSON.object(text) else { return }
            self.handle(message)
        }
        link.onClose = { [weak self] reason in
            guard let self, token == self.generation else { return }
            if !answered && remaining.count > 1 { self.open(Array(remaining.dropFirst()), generation: token); return }
            self.closed(reason)
        }
        link.open()
    }

    public func disconnect() {
        generation += 1
        link?.close(); link = nil
        pointer?.close(); pointer = nil
        registered = false
        repeater.releaseAll()
        for continuation in pending.values { continuation.resume(throwing: RemoteFailure.message(String(localized: "The TV closed the remote connection."))) }
        pending = [:]
        launchPoints = nil; sent = ""
    }

    private func closed(_ reason: String?) {
        let wasRegistered = registered
        disconnect()
        event?(.error(wasRegistered ? String(localized: "The TV closed the remote connection.") : (reason ?? String(localized: "Couldn't reach the TV. Check that it's on and on the same Wi-Fi as this iPhone."))))
    }

    func registration() -> [String: Any] {
        var payload = Self.registrationPayload
        if let clientKey { payload["client-key"] = clientKey }
        return ["type": "register", "id": "register_0", "payload": payload]
    }

    private func handle(_ message: [String: Any]) {
        let id = message["id"] as? String ?? ""
        let type = message["type"] as? String ?? ""
        let payload = message["payload"] as? [String: Any] ?? [:]
        if id == "register_0" {
            switch type {
            case "response" where payload["pairingType"] as? String == "PROMPT": event?(.approvalNeeded)
            case "registered":
                registered = true
                if let key = payload["client-key"] as? String, key != clientKey {
                    clientKey = key
                    event?(.approved(Data(key.utf8)))
                }
                event?(.connected)
                subscribe()
            case "error":
                let reason = message["error"] as? String ?? ""
                disconnect()
                event?(.error(String(localized: "The TV didn't accept this phone. Accept it on the TV when it asks, and check that LG Connect Apps is on in the TV's network settings.") + (reason.isEmpty ? "" : " (\(reason))")))
            default: break
            }
            return
        }
        switch id {
        case "fg": if let appId = payload["appId"] as? String { foreground(appId) }
        case "vol": volume(payload)
        case "power": if let state = payload["state"] as? String { event?(.power(state == "Active" || state == "Screen Saver")) }
        default:
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if type == "error" || payload["returnValue"] as? Bool == false {
                let text = (message["error"] as? String) ?? (payload["errorText"] as? String) ?? "error"
                continuation.resume(throwing: RemoteFailure.message(String(localized: "The TV refused: \(text)")))
            } else { continuation.resume(returning: payload) }
        }
    }

    private func subscribe() {
        link?.send(json: ["id": "fg", "type": "subscribe", "uri": "ssap://com.webos.applicationManager/getForegroundAppInfo"])
        link?.send(json: ["id": "vol", "type": "subscribe", "uri": "ssap://audio/getVolume"])
        link?.send(json: ["id": "power", "type": "subscribe", "uri": "ssap://com.webos.service.tvpower/power/getPowerState"])
        let token = generation
        Task { @MainActor in
            guard let path = try? await self.request("com.webos.service.networkinput/getPointerInputSocket")["socketPath"] as? String,
                  token == self.generation, var url = URL(string: path) else { return }
            // A TV reached over TLS hands out a plain ws:// path that it only serves over TLS on 3001.
            if self.secure, url.scheme == "ws", url.port == 3000,
               let secure = URL(string: path.replacingOccurrences(of: "ws://", with: "wss://").replacingOccurrences(of: ":3000/", with: ":3001/")) { url = secure }
            let pointer = WebSocketLink(url: url)
            pointer.onClose = { [weak self] _ in if token == self?.generation { self?.pointer = nil } }
            pointer.open()
            self.pointer = pointer
        }
    }

    private func foreground(_ appId: String) {
        guard !appId.isEmpty else { return }
        let token = generation
        Task { @MainActor in
            let name = (try? await self.apps())?.first { $0.id == appId }?.name
            guard token == self.generation else { return }
            self.event?(.foreground(name ?? appId))
        }
    }
    private func volume(_ payload: [String: Any]) {
        let status = payload["volumeStatus"] as? [String: Any] ?? payload
        guard let level = status["volume"] as? Int else { return }
        muted = (status["muteStatus"] as? Bool) ?? (status["muted"] as? Bool) ?? muted
        event?(.volume(level, (status["maxVolume"] as? Int) ?? 100, muted))
    }

    /// One SSAP request and its answer (6 s at most).
    func request(_ uri: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        guard registered, let link else { throw RemoteFailure.message(String(localized: "TV is not ready")) }
        nextID += 1
        let id = "c\(nextID)"
        let token = generation
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            link.send(json: ["id": id, "type": "request", "uri": "ssap://\(uri)", "payload": payload])
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, token == self.generation, let waiting = self.pending.removeValue(forKey: id) else { return }
                waiting.resume(throwing: RemoteFailure.message(String(localized: "The TV didn't answer.")))
            }
        }
    }
    private func command(_ uri: String, _ payload: [String: Any] = [:]) {
        guard registered else { return }
        nextID += 1
        link?.send(json: ["id": "c\(nextID)", "type": "request", "uri": "ssap://\(uri)", "payload": payload])
    }

    public func key(_ key: TVKey, direction: UInt64) {
        switch direction {
        case 1 where [.up, .down, .left, .right, .volumeUp, .volumeDown].contains(key): repeater.press(key) { [weak self] in self?.tap($0) }
        case 2: repeater.release(key)
        case 1: tap(key)
        default: tap(key)
        }
    }
    public func writeKey(_ key: TVKey) async throws {
        guard registered else { throw RemoteFailure.message(String(localized: "TV is not ready")) }
        tap(key)
    }

    private func tap(_ key: TVKey) {
        switch key {
        case .volumeUp: command("audio/volumeUp")
        case .volumeDown: command("audio/volumeDown")
        case .mute: command("audio/setMute", ["mute": !muted])
        case .power: command("system/turnOff")
        case .playPause: playing.toggle(); button(playing ? "PLAY" : "PAUSE")
        case .delete: command("com.webos.service.ime/deleteCharacters", ["count": 1])
        default: if let name = Self.button(key) { button(name) }
        }
    }
    private func button(_ name: String) { pointer?.send("type:button\nname:\(name)\n\n") }

    public func apps() async throws -> [BrandApp] {
        if let launchPoints { return launchPoints }
        let payload = try await request("com.webos.applicationManager/listLaunchPoints")
        let points = (payload["launchPoints"] as? [[String: Any]] ?? []).compactMap { point -> BrandApp? in
            guard let id = point["id"] as? String else { return nil }
            return BrandApp(id: id, name: point["title"] as? String ?? id)
        }
        launchPoints = points
        return points
    }
    public func launch(_ app: BrandApp) async throws { _ = try await request("system.launcher/launch", ["id": app.id]) }

    public func writeText(_ text: String) async throws {
        let edit = TVSession.typingEdit(from: sent, to: text)
        if edit.deletes > 0 { _ = try await request("com.webos.service.ime/deleteCharacters", ["count": edit.deletes]) }
        if !edit.insert.isEmpty { _ = try await request("com.webos.service.ime/insertText", ["text": edit.insert, "replace": 0]) }
        sent = text
    }

    public func alive() async -> Bool { (try? await request("com.webos.applicationManager/getForegroundAppInfo")) != nil }

    static let signature = "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw=="

    static let registrationPayload: [String: Any] = [
        "forcePairing": false,
        "pairingType": "PROMPT",
        "manifest": [
            "appVersion": "1.1",
            "manifestVersion": 1,
            "permissions": ["LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED", "CONTROL_AUDIO",
                            "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_MEDIA_PLAYBACK",
                            "CONTROL_INPUT_TV", "CONTROL_POWER", "CONTROL_TV_SCREEN", "READ_APP_STATUS", "READ_CURRENT_CHANNEL",
                            "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE", "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST",
                            "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE", "READ_COUNTRY_INFO", "CONTROL_INPUT_TEXT",
                            "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS", "READ_SETTINGS"],
            "signatures": [["signature": signature, "signatureVersion": 1]],
            "signed": [
                "appId": "com.lge.test",
                "created": "20140509",
                "localizedAppNames": ["": "LG Remote App", "ko-KR": "리모컨 앱", "zxx-XX": "ЛГ Rэмotэ AПП"],
                "localizedVendorNames": ["": "LG Electronics"],
                "permissions": ["TEST_SECURE", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS", "READ_LGE_SDX",
                                "READ_NOTIFICATIONS", "SEARCH", "WRITE_SETTINGS", "WRITE_NOTIFICATION_ALERT", "CONTROL_POWER",
                                "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS", "READ_UPDATE_INFO", "UPDATE_FROM_REMOTE_APP",
                                "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME"],
                "serial": "2f930e2d2cfe083771f68e4fe7bb07",
                "vendorId": "com.lge",
            ] as [String: Any],
        ] as [String: Any],
    ]
}
