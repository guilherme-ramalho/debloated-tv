import Foundation

/// The phone-side port of cleanyourtv's tools/disable.sh, tools/restore.sh and tools/recovery.py: the same list
/// format, the same safety guards and the same recovery record, so a TV cleaned from the iPhone can be undone the
/// way upstream undoes it. Packages are only ever disabled for user 0, never uninstalled.

public protocol TVShell: Sendable {
    func shell(_ command: String, timeout: Double) async throws -> AdbClient.ShellResult
}
extension AdbClient: TVShell {}
extension TVShell {
    func run(_ command: String, timeout: Double = 120) async throws -> String {
        try await shell(command, timeout: timeout).output.replacingOccurrences(of: "\r", with: "")
    }
}

enum Pattern {
    static func matches(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static let package = "^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$"
    static func isPackage(_ s: String) -> Bool { matches(package, s) }
    static func packageNames(_ answer: String) -> Set<String> {
        Set(answer.split(separator: "\n").compactMap { line in
            line.hasPrefix("package:") ? String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) : nil
        })
    }
}

// MARK: - Lists

/// An upstream debloat.txt: one package per line, # comments, groups headed "# 1. Title" / "# 1b. Title".
public struct DebloatList: Equatable {
    public struct Entry: Equatable, Identifiable {
        public var id: String { package }
        public let package: String
        public let group: String
        public let note: String
    }
    public let header: [String]
    public let entries: [Entry]
    /// Packages the list's header names under "Never disable:"; the app never offers them.
    public let neverDisable: Set<String>
    public var groups: [String] { entries.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } } }

    public static func parse(_ text: String) throws -> DebloatList {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        var header = [String](), entries = [Entry](), group = "Other", seenGroup = false
        var bad = [String]()
        for raw in body.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let comment = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if let title = groupTitle(comment) { group = title; seenGroup = true }
                else if !seenGroup && entries.isEmpty { header.append(comment) }
                continue
            }
            var package = line, note = ""
            if let hash = line.range(of: "#"), line[..<hash.lowerBound].last?.isWhitespace == true {
                package = line[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
                note = line[hash.upperBound...].trimmingCharacters(in: .whitespaces)
            }
            package = package.split(separator: " ").first.map(String.init) ?? package
            guard Pattern.isPackage(package) else { bad.append(package); continue }
            if !entries.contains(where: { $0.package == package }) { entries.append(Entry(package: package, group: group, note: note)) }
        }
        guard bad.isEmpty else { throw RemoteFailure.message("This list has lines that are not package names: \(bad.joined(separator: ", "))") }
        return DebloatList(header: header, entries: entries, neverDisable: neverDisable(header))
    }

    static func groupTitle(_ comment: String) -> String? {
        guard Pattern.matches("^[0-9]+[a-z]?\\. ", comment) else { return nil }
        return String(comment.drop { $0 != " " }.dropFirst())
    }

    static func neverDisable(_ header: [String]) -> Set<String> {
        var out = Set<String>(), inside = false
        for line in header {
            if let range = line.range(of: "Never disable:") {
                inside = true
                out.formUnion(tokens(String(line[range.upperBound...])))
                continue
            }
            // Another "Label:" line ends the never-disable run.
            if inside && Pattern.matches("^[A-Z][A-Za-z /()-]{2,40}:", line) { inside = false }
            if inside { out.formUnion(tokens(line)) }
        }
        return out
    }
    private static func tokens(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "()")) }.filter(Pattern.isPackage))
    }
}

// MARK: - Rules shared with upstream

