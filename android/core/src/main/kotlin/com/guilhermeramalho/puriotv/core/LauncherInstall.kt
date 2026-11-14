package com.guilhermeramalho.puriotv.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.security.MessageDigest

/*
 * The phone-side port of cleanyourtv's launcher/build-and-install.sh (LauncherInstall.swift): push the bundled
 * launcher, install it, start it, hand Home over and roll back if Home doesn't end up on it. The stock launcher is only
 * disabled once the new one started, and enabled again if the handover fails.
 */

/** A profile's launcher options; every key is optional in a profile.json. */
@Serializable
data class LauncherOptions(
    /** For remotes whose Home or app buttons need the launcher's key helper (TCL AR11: the app buttons and the volume fix). */
    val homeKeyService: Boolean = false,
    /** The remote's Input button opens the input switcher from any screen. */
    val inputKeyService: Boolean = false,
    /** Puts the key helpers back after a force stop (needs WRITE_SECURE_SETTINGS). */
    val restoreKeyServices: Boolean = false,
    /**
     * The TV's list installed the launcher with STOCK_LAUNCHER=none: the stock launcher stays enabled (some firmware
     * leaves a black Home or blocks the remote's app buttons without it). The new one is still made Home.
     */
    val keepStockLauncher: Boolean = false,
)

/** The install's steps, in order; [english] is the iPhone app's title (the app shows its own translation). */
enum class LauncherStep(val english: String) {
    CHECKING("Checking the TV"), PUSHING("Sending the Home screen"), INSTALLING("Installing"), STARTING("Starting it"),
    HANDOVER("Making it Home"), HELPERS("Turning on the remote helpers"), THEME("Applying your layout"), DONE("Done"),
}

/**
 * Which launcher build the TV runs against the one this app carries, to offer "Update Home screen" only when the
 * app's is newer. The TV reports its versionCode in the editor snapshot (home.version); the app's comes from
 * Launcher/tvhome.json, which scripts/bundle-launcher.sh writes from the APK itself.
 */
object LauncherVersion {
    /** What a launcher that doesn't report its version is: the build app 1.0 shipped (versionCode 12). */
    const val UNREPORTED = 12

    fun onTV(snapshot: LauncherSnapshot): Int = snapshot.home?.version ?: UNREPORTED

    /** The bundled APK's versionCode from tvhome.json ({"versionCode": 13}); null if missing or unreadable. */
    fun bundled(json: ByteArray?): Int? {
        if (json == null) return null
        return try {
            val code = (Json.parseToJsonElement(json.decodeToString()) as? JsonObject)?.get("versionCode")?.jsonPrimitive?.intOrNull
            code?.takeIf { it > 0 }
        } catch (e: Exception) { null }
    }

    /** Only a strictly newer bundled build is offered; an unknown bundled version never is. */
    fun updateAvailable(tv: Int, bundled: Int?): Boolean = bundled?.let { it > tv } ?: false

    /** The versionCode in `dumpsys package` output ("versionCode=12 minSdk=26 targetSdk=34"); null if absent. */
    fun fromDumpsys(output: String): Int? {
        val at = output.indexOf("versionCode=")
        if (at < 0) return null
        return output.substring(at + 12).takeWhile { it.isDigit() }.toIntOrNull()
    }
}

