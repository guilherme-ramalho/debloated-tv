package com.guilhermeramalho.puriotv.core

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.temporal.ChronoUnit
import kotlin.coroutines.cancellation.CancellationException

/*
 * The phone-side port of cleanyourtv's tools/disable.sh, tools/restore.sh and tools/recovery.py (Debloat.swift): the
 * same list format, the same safety guards and the same recovery record, so a TV cleaned from either phone can be
 * undone the way upstream undoes it. Packages are only ever disabled for user 0, never uninstalled.
 */

/** Something that runs shell commands on the TV: [AdbClient], or a scripted TV in tests. */
interface TVShell {
    suspend fun shell(command: String, timeoutMs: Long = 60_000): AdbClient.ShellResult
}

/** A TV that also takes files (adb push). */
interface TVDevice : TVShell {
    suspend fun push(data: ByteArray, path: String, mode: Int = 420 /* 0o644 */, progress: ((Double) -> Unit)? = null)
    suspend fun close() {}
}

/** Runs a command and returns its output without carriage returns (TVShell.run in Swift). */
suspend fun TVShell.exec(command: String, timeoutMs: Long = 120_000): String =
    shell(command, timeoutMs).output.replace("\r", "")

/** Swift's `try?`: null when the call fails, but cancellation still cancels. */
internal suspend fun <T> attempt(block: suspend () -> T): T? =
    try { block() } catch (e: CancellationException) { throw e } catch (e: Exception) { null }

/** The last non-empty line, trimmed (how Home answers are read). */
internal fun lastLine(answer: String): String = answer.split("\n").lastOrNull { it.isNotEmpty() }?.trim() ?: ""

/** The package part of a component ("pkg/cls"). */
internal fun packageOf(component: String): String = component.split("/").firstOrNull { it.isNotEmpty() } ?: ""

object Pattern {
    fun matches(pattern: String, text: String, ignoreCase: Boolean = false): Boolean =
        (if (ignoreCase) Regex(pattern, RegexOption.IGNORE_CASE) else Regex(pattern)).containsMatchIn(text)

    const val PACKAGE = "^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$"
    private val packageExpression = Regex(PACKAGE)
    fun isPackage(s: String): Boolean = packageExpression.containsMatchIn(s)

    /**
     * Package names from `pm list packages`. Only names made of letters, digits, `_` and `.` are kept (that includes
     * the framework, "android"), because they go back into shell commands: anything else never reaches the TV's shell.
     */
    fun packageNames(answer: String): Set<String> = answer.split("\n").filter { it.isNotEmpty() && it.startsWith("package:") }
        .mapNotNull { it.substring(8).trim().split(" ").firstOrNull { p -> p.isNotEmpty() } }
        .filter { name -> name.all { c -> c in '0'..'9' || c in 'A'..'Z' || c in 'a'..'z' || c == '_' || c == '.' } }
        .toSet()
}

// MARK: - Lists

/** An upstream debloat.txt: one package per line, # comments, groups headed "# 1. Title" / "# 1b. Title". */
data class DebloatList(val header: List<String>, val entries: List<Entry>, val neverDisable: Set<String>) {
    data class Entry(val packageName: String, val group: String, val note: String)

    val groups: List<String> get() = entries.map { it.group }.distinct()

    companion object {
        fun parse(text: String): DebloatList {
            val body = text.removePrefix("﻿")
            val header = mutableListOf<String>()
            val entries = mutableListOf<Entry>()
            var group = "Other"
            var seenGroup = false
            val bad = mutableListOf<String>()
            for (raw in body.replace("\r", "").split("\n")) {
                val line = raw.trim()
                if (line.isEmpty()) continue
                if (line.startsWith("#")) {
                    val comment = line.trimStart('#').trim()
                    val title = groupTitle(comment)
                    if (title != null) { group = title; seenGroup = true } else if (!seenGroup && entries.isEmpty()) header += comment
                    continue
                }
                var pkg = line
                var note = ""
                val hash = line.indexOf('#')
                if (hash > 0 && line[hash - 1].isWhitespace()) {
                    pkg = line.substring(0, hash).trim()
                    note = line.substring(hash + 1).trim()
                }
                pkg = pkg.split(" ").firstOrNull { it.isNotEmpty() } ?: pkg
                if (!Pattern.isPackage(pkg)) { bad += pkg; continue }
                if (entries.none { it.packageName == pkg }) entries += Entry(pkg, group, note)
            }
            if (bad.isNotEmpty()) throw SetupFailure(SetupIssue.LIST_NOT_PACKAGES, bad.joinToString(", "))
            return DebloatList(header, entries, neverDisable(header))
        }

        private val groupHeading = Regex("^[0-9]+[a-z]?\\. ")
        fun groupTitle(comment: String): String? =
            if (groupHeading.containsMatchIn(comment)) comment.substringAfter(' ') else null

        private val label = Regex("^[A-Z][A-Za-z /()-]{2,40}:")
        fun neverDisable(header: List<String>): Set<String> {
            val out = mutableSetOf<String>()
            var inside = false
            for (line in header) {
                val at = line.indexOf("Never disable:")
                if (at >= 0) {
                    inside = true
                    out += tokens(line.substring(at + "Never disable:".length))
                    continue
                }
                // Another "Label:" line ends the never-disable run.
                if (inside && label.containsMatchIn(line)) inside = false
                if (inside) out += tokens(line)
            }
            return out
        }

        private fun tokens(s: String): Set<String> = s.split(' ', ',', ';').filter { it.isNotEmpty() }
            .map { it.trim('(', ')') }.filter(Pattern::isPackage).toSet()
    }
}