public enum DebloatRules {
    /// Core Android and TV middleware: with one of these off the TV may not boot again (#884, #1578). Never overridable.
    // Same as upstream CORE_RE (tools/disable.sh, at f5c37c36): location.fused boot-looped a TCL 43S5400A (#2803).
    static let core = "^(android|android\\.ext\\.(services|shared)|com\\.android\\.sdksandbox|com\\.android\\.location\\.fused|com\\.android\\.systemui|com\\.android\\.shell|com\\.android\\.phone|com\\.android\\.settings|com\\.android\\.tv\\.settings|com\\.(google\\.)?android\\.(permissioncontroller|packageinstaller|ext\\.services|ext\\.shared|modulemetadata)|com\\.google\\.android\\.overlay\\.modules.*|com\\.android\\.providers\\..*|com\\.cltv\\.mal|com\\.mediatek\\.(tis|tv\\.service|tv\\.agent))$"
    static let coreOK = "^com\\.android\\.providers\\.(calendar|contacts|userdictionary|blockednumber)$"
    public static func isCore(_ p: String) -> Bool { Pattern.matches(core, p) && !Pattern.matches(coreOK, p) }
    public static let setupwraith = "com.google.android.tungsten.setupwraith"
    public static let customLauncher = "com.gathin.tvhome"
    public static let stockLaunchers = ["com.google.android.tvlauncher", "com.google.android.apps.tv.launcherx",
                                        "com.google.android.leanbacklauncher", "com.mitv.tvhome"]
    static let notLaunchers: Set<String> = [setupwraith, "com.android.tv.settings", "com.android.settings", "com.android.provision"]
    public static let animationSettings = ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]
    static let homeQuery = "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
    static let claimQuery = "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME"

    static func isChooser(_ home: String?) -> Bool {
        guard let home else { return false }
        return !Pattern.isPackage(String(home.split(separator: "/").first ?? ""))
    }
    static func notALauncher(_ home: String?) -> Bool {
        guard let home else { return false }
        let package = String(home.split(separator: "/").first ?? "")
        return notLaunchers.contains(package) || Pattern.matches("/\\S*FallbackHome$", home)
            || Pattern.matches("factorytest|factory_test|factorymode", package, caseInsensitive: true)
    }
    /// Packages among HOME claims that are real launchers (not the setup wizard, settings, FallbackHome or factory test).
    static func launchers(in claims: [String]) -> Set<String> {
        Set(claims.filter { !Pattern.matches("/[^ ]*FallbackHome$", $0) }
            .map { String($0.split(separator: "/").first ?? "") }
            .filter { !Pattern.matches("factorytest|factory_test|factorymode", $0, caseInsensitive: true) && !notLaunchers.contains($0) })
    }
    /// Components at the start of each line, as disable.sh's grep -o '^ *pkg/cls' reads them.
    static func components(_ answer: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "^ *([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)") else { return [] }
        return answer.split(separator: "\n").compactMap { line -> String? in
            let text = String(line)
            guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }
}

// MARK: - What the TV has

public struct TVInventory: Equatable {
    public var properties: [String: String]
    public var installed: Set<String>
    public var disabled: Set<String>
    /// Whether answers came for user 0 (Android 14 merges every user without --user 0).
    public var userScoped: Bool
    public var home: String?
    public var animationScales: [String: String]
    public var adbSecure: String
}

/// Why a package stays enabled even though it was chosen.
public struct DebloatSkip: Equatable, Identifiable {
    public var id: String { package }
    public let package: String
    public let reason: String
}

public struct DebloatPlan: Equatable {
    public var disable: [String]
    public var skipped: [DebloatSkip]
    public var notes: [String]
}

/// Upstream's per-run overrides, off by default. Each is offered only with the explanation of what it bypasses.
public struct DebloatOverrides: Equatable {
    public var setupwraithOnEthernet = false
    public var home = false
    public init() {}
}

/// The state needed to put the TV back: tools/recovery.py's record, version 1, as JSON.
public struct RecoveryRecord: Codable, Equatable {
    public var version = 1
    public var created: String
    public var host: String
    public var list: String
    public var home: String?
    public var settings: [String: String]
    public var packages: [String: String]   // "enabled" | "disabled" | "absent", before cleanup
}

public struct ApplyResult: Equatable {
    public var disabled: [String]
    public var stillEnabled: [String]
    public var stoppedEarly: Bool
}

// MARK: - Engine

public struct Debloater: Sendable {
    let tv: TVShell
    public init(tv: TVShell) { self.tv = tv }

