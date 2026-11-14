package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.coroutines.coroutineContext

/*
 * The pieces of the iPhone's DebloatFlow / HomeUpdateFlow (ios/Sources/App/DebloatFlow.swift) that carry safety
 * rules, without any UI: the recovery store, the group-by-group apply, the Wi-Fi re-save and its check, the restart
 * check with its 20 s wait, switching debugging off, and the Home screen update. The app sequences them and shows
 * progress; every TV change still goes through Debloater / LauncherInstaller.
 */

/**
 * Saved recovery records, one per TV (by its android_id or a real serial; older builds kept one per TV and list).
 * They're the only way to undo a setup exactly: keep [directory] in backed-up app storage (filesDir) and let the
 * person export them. Same file names and JSON as the iPhone's, so records can be moved between the apps.
 */
class RecoveryStore(val directory: File) {
    data class Saved(val file: File, val record: RecoveryRecord)

    private fun dir(): File = directory.also { it.mkdirs() }

    fun file(profile: String, tv: String): File = File(dir(), "recovery-$profile-${safe(tv)}.json")
    fun file(identity: TVIdentity, host: String): File = file("tv", identity.key ?: "host-$host")

    fun load(file: File): RecoveryRecord? = try { decode(file.readBytes()) } catch (e: Exception) { null }

    /** Pretty JSON with sorted keys, written atomically. */
    fun save(record: RecoveryRecord, file: File) {
        val tmp = File(file.parentFile, ".${file.name}.tmp")
        tmp.writeBytes(encode(record))
        if (!tmp.renameTo(file)) { file.delete(); if (!tmp.renameTo(file)) throw IOException("Couldn't save ${file.name}") }
    }

    /** This TV's record, with any older per-list records of it folded in (oldest state wins), and those older files. */
    fun forTV(identity: TVIdentity, host: String): Triple<File, RecoveryRecord?, List<File>> {
        val target = file(identity, host)
        val legacy = all().filter { saved ->
            if (saved.file == target || saved.file.name.startsWith("recovery-tv-")) return@filter false
            val tv = saved.record.tv
            val serial = identity.realSerial
            when {
                tv != null -> tv.sameTV(identity) && tv.key != null && tv.key == identity.key
                serial != null -> saved.file.name.endsWith("-${safe(serial)}.json")
                else -> saved.record.host == host
            }
        }.sortedBy { it.record.created }
        var older: RecoveryRecord? = null
        for (saved in legacy) older = older?.let { saved.record.mergedWithOlder(it) } ?: saved.record
        val current = load(target)
        val existing = when {
            current != null && older != null -> current.mergedWithOlder(older)
            else -> current ?: older
        }
        return Triple(target, existing, legacy.map { it.file })
    }

    /** Every readable record, newest first. */
    fun all(): List<Saved> = (dir().listFiles() ?: emptyArray()).filter { it.extension == "json" }
        .mapNotNull { f -> load(f)?.let { Saved(f, it) } }.sortedByDescending { it.record.created }

    companion object {
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }
        private val pretty = Json { prettyPrint = true }

        fun decode(data: ByteArray): RecoveryRecord = json.decodeFromString(RecoveryRecord.serializer(), data.decodeToString())
        fun encode(record: RecoveryRecord): ByteArray =
            pretty.encodeToString(JsonElement.serializer(), DebloatProfile.sorted(json.encodeToJsonElement(RecoveryRecord.serializer(), record)))
                .toByteArray()

        internal fun safe(s: String): String = buildString {
            s.codePoints().forEach { c -> if (Character.isLetterOrDigit(c) || c == '.'.code || c == '-'.code) appendCodePoint(c) else append('_') }
        }
    }
}

/** Opens a new connection to the same TV with the already approved key (an [AdbClient] in the app). Throws when it can't. */
fun interface TVConnector {
    suspend fun open(approvalTimeoutMs: Long, onApproval: () -> Unit): TVDevice
}