// MARK: - Rules shared with upstream

object DebloatRules {
    /** Core Android and TV middleware: with one of these off the TV may not boot again (#884, #1578). Never overridable. */
    // Same as upstream CORE_RE (tools/disable.sh, at f5c37c36): location.fused boot-looped a TCL 43S5400A (#2803).
    private val core = Regex("^(android|android\\.ext\\.(services|shared)|com\\.android\\.sdksandbox|com\\.android\\.location\\.fused|com\\.android\\.systemui|com\\.android\\.shell|com\\.android\\.phone|com\\.android\\.settings|com\\.android\\.tv\\.settings|com\\.(google\\.)?android\\.(permissioncontroller|packageinstaller|ext\\.services|ext\\.shared|modulemetadata)|com\\.google\\.android\\.overlay\\.modules.*|com\\.android\\.providers\\..*|com\\.cltv\\.mal|com\\.mediatek\\.(tis|tv\\.service|tv\\.agent))$")
    private val coreOK = Regex("^com\\.android\\.providers\\.(calendar|contacts|userdictionary|blockednumber)$")

    /** A CVTE board's stock launcher: kept unless the list was made for that exact board (PROMPT.md, #741). */
    fun isCVTELauncher(p: String) = p.startsWith("com.cvte.tv.launcher")
    fun isCore(p: String) = core.containsMatchIn(p) && !coreOK.containsMatchIn(p)

    const val SETUPWRAITH = "com.google.android.tungsten.setupwraith"
    const val CUSTOM_LAUNCHER = "com.gathin.tvhome"
    val stockLaunchers = listOf("com.google.android.tvlauncher", "com.google.android.apps.tv.launcherx",
        "com.google.android.leanbacklauncher", "com.mitv.tvhome")
    private val notLaunchers = setOf(SETUPWRAITH, "com.android.tv.settings", "com.android.settings", "com.android.provision")
    val animationSettings = listOf("window_animation_scale", "transition_animation_scale", "animator_duration_scale")
    val accessibilitySettings = listOf("enabled_accessibility_services", "accessibility_enabled")
    const val HOME_QUERY = "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
    const val CLAIM_QUERY = "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
    const val CAST_RECEIVER = "com.google.android.apps.mediashell"

    fun isChooser(home: String?): Boolean = home != null && !Pattern.isPackage(packageOf(home))

    private val factory = Regex("factorytest|factory_test|factorymode", RegexOption.IGNORE_CASE)
    fun notALauncher(home: String?): Boolean {
        if (home == null) return false
        val pkg = packageOf(home)
        return pkg in notLaunchers || Regex("/\\S*FallbackHome$").containsMatchIn(home) || factory.containsMatchIn(pkg)
    }

    private val wifiHeader = Regex("ID:\\s*(\\d+)\\s+SSID:\\s*\"(.*)\"\\s+PROVIDER-NAME:")

    /**
     * Saved networks from `dumpsys wifi` (WifiConfiguration lines: "ID: 0 SSID: \"Home\" …", " KeyMgmt: WPA_PSK …",
     * "… cname=<creator> …"). null when the dump has no network section to read (a hung system, no Wi-Fi service).
     */
    fun wifiNetworks(dump: String): List<WifiNetwork>? {
        if (!dump.contains("WifiConfigManager")) return null
        val found = mutableListOf<WifiNetwork>()
        var id = -1; var ssid = ""; var security = ""; var owner = ""; var open = false
        fun close() { if (open) found += WifiNetwork(id, ssid, security, owner); open = false }
        for (line in dump.split("\n")) {
            val m = wifiHeader.find(line)
            if (m != null) {
                close()
                id = m.groupValues[1].toIntOrNull() ?: -1; ssid = m.groupValues[2]; security = ""; owner = ""; open = true
            }
            if (!open) continue
            val k = line.indexOf("KeyMgmt:")
            if (k >= 0) {
                val kinds = line.substring(k + 8).split(" ").filter { it.isNotEmpty() }.takeWhile { !it.endsWith(":") }
                security = when {
                    kinds.any { it.contains("EAP") || it.contains("8021X") || it.contains("SUITE_B") } -> ""
                    "SAE" in kinds -> "wpa3"
                    kinds.any { it.contains("PSK") } -> "wpa2"
                    "OWE" in kinds -> "owe"
                    "NONE" in kinds -> "open"
                    else -> ""
                }
            }
            val c = line.indexOf("cname=")
            if (c >= 0) {
                owner = line.substring(c + 6).takeWhile { !it.isWhitespace() }
                close()
            }
        }
        close()
        return found.filter { it.networkId >= 0 }
    }

