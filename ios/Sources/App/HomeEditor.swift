import SwiftUI

@MainActor final class HomeEditor: ObservableObject {
    @Published var ready = false
    @Published var busy = false
    @Published var showingPIN = false
    @Published var message = "Drafts are saved on this iPhone. Connect the TV editor to apply them."
    @Published private(set) var snapshot: LauncherSnapshot?
    private let client = LauncherClient()
    private var identity: ClientIdentity?
    private var host = ""
    private var operation: Task<Void, Never>?
    private var active = false
    private var generation = 0
    private static let service = "PersonalTVRemote.HomeEditorPin.v1"
    func close() { generation += 1; snapshot = nil; active = false; operation?.cancel(); operation = nil; client.close(); ready = false; busy = false; showingPIN = false }
    func connect(model: RemoteModel, pair: Bool = false) {
        close(); let token = generation; active = true; host = model.host; busy = true
        guard model.ready else { busy = false; message = "The TV is unavailable. You can continue editing this draft."; return }
        client.event = { [weak self, weak model] event in
            guard let self, self.active, self.generation == token else { return }
            switch event {
            case .code: self.showingPIN = true; self.message = "Enter the code displayed by the launcher."
            case .paired(let pin):
                do { try TVPairingStore.save(pin, host: self.host, service: Self.service) }
                catch { self.message = error.localizedDescription; self.busy = false; return }
                if let model { self.connect(model: model) }
            case .disconnected(let message): self.ready = false; self.busy = false; self.message = message
            }
        }
        model.launch(pair ? "tvhome://phone-setup" : "tvhome://phone-edit")
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                identity = try ClientIdentity.loadOrCreate()
                let pin = TVPairingStore.pin(host: host, service: Self.service)
                guard pair || pin != nil else { busy = false; message = "Pair TV Home once using its on-screen code."; return }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try await client.open(host: host, identity: identity!, pin: pin, pair: pair)
                if !pair { try await refresh() }
                if generation == token { busy = false }
            } catch is CancellationError { if generation == token { busy = false } }
            catch { guard generation == token else { return }; ready = false; busy = false; message = "TV editor unavailable. Your draft is safe. \(error.localizedDescription)" }
        }
    }
    func submit(_ code: String) {
        guard let identity else { return }
        do { try client.submit(code: code, identity: identity) } catch { message = error.localizedDescription }
    }
    func refresh() async throws {
        let token = generation
        let result = try await client.request("snapshot", as: LauncherSnapshot.self)
        guard generation == token else { throw CancellationError() }
        try result.validate(); snapshot = result; ready = true; message = "TV editor connected"
    }
    func apply(_ layout: HomeLayout, wallpaper: Data?) async throws {
        try layout.validate()
        guard ready, let snapshot else { throw RemoteFailure.message("Connect the TV editor before applying") }
        guard (wallpaper?.count ?? 0) <= 1_000_000 else { throw RemoteFailure.message("Wallpaper exceeds 1 MB") }
        var payload: [String: Any] = ["expectedRevision":snapshot.revision, "layout":try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout))]
        if let wallpaper { payload["wallpaperJPEG"] = wallpaper.base64EncodedString() }
        let token = generation
        let result = try await client.request("applyLayout", payload: payload, as: LauncherSnapshot.self)
        guard generation == token else { throw CancellationError() }
        try result.validate(); self.snapshot = result; message = "TV Home updated"
    }
    struct Confirmation: Decodable { let status: String }
    func uninstall(_ app: RemoteApp) async throws {
        guard ready, app.installed == true, !app.system, RemoteApp.validPackage(app.id) else { throw RemoteFailure.message("Sync installed apps before uninstalling") }
        let token = generation
        let result = try await client.request("uninstall", payload: ["package":app.id], as: Confirmation.self)
        guard generation == token else { throw CancellationError() }
        guard result.status == "confirmationRequired" else { throw RemoteFailure.message("Unexpected uninstall response. Refresh the app list.") }
        message = "Confirm uninstall on your TV. Refresh afterward to check the result."
    }
    func sleepTimer(minutes: Int) async throws {
        guard ready, (0...240).contains(minutes) else { throw RemoteFailure.message("Connect the TV editor to schedule a sleep timer") }
        let token = generation
        let result = try await client.request("sleepTimer", payload: ["minutes":minutes], as: LauncherSnapshot.self)
        guard generation == token else { throw CancellationError() }
        try result.validate(); snapshot = result
    }
}
