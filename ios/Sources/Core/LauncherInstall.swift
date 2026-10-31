import Foundation
import CryptoKit

/// The phone-side port of cleanyourtv's launcher/build-and-install.sh: push the bundled launcher, install it, start it,
/// hand Home over and roll back if Home doesn't end up on it. The stock launcher is only disabled once the new one
/// started, and enabled again if the handover fails.

public protocol TVDevice: TVShell {
    func push(_ data: Data, to path: String, mode: UInt32, progress: (@Sendable (Double) -> Void)?) async throws
}
extension AdbClient: TVDevice {}

public struct LauncherOptions: Equatable, Codable {
    /// For remotes whose Home or app buttons need the launcher's key helper (TCL AR11: the app buttons and the volume fix).
    public var homeKeyService = false
    /// The remote's Input button opens the input switcher from any screen.
    public var inputKeyService = false
    /// Puts the key helpers back after a force stop (needs WRITE_SECURE_SETTINGS).
    public var restoreKeyServices = false
    public init(homeKeyService: Bool = false, inputKeyService: Bool = false, restoreKeyServices: Bool = false) {
        self.homeKeyService = homeKeyService; self.inputKeyService = inputKeyService; self.restoreKeyServices = restoreKeyServices
    }
}

public enum LauncherStep: String, CaseIterable {
    case checking = "Checking the TV", pushing = "Sending the Home screen", installing = "Installing", starting = "Starting it"
    case handover = "Making it Home", helpers = "Turning on the remote helpers", theme = "Applying your layout", done = "Done"
}

public struct LauncherInstaller: Sendable {
    public static let package = "com.gathin.tvhome"
    public static let activity = "com.gathin.tvhome/.MainActivity"
    static let minSDK = 26
    static let tmpAPK = "/data/local/tmp/tvhome.apk"
    let tv: TVDevice
    public init(tv: TVDevice) { self.tv = tv }

    /// Which launcher to disable once the new one is Home: the one owning Home now, if it's a known stock launcher.
    /// nil means leave every launcher alone (the new one already owns Home, or Home is something unexpected).
    public func stockLauncher() async throws -> String? {
        let answer = try await tv.run(DebloatRules.homeQuery)
        let home = answer.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let package = String(home.split(separator: "/").first ?? "")
        if package == Self.package { return nil }
        if DebloatRules.stockLaunchers.contains(package) { return package }
        if package == "android" {   // the chooser: take the one known stock launcher among the claimants, if exactly one
            let claimants = Set(DebloatRules.components(try await tv.run(DebloatRules.claimQuery)).map { String($0.split(separator: "/").first ?? "") })
            let known = DebloatRules.stockLaunchers.filter(claimants.contains)
            if known.count == 1 { return known[0] }
            throw RemoteFailure.message("Home has no default and \(known.count) stock launchers claim it. Pick a default Home on the TV first.")
        }
        if package == "com.google.android.tungsten.setupwraith" {
            throw RemoteFailure.message("Home belongs to Google TV's setup wizard. Finish the TV's setup, or include the setup wizard in the debloat, then try again.")
        }
        throw RemoteFailure.message("Home currently belongs to \(package.isEmpty ? "nothing" : package), which isn't a stock launcher this app knows. Nothing was changed.")
    }