    /**
     * How many "cname=" owners in the dump are the setup wizard, read the way upstream's disable.sh does
     * (`grep -o 'cname=[^ ]*'`), whatever the network lines around them look like.
     */
    fun wizardOwnerCount(dump: String): Int =
        dump.split("cname=").drop(1).count { part -> part.takeWhile { !it.isWhitespace() }.contains("setupwraith") }

    /**
     * Saves a network again as the shell's, so disabling the setup wizard keeps it: forget the wizard's copy, then
     * connect with the same name and password. Detached with nohup, so it finishes even when forgetting the network
     * drops this connection (a TV on Wi-Fi); the phone reconnects and checks. `connect-network` keeps an existing
     * network's creator, which is why the old one goes first.
     */
    fun resaveWifiCommand(network: WifiNetwork, password: String): String {
        fun q(s: String) = "'" + s.replace("'", "'\\''") + "'"
        var connect = "cmd wifi connect-network ${q(network.ssid)} ${network.security}"
        if (network.needsPassword) connect += " " + q(password)
        val inner = "cmd wifi forget-network ${network.networkId} && $connect"
        return "nohup sh -c ${q(inner)} >/dev/null 2>&1 &"
    }

    /** Packages among HOME claims that are real launchers (not the setup wizard, settings, FallbackHome or factory test). */
    fun launchers(claims: List<String>): Set<String> = claims.filter { !Regex("/[^ ]*FallbackHome$").containsMatchIn(it) }
        .map(::packageOf).filter { !factory.containsMatchIn(it) && it !in notLaunchers }.toSet()

    private val componentLine = Regex("^ *([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)")
    /** Components at the start of each line, as disable.sh's grep -o '^ *pkg/cls' reads them. */
    fun components(answer: String): List<String> =
        answer.split("\n").filter { it.isNotEmpty() }.mapNotNull { componentLine.find(it)?.groupValues?.get(1) }
}

// MARK: - What the TV has

data class TVInventory(
    val properties: Map<String, String>,
    val installed: Set<String>,
    val disabled: Set<String>,
    /** Whether answers came for user 0 (Android 14 merges every user without --user 0). */
    val userScoped: Boolean,
    val home: String?,
    val animationScales: Map<String, String>,
    val adbSecure: String,
)

/** Why a chosen package stays enabled; [english] is the iPhone app's text. */
enum class SkipReason(val english: String) {
    NOT_A_PACKAGE("Not a package name."),
    CORE("Core Android or TV middleware: with it disabled the TV may not boot again. This can't be overridden."),
    NEVER_DISABLE("This TV's tested list says never to disable it."),
    WIFI_UNREADABLE("Couldn't read the TV's saved Wi-Fi networks, so the setup wizard stays: disabling it could delete them. Restart the TV and review again."),
    WIFI_ENTERPRISE("A Wi-Fi network on the TV belongs to the setup wizard and uses a sign-in this phone can't save again. On the TV, forget it and join it again in Settings › Network & Internet, then review again."),
    WIFI_NO_SHELL("The TV's Wi-Fi network belongs to the setup wizard, and this TV can't have it saved again from the phone. On the TV, forget the network and join it again in Settings › Network & Internet, then review again."),
    HOME_OWNER_ALONE("It owns Home and nothing else that can answer Home stays enabled. Install the new Home screen first; it's disabled afterwards."),
    HOME_OWNER_WIZARD("It owns Home, and the setup wizard stays enabled and would take Home instead, a black screen the TV can crash-loop on. Install the new Home screen first."),
    HOME_NO_DEFAULT("Home has no default, and no other app could answer Home. Install the new Home screen first."),
    HOME_STOCK_UNKNOWN("Couldn't ask the TV which apps answer Home, and this is a stock launcher."),
    INPUT_CHECK_HUNG("The TV's system diagnostics are switched off after a hang, so the input-driver check can't read it. Restart the TV and try again."),
    INPUT_CHECK_UNREADABLE("This firmware doesn't show its permissions, so the input-driver check can't read it. It stays enabled to be safe."),
    INPUT_DRIVER("It drives the HDMI, AV or tuner inputs. Disabled, they notice the cable but stay black, and only a full restore fixes it."),
    OPENS_INPUTS("The TV opens its inputs and channels with it; disabled, the input tiles do nothing."),
    OPENS_SETTINGS("The TV opens Settings with it; disabled, Settings (and the way back to Developer options) won't open."),
}

data class DebloatSkip(val packageName: String, val reason: SkipReason)

/** Something the review screen says about the whole plan; [english] is the iPhone app's text. */
enum class PlanNote(val english: String) {
    HOME_BY_CLAIMS("Home has no default on this TV, so the Home check went by the apps that answer Home."),
    INPUTS_UNCHECKED("Couldn't check which apps drive the HDMI inputs. After applying, open every input before putting the remote down."),
    INPUTS_SETTINGS_UNCHECKED("Couldn't check which apps open the inputs and Settings. After applying, open an HDMI input and Settings from Home."),
    OPEN_DEBUGGING_PORT("This TV lets any device on your network use its debugging port without asking. Turn debugging off when you're done."),
    CHROMECAST("Chromecast built-in keeps its credentials in the setup wizard: with the wizard off, casting to this TV stops working."),
}