/** Whether a TCP port refuses connections (true), accepts them (false), or didn't answer (null, e.g. TV asleep). */
object PortProbe {
    suspend fun refuses(host: String, port: Int, timeoutMs: Int = 4000): Boolean? = withContext(Dispatchers.IO) {
        try { Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs) }; false }
        catch (e: ConnectException) { if (e.message?.contains("refused", ignoreCase = true) == true) true else null }
        catch (e: IOException) { null }
    }
}

/** Why setup can't offer the new Home screen with a list on this TV. */
enum class HomeScreenBlock { FIRE_OS, CVTE, DEBLOAT_ONLY, CUSTOM_BUILD, NO_CONFIG }

/** What the restart at the end of apply found. [check] null: the TV didn't let the phone back in. */
data class RestartOutcome(val device: TVDevice?, val check: RestartCheck?)

object SetupSequence {
    /** Entries the user can choose: installed, still enabled, and not protected. */
    fun choices(profile: DebloatProfile, inventory: TVInventory, kind: ProfileMatch.Kind?): List<DebloatList.Entry> =
        profile.list.entries.filter {
            it.packageName in inventory.installed && it.packageName !in inventory.disabled &&
                it.packageName !in profile.list.neverDisable && !DebloatRules.isCore(it.packageName) &&
                !(kind == ProfileMatch.Kind.CLOSEST && DebloatRules.isCVTELauncher(it.packageName))
        }

    /** null: setup may install the new Home screen with this list. Fire TVs and CVTE boards never. */
    fun homeScreenBlock(profile: DebloatProfile?, inventory: TVInventory?): HomeScreenBlock? {
        if (profile == null || inventory == null) return HomeScreenBlock.NO_CONFIG
        if ((inventory.properties["ro.product.manufacturer"] ?: "").contains("amazon", ignoreCase = true)) return HomeScreenBlock.FIRE_OS
        if (inventory.installed.any { it.startsWith("com.cvte.") }) return HomeScreenBlock.CVTE
        if (profile.offersHomeScreen) return null
        return when (profile.manifest.homeScreenNote) {
            "fireOS" -> HomeScreenBlock.FIRE_OS
            "cvte", "special" -> HomeScreenBlock.CVTE
            "customBuild" -> HomeScreenBlock.CUSTOM_BUILD
            "debloatOnly" -> HomeScreenBlock.DEBLOAT_ONLY
            else -> HomeScreenBlock.NO_CONFIG
        }
    }

    /** The first five dock candidates the TV has. */
    fun defaultDock(profile: DebloatProfile, inventory: TVInventory): List<String> =
        profile.manifest.dockCandidates.filter { it in inventory.installed }.take(5)

    /** Every Wi-Fi network the wizard owns that needs a password has one typed, twice the same. */
    fun wifiReady(plan: DebloatPlan?, passwords: Map<String, String>, confirm: Map<String, String>): Boolean =
        plan?.wifiToResave?.all { !it.needsPassword || (!passwords[it.ssid].isNullOrEmpty() && passwords[it.ssid] == confirm[it.ssid]) } ?: true

    /**
     * Saves how the TV is before this run changes anything: one record per TV, which a later run only extends, so the
     * state before the very first setup is what Undo puts back. Call it before any change; nothing changes if it throws.
     * [inventory] is the one read at inspect. Returns the record's file.
     */
    suspend fun saveRecord(tv: TVShell, store: RecoveryStore, profile: DebloatProfile, inventory: TVInventory, host: String): File {
        val debloater = Debloater(tv)
        val identity = debloater.identity()
        val accessibility = debloater.accessibilitySettings()
        val (file, existing, legacy) = store.forTV(identity, host)
        val record = debloater.record(profile.list, profile.id, host, inventory, existing, identity, accessibility)
        store.save(record, file)
        for (old in legacy) old.delete()   // folded into this TV's record
        return file
    }