class LauncherInstaller(private val tv: TVDevice) {
    companion object {
        const val PACKAGE = "com.gathin.tvhome"
        const val ACTIVITY = "com.gathin.tvhome/.MainActivity"
        const val MIN_SDK = 26
        const val TMP_APK = "/data/local/tmp/tvhome.apk"

        /** Appends a key helper to the enabled accessibility services without dropping the user's others (enable_service). */
        fun enableService(name: String): String {
            val svc = "$PACKAGE/.$name"
            return "cmd appops set $PACKAGE AUTO_START allow 2>/dev/null; cmd appops set $PACKAGE APP_AUTO_START allow 2>/dev/null; appops write-settings 2>/dev/null; " +
                "s=\$(settings get secure enabled_accessibility_services); case \"\$s\" in *$name*) settings put secure enabled_accessibility_services ''; " +
                "settings put secure accessibility_enabled 0; sleep 1; settings put secure enabled_accessibility_services \"\$s\" ;; " +
                "null|'') settings put secure enabled_accessibility_services $svc ;; *) settings put secure enabled_accessibility_services \"\$s:$svc\" ;; esac; " +
                "settings put secure accessibility_enabled 1; echo $name enabled"
        }

        /** Force-stops the launcher and re-binds the key helpers it had, keeping the user's other accessibility services. */
        const val RESTART_WITH_HELPERS = "s=\$(settings get secure enabled_accessibility_services); a=\$(settings get secure accessibility_enabled); " +
            "am force-stop $PACKAGE; case \"\$s\" in *$PACKAGE*) settings put secure enabled_accessibility_services \"\"; " +
            "settings put secure enabled_accessibility_services \"\$s\"; settings put secure accessibility_enabled \"\$a\" ;; esac"

        /**
         * WRITE_SECURE_SETTINGS follows the profile on every install, as upstream's build-and-install.sh does (#2458):
         * `pm install -r` keeps an earlier grant, so an install that doesn't ask for it takes it back. The TV prints the
         * marker only once dumpsys shows the state asked for; a dumpsys that timed out or doesn't list it prints nothing.
         */
        fun secureSettingsStep(grant: Boolean): String {
            val secure = "android.permission.WRITE_SECURE_SETTINGS"
            val read = "s=\$(dumpsys package $PACKAGE) && case \"\$s\" in *\"DUMP TIMEOUT\"*) ;; *\"$secure: granted=true\"*)"
            return if (grant) "pm grant $PACKAGE $secure && $read echo restore-granted ;; esac"
            else "pm revoke $PACKAGE $secure; $read ;; *\"$secure\"*) echo secure-settings-revoked ;; esac"
        }

        /** Only a line that is the marker and nothing else counts. */
        fun secureSettingsDone(output: String, grant: Boolean): Boolean {
            val marker = if (grant) "restore-granted" else "secure-settings-revoked"
            return output.lines().any { it.trim() == marker }
        }

        internal fun md5(data: ByteArray) = MessageDigest.getInstance("MD5").digest(data).joinToString("") { "%02x".format(it) }
    }

    /**
     * Which launcher to disable once the new one is Home: the one owning Home now, if it's a known stock launcher or
     * the one the TV's own list names ([listed], a vendor launcher such as com.xgimi.home). null means leave every
     * launcher alone (the new one already owns Home). Anything unexpected throws before a change.
     */
    suspend fun stockLauncher(listed: String? = null): String? {
        val known = DebloatRules.stockLaunchers + listOfNotNull(listed).filter(Pattern::isPackage)
        val pkg = packageOf(lastLine(tv.exec(DebloatRules.HOME_QUERY)))
        if (pkg == PACKAGE) return null
        if (pkg in known) return pkg
        if (pkg == "android") {   // the chooser: take the one known stock launcher among the claimants, if exactly one
            val claimants = DebloatRules.components(tv.exec(DebloatRules.CLAIM_QUERY)).map(::packageOf).toSet()
            val present = known.filter { it in claimants }
            if (present.size == 1) return present[0]
            throw SetupFailure(SetupIssue.HOME_CHOOSER_AMBIGUOUS, present.size.toString())
        }
        if (pkg == DebloatRules.SETUPWRAITH) throw SetupFailure(SetupIssue.HOME_SETUP_WIZARD)
        throw SetupFailure(SetupIssue.HOME_UNKNOWN, pkg.ifEmpty { "nothing" })
    }

    /** The installed launcher's versionCode, read over ADB; null when it isn't installed. */
    suspend fun installedVersion(): Int? =
        LauncherVersion.fromDumpsys(tv.exec("dumpsys package $PACKAGE | grep -m 1 versionCode="))