data class DebloatPlan(
    val disable: List<String>,
    val skipped: List<DebloatSkip> = emptyList(),
    val notes: List<PlanNote> = emptyList(),
    /**
     * Wi-Fi networks the setup wizard created. Disabling the wizard deletes them, so each is saved again from the
     * phone (with the password the user types) before the wizard goes. Empty: nothing to move.
     */
    val wifiToResave: List<WifiNetwork> = emptyList(),
    /**
     * The setup wizard stays enabled and answers Home: a new Home screen can't take over (Google TV gives Home to
     * the wizard's RecoveryActivity). The Home step says so before anything changes.
     */
    val setupKeepsHome: Boolean = false,
)

/** A Wi-Fi network saved on the TV, as `dumpsys wifi` lists it. */
data class WifiNetwork(
    val networkId: Int,
    val ssid: String,
    /**
     * The type `cmd wifi connect-network` takes: wpa2, wpa3, owe or open. Empty: one the phone can't save again
     * (enterprise sign-in), so the user rejoins it on the TV.
     */
    val security: String,
    val owner: String,
) {
    val needsPassword: Boolean get() = security == "wpa2" || security == "wpa3"
}

/** Upstream's per-run overrides, off by default. Each is offered only with the explanation of what it bypasses. */
data class DebloatOverrides(val home: Boolean = false)

/**
 * The state needed to put the TV back: tools/recovery.py's record, version 1, as JSON (same keys as the iPhone's,
 * so records move between the two apps and upstream's recovery.py).
 */
@Serializable
data class RecoveryRecord(
    val version: Int = 1,
    val created: String,
    val host: String,
    val list: String,
    val home: String? = null,
    val settings: Map<String, String> = emptyMap(),
    /** "enabled" | "disabled" | "absent", before cleanup. */
    val packages: Map<String, String> = emptyMap(),
    // Purio TV additions; upstream's recovery.py ignores them, and records from before them still load.
    /** The TV this record belongs to: a restore on another TV is refused. */
    val tv: TVIdentity? = null,
    /** Every list applied on this TV, first one first (the record keeps the state before the first). */
    val lists: List<String>? = null,
    /** enabled_accessibility_services and accessibility_enabled before the new Home's remote helpers were added. */
    val accessibility: Map<String, String>? = null,
) {
    /** The list applied last (what an update of the Home screen follows). */
    val lastList: String get() = lists?.lastOrNull() ?: list

    /**
     * Folds in an older record of the same TV (upstream's extend_record): the oldest state of each package wins, and
     * Home, settings and helpers come from the oldest record that has them.
     */
    fun mergedWithOlder(older: RecoveryRecord): RecoveryRecord {
        val pkgs = older.packages.toMutableMap()
        for ((p, state) in packages) if (p !in pkgs) pkgs[p] = state
        return older.copy(
            packages = pkgs,
            home = older.home ?: home,
            tv = older.tv ?: tv,
            accessibility = older.accessibility ?: accessibility,
            lists = ((older.lists ?: listOf(older.list)) + (lists ?: listOf(list))).distinct(),
            host = host,
        )
    }
}

/**
 * Who a TV is, as far as the shell can tell. android_id is per device (and per user); many MediaTek/Realtek boards
 * share a dummy serial, so the serial only counts when it looks real.
 */
@Serializable
data class TVIdentity(val androidId: String, val serial: String, val model: String, val device: String) {
    val realSerial: String? get() = if (serial.lowercase() in dummySerials) null else serial
    val validAndroidId: String? get() = if (Regex("^[0-9a-fA-F]{8,32}$").containsMatchIn(androidId)) androidId.lowercase() else null
    /** A key for this TV's record file, null when nothing identifies it. */
    val key: String? get() = validAndroidId?.let { "id-$it" } ?: realSerial?.let { "sn-$it" }

    /** false: certainly another TV. true: the same one, or nothing to tell them apart (a record from before identities). */
    fun sameTV(other: TVIdentity): Boolean {
        val a = validAndroidId; val b = other.validAndroidId
        if (a != null && b != null) return a == b
        val s = realSerial; val t = other.realSerial
        if (s != null && t != null) return s == t
        return model == other.model && device == other.device
    }

    companion object {
        val dummySerials = setOf("", "unknown", "0123456789abcdef", "0123456789", "123456789", "0000000000000000", "null")
    }
}