    /**
     * Disables the plan group by group, as upstream's tested runs did, checking the TV still answers after each and
     * stopping if it doesn't. [onGroup] gets (group index from 0, group count, apps in it); [onProgress] apps done so far.
     */
    suspend fun applyGroups(tv: TVShell, profile: DebloatProfile, plan: DebloatPlan,
                            onGroup: (Int, Int, Int) -> Unit = { _, _, _ -> }, onProgress: (Int) -> Unit = {}): ApplyResult {
        val debloater = Debloater(tv)
        val disabled = mutableListOf<String>(); val still = mutableListOf<String>()
        val groups = profile.list.groups.map { g ->
            profile.list.entries.filter { it.group == g }.map { it.packageName }.filter { it in plan.disable }
        }.filter { it.isNotEmpty() }
        for ((i, group) in groups.withIndex()) {
            coroutineContext.ensureActive()
            onGroup(i, groups.size, group.size)
            val r = debloater.apply(DebloatPlan(group))
            disabled += r.disabled; still += r.stillEnabled
            onProgress(disabled.size + still.size)
            tv.shell("echo ok", 15_000)   // the TV still answers after this group
            if (r.stoppedEarly) throw SetupFailure(SetupIssue.STOPPED_DURING_GROUP, (i + 1).toString())
        }
        return ApplyResult(disabled, still, false)
    }

    /**
     * Saves each network the setup wizard owns again as the shell's, waits for the TV (it can drop off Wi-Fi for a
     * moment, then [connector] reconnects), and checks the copies are there and no longer the wizard's. Run it after
     * [saveRecord] and before disabling anything. Returns the connection to keep using (maybe a new one).
     */
    suspend fun resaveWifi(tv: TVDevice, networks: List<WifiNetwork>, passwords: Map<String, String>, connector: TVConnector): TVDevice {
        for (network in networks) attempt { tv.shell(DebloatRules.resaveWifiCommand(network, passwords[network.ssid] ?: ""), 15_000) }
        delay(6_000)
        var client = tv
        var after: List<WifiNetwork>? = null
        for (attempt in 1..8) {
            val dump = attempt { client.exec("dumpsys wifi", 30_000) }
            val parsed = dump?.let(DebloatRules::wifiNetworks)
            if (parsed != null) { after = parsed; break }
            if (attempt == 8) break
            // The connection went with the old network: reconnect with the approved key (no prompt on the TV).
            client.close()
            delay(5_000)
            attempt { connector.open(10_000) {} }?.let { client = it }
        }
        val names = networks.joinToString(", ") { it.ssid }
        val found = after ?: throw SetupFailure(SetupIssue.WIFI_NOT_BACK, names)
        val missing = networks.filter { n -> found.none { it.ssid == n.ssid && !it.owner.contains("setupwraith") } }
        if (missing.isNotEmpty()) throw SetupFailure(SetupIssue.WIFI_NOT_SAVED, missing.joinToString(", ") { it.ssid })
        return client
    }

    /**
     * Restarts the TV once and checks Home and the disabled apps, while network debugging is still on and Undo can still
     * reach the TV (PROMPT.md). Android writes package state and the Home choice to disk about ten seconds after a
     * change (WRITE_SETTINGS_DELAY) and `sync` only flushes what is already written: rebooting sooner boots the old
     * state. So it waits 20 s, syncs, reboots, then reconnects for about four minutes. Skip it when nothing changed.
     * [expectedHome]: LauncherInstaller.PACKAGE when setup installed the new Home, else null.
     */
    suspend fun restartAndCheck(tv: TVDevice, connector: TVConnector, disabledBySetup: List<String>, expectedHome: String?,
                                onApproval: () -> Unit = {}): RestartOutcome {
        delay(20_000)
        attempt { tv.shell("sync", 30_000) }
        attempt { tv.shell("reboot", 5_000) }
        tv.close()
        delay(25_000)
        var client: TVDevice? = null
        for (i in 0 until 24) {   // about four minutes
            coroutineContext.ensureActive()
            client = attempt { connector.open(60_000, onApproval) }
            if (client != null) break
            delay(8_000)
        }
        val device = client ?: return RestartOutcome(null, null)
        for (i in 0 until 30) {   // until Android says the boot finished
            if (attempt { device.exec("getprop sys.boot_completed", 10_000) }?.trim() == "1") break
            delay(3_000)
        }
        delay(5_000)
        val home = lastLine(device.exec(DebloatRules.HOME_QUERY))
        val enabled = Pattern.packageNames(device.exec("pm list packages -e --user 0"))
        return RestartOutcome(device, RestartCheck.judge(home, enabled, disabledBySetup, expectedHome))
    }