    public func install(apk: Data, options: LauncherOptions, theme: Data? = nil,
                        step: (@Sendable (LauncherStep, Double) -> Void)? = nil) async throws -> String {
        step?(.checking, 0)
        let sdk = Int(try await tv.run("getprop ro.build.version.sdk").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard sdk >= Self.minSDK else { throw RemoteFailure.message("This TV runs Android SDK \(sdk); the new Home screen needs Android 8.0 (SDK 26) or newer. Nothing was changed.") }
        let stock = try await stockLauncher()

        step?(.pushing, 0)
        try await tv.push(apk, to: Self.tmpAPK, mode: 0o644) { step?(.pushing, $0) }
        let md5 = Insecure.MD5.hash(data: apk).map { String(format: "%02x", $0) }.joined()
        let remote = try await tv.run("md5sum \(Self.tmpAPK) 2>/dev/null || toybox md5sum \(Self.tmpAPK)")
        if let sum = remote.split(separator: " ").first, sum.count == 32, String(sum) != md5 {
            _ = try? await tv.run("rm -f \(Self.tmpAPK)")
            throw RemoteFailure.message("The Home screen arrived damaged on the TV (checksum mismatch). Nothing was installed; try again.")
        }

        step?(.installing, 0)
        let out = try await tv.run("pm install -r \(Self.tmpAPK); rm -f \(Self.tmpAPK)", timeout: 300)
        if out.contains("INSTALL_FAILED_OLDER_SDK") { throw RemoteFailure.message("The TV refused the Home screen as too new for its Android version. Nothing else was changed.") }
        if out.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            throw RemoteFailure.message("A different build of this Home screen is already on the TV, signed with another key. Uninstall it on the TV first, then try again.")
        }
        guard out.contains("Success") else { throw RemoteFailure.message("The TV refused to install the Home screen: \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }

        _ = try await tv.run(Self.restartWithHelpers)

        step?(.starting, 0)
        let start = try await tv.run(stock == nil ? "am start -W -n \(Self.activity)"
                                                  : "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME -n \(Self.activity)")
        guard start.contains("Status: ok"), !start.split(separator: "\n").contains(where: { $0.lowercased().hasPrefix("error") }) else {
            throw RemoteFailure.message("The new Home screen didn't start, so the stock one was left as it was.")
        }

        step?(.handover, 0)
        _ = try await tv.run("pm grant \(Self.package) android.permission.ACCESS_FINE_LOCATION 2>/dev/null; echo location-granted")
        _ = try await tv.run("cmd package compile -m speed -f \(Self.package)", timeout: 300)
        if let stock { _ = try await tv.run("pm disable-user --user 0 \(stock)") }
        _ = try await tv.run("cmd package set-home-activity --user 0 \(Self.activity)")
        let home = try await tv.run(DebloatRules.homeQuery).split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard home.hasPrefix(Self.package + "/") else {
            if let stock { try await rollback(stock) }
            throw RemoteFailure.message(home.isEmpty
                ? "The TV stopped answering while Home was being switched. The stock Home screen was put back."
                : "Home went to \(home) instead of the new Home screen, so the stock one was put back. On Google TV this usually means the setup wizard also claims Home: include it in the debloat, then try again.")
        }

        step?(.helpers, 0)
        if options.inputKeyService { _ = try await tv.run(Self.enableService("InputKeyService")) }
        if options.homeKeyService { _ = try await tv.run(Self.enableService("HomeKeyService")) }
        if options.restoreKeyServices { _ = try await tv.run("pm grant \(Self.package) android.permission.WRITE_SECURE_SETTINGS && echo restore-granted") }

        if let theme {
            step?(.theme, 0)
            try await applyTheme(theme)
        }
        step?(.done, 1)
        return home
    }

    /// Appends a key helper to the enabled accessibility services without dropping the user's others (enable_service).
    static func enableService(_ name: String) -> String {
        let svc = "\(package)/.\(name)"
        return "cmd appops set \(package) AUTO_START allow 2>/dev/null; cmd appops set \(package) APP_AUTO_START allow 2>/dev/null; appops write-settings 2>/dev/null; s=$(settings get secure enabled_accessibility_services); case \"$s\" in *\(name)*) settings put secure enabled_accessibility_services ''; settings put secure accessibility_enabled 0; sleep 1; settings put secure enabled_accessibility_services \"$s\" ;; null|'') settings put secure enabled_accessibility_services \(svc) ;; *) settings put secure enabled_accessibility_services \"$s:\(svc)\" ;; esac; settings put secure accessibility_enabled 1; echo \(name) enabled"
    }

    /// Force-stops the launcher and re-binds the key helpers it had, keeping the user's other accessibility services.
    static let restartWithHelpers = "s=$(settings get secure enabled_accessibility_services); a=$(settings get secure accessibility_enabled); am force-stop \(package); case \"$s\" in *\(package)*) settings put secure enabled_accessibility_services \"\"; settings put secure enabled_accessibility_services \"$s\"; settings put secure accessibility_enabled \"$a\" ;; esac"

    func rollback(_ stock: String) async throws {
        _ = try? await tv.run("pm enable --user 0 \(stock)")
        _ = try? await tv.run("cmd package set-home-activity --user 0 $(\(DebloatRules.homeQuery) \(stock) | tail -n 1)")
    }

    /// Writes the launcher's config.json through its ThemeProvider (the shell may not reach Android/data on TCL) and restarts Home.
    public func applyTheme(_ config: Data) async throws {
        guard (try? JSONSerialization.jsonObject(with: config)) is [String: Any] else { throw RemoteFailure.message("Invalid Home layout") }
        let tmp = "/data/local/tmp/tvhome-config.json"
        try await tv.push(config, to: tmp, mode: 0o644, progress: nil)
        // Through the provider first (TCL locks the shell out of Android/data), else a plain copy, as theme.sh does.
        let dir = "/sdcard/Android/data/\(Self.package)/files"
        let out = try await tv.run("{ o=$(content write --uri content://\(Self.package).theme/config.json < \(tmp) 2>&1) && case \"$o\" in *'Unsupported operation'*|*'Error while accessing provider'*) false ;; esac; } || { mkdir -p \(dir) && cp \(tmp) \(dir)/config.json; }; rc=$?; rm -f \(tmp); echo theme-rc=$rc")
        guard out.contains("theme-rc=0") else { throw RemoteFailure.message("The TV refused the Home layout: \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
        _ = try await tv.run(Self.restartWithHelpers + "; am start -a android.intent.action.MAIN -c android.intent.category.HOME")
    }
}