/** The TV after the restart that ends a setup (PROMPT.md: reboot once, then compare). */
data class RestartCheck(
    val home: String,
    /** Disabled by this setup and on again after the restart: the firmware turns them back on at every boot. */
    val reEnabled: List<String>,
    val homeOK: Boolean,
) {
    companion object {
        /**
         * [expectedHome]: the new Home screen's package when setup installed it; otherwise any real Home will do, but
         * not the setup wizard's RecoveryActivity, FallbackHome or nothing (a black Home, docs/devices/acer-r4g.md upstream).
         */
        fun judge(home: String, enabled: Set<String>, disabledBySetup: List<String>, expectedHome: String?): RestartCheck {
            val broken = home.isEmpty() || home.contains("setupwraith") || home.endsWith("FallbackHome") || home.contains("RecoveryActivity")
            val ok = !broken && (expectedHome?.let { home.startsWith("$it/") } ?: true)
            return RestartCheck(home, disabledBySetup.filter { it in enabled }.sorted(), ok)
        }
    }
}

/** What a restore did, read back from the TV. */
data class RestoreReport(
    /** Recorded as enabled before setup, installed, and still disabled after the restore. */
    val notBack: List<String>,
    /** Disabled now because they were already off before setup. */
    val keptOff: List<String>,
    /** Where Home resolves now, and the package it should (null: the record didn't say, so not checked). */
    val home: String,
    val expectedHome: String?,
) {
    val homeOK: Boolean get() = expectedHome?.let { home.startsWith("$it/") } ?: true
    val complete: Boolean get() = notBack.isEmpty() && homeOK
}

data class ApplyResult(val disabled: List<String>, val stillEnabled: List<String>, val stoppedEarly: Boolean)

// MARK: - Engine

class Debloater(private val tv: TVShell) {
    /** The properties profiles match on. The ADB banner carries only some (no Android version), so the rest are read. */
    suspend fun profileProperties(banner: Map<String, String> = emptyMap()): Map<String, String> {
        val props = banner.toMutableMap()
        for (key in listOf("ro.product.model", "ro.product.device", "ro.product.name", "ro.product.manufacturer", "ro.build.id",
            "ro.build.display.id", "ro.build.version.incremental", "ro.build.version.sdk", "ro.build.version.release")) {
            if (key !in props) props[key] = tv.exec("getprop $key").trim()
        }
        return props
    }

    suspend fun inspect(properties: Map<String, String> = emptyMap()): TVInventory {
        val props = profileProperties(properties)
        var scoped = true
        var installed = Pattern.packageNames(tv.exec("pm list packages --user 0"))
        if (installed.isEmpty()) { scoped = false; installed = Pattern.packageNames(tv.exec("pm list packages")) }
        if (installed.isEmpty()) throw SetupFailure(SetupIssue.NO_APPS_LISTED)
        val disabled = Pattern.packageNames(tv.exec("pm list packages -d" + if (scoped) " --user 0" else ""))
        val candidate = lastLine(tv.exec(DebloatRules.HOME_QUERY))
        val home = if (Regex("^[A-Za-z_][\\w.]*/[\\w.$]+$").containsMatchIn(candidate)) candidate else null
        val scales = DebloatRules.animationSettings.associateWith { tv.exec("settings get global $it").trim() }
        val secure = attempt { tv.exec("getprop ro.adb.secure").trim() } ?: "unread"
        return TVInventory(props, installed, disabled, scoped, home, scales, secure)
    }