    /**
     * The last ADB command of a setup or an update: switches debugging off on the TV (adbd stops, so the connection
     * drops), then checks the port refuses connections. Returns PortProbe's answer.
     */
    suspend fun turnOffDebugging(current: TVDevice?, connector: TVConnector, host: String, port: Int): Boolean? {
        var client = current
        // The link may have gone idle while the user tested the TV: reconnect with the approved key (no prompt).
        if (client != null && attempt { client!!.shell("echo ok", 5_000) } == null) { client.close(); client = null }
        if (client == null) {
            client = try { connector.open(15_000) {} } catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (e: Exception) { throw SetupFailure(SetupIssue.DEBUGGING_UNREACHABLE) }
        }
        attempt { client.shell("settings put global adb_wifi_enabled 0; settings put global adb_enabled 0", 8_000) }
        client.close()
        delay(2_000)
        return PortProbe.refuses(host, port)
    }

    /**
     * "Update Home screen": installs the newer launcher this app carries over the one on the TV (`pm install -r`),
     * keeping its config.json, wallpaper and layout. Returns false when the TV already had [bundledVersion] or newer
     * (nothing installed). [banner]: the connection's banner properties.
     */
    suspend fun updateHome(tv: TVDevice, banner: Map<String, String>, apk: ByteArray, bundledVersion: Int,
                           profiles: List<DebloatProfile>, store: RecoveryStore, host: String,
                           step: ((LauncherStep, Double) -> Unit)? = null): Boolean {
        // The profile decides the remote helpers and permissions, exactly as setup installed them.
        val properties = Debloater(tv).profileProperties(banner)
        // Only a TV whose Home is the new Home screen: after an undo the stock launcher is Home again, and an update
        // must not take it over (nor disable it) without a setup and its recovery record.
        val home = lastLine(tv.shell(DebloatRules.HOME_QUERY, 30_000).output.replace("\r", ""))
        if (!home.startsWith(LauncherInstaller.PACKAGE + "/")) throw SetupFailure(SetupIssue.UPDATE_HOME_NOT_OURS)
        // A tested profile by exact match, or the list applied last in this TV's recovery record.
        val identity = Debloater(tv).identity()
        val used = store.all().firstOrNull { saved ->
            saved.record.tv?.let { it.sameTV(identity) && it.key != null && it.key == identity.key } ?: (saved.record.host == host)
        }?.let { saved -> profiles.firstOrNull { it.id == saved.record.lastList } }
        val profile = DebloatProfile.match(properties, profiles) ?: used ?: throw SetupFailure(SetupIssue.UPDATE_NO_PROFILE)
        val installer = LauncherInstaller(tv)
        val installed = installer.installedVersion() ?: throw SetupFailure(SetupIssue.UPDATE_NOT_INSTALLED)
        if (installed >= bundledVersion) return false
        installer.install(apk, profile.manifest.launcher, theme = null, listedStock = profile.manifest.stockLauncher, step = step)
        if (installer.installedVersion() != bundledVersion) throw SetupFailure(SetupIssue.UPDATE_STILL_OLD)
        return true
    }
}