    public func inspect(properties: [String: String] = [:]) async throws -> TVInventory {
        var props = properties
        for key in ["ro.product.model", "ro.product.device", "ro.product.name", "ro.product.manufacturer", "ro.build.id",
                    "ro.build.display.id", "ro.build.version.sdk", "ro.build.version.release"] where props[key] == nil {
            props[key] = try await tv.run("getprop " + key).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var scoped = true
        var installed = Pattern.packageNames(try await tv.run("pm list packages --user 0"))
        if installed.isEmpty { scoped = false; installed = Pattern.packageNames(try await tv.run("pm list packages")) }
        guard !installed.isEmpty else { throw RemoteFailure.message("The TV listed no apps, so nothing was changed. Check the connection and try again.") }
        let disabled = Pattern.packageNames(try await tv.run("pm list packages -d" + (scoped ? " --user 0" : "")))
        let answer = try await tv.run(DebloatRules.homeQuery)
        let candidate = answer.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let home = Pattern.matches("^[A-Za-z_][\\w.]*/[\\w.$]+$", candidate) ? candidate : nil
        var scales = [String: String]()
        for key in DebloatRules.animationSettings { scales[key] = try await tv.run("settings get global " + key).trimmingCharacters(in: .whitespacesAndNewlines) }
        let secure = (try? await tv.run("getprop ro.adb.secure").trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unread"
        return TVInventory(properties: props, installed: installed, disabled: disabled, userScoped: scoped, home: home, animationScales: scales, adbSecure: secure)
    }

    /// The guards from disable.sh, in its order. `chosen` is what the user agreed to disable.
    public func plan(_ chosen: [String], list: DebloatList, inventory: TVInventory, overrides: DebloatOverrides = .init()) async throws -> DebloatPlan {
        var pkgs = chosen.filter { inventory.installed.contains($0) && !inventory.disabled.contains($0) }
        var skipped = [DebloatSkip](), notes = [String]()
        func drop(_ p: String, _ reason: String) {
            guard let i = pkgs.firstIndex(of: p) else { return }
            pkgs.remove(at: i); skipped.append(DebloatSkip(package: p, reason: reason))
        }
        for p in pkgs where !Pattern.isPackage(p) { drop(p, "Not a package name.") }
        for p in pkgs where DebloatRules.isCore(p) {
            drop(p, "Core Android or TV middleware: with it disabled the TV may not boot again. This can't be overridden.")
        }
        for p in pkgs where list.neverDisable.contains(p) { drop(p, "This TV's tested list says never to disable it.") }

        // Wi-Fi saved during setup belongs to setupwraith; disabling it deletes the network (and this connection).
        if pkgs.contains(DebloatRules.setupwraith) && !overrides.setupwraithOnEthernet {
            let wifi = (try? await tv.run("dumpsys wifi")) ?? ""
            let owners = wifi.components(separatedBy: .whitespacesAndNewlines).filter { $0.hasPrefix("cname=") }
            if owners.isEmpty {
                drop(DebloatRules.setupwraith, "Couldn't check which app owns the saved Wi-Fi networks. If the TV uses Ethernet, you can allow it.")
            } else if owners.contains(where: { $0.contains("setupwraith") }) {
                drop(DebloatRules.setupwraith, "The TV's Wi-Fi network belongs to the setup wizard, and disabling it would delete that network and take the TV offline. On the TV, forget the network and join it again in Settings › Network & Internet, then run this again.")
            }
        }

        // Home guard (#239): never leave the TV with nothing to start when Home is pressed.
        if !overrides.home && !pkgs.isEmpty {
            var homePackage = inventory.home.map { String($0.split(separator: "/").first ?? "") }
            if let h = homePackage, !Pattern.isPackage(h) { homePackage = nil }
            if homePackage == nil {
                let activity = (try? await tv.run("dumpsys activity")) ?? ""
                if let match = activity.split(separator: "\n").first(where: { $0.contains("mHomeProcess:") }),
                   let re = try? NSRegularExpression(pattern: "[: ]([A-Za-z0-9_.]+)/[A-Za-z0-9_.]+"),
                   let m = re.firstMatch(in: String(match), range: NSRange(match.startIndex..., in: match)),
                   let r = Range(m.range(at: 1), in: match) {
                    let p = String(match[r]); if Pattern.isPackage(p) { homePackage = p }
                }
            }
            let claims = DebloatRules.components((try? await tv.run(DebloatRules.claimQuery)) ?? "")
            let launchers = DebloatRules.launchers(in: claims)
            if let home = homePackage {
                if pkgs.contains(home) {
                    let others = launchers.subtracting([home]).subtracting(pkgs)
                    let setupAnswersHome = claims.contains { $0.hasPrefix(DebloatRules.setupwraith + "/") } && !pkgs.contains(DebloatRules.setupwraith)
                    if others.isEmpty {
                        drop(home, "It owns Home and nothing else that can answer Home stays enabled. Install the new Home screen first; it's disabled afterwards.")
                    } else if setupAnswersHome {
                        drop(home, "It owns Home, and the setup wizard stays enabled and would take Home instead, a black screen the TV can crash-loop on. Install the new Home screen first.")
                    }
                }
            } else if !claims.isEmpty {
                let listed = launchers.intersection(pkgs)
                if !listed.isEmpty && launchers.subtracting(pkgs).isEmpty {
                    for p in listed { drop(p, "Home has no default, and no other app could answer Home. Install the new Home screen first.") }
                }
                notes.append("Home has no default on this TV, so the Home check went by the apps that answer Home.")
            } else {
                for p in DebloatRules.stockLaunchers where pkgs.contains(p) {
                    drop(p, "Couldn't ask the TV which apps answer Home, and this is a stock launcher.")
                }
            }
        }

        // HDMI/AV/tuner drivers (#321): with one off, the inputs stay black and only a full restore fixes it.
        if !pkgs.isEmpty {
            let names = pkgs.joined(separator: " ")
            let command = "s=$(getprop ro.build.version.sdk); for p in \(names); do d=$(dumpsys package $p 2>/dev/null); case $d in *'requested permissions:'*) printf '%s\\n' \"$d\" | sed -n -E '/requested permissions:/,/(install|runtime) permissions:|User [0-9]+:/p' | grep -q TV_INPUT_HARDWARE && echo $p;; *'grantedPermissions:'*) printf '%s\\n' \"$d\" | sed -n -E '/grantedPermissions:/,/(install|runtime) permissions:|User [0-9]+:/p' | grep -q TV_INPUT_HARDWARE && echo $p;; *'Service Resolver Table:'*) printf '%s\\n' \"$d\" | grep -q 'android.media.tv.TvInputService' && echo $p;; *'Unable to find'*) :;; *'hung system process'*) echo \"HUNG $p\";; *\"Package [$p]\"*) [ \"${s:-0}\" -ge 23 ] 2>/dev/null || echo \"NOCHK $p\";; *) echo \"NOCHK $p\";; esac; done; true"
            if let answer = try? await tv.run(command, timeout: 300) {
                for line in answer.split(separator: "\n").map(String.init) {
                    if line.hasPrefix("HUNG ") { drop(String(line.dropFirst(5)), "The TV's system diagnostics are switched off after a hang, so the input-driver check can't read it. Restart the TV and try again.") }
                    else if line.hasPrefix("NOCHK ") { drop(String(line.dropFirst(6)), "This firmware doesn't show its permissions, so the input-driver check can't read it. It stays enabled to be safe.") }
                    else if Pattern.isPackage(line) { drop(line, "It drives the HDMI, AV or tuner inputs. Disabled, they notice the cable but stay black, and only a full restore fixes it.") }
                }
            } else {
                notes.append("Couldn't check which apps drive the HDMI inputs. After applying, open every input before putting the remote down.")
            }
        }

        // Apps that open the inputs or Settings: the way back to Developer options goes through Settings.
        if !pkgs.isEmpty {
            let q = "cmd package query-activities --brief"
            if let answer = try? await tv.run("\(q) -a android.intent.action.VIEW -t vnd.android.cursor.item/channel 2>/dev/null; echo ==; \(q) -a android.settings.SETTINGS 2>/dev/null; true") {
                let parts = answer.components(separatedBy: "\n==\n")
                func names(_ s: String) -> Set<String> {
                    Set(s.split(separator: "\n").compactMap { line -> String? in
                        let first = line.trimmingCharacters(in: .whitespaces).split(separator: "/").first.map(String.init) ?? ""
                        return line.contains("/") && Pattern.isPackage(first) ? first : nil
                    })
                }
                let inputApps = names(parts.first ?? ""), settingsApps = names(parts.count > 1 ? parts[1] : "")
                if settingsApps.isEmpty { notes.append("Couldn't check which apps open the inputs and Settings. After applying, open an HDMI input and Settings from Home.") }
                for p in inputApps { drop(p, "The TV opens its inputs and channels with it; disabled, the input tiles do nothing.") }
                for p in settingsApps { drop(p, "The TV opens Settings with it; disabled, Settings (and the way back to Developer options) won't open.") }
            } else {
                notes.append("Couldn't check which apps open the inputs and Settings. After applying, open an HDMI input and Settings from Home.")
            }
        }
        if inventory.adbSecure == "0" || inventory.adbSecure.isEmpty {
            notes.append("This TV lets any device on your network use its debugging port without asking. Turn debugging off when you're done.")
        }
        return DebloatPlan(disable: pkgs, skipped: skipped, notes: notes)
    }

    /// The record of how things were before the first run (recovery.py save). An existing record is extended, never overwritten.
    public func record(_ list: DebloatList, listName: String, host: String, inventory: TVInventory, existing: RecoveryRecord?) -> RecoveryRecord {
        func state(_ p: String) -> String { !inventory.installed.contains(p) ? "absent" : inventory.disabled.contains(p) ? "disabled" : "enabled" }
        let names = list.entries.map(\.package)
        if var record = existing {
            for p in names where record.packages[p] == nil { record.packages[p] = state(p) }
            for p in names where record.packages[p] == "absent" && state(p) == "enabled" { record.packages[p] = "enabled" }
            return record
        }
        var home = inventory.home
        if DebloatRules.isChooser(home) { home = nil }
        let homePackage = home.map { String($0.split(separator: "/").first ?? "") }
        var targets = names
        if let hp = homePackage, !targets.contains(hp) { targets.append(hp) }
        targets += DebloatRules.stockLaunchers.filter { inventory.installed.contains($0) && !targets.contains($0) }
        if DebloatRules.notALauncher(home) { home = nil }
        let formatter = ISO8601DateFormatter()
        return RecoveryRecord(created: formatter.string(from: Date()), host: host, list: listName, home: home,
                              settings: inventory.animationScales, packages: Dictionary(uniqueKeysWithValues: targets.map { ($0, state($0)) }))
    }

    /// Disables the plan's packages one by one, then reads the TV back instead of trusting silence (#1376).
    public func apply(_ plan: DebloatPlan, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ApplyResult {
        var stoppedEarly = false
        for (i, p) in plan.disable.enumerated() {
            do { _ = try await tv.shell("pm disable-user --user 0 " + p, timeout: 60) }
            catch { stoppedEarly = true; break }
            progress?(i + 1, plan.disable.count)
        }
        let enabled = Pattern.packageNames(try await tv.run("pm list packages -e --user 0"))
        let still = plan.disable.filter { enabled.contains($0) }
        return ApplyResult(disabled: plan.disable.filter { !enabled.contains($0) }, stillEnabled: still, stoppedEarly: stoppedEarly)
    }

    /// recovery.py restore_commands: put recorded states back, Home, and animation scales.
    public static func restoreCommands(_ record: RecoveryRecord, stock: String = "com.google.android.tvlauncher") -> [String] {
        var commands = record.packages.filter { $0.value == "enabled" }.keys.sorted().map { "pm enable \($0)" }
        let fallbackState = record.packages[stock]
        let resolve = "cmd package set-home-activity --user 0 $(\(DebloatRules.homeQuery) \(stock) | tail -n 1)"
        if let home = record.home, String(home.split(separator: "/").first ?? "") != DebloatRules.customLauncher {
            commands.append("cmd package set-home-activity --user 0 \(home)")
        } else if let home = record.home, fallbackState != "enabled" {
            commands.append("cmd package set-home-activity --user 0 \(home)")
        } else if record.home == nil, fallbackState == "disabled" || fallbackState == "absent" {
            // leave Home alone: none recorded and the stock launcher was not on before
        } else {
            commands.append(resolve)
        }
        for key in DebloatRules.animationSettings {
            let value = (record.settings[key] ?? "").trimmingCharacters(in: .whitespaces)
            if value == "null" { commands.append("settings delete global \(key)") }
            else if Pattern.matches("^-?[0-9]+(\\.[0-9]+)?$", value) { commands.append("settings put global \(key) \(value)") }
        }
        return commands
    }

    public func restore(_ record: RecoveryRecord, stock: String = "com.google.android.tvlauncher") async throws -> [String] {
        for command in Self.restoreCommands(record, stock: stock) { _ = try await tv.shell(command, timeout: 60) }
        return Array(Pattern.packageNames(try await tv.run("pm list packages -d --user 0"))).sorted()
    }
}