    /** The guards from disable.sh, in its order. [chosen] is what the user agreed to disable. */
    suspend fun plan(chosen: List<String>, list: DebloatList, inventory: TVInventory,
                     overrides: DebloatOverrides = DebloatOverrides()): DebloatPlan {
        val pkgs = chosen.filter { it in inventory.installed && it !in inventory.disabled }.toMutableList()
        val skipped = mutableListOf<DebloatSkip>()
        val notes = mutableListOf<PlanNote>()
        fun drop(p: String, reason: SkipReason) {
            if (pkgs.remove(p)) skipped += DebloatSkip(p, reason)
        }
        for (p in pkgs.toList()) if (!Pattern.isPackage(p)) drop(p, SkipReason.NOT_A_PACKAGE)
        for (p in pkgs.toList()) if (DebloatRules.isCore(p)) drop(p, SkipReason.CORE)
        for (p in pkgs.toList()) if (p in list.neverDisable) drop(p, SkipReason.NEVER_DISABLE)

        // Wi-Fi saved during first setup belongs to setupwraith, and disabling it deletes those networks (and, on
        // Wi-Fi, this connection). No such network: disable it. Some: they're saved again from the phone first
        // (wifiToResave), which needs the shell's connect-network; one that can't be (enterprise) keeps the wizard.
        var wifiToResave = emptyList<WifiNetwork>()
        if (DebloatRules.SETUPWRAITH in pkgs) {
            val dump = attempt { tv.exec("dumpsys wifi") } ?: ""
            val saved = DebloatRules.wifiNetworks(dump)
            if (saved != null) {
                val wizard = saved.filter { it.owner.contains("setupwraith") }
                if (DebloatRules.wizardOwnerCount(dump) > wizard.size) {
                    // Upstream's raw check (grep -o 'cname=[^ ]*') sees a wizard network the parser didn't: fail closed.
                    drop(DebloatRules.SETUPWRAITH, SkipReason.WIFI_UNREADABLE)
                } else if (wizard.any { it.security.isEmpty() }) {
                    drop(DebloatRules.SETUPWRAITH, SkipReason.WIFI_ENTERPRISE)
                } else if (wizard.isNotEmpty()) {
                    val help = attempt { tv.exec("cmd wifi help 2>&1") } ?: ""
                    if (help.contains("connect-network") && help.contains("forget-network")) wifiToResave = wizard
                    else drop(DebloatRules.SETUPWRAITH, SkipReason.WIFI_NO_SHELL)
                }
            } else {
                drop(DebloatRules.SETUPWRAITH, SkipReason.WIFI_UNREADABLE)
            }
        }

        // Home guard (#239): never leave the TV with nothing to start when Home is pressed.
        if (!overrides.home && pkgs.isNotEmpty()) {
            var homePackage = inventory.home?.let(::packageOf)
            if (homePackage != null && !Pattern.isPackage(homePackage)) homePackage = null
            if (homePackage == null) {
                val activity = attempt { tv.exec("dumpsys activity") } ?: ""
                val line = activity.split("\n").firstOrNull { it.isNotEmpty() && it.contains("mHomeProcess:") }
                val p = line?.let { Regex("[: ]([A-Za-z0-9_.]+)/[A-Za-z0-9_.]+").find(it)?.groupValues?.get(1) }
                if (p != null && Pattern.isPackage(p)) homePackage = p
            }
            val claims = DebloatRules.components(attempt { tv.exec(DebloatRules.CLAIM_QUERY) } ?: "")
            val launchers = DebloatRules.launchers(claims)
            if (homePackage != null) {
                val home: String = homePackage
                if (home in pkgs) {
                    val others = launchers - home - pkgs.toSet()
                    val setupAnswersHome = claims.any { it.startsWith(DebloatRules.SETUPWRAITH + "/") } && DebloatRules.SETUPWRAITH !in pkgs
                    if (others.isEmpty()) drop(home, SkipReason.HOME_OWNER_ALONE)
                    else if (setupAnswersHome) drop(home, SkipReason.HOME_OWNER_WIZARD)
                }
            } else if (claims.isNotEmpty()) {
                val listed = launchers.intersect(pkgs.toSet())
                if (listed.isNotEmpty() && (launchers - pkgs.toSet()).isEmpty()) {
                    for (p in listed) drop(p, SkipReason.HOME_NO_DEFAULT)
                }
                notes += PlanNote.HOME_BY_CLAIMS
            } else {
                for (p in DebloatRules.stockLaunchers) if (p in pkgs) drop(p, SkipReason.HOME_STOCK_UNKNOWN)
            }
        }

        // HDMI/AV/tuner drivers (#321): with one off, the inputs stay black and only a full restore fixes it.
        if (pkgs.isNotEmpty()) {
            val answer = attempt { tv.exec(inputDriverCommand(pkgs), 300_000) }
            if (answer != null) {
                for (line in answer.split("\n").filter { it.isNotEmpty() }) {
                    when {
                        line.startsWith("HUNG ") -> drop(line.substring(5), SkipReason.INPUT_CHECK_HUNG)
                        line.startsWith("NOCHK ") -> drop(line.substring(6), SkipReason.INPUT_CHECK_UNREADABLE)
                        Pattern.isPackage(line) -> drop(line, SkipReason.INPUT_DRIVER)
                    }
                }
            } else {
                notes += PlanNote.INPUTS_UNCHECKED
            }
        }

        // Apps that open the inputs or Settings: the way back to Developer options goes through Settings.
        if (pkgs.isNotEmpty()) {
            val q = "cmd package query-activities --brief"
            val answer = attempt { tv.exec("$q -a android.intent.action.VIEW -t vnd.android.cursor.item/channel 2>/dev/null; echo ==; $q -a android.settings.SETTINGS 2>/dev/null; true") }
            if (answer != null) {
                val parts = answer.split("\n==\n")
                fun names(s: String): Set<String> = s.split("\n").filter { it.isNotEmpty() }.mapNotNull { line ->
                    val first = line.trim().split("/").firstOrNull { it.isNotEmpty() } ?: ""
                    if (line.contains("/") && Pattern.isPackage(first)) first else null
                }.toSet()
                val inputApps = names(parts.first())
                val settingsApps = names(if (parts.size > 1) parts[1] else "")
                if (settingsApps.isEmpty()) notes += PlanNote.INPUTS_SETTINGS_UNCHECKED
                for (p in inputApps) drop(p, SkipReason.OPENS_INPUTS)
                for (p in settingsApps) drop(p, SkipReason.OPENS_SETTINGS)
            } else {
                notes += PlanNote.INPUTS_SETTINGS_UNCHECKED
            }
        }
        if (inventory.adbSecure == "0" || inventory.adbSecure.isEmpty()) notes += PlanNote.OPEN_DEBUGGING_PORT
        val wizardOff = DebloatRules.SETUPWRAITH in pkgs
        // Chromecast built-in reads its device credentials from a provider inside the setup wizard (upstream).
        if (wizardOff && DebloatRules.CAST_RECEIVER in inventory.installed && DebloatRules.CAST_RECEIVER !in inventory.disabled &&
            DebloatRules.CAST_RECEIVER !in pkgs) notes += PlanNote.CHROMECAST
        var setupKeepsHome = false
        if (!wizardOff && DebloatRules.SETUPWRAITH in inventory.installed && DebloatRules.SETUPWRAITH !in inventory.disabled) {
            val claims = DebloatRules.components(attempt { tv.exec(DebloatRules.CLAIM_QUERY) } ?: "")
            setupKeepsHome = claims.any { it.startsWith(DebloatRules.SETUPWRAITH + "/") }
        }
        return DebloatPlan(pkgs.toList(), skipped, notes, if (wizardOff) wifiToResave else emptyList(), setupKeepsHome)
    }

