import SwiftUI
import FoundationModels

// The assistant (opt-in, Settings › Remote preferences): say what you want in your own words ("open Netflix and
// search for Dark", "turn it down a bit") and Apple's on-device model does it with the remote's own tools. It runs
// on this iPhone (Apple Intelligence, iOS 26); nothing is sent anywhere. Off by default; the model is loaded only
// while the sheet is open. Vocabulary in Core: AssistantCommands.

enum AssistantSettings {
    static let key = "assistantOn"
    /// The person turned it on in Settings.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Whether this iPhone can run it at all, and if not, why (nil = it can).
    enum Readiness: Equatable { case ready, notEligible, turnOnAppleIntelligence, downloading, needsNewerIOS }
    static var readiness: Readiness {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestAssistant") { return .ready }
        #endif
        guard #available(iOS 26, *) else { return .needsNewerIOS }
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(.deviceNotEligible): return .notEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .turnOnAppleIntelligence
        case .unavailable(.modelNotReady): return .downloading
        case .unavailable: return .notEligible
        }
    }
    /// The header shows the button only when it's on and can run.
    static var showsButton: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestAssistant") { return true }
        #endif
        return isOn && readiness == .ready
    }
}

// MARK: - Tools (what the model may do)

@available(iOS 26, *)
struct PressKeyTool: Tool {
    let remote: RemoteModel
    let name = "pressKey"
    let description = "Presses a button on the TV remote, once or several times: 'ok' selects or confirms, 'down' 3 times moves down three rows, 'volumeDown' 2 times makes it a bit quieter, 'volumeUp' 5 times makes it a lot louder."
    @Generable struct Arguments {
        @Guide(description: "The button.", .anyOf(AssistantCommands.keyNames)) var key: String
        @Guide(description: "How many times to press it.", .range(1...10)) var times: Int
    }
    func call(arguments: Arguments) async throws -> String {
        guard let key = AssistantCommands.key(named: arguments.key) else { return "There is no \(arguments.key) button." }
        let problem = await MainActor.run { () -> String? in
            if !remote.ready { return "The TV isn't connected." }
            if !remote.supports(key) { return "This TV has no \(arguments.key) button." }
            return nil
        }
        if let problem { return problem }
        let times = AssistantCommands.times(arguments.times)
        for i in 0..<times {
            await MainActor.run { remote.tap(key) }
            if i < times - 1 { try? await Task.sleep(for: .milliseconds(180)) }
        }
        return "Pressed \(arguments.key) \(times) time\(times == 1 ? "" : "s")."
    }
}

@available(iOS 26, *)
struct OpenAppTool: Tool {
    let remote: RemoteModel
    let apps: [RemoteApp]
    let name = "openApp"
    let description = "Opens an app on the TV by its name, such as Netflix, YouTube or Prime Video."
    @Generable struct Arguments {
        @Guide(description: "The app's name.") var name: String
    }
    func call(arguments: Arguments) async throws -> String {
        guard await MainActor.run(body: { remote.ready }) else { return "The TV isn't connected." }
        if await MainActor.run(body: { remote.kind }) == .androidTV {
            guard let app = AssistantCommands.app(named: arguments.name, in: apps) else {
                return "No app called \(arguments.name). Apps Purio can open: \(apps.map(\.name).joined(separator: ", "))."
            }
            await MainActor.run { remote.open(app) }
            return "Opened \(app.name)."
        }
        let opened = try await remote.open(named: arguments.name, link: "")
        return opened ? "Opened \(arguments.name)." : "\(arguments.name) isn't on this TV."
    }
}

@available(iOS 26, *)
struct TypeTextTool: Tool {
    let remote: RemoteModel
    let name = "typeText"
    let description = "Types words into a text box on the TV, such as a search box. Only for words to type, never for buttons like select or ok."
    @Generable struct Arguments {
        @Guide(description: "The text to type.") var text: String
    }
    func call(arguments: Arguments) async throws -> String {
        guard await MainActor.run(body: { remote.ready }) else { return "The TV isn't connected." }
        do { try await remote.sendText(String(arguments.text.prefix(200))); return "Typed \"\(arguments.text)\"." }
        catch { return "The TV didn't take the text: \(error.localizedDescription)" }
    }
}

