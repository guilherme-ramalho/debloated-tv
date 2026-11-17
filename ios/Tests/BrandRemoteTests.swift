import XCTest
import Network
@testable import TVRemoteCore

/// Roku, LG and Samsung remotes (REM-21..24) against stand-in TVs on this Mac that answer as each brand's protocol
/// says: an HTTP server for Roku's ECP and Samsung's REST, WebSocket servers for LG's SSAP (and its pointer socket)
/// and Samsung's remote channel. What only a real TV can show is in docs/tv-brands.md.
@MainActor final class BrandRemoteTests: XCTestCase {
    // MARK: app names

    func testAppsAreFoundByTheirNameOnTheTV() {
        let apps = [BrandApp(id: "12", name: "Netflix"), BrandApp(id: "13", name: "Amazon Prime Video"), BrandApp(id: "a", name: "YouTube TV"),
                    BrandApp(id: "b", name: "YouTube"), BrandApp(id: "c", name: "Max"), BrandApp(id: "d", name: "Disney Plus")]
        XCTAssertEqual(BrandApps.match("Netflix", in: apps)?.id, "12")
        XCTAssertEqual(BrandApps.match("Prime Video", in: apps)?.id, "13")
        XCTAssertEqual(BrandApps.match("YouTube", in: apps)?.id, "b")
        XCTAssertEqual(BrandApps.match("HBO Max", in: apps)?.id, "c")
        XCTAssertEqual(BrandApps.match("Disney+", in: apps)?.id, "d")
        XCTAssertNil(BrandApps.match("Spotify", in: apps))
    }

    // MARK: Roku

    func testRokuConnectsWithoutAPromptAndSendsKeysAppsAndText() async throws {
        let tv = try await FakeHTTP.start { request in
            switch request {
            case "GET /query/device-info": return (200, "<device-info><power-mode>PowerOn</power-mode></device-info>")
            case "GET /query/active-app": return (200, "<active-app><app id=\"12\">Netflix</app></active-app>")
            case "GET /query/apps": return (200, "<apps><app id=\"12\" type=\"appl\" version=\"5\">Netflix</app><app id=\"837\" type=\"appl\">YouTube</app><app id=\"2285\">Hulu &amp; Co</app></apps>")
            default: return (200, "")
            }
        }
        defer { tv.stop() }
        let roku = RokuRemote(host: "127.0.0.1", base: tv.url)
        let events = EventLog(); roku.event = events.add
        roku.connect(credential: nil)
        try await events.wait(for: .foreground("Netflix"))
        XCTAssertEqual(Array(events.items.prefix(3)), [.approved(RokuRemote.credential), .connected, .power(true)])

        roku.key(.up, direction: 3); roku.key(.volumeUp, direction: 1); roku.key(.volumeUp, direction: 2)
        try await roku.writeKey(.power)
        let names = try await roku.apps().map(\.name)
        XCTAssertEqual(names, ["Netflix", "YouTube", "Hulu & Co"])
        let opened = try await roku.launch(named: "YouTube")
        XCTAssertTrue(opened)
        try await roku.writeText("hi ")
        try await roku.writeText("h")
        try await tv.wait(for: "POST /keypress/Backspace")
        XCTAssertEqual(tv.requests.filter { $0.hasPrefix("POST") }, [
            "POST /keypress/Up", "POST /keydown/VolumeUp", "POST /keyup/VolumeUp", "POST /keypress/PowerOff", "POST /launch/837",
            "POST /keypress/Lit_h", "POST /keypress/Lit_i", "POST /keypress/Lit_%20", "POST /keypress/Backspace", "POST /keypress/Backspace"])
        XCTAssertFalse(roku.supports(.captions))
    }

    func testARokuLimitingMobileAppsIsExplained() async throws {
        let tv = try await FakeHTTP.start { _ in (403, "") }
        defer { tv.stop() }
        let roku = RokuRemote(host: "127.0.0.1", base: tv.url)
        let events = EventLog(); roku.event = events.add
        roku.connect(credential: RokuRemote.credential)
        let error = try await events.firstError()
        XCTAssertTrue(error.contains("Control by mobile apps"), error)
    }