    /** Who this TV is (recovery records are tied to it). */
    suspend fun identity(): TVIdentity {
        suspend fun get(command: String): String {
            val out = tv.exec(command).trim()
            return if (out.contains("\n") || out.lowercase().contains("error")) "" else out
        }
        return TVIdentity(get("settings get secure android_id"), get("getprop ro.serialno"),
            get("getprop ro.product.model"), get("getprop ro.product.device"))
    }

    /** The accessibility settings the new Home's helpers change, as they are now. */
    suspend fun accessibilitySettings(): Map<String, String> =
        DebloatRules.accessibilitySettings.associateWith { tv.exec("settings get secure $it").trim() }

    /**
     * The record of how things were before the first run (recovery.py save). An [existing] record is extended, never
     * overwritten.
     */
    fun record(list: DebloatList, listName: String, host: String, inventory: TVInventory, existing: RecoveryRecord?,
               tv: TVIdentity? = null, accessibility: Map<String, String>? = null): RecoveryRecord {
        fun state(p: String) = when {
            p !in inventory.installed -> "absent"
            p in inventory.disabled -> "disabled"
            else -> "enabled"
        }
        val names = list.entries.map { it.packageName }
        if (existing != null) {
            val pkgs = existing.packages.toMutableMap()
            for (p in names) if (p !in pkgs) pkgs[p] = state(p)
            for (p in names) if (pkgs[p] == "absent" && state(p) == "enabled") pkgs[p] = "enabled"
            val hp = inventory.home?.let(::packageOf)
            if (hp != null && hp !in pkgs && !DebloatRules.isChooser(inventory.home) && hp != DebloatRules.CUSTOM_LAUNCHER) pkgs[hp] = state(hp)
            return existing.copy(
                packages = pkgs,
                lists = ((existing.lists ?: listOf(existing.list)) + listName).distinct(),
                tv = existing.tv ?: tv,
                accessibility = existing.accessibility ?: accessibility,
                host = host,
            )
        }
        var home = inventory.home
        if (DebloatRules.isChooser(home)) home = null
        val homePackage = home?.let(::packageOf)
        val targets = names.toMutableList()
        if (homePackage != null && homePackage !in targets) targets += homePackage
        targets += DebloatRules.stockLaunchers.filter { it in inventory.installed && it !in targets }
        if (DebloatRules.notALauncher(home)) home = null
        return RecoveryRecord(created = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString(), host = host, list = listName,
            home = home, settings = inventory.animationScales, packages = targets.associateWith(::state),
            tv = tv, lists = listOf(listName), accessibility = accessibility)
    }

    /** Disables the plan's packages one by one, then reads the TV back instead of trusting silence (#1376). */
    suspend fun apply(plan: DebloatPlan, progress: ((Int, Int) -> Unit)? = null): ApplyResult {
        var stoppedEarly = false
        for ((i, p) in plan.disable.withIndex()) {
            if (attempt { tv.shell("pm disable-user --user 0 $p", 60_000) } == null) { stoppedEarly = true; break }
            progress?.invoke(i + 1, plan.disable.size)
        }
        val enabled = Pattern.packageNames(tv.exec("pm list packages -e --user 0"))
        // An empty answer is a check that didn't run, not proof that everything went off (disable.sh does the same).
        if (enabled.isEmpty() && plan.disable.isNotEmpty()) throw SetupFailure(SetupIssue.APPLY_UNCHECKED)
        return ApplyResult(plan.disable.filter { it !in enabled }, plan.disable.filter { it in enabled }, stoppedEarly)
    }