    /**
     * Installs [apk] and makes it Home. [theme]: config.json to apply (null keeps the TV's layout, as an update does).
     * [step] reports each step and its fraction. Returns the Home component the TV resolves afterwards.
     */
    suspend fun install(apk: ByteArray, options: LauncherOptions, theme: ByteArray? = null, listedStock: String? = null,
                        step: ((LauncherStep, Double) -> Unit)? = null): String {
        step?.invoke(LauncherStep.CHECKING, 0.0)
        val sdk = tv.exec("getprop ro.build.version.sdk").trim().toIntOrNull() ?: 0
        if (sdk < MIN_SDK) throw SetupFailure(SetupIssue.OLD_ANDROID, sdk.toString())
        // As build-and-install.sh with STOCK_LAUNCHER=none: nothing is disabled, so whatever owns Home now stays.
        val stock = if (options.keepStockLauncher) null else stockLauncher(listedStock)

        step?.invoke(LauncherStep.PUSHING, 0.0)
        tv.push(apk, TMP_APK, 420) { step?.invoke(LauncherStep.PUSHING, it) }
        val remote = tv.exec("md5sum $TMP_APK 2>/dev/null || toybox md5sum $TMP_APK")
        val sum = remote.split(" ").firstOrNull { it.isNotEmpty() }
        if (sum != null && sum.length == 32 && sum != md5(apk)) {
            attempt { tv.exec("rm -f $TMP_APK") }
            throw SetupFailure(SetupIssue.APK_DAMAGED)
        }

        step?.invoke(LauncherStep.INSTALLING, 0.0)
        val out = tv.exec("pm install -r $TMP_APK; rm -f $TMP_APK", 300_000)
        if (out.contains("INSTALL_FAILED_OLDER_SDK")) throw SetupFailure(SetupIssue.INSTALL_OLDER_SDK)
        if (out.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE")) throw SetupFailure(SetupIssue.INSTALL_OTHER_KEY)
        if (out.contains("INSTALL_FAILED_VERSION_DOWNGRADE")) throw SetupFailure(SetupIssue.INSTALL_DOWNGRADE)
        if (!out.contains("Success")) throw SetupFailure(SetupIssue.INSTALL_REFUSED, out.trim())

        tv.exec(RESTART_WITH_HELPERS)

        step?.invoke(LauncherStep.STARTING, 0.0)
        val start = tv.exec(if (stock == null) "am start -W -n $ACTIVITY"
            else "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME -n $ACTIVITY")
        if (!start.contains("Status: ok") || start.split("\n").any { it.lowercase().startsWith("error") }) {
            throw SetupFailure(SetupIssue.HOME_DID_NOT_START)
        }

        step?.invoke(LauncherStep.HANDOVER, 0.0)
        tv.exec("pm grant $PACKAGE android.permission.ACCESS_FINE_LOCATION 2>/dev/null; echo location-granted")
        tv.exec("cmd package compile -m speed -f $PACKAGE", 300_000)
        if (stock != null) tv.exec("pm disable-user --user 0 $stock")
        tv.exec("cmd package set-home-activity --user 0 $ACTIVITY")
        val home = lastLine(tv.exec(DebloatRules.HOME_QUERY))
        if (!home.startsWith("$PACKAGE/")) {
            if (stock != null) rollback(stock)
            else if (home.isNotEmpty()) throw SetupFailure(SetupIssue.HOME_STAYED, home)
            throw if (home.isEmpty()) SetupFailure(SetupIssue.HOME_SWITCH_NO_ANSWER) else SetupFailure(SetupIssue.HOME_WENT_ELSEWHERE, home)
        }

        step?.invoke(LauncherStep.HELPERS, 0.0)
        if (options.inputKeyService) tv.exec(enableService("InputKeyService"))
        if (options.homeKeyService) tv.exec(enableService("HomeKeyService"))
        val secureSettings = tv.exec(secureSettingsStep(options.restoreKeyServices))

        if (theme != null) {
            step?.invoke(LauncherStep.THEME, 0.0)
            applyTheme(theme)
        }
        if (!secureSettingsDone(secureSettings, options.restoreKeyServices)) {
            throw SetupFailure(if (options.restoreKeyServices) SetupIssue.HELPERS_NOT_GRANTED else SetupIssue.SECURE_SETTINGS_KEPT)
        }
        step?.invoke(LauncherStep.DONE, 1.0)
        return home
    }

    private suspend fun rollback(stock: String) {
        attempt { tv.exec("pm enable --user 0 $stock") }
        attempt { tv.exec("cmd package set-home-activity --user 0 \$(${DebloatRules.HOME_QUERY} $stock | tail -n 1)") }
    }

    /** Writes the launcher's config.json through its ThemeProvider (the shell may not reach Android/data on TCL) and restarts Home. */
    suspend fun applyTheme(config: ByteArray) {
        val valid = try { Json.parseToJsonElement(config.decodeToString()) is JsonObject } catch (e: Exception) { false }
        if (!valid) throw SetupFailure(SetupIssue.INVALID_THEME)
        val tmp = "/data/local/tmp/tvhome-config.json"
        tv.push(config, tmp, 420, null)
        // Through the provider first (TCL locks the shell out of Android/data), else a plain copy, as theme.sh does.
        val dir = "/sdcard/Android/data/$PACKAGE/files"
        val out = tv.exec("{ o=\$(content write --uri content://$PACKAGE.theme/config.json < $tmp 2>&1) && case \"\$o\" in *'Unsupported operation'*|*'Error while accessing provider'*) false ;; esac; } || { mkdir -p $dir && cp $tmp $dir/config.json; }; rc=\$?; rm -f $tmp; echo theme-rc=\$rc")
        if (!out.contains("theme-rc=0")) throw SetupFailure(SetupIssue.THEME_REFUSED, out.trim())
        tv.exec("$RESTART_WITH_HELPERS; am start -a android.intent.action.MAIN -c android.intent.category.HOME")
    }
}