@available(iOS 26, *)
struct WhatsOnTool: Tool {
    let remote: RemoteModel
    let name = "whatsOn"
    let description = "Tells whether the TV is on, which app is on screen, and its volume."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            guard remote.ready else { return "The TV isn't connected." }
            let power = remote.powerOn == false ? "in standby" : "on"
            return "The TV (\(remote.tvName)) is \(power). On screen: \(remote.currentAppName ?? "no app Purio recognises"). \(remote.volume)."
        }
    }
}

@available(iOS 26, *)
struct PowerTool: Tool {
    let remote: RemoteModel
    let name = "power"
    let description = "Turns the TV off (standby) or on."
    @Generable struct Arguments {
        @Guide(description: "on or off.", .anyOf(["on", "off"])) var state: String
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let isOn = remote.ready && remote.powerOn != false
            if arguments.state == "off" {
                guard isOn else { return "The TV is already off." }
                remote.tap(.power); return "Turned the TV off."
            }
            guard !isOn else { return "The TV is already on." }
            remote.power(); return "Turning the TV on."
        }
    }
}

// MARK: - The conversation

@available(iOS 26, *)
@MainActor final class AssistantModel: ObservableObject {
    struct Line: Identifiable, Equatable { let id = UUID(); let mine: Bool; let text: String }
    @Published private(set) var lines: [Line] = []
    @Published private(set) var thinking = false
    private var session: LanguageModelSession?
    private let remote: RemoteModel
    private let apps: [RemoteApp]

    init(remote: RemoteModel, apps: [RemoteApp]) { self.remote = remote; self.apps = apps }

    private func newSession() -> LanguageModelSession {
        let tools: [any Tool] = [PressKeyTool(remote: remote), OpenAppTool(remote: remote, apps: apps), TypeTextTool(remote: remote),
                                 WhatsOnTool(remote: remote), PowerTool(remote: remote)]
        let session = LanguageModelSession(tools: tools, instructions: """
            You are Purio, the remote for the person's TV. Do what they ask on the TV with the tools: press buttons, \
            open apps, type text, check what's on, turn it on or off. Act instead of asking, and use several tools in \
            a row when needed (to search in an app: open it, move to its search, then type). After acting, answer in \
            one short sentence, in the language the person wrote in. If a request isn't about the TV, say in one \
            sentence that you can only control the TV.
            """)
        self.session = session
        return session
    }

    /// Loads the model while the sheet opens, so the first answer comes sooner.
    func prepare() { (session ?? newSession()).prewarm() }
    /// The sheet closed: let the model go.
    func close() { session = nil }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        lines.append(Line(mine: true, text: text))
        thinking = true
        Task {
            defer { thinking = false }
            do {
                let answer = try await (session ?? newSession()).respond(to: text).content
                lines.append(Line(mine: false, text: answer))
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error { session = nil }
                lines.append(Line(mine: false, text: Self.message(for: error)))
            } catch {
                lines.append(Line(mine: false, text: error.localizedDescription))
            }
        }
    }

    static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation, .refusal: String(localized: "I can't help with that. I can only control your TV.")
        case .unsupportedLanguageOrLocale: String(localized: "Apple Intelligence doesn't understand this language yet.")
        case .exceededContextWindowSize: String(localized: "That was a long chat, so I've started a fresh one. Please say it again.")
        case .assetsUnavailable: String(localized: "Apple Intelligence is still getting ready. Try again in a moment.")
        default: error.localizedDescription
        }
    }
}

// MARK: - The sheet

struct AssistantSheet: View {
    @ObservedObject var remote: RemoteModel
    let apps: [RemoteApp]
    var body: some View {
        if #available(iOS 26, *) { AssistantConversation(remote: remote, apps: apps) }
        else { Text("The assistant needs iOS 26.").padding() }
    }
}