    /** Restores a record, refusing one made on another TV, then reads the TV back (restore.sh's check, upstream 956d7334). */
    suspend fun restore(record: RecoveryRecord, stock: String = DEFAULT_STOCK): RestoreReport {
        val saved = record.tv
        if (saved != null && !saved.sameTV(identity())) throw SetupFailure(SetupIssue.RESTORE_OTHER_TV, saved.model)
        for (command in restoreCommands(record, stock)) tv.shell(command, 60_000)
        val installed = Pattern.packageNames(tv.exec("pm list packages --user 0"))
        val enabled = Pattern.packageNames(tv.exec("pm list packages -e --user 0"))
        if (installed.isEmpty() || enabled.isEmpty()) throw SetupFailure(SetupIssue.RESTORE_UNCHECKED)
        val notBack = record.packages.filter { it.value == "enabled" && it.key in installed && it.key !in enabled }.keys.sorted()
        val keptOff = record.packages.filter { it.value == "disabled" && it.key !in enabled }.keys.sorted()
        val home = lastLine(tv.exec(DebloatRules.HOME_QUERY))
        val recorded = record.home?.let(::packageOf)
        val validStock = if (Pattern.isPackage(stock)) stock else DEFAULT_STOCK
        val expected = recorded?.takeIf { it != DebloatRules.CUSTOM_LAUNCHER }
            ?: (if (record.packages[validStock] == "enabled") validStock else null)
        return RestoreReport(notBack, keptOff, home, expected)
    }

    companion object {
        const val DEFAULT_STOCK = "com.google.android.tvlauncher"

        /** disable.sh's input-driver check over every package in one shell call. */
        internal fun inputDriverCommand(pkgs: List<String>): String {
            val names = pkgs.joinToString(" ")
            return "s=\$(getprop ro.build.version.sdk); for p in $names; do d=\$(dumpsys package \$p 2>/dev/null); case \$d in " +
                "*'requested permissions:'*) printf '%s\\n' \"\$d\" | sed -n -E '/requested permissions:/,/(install|runtime) permissions:|User [0-9]+:/p' | grep -q TV_INPUT_HARDWARE && echo \$p;; " +
                "*'grantedPermissions:'*) printf '%s\\n' \"\$d\" | sed -n -E '/grantedPermissions:/,/(install|runtime) permissions:|User [0-9]+:/p' | grep -q TV_INPUT_HARDWARE && echo \$p;; " +
                "*'Service Resolver Table:'*) printf '%s\\n' \"\$d\" | grep -q 'android.media.tv.TvInputService' && echo \$p;; " +
                "*'Unable to find'*) :;; *'hung system process'*) echo \"HUNG \$p\";; " +
                "*\"Package [\$p]\"*) [ \"\${s:-0}\" -ge 23 ] 2>/dev/null || echo \"NOCHK \$p\";; *) echo \"NOCHK \$p\";; esac; done; true"
        }

        /**
         * recovery.py restore_commands: put recorded states back, Home, and animation scales. Records can come from
         * files (an import, upstream's recovery.py), so everything that reaches the TV's shell is validated: package
         * names must look like package names, Home like a component, settings like numbers.
         */
        fun restoreCommands(record: RecoveryRecord, stock: String = DEFAULT_STOCK): List<String> {
            val home = record.home?.takeIf { Regex("^[A-Za-z_][A-Za-z0-9_.]*/[A-Za-z0-9_.]+$").containsMatchIn(it) }
            val validStock = if (Pattern.isPackage(stock)) stock else DEFAULT_STOCK
            val commands = record.packages.filter { it.value == "enabled" && Pattern.isPackage(it.key) }.keys.sorted()
                .map { "pm enable $it" }.toMutableList()
            val fallbackState = record.packages[validStock]
            val resolve = "cmd package set-home-activity --user 0 \$(${DebloatRules.HOME_QUERY} $validStock | tail -n 1)"
            when {
                home != null && packageOf(home) != DebloatRules.CUSTOM_LAUNCHER -> commands += "cmd package set-home-activity --user 0 $home"
                home != null && fallbackState != "enabled" -> commands += "cmd package set-home-activity --user 0 $home"
                home == null && (fallbackState == "disabled" || fallbackState == "absent") -> {}
                // ^ leave Home alone: none recorded and the stock launcher was not on before
                else -> commands += resolve
            }
            for (key in DebloatRules.animationSettings) {
                val value = (record.settings[key] ?: "").trim()
                if (value == "null") commands += "settings delete global $key"
                else if (Regex("^-?[0-9]+(\\.[0-9]+)?$").containsMatchIn(value)) commands += "settings put global $key $value"
            }
            // The new Home's remote helpers: the accessibility list goes back to what it was before setup, and the
            // launcher loses the permission to turn them on again by itself. The launcher stays installed (as upstream).
            val saved = record.accessibility
            if (saved != null && (home?.let { !it.startsWith(DebloatRules.CUSTOM_LAUNCHER + "/") } ?: true)) {
                val services = (saved["enabled_accessibility_services"] ?: "").trim()
                if (services == "null" || services.isEmpty()) commands += "settings delete secure enabled_accessibility_services"
                else if (Regex("^[A-Za-z0-9_.$/:]+$").containsMatchIn(services)) commands += "settings put secure enabled_accessibility_services $services"
                val on = (saved["accessibility_enabled"] ?: "").trim()
                if (on == "null" || on.isEmpty()) commands += "settings delete secure accessibility_enabled"
                else if (Regex("^[01]$").containsMatchIn(on)) commands += "settings put secure accessibility_enabled $on"
                commands += "pm revoke ${DebloatRules.CUSTOM_LAUNCHER} android.permission.WRITE_SECURE_SETTINGS 2>/dev/null; true"
            }
            return commands
        }
    }
}