    // MARK: LG

    func testLGAsksToAcceptThenKeepsTheKeyAndSendsButtons() async throws {
        let pointer = try await FakeWebSocket.start { _ in [] }
        defer { pointer.stop() }
        let tv = try await FakeWebSocket.start { text in
            guard let m = JSON.object(text) else { return [] }
            let id = m["id"] as? String ?? ""
            switch (m["type"] as? String, m["uri"] as? String) {
            case ("register", _):
                let payload = m["payload"] as? [String: Any] ?? [:]
                XCTAssertNotNil((payload["manifest"] as? [String: Any])?["signatures"], "LG's signed manifest")
                if payload["client-key"] as? String == "key-1" { return [#"{"type":"registered","id":"register_0","payload":{"client-key":"key-1"}}"#] }
                return [#"{"type":"response","id":"register_0","payload":{"pairingType":"PROMPT","returnValue":true}}"#,
                        #"{"type":"registered","id":"register_0","payload":{"client-key":"key-1"}}"#]
            case ("subscribe", "ssap://com.webos.applicationManager/getForegroundAppInfo"):
                return [#"{"type":"response","id":"fg","payload":{"appId":"netflix","returnValue":true}}"#]
            case ("subscribe", "ssap://audio/getVolume"):
                return [#"{"type":"response","id":"vol","payload":{"volumeStatus":{"volume":12,"muteStatus":false,"maxVolume":100},"returnValue":true}}"#]
            case ("request", "ssap://com.webos.service.networkinput/getPointerInputSocket"):
                return [#"{"type":"response","id":"\#(id)","payload":{"socketPath":"\#(pointer.url.absoluteString)/resources/x/netinput.pointer.sock","returnValue":true}}"#]
            case ("request", "ssap://com.webos.applicationManager/listLaunchPoints"):
                return [#"{"type":"response","id":"\#(id)","payload":{"launchPoints":[{"id":"netflix","title":"Netflix"},{"id":"youtube.leanback.v4","title":"YouTube"}],"returnValue":true}}"#]
            case ("request", _):
                return [#"{"type":"response","id":"\#(id)","payload":{"returnValue":true}}"#]
            default: return []
            }
        }
        defer { tv.stop() }
        let lg = LGRemote(host: "127.0.0.1", urls: [tv.url])
        let events = EventLog(); lg.event = events.add
        lg.connect(credential: nil)
        try await events.wait(for: .foreground("Netflix"))
        XCTAssertEqual(Array(events.items.prefix(3)), [.approvalNeeded, .approved(Data("key-1".utf8)), .connected])
        XCTAssertTrue(events.items.contains(.volume(12, 100, false)))
        try await pointer.waitForClient()
        lg.key(.up, direction: 3); lg.key(.select, direction: 3); lg.key(.volumeUp, direction: 3); lg.key(.mute, direction: 3)
        let opened = try await lg.launch(named: "YouTube")
        XCTAssertTrue(opened)
        try await lg.writeText("ab"); try await lg.writeText("a")
        try await pointer.wait(for: "type:button\nname:ENTER\n\n")
        XCTAssertEqual(pointer.received, ["type:button\nname:UP\n\n", "type:button\nname:ENTER\n\n"])
        let uris = tv.received.compactMap { JSON.object($0)?["uri"] as? String }
        for uri in ["ssap://audio/volumeUp", "ssap://audio/setMute", "ssap://system.launcher/launch", "ssap://com.webos.service.ime/insertText",
                    "ssap://com.webos.service.ime/deleteCharacters"] { XCTAssertTrue(uris.contains(uri), uri) }
        lg.disconnect()

        // Next time: the key, no prompt.
        let again = EventLog(); lg.event = again.add
        lg.connect(credential: Data("key-1".utf8))
        try await again.wait(for: .connected)
        XCTAssertFalse(again.items.contains(.approvalNeeded))
        lg.disconnect()
    }

    func testLGThatSaysNoIsExplained() async throws {
        let tv = try await FakeWebSocket.start { _ in [#"{"type":"error","id":"register_0","error":"403 User denied access"}"#] }
        defer { tv.stop() }
        let lg = LGRemote(host: "127.0.0.1", urls: [tv.url])
        let events = EventLog(); lg.event = events.add
        lg.connect(credential: nil)
        let error = try await events.firstError()
        XCTAssertTrue(error.contains("LG Connect Apps"), error)
    }

    // MARK: Samsung

    func testSamsungAsksToAllowThenSendsKeysAndOpensAppsOverREST() async throws {
        let rest = try await FakeHTTP.start { request in
            switch request {
            case "GET /api/v2/": return (200, #"{"device":{"PowerState":"on","name":"Samsung TV"}}"#)
            case "POST /api/v2/applications/111299001912": return (200, "true")
            default: return (404, "")
            }
        }
        defer { rest.stop() }
        let tv = try await FakeWebSocket.start(greeting: [#"{"event":"ms.channel.connect","data":{"token":"tok-9"}}"#]) { text in
            guard let m = JSON.object(text), (m["params"] as? [String: Any])?["event"] as? String == "ed.installedApp.get" else { return [] }
            return [#"{"event":"ed.installedApp.get","data":{"data":[{"appId":"111299001912","name":"YouTube"},{"appId":"3201907018807","name":"Netflix"}]}}"#]
        }
        defer { tv.stop() }
        let samsung = SamsungRemote(host: "127.0.0.1", name: "Purio test", socketBase: tv.url, rest: rest.url)
        XCTAssertTrue(samsung.socketURL.absoluteString.contains("api/v2/channels/samsung.remote.control?name=UHVyaW8gdGVzdA%3D%3D"))
        let events = EventLog(); samsung.event = events.add
        samsung.connect(credential: nil)
        try await events.wait(for: .power(true))
        XCTAssertEqual(Array(events.items.prefix(3)), [.approvalNeeded, .approved(Data("tok-9".utf8)), .connected])
        samsung.key(.up, direction: 3); samsung.key(.volumeUp, direction: 1); samsung.key(.volumeUp, direction: 2)
        let opened = try await samsung.launch(named: "YouTube")
        XCTAssertTrue(opened)
        try await samsung.writeText("hello")
        try await tv.wait(forContaining: "SendInputEnd")
        let keys = tv.received.compactMap { JSON.object($0)?["params"] as? [String: Any] }.filter { $0["TypeOfRemote"] as? String == "SendRemoteKey" }
            .map { "\($0["Cmd"]!) \($0["DataOfCmd"]!)" }
        XCTAssertEqual(keys, ["Click KEY_UP", "Press KEY_VOLUP", "Release KEY_VOLUP"])
        XCTAssertTrue(tv.received.contains { $0.contains("aGVsbG8=") }, "text goes base64")
        XCTAssertTrue(rest.requests.contains("POST /api/v2/applications/111299001912"))
        XCTAssertTrue(SamsungRemote(host: "x", name: "n").socketURL.absoluteString.hasPrefix("wss://x:8002/"))
    }
}

// MARK: - Stand-ins

@MainActor final class EventLog {
    private(set) var items: [BrandEvent] = []
    func add(_ event: BrandEvent) { items.append(event) }
    func wait(for event: BrandEvent, timeout: Double = 5) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !items.contains(event) {
            guard Date() < end else { XCTFail("no \(event) in \(items)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func firstError(timeout: Double = 5) async throws -> String {
        let end = Date().addingTimeInterval(timeout)
        while true {
            for case .error(let text) in items { return text }
            guard Date() < end else { XCTFail("no error in \(items)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// An HTTP/1.1 server that answers each "METHOD /path" with a status and body, and keeps the requests.
final class FakeHTTP: @unchecked Sendable {
    let listener: NWListener
    let url: URL
    private let lock = NSLock()
    private var _requests: [String] = []
    var requests: [String] { lock.withLock { _requests } }
    private let answer: @Sendable (String) -> (Int, String)

    private init(listener: NWListener, port: UInt16, answer: @escaping @Sendable (String) -> (Int, String)) {
        self.listener = listener; self.answer = answer
        url = URL(string: "http://127.0.0.1:\(port)/")!
    }
    static func start(_ answer: @escaping @Sendable (String) -> (Int, String)) async throws -> FakeHTTP {
        let listener = try NWListener(using: .tcp, on: .any)
        let port: UInt16 = try await withCheckedThrowingContinuation { done in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { done.resume(returning: listener.port!.rawValue) }
                if case .failed(let error) = state, once.claim() { done.resume(throwing: error) }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: .global())
        }
        let server = FakeHTTP(listener: listener, port: port, answer: answer)
        listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        return server
    }
    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        read(connection, Data())
    }
    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, _ in
            var buffer = buffer; if let data { buffer.append(data) }
            guard let head = HTTPRequestHead.parse(buffer) else { if !done { read(connection, buffer) } else { connection.cancel() }; return }
            let request = "\(head.method) \(head.path)"
            lock.withLock { _requests.append(request) }
            let (status, body) = answer(request)
            let response = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func wait(for request: String, timeout: Double = 5) async throws {
        let end = Date().addingTimeInterval(timeout)
        while requests.filter({ $0 == request }).isEmpty || (request.hasSuffix("Backspace") && requests.filter({ $0 == request }).count < 2) {
            guard Date() < end else { XCTFail("no \(request) in \(requests)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func stop() { listener.cancel() }
}

/// A WebSocket server that sends `greeting` to each client and answers each text message with zero or more texts.
final class FakeWebSocket: @unchecked Sendable {
    let listener: NWListener
    let url: URL
    private let lock = NSLock()
    private var _received: [String] = []
    private var clients = 0
    var received: [String] { lock.withLock { _received } }
    private let greeting: [String]
    private let answer: @Sendable (String) -> [String]

    private init(listener: NWListener, port: UInt16, greeting: [String], answer: @escaping @Sendable (String) -> [String]) {
        self.listener = listener; self.greeting = greeting; self.answer = answer
        url = URL(string: "ws://127.0.0.1:\(port)")!
    }
    static func start(greeting: [String] = [], _ answer: @escaping @Sendable (String) -> [String]) async throws -> FakeWebSocket {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: parameters, on: .any)
        let port: UInt16 = try await withCheckedThrowingContinuation { done in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { done.resume(returning: listener.port!.rawValue) }
                if case .failed(let error) = state, once.claim() { done.resume(throwing: error) }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: .global())
        }
        let server = FakeWebSocket(listener: listener, port: port, greeting: greeting, answer: answer)
        listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        return server
    }
    private func serve(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [self] state in
            guard case .ready = state else { return }
            lock.withLock { clients += 1 }
            greeting.forEach { send($0, on: connection) }
            receive(connection)
        }
        connection.start(queue: .global())
    }
    private func send(_ text: String, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "t", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [self] data, _, _, error in
            guard error == nil else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                lock.withLock { _received.append(text) }
                answer(text).forEach { send($0, on: connection) }
            }
            receive(connection)
        }
    }
    func waitForClient(timeout: Double = 5) async throws {
        let end = Date().addingTimeInterval(timeout)
        while lock.withLock({ clients }) == 0 {
            guard Date() < end else { XCTFail("nobody connected"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func wait(for text: String, timeout: Double = 5) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !received.contains(text) {
            guard Date() < end else { XCTFail("no \(text) in \(received)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func wait(forContaining text: String, timeout: Double = 5) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !received.contains(where: { $0.contains(text) }) {
            guard Date() < end else { XCTFail("nothing with \(text) in \(received)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func stop() { listener.cancel() }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