@available(iOS 26, *)
private struct AssistantConversation: View {
    @ObservedObject var remote: RemoteModel
    @StateObject private var assistant: AssistantModel
    @State private var text = ""
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    init(remote: RemoteModel, apps: [RemoteApp]) {
        self.remote = remote
        _assistant = StateObject(wrappedValue: AssistantModel(remote: remote, apps: apps))
    }

    private var suggestions: [String] {
        [String(localized: "What's on the TV?"), String(localized: "Open YouTube"), String(localized: "A bit quieter"), String(localized: "Pause")]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if assistant.lines.isEmpty {
                                Text("Say what you'd like the TV to do. It runs on this iPhone; nothing is sent anywhere.")
                                    .font(.system(size: 14)).foregroundStyle(QuietTheme.muted).padding(.vertical, 8)
                                FlowRow(suggestions) { suggestion in
                                    Button { assistant.send(suggestion) } label: {
                                        Text(verbatim: suggestion).font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(QuietTheme.panel, in: Capsule())
                                    }.buttonStyle(.plain)
                                }
                            }
                            ForEach(assistant.lines) { line in
                                Text(verbatim: line.text).font(.system(size: 15))
                                    .padding(.horizontal, 13).padding(.vertical, 9)
                                    .background(line.mine ? QuietTheme.cyan.opacity(0.22) : QuietTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                                    .frame(maxWidth: .infinity, alignment: line.mine ? .trailing : .leading)
                                    .id(line.id)
                            }
                            if assistant.thinking {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(QuietTheme.muted) }
                                    .font(.system(size: 14)).id("thinking")
                            }
                        }.padding(16)
                    }
                    .onChange(of: assistant.lines) { _, lines in withAnimation { proxy.scrollTo(lines.last?.id, anchor: .bottom) } }
                }
                HStack(spacing: 10) {
                    TextField("Ask Purio…", text: $text, axis: .vertical)
                        .lineLimit(1...4).focused($typing).submitLabel(.send)
                        .onSubmit(send)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(QuietTheme.panel, in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityIdentifier("assistantField")
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(QuietTheme.background)
                            .frame(width: 38, height: 38).background(QuietTheme.cyan, in: Circle())
                    }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || assistant.thinking).accessibilityLabel("Send")
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
            .background(QuietTheme.background)
            .navigationTitle("Ask Purio").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .onAppear { assistant.prepare(); typing = true }
        .onDisappear { assistant.close() }
    }

    private func send() { let sent = text; text = ""; assistant.send(sent) }
}

/// Suggestions laid out left to right, wrapping.
private struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) { self.items = items; self.content = content }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(items, id: \.self, content: content) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { ForEach(items.prefix(2), id: \.self, content: content) }
                HStack(spacing: 8) { ForEach(items.dropFirst(2), id: \.self, content: content) }
            }
        }
    }
}

// MARK: - Settings row

/// Settings › Remote preferences: the switch, and why it can't run when it can't. Hidden on iPhones that will never
/// run it (no Apple Intelligence).
struct AssistantSettingRow: View {
    @AppStorage(AssistantSettings.key) private var on = false
    var body: some View {
        let readiness = AssistantSettings.readiness
        if readiness != .notEligible && readiness != .needsNewerIOS {
            Toggle(isOn: $on) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assistant").font(.system(size: 14, weight: .medium))
                    Text("Ask in your own words: “open Netflix”, “a bit quieter”. Runs on this iPhone with Apple Intelligence; nothing is sent anywhere.")
                        .font(.system(size: 12)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
                    if on, readiness == .turnOnAppleIntelligence {
                        Text("Turn on Apple Intelligence in iOS Settings to use it.").font(.system(size: 12)).foregroundStyle(.orange)
                    } else if on, readiness == .downloading {
                        Text("Apple Intelligence is still downloading; the button appears when it's ready.").font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
            }.toggleStyle(QuietToggleStyle()).padding(.horizontal, 13).padding(.vertical, 10)
            .accessibilityIdentifier("assistantToggle")
        }
    }
}
