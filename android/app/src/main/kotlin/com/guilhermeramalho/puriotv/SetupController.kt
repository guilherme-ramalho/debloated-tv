package com.guilhermeramalho.puriotv

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.guilhermeramalho.puriotv.core.AdbClient
import com.guilhermeramalho.puriotv.core.ApplyResult
import com.guilhermeramalho.puriotv.core.DebloatList
import com.guilhermeramalho.puriotv.core.DebloatOverrides
import com.guilhermeramalho.puriotv.core.DebloatPlan
import com.guilhermeramalho.puriotv.core.DebloatProfile
import com.guilhermeramalho.puriotv.core.Debloater
import com.guilhermeramalho.puriotv.core.HomeScreenBlock
import com.guilhermeramalho.puriotv.core.LauncherInstaller
import com.guilhermeramalho.puriotv.core.LauncherStep
import com.guilhermeramalho.puriotv.core.PortProbe
import com.guilhermeramalho.puriotv.core.ProfileMatch
import com.guilhermeramalho.puriotv.core.ProfileMatcher
import com.guilhermeramalho.puriotv.core.RecoveryRecord
import com.guilhermeramalho.puriotv.core.RecoveryStore
import com.guilhermeramalho.puriotv.core.SetupFailure
import com.guilhermeramalho.puriotv.core.SetupIssue
import com.guilhermeramalho.puriotv.core.SetupSequence
import com.guilhermeramalho.puriotv.core.TVAddress
import com.guilhermeramalho.puriotv.core.TVDevice
import com.guilhermeramalho.puriotv.core.TVInventory
import com.guilhermeramalho.puriotv.core.TVSetupStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Shared by the setup controllers: one job at a time on the main thread (the engine does its socket work on IO), the
 * connection it holds, and cancel() for when the screen goes away. Nothing outlives the screen's work: cancel() stops
 * the job and closes the connection, and nothing is scheduled.
 */
abstract class SetupWork(protected val app: Context) {
    protected val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var task: Job? = null
    protected var adb: TVDevice? = null

    var busy by mutableStateOf(false); protected set
    var waitingForApproval by mutableStateOf(false); protected set
    var message by mutableStateOf("")
    var error by mutableStateOf<String?>(null)

    protected fun s(id: Int, vararg args: Any): String = app.getString(id, *args)

    /** The connection's gone (the screen went away and came back): the TV must be read again before any change. */
    var lostConnection by mutableStateOf(false); protected set

    open fun cancel() {
        task?.cancel(); task = null
        busy = false; waitingForApproval = false
        adb?.let { old -> scope.launch { old.close() } }
        adb = null
    }

    protected fun perform(work: suspend () -> Unit) {
        task?.cancel()
        error = null; busy = true
        var job: Job? = null
        job = scope.launch {
            try { work() } catch (e: CancellationException) { } catch (e: Throwable) { error = setupErrorText(app, e) }
            if (task === job) { busy = false; waitingForApproval = false }
        }
        task = job
        if (job.isCompleted) { busy = false; waitingForApproval = false }
    }

    /** Called from the connection's IO thread while the TV asks to allow this phone. */
    protected fun approvalAsked(note: String? = null) {
        scope.launch { waitingForApproval = true; if (note != null) message = note }
    }

    protected fun requireConnection(): TVDevice? {
        val tv = adb
        if (tv == null) { lostConnection = true; error = s(R.string.su_issue_not_connected) }
        return tv
    }
}

/**
 * The guided setup (DebloatFlow.swift): connect over network debugging, recognise the TV, choose, review, apply,
 * install the new Home screen, test, and close debugging again. Every TV change goes through the engine
 * (Debloater, LauncherInstaller, SetupSequence), which carries upstream's safety checks; this class only sequences
 * them and keeps the recovery record saved before any change.
 */
class DebloatController(app: Context, private val status: TVSetupStatus, host: String) : SetupWork(app) {
    enum class Step { OVERVIEW, DEVELOPER, CONNECT, INSPECT, CHOOSE, REVIEW, HOME, APPLY, TEST, FINISH }

    var step by mutableStateOf(Step.OVERVIEW)
    var address by mutableStateOf(host)
    var acknowledged by mutableStateOf(false)
    var inventory by mutableStateOf<TVInventory?>(null); private set
    var profile by mutableStateOf<DebloatProfile?>(null); private set
    /** The lists setup can offer for this TV, best first (ProfileMatcher), and the one in use. */
    var candidates by mutableStateOf<List<ProfileMatch>>(emptyList()); private set
    var match by mutableStateOf<ProfileMatch?>(null); private set
    var keep by mutableStateOf<Set<String>>(emptySet())
    var plan by mutableStateOf<DebloatPlan?>(null); private set
    var understood by mutableStateOf(false)
    /** Passwords typed for the networks the setup wizard owns; kept only until they're sent, never saved. */
    var wifiPasswords by mutableStateOf<Map<String, String>>(emptyMap())
    /** Each password typed a second time: a typo would take the TV off Wi-Fi. */
    var wifiConfirm by mutableStateOf<Map<String, String>>(emptyMap())
    var installLauncher by mutableStateOf(true)
    var dock by mutableStateOf<List<String>>(emptyList())
    var progress by mutableFloatStateOf(0f); private set
    val log = mutableStateListOf<String>()
    var result by mutableStateOf<ApplyResult?>(null); private set
    var recordFile by mutableStateOf<File?>(null); private set
    var homeComponent by mutableStateOf<String?>(null); private set
    var debuggingClosed by mutableStateOf<Boolean?>(null); private set
    /** What the restart at the end of apply found; shown on the test step. */
    var restartProblem by mutableStateOf<String?>(null); private set
    var restartNote by mutableStateOf<String?>(null); private set
    var restartChecked by mutableStateOf(false); private set
    /** What the last restore from this flow read back from the TV. */
    var restoreResult by mutableStateOf<String?>(null); private set
    var restoredOK by mutableStateOf(false); private set
    /** The bundled lists, read once a connection needs them (hundreds of small files, off the main thread). */
    var profiles by mutableStateOf<List<DebloatProfile>>(emptyList()); private set
    private var profilesLoaded = false
    /** Whether the last failure came while reading the TV (Try again reads it again instead of reconnecting). */
    private var inspectFailed = false

    val store: RecoveryStore = SetupPlatform.store(app)

    /** The address the TV tab keys this TV by. */
    val setupHost: String get() = TVAddress.parse(address)?.host ?: address

    private fun note(line: String) { log.add(line); message = line }

    // MARK: connect and inspect

    fun connect() {
        val target = TVAddress.parse(address) ?: run { error = s(R.string.su_issue_invalid_address); return }
        lostConnection = false
        inspectFailed = false
        perform {
            message = s(R.string.su_connecting_to, target.host)
            adb?.let { old -> adb = null; old.close() }
            val client = SetupPlatform.open(target, 120_000) { approvalAsked(s(R.string.su_allow_on_tv)) }
            adb = client
            waitingForApproval = false
            note(s(R.string.su_connected_to, client.properties["ro.product.model"] ?: s(R.string.su_the_tv)))
            step = Step.INSPECT
            inspectNow(client.properties)
        }
    }

    fun inspect() { perform { inspectNow((adb as? AdbClient)?.properties ?: emptyMap()) } }

    /** Try again on the connecting step: read the TV again when the connection is up, else connect again. */
    fun retry() { if (inspectFailed && adb != null) inspect() else connect() }

    private suspend fun inspectNow(banner: Map<String, String>) {
        val tv = adb ?: throw SetupFailure(SetupIssue.NOT_CONNECTED)
        inspectFailed = true
        message = s(R.string.su_reading)
        if (!profilesLoaded) {
            profiles = withContext(Dispatchers.IO) { SetupPlatform.loadProfiles(app) }
            profilesLoaded = true
        }
        val inv = Debloater(tv).inspect(banner)
        inspectFailed = false
        inventory = inv
        profile = null; match = null
        candidates = ProfileMatcher.rank(inv.properties, inv.installed, inv.disabled, profiles)
        // What the TV tab shows comes from what this flow saw.
        status.inspected(setupHost, inv.properties, null, listsFound = candidates.isNotEmpty())
        // A profile tested with Purio TV on this exact firmware is used as before; a community list is the person's choice.
        val first = candidates.firstOrNull()
        if (first != null && first.kind == ProfileMatch.Kind.TESTED) { use(first); return }
        message = if (candidates.isEmpty()) s(R.string.su_no_list) else s(R.string.su_choose_list_message)
    }

    /** The person picked one of [candidates] ("closest" ones only after the confirmation). */
    fun choose(candidate: ProfileMatch) { perform { use(candidate) } }

    private fun use(candidate: ProfileMatch) {
        val inv = inventory
        if (adb == null || inv == null) throw SetupFailure(SetupIssue.NOT_CONNECTED)
        val chosen = candidate.profile
        profile = chosen
        match = candidate
        installLauncher = homeScreenBlock == null
        // The recovery record is written when the person applies, before the first change (saveRecord).
        keep = emptySet()
        dock = SetupSequence.defaultDock(chosen, inv)
        status.inspected(setupHost, inv.properties, chosen)
        note(s(R.string.su_recognised, chosen.manifest.name))
        step = Step.CHOOSE
    }

    /** Entries the person can choose: installed, still enabled, and not protected. */
    val choices: List<DebloatList.Entry>
        get() {
            val p = profile ?: return emptyList(); val inv = inventory ?: return emptyList()
            return SetupSequence.choices(p, inv, match?.kind)
        }

    /** null: setup may install the new Home screen with this list on this TV. */
    val homeScreenBlock: HomeScreenBlock? get() = SetupSequence.homeScreenBlock(profile, inventory)
    val protectedCount: Int get() = profile?.list?.neverDisable?.count { inventory?.installed?.contains(it) == true } ?: 0
    val alreadyHandled: Int get() = (profile?.list?.entries?.size ?: 0) - choices.size

    // MARK: review and apply

    fun review() {
        val p = profile ?: return; val inv = inventory ?: return
        val tv = requireConnection() ?: return
        perform {
            message = s(R.string.su_running_checks)
            val chosen = choices.map { it.packageName }.filter { it !in keep }
            plan = Debloater(tv).plan(chosen, p.list, inv, DebloatOverrides())
            understood = false
            step = Step.REVIEW
        }
    }

    /** Every Wi-Fi network the wizard owns that needs a password has one typed in, twice the same. */
    val wifiReady: Boolean get() = SetupSequence.wifiReady(plan, wifiPasswords, wifiConfirm)

    /** The Home step blocks applying: the new Home is wanted but the setup wizard keeps Home. */
    val homeBlocked: Boolean get() = installLauncher && homeScreenBlock == null && plan?.setupKeepsHome == true

    fun apply() {
        val p = profile ?: return; val pl = plan ?: return; val inv = inventory ?: return
        if (homeBlocked) return
        val wantsHome = installLauncher && homeScreenBlock == null
        if (wantsHome && !SetupPlatform.hasBundledApk(app)) { error = s(R.string.su_no_bundled_home); return }
        val target = TVAddress.parse(address) ?: run { error = s(R.string.su_issue_invalid_address); return }
        val first = requireConnection() ?: return
        step = Step.APPLY; log.clear(); progress = 0f; result = null
        val passwords = wifiPasswords
        val host = setupHost
        val chosenDock = dock
        perform {
            val apk = if (wantsHome) SetupPlatform.bundledApk(app) ?: throw SetupFailure(SetupIssue.NO_BUNDLED_HOME) else null
            var tv: TVDevice = first
            // How the TV is before anything changes; nothing changes if this fails.
            recordFile = SetupSequence.saveRecord(tv, store, p, inv, host)
            note(s(R.string.su_record_saved))
            // Wi-Fi the setup wizard saved goes when the wizard is disabled: save it again as the shell's first.
            if (pl.wifiToResave.isNotEmpty()) {
                note(s(R.string.su_saving_wifi))
                tv = SetupSequence.resaveWifi(tv, pl.wifiToResave, passwords, SetupPlatform.connector(target))
                adb = tv
                wifiPasswords = emptyMap(); wifiConfirm = emptyMap()
                note(s(R.string.su_wifi_saved, pl.wifiToResave.joinToString(", ") { it.ssid }))
            }
            // Group by group, as upstream's tested runs did, stopping if the TV stops answering.
            val total = maxOf(1, pl.disable.size) + (if (apk == null) 0 else 6)
            val r = SetupSequence.applyGroups(tv, p, pl,
                onGroup = { i, n, count -> note(s(R.string.su_disabling_group, i + 1, n, count)) },
                onProgress = { done -> progress = done.toFloat() / total })
            result = r
            note(if (r.stillEnabled.isEmpty()) s(R.string.su_disabled_n, r.disabled.size) else s(R.string.su_disabled_n_still, r.disabled.size, r.stillEnabled.size))
            if (apk != null) {
                val theme = p.themeConfig(chosenDock)
                val base = progress
                val steps = LauncherStep.entries.size
                homeComponent = LauncherInstaller(tv).install(apk, p.manifest.launcher, theme, p.manifest.stockLauncher) { st, fraction ->
                    scope.launch {
                        message = s(st.text())
                        progress = minOf(1f, base + ((st.ordinal + fraction) / steps).toFloat() * (1 - base))
                    }
                }
                note(s(R.string.su_home_installed))
            }
            // Nothing changed (every app kept, no new Home): nothing a restart could undo, so no restart.
            if (r.disabled.isNotEmpty() || apk != null) restartAndCheck(tv, target, r.disabled)
            progress = 1f
            step = Step.TEST
            status.update(host) { info ->
                info.copy(homeInstalled = if (homeComponent != null) true else info.homeInstalled, disabledCount = r.disabled.size)
            }
        }
    }

    /**
     * Restarts the TV once and checks Home and the disabled apps while network debugging is still on and Undo can still
     * reach the TV (SetupSequence.restartAndCheck: 20 s wait, sync, reboot, reconnect for about four minutes). A
     * one-time minute or two per setup; nothing runs afterwards.
     */
    private suspend fun restartAndCheck(tv: TVDevice, target: TVAddress, disabledBySetup: List<String>) {
        restartProblem = null; restartNote = null; restartChecked = false
        note(s(R.string.su_restarting))
        // The engine closes this connection for the reboot; until then cancel() still closes it.
        val outcome = SetupSequence.restartAndCheck(tv, SetupPlatform.connector(target), disabledBySetup,
            expectedHome = if (homeComponent == null) null else LauncherInstaller.PACKAGE,
            onApproval = { approvalAsked() })
        waitingForApproval = false
        adb = outcome.device
        val check = outcome.check
        if (check == null) { restartProblem = s(R.string.su_restart_no_reconnect); return }
        if (!check.homeOK) restartProblem = s(R.string.su_restart_bad_home, check.home.ifEmpty { s(R.string.su_nothing) })
        if (check.reEnabled.isNotEmpty()) restartNote = s(R.string.su_re_enabled, check.reEnabled.size, check.reEnabled.joinToString(", "))
        restartChecked = check.homeOK
        note(if (check.homeOK) s(R.string.su_restart_ok) else restartProblem ?: "")
    }

    /**
     * Puts back what this setup's recovery record holds (from the apply and test steps). Reconnects with the approved
     * key when the connection went away; the engine refuses a record made on another TV.
     */
    fun restore() {
        val file = recordFile ?: return
        val record: RecoveryRecord = store.load(file) ?: return
        val target = TVAddress.parse(address) ?: return
        val stock = profile?.manifest?.stockLauncher ?: Debloater.DEFAULT_STOCK
        val host = setupHost
        restoreResult = null
        perform {
            note(s(R.string.su_restoring))
            val current = adb
            val alive = current != null && runCatchingTV { current.shell("echo ok", 5_000) } != null
            val tv: TVDevice = current?.takeIf { alive } ?: run {
                current?.close(); adb = null
                SetupPlatform.open(target, 120_000) { approvalAsked(s(R.string.su_allow_on_tv)) }.also { adb = it; waitingForApproval = false }
            }
            val report = Debloater(tv).restore(record, stock)
            val summary = restoreSummary(app, report)
            note(summary)
            restoreResult = summary; restoredOK = report.complete
            if (report.complete) status.restored(host)
        }
    }

    // MARK: finish

    /** The last step of a setup: switches debugging off on the TV, then checks the port refuses connections. */
    fun turnOffDebugging() {
        val target = TVAddress.parse(address) ?: return
        debuggingClosed = null
        perform {
            val client = adb
            adb = null
            debuggingClosed = SetupSequence.turnOffDebugging(client, SetupPlatform.connector(target), target.host, target.port)
        }
    }

    fun checkDebuggingClosed() {
        val target = TVAddress.parse(address) ?: return
        cancel()
        debuggingClosed = null
        scope.launch { debuggingClosed = PortProbe.refuses(target.host, target.port) }
    }

    /** Back on the connecting step after the connection went away: read the TV again from the start. */
    fun reconnect() {
        error = null
        step = Step.CONNECT
        connect()
    }

    /** One step back (the toolbar's Back on the steps before apply). */
    fun back() {
        if (busy) return
        error = null
        step = Step.entries[maxOf(0, step.ordinal - 1)]
    }

    /** Back while connecting or reading the TV (the approval can wait two minutes): stop, close, and go to the address. */
    fun abandonConnecting() {
        cancel()
        error = null
        step = Step.DEVELOPER
    }
}

/** Swift's `try?` for a TV call: null when it fails, but cancellation still cancels. */
internal suspend fun <T> runCatchingTV(block: suspend () -> T): T? =
    try { block() } catch (e: CancellationException) { throw e } catch (e: Exception) { null }

/**
 * "Update Home screen" (HomeUpdateFlow): installs the newer launcher this app carries over the one on the TV, keeping
 * its layout and settings. SetupSequence.updateHome checks the TV again over ADB before anything is installed.
 */
class HomeUpdateController(app: Context, host: String) : SetupWork(app) {
    enum class Step { START, CONNECTING, UPDATING, DONE }

    var step by mutableStateOf(Step.START)
    var address by mutableStateOf(host)
    var progress by mutableFloatStateOf(0f); private set
    /** True when the TV already had this version (nothing installed). */
    var alreadyCurrent by mutableStateOf(false); private set
    var debuggingClosed by mutableStateOf<Boolean?>(null); private set
    /** The TV hasn't reported anything for a while. */
    var slow by mutableStateOf(false); private set
    /** Asking the TV afresh whether the update landed, after the connection broke or stalled. */
    var checking by mutableStateOf(false); private set
    /** The TV started installing in this session: a retry checks it and finishes the update rather than starting over. */
    var installStarted by mutableStateOf(false); private set
    private var lastHeard = System.currentTimeMillis()
    private var stalled = false
    private var watchdog: Job? = null

    private fun heard() { lastHeard = System.currentTimeMillis(); slow = false }

    override fun cancel() {
        watchdog?.cancel(); watchdog = null
        slow = false; checking = false
        super.cancel()
    }

    fun update() {
        val target = TVAddress.parse(address) ?: run { error = s(R.string.su_issue_invalid_address); return }
        val bundled = bundledHomeVersion(app)
        if (bundled == null || !SetupPlatform.hasBundledApk(app)) { error = s(R.string.su_no_bundled_home); return }
        step = if (installStarted) Step.UPDATING else Step.CONNECTING
        progress = 0f; alreadyCurrent = false; debuggingClosed = null; stalled = false
        heard()
        perform {
            try {
                try { attempt(target, bundled) }
                catch (first: Exception) {
                    if (!installStarted || (first is CancellationException && !stalled)) throw first
                    // The connection broke or stalled after the TV began installing. It may well have finished: ask
                    // it over a fresh connection, and finish the last steps if the new Home is there.
                    stalled = false; checking = true
                    try { attempt(target, bundled) }
                    catch (second: Exception) { throw if (second is CancellationException && !stalled) second else if (second is CancellationException) first else second }
                }
            } finally { watchdog?.cancel(); watchdog = null; slow = false; checking = false }
        }
        watchdog?.cancel()
        watchdog = scope.launch {
            while (true) {
                delay(5_000)
                if (!busy) return@launch
                if (waitingForApproval) { heard(); continue }   // the person is at the TV
                val quiet = System.currentTimeMillis() - lastHeard
                if (quiet > SLOW_AFTER_MS && !slow) slow = true
                if (quiet > STALLED_AFTER_MS && installStarted && !checking && !stalled) {
                    stalled = true
                    adb?.let { old -> adb = null; old.close() }   // the waiting step throws; update() asks the TV afresh
                }
            }
        }
    }

    private suspend fun attempt(target: TVAddress, bundled: Int) {
        message = if (checking) s(R.string.su_update_checking) else s(R.string.su_connecting_to, target.host); heard()
        adb?.let { old -> adb = null; old.close() }
        val apk = SetupPlatform.bundledApk(app) ?: throw SetupFailure(SetupIssue.NO_BUNDLED_HOME)
        val client = SetupPlatform.open(target, 120_000) { approvalAsked(s(R.string.su_allow_on_tv)) }
        adb = client
        waitingForApproval = false
        heard()
        val profiles = withContext(Dispatchers.IO) { SetupPlatform.loadProfiles(app) }
        val steps = LauncherStep.entries.size
        val installed = SetupSequence.updateHome(client, client.properties, apk, bundled, profiles, SetupPlatform.store(app), target.host,
            resume = installStarted, installing = { installStarted = true }) { st, fraction ->
            scope.launch {
                if (step == Step.DONE) return@launch   // a late progress report
                step = Step.UPDATING
                message = s(st.text())
                progress = minOf(1f, ((st.ordinal + fraction) / steps).toFloat())
                heard()
            }
        }
        alreadyCurrent = !installed
        progress = 1f
        step = Step.DONE
    }

    companion object {
        /** No news from the TV for this long: the screen says it's taking a while. */
        const val SLOW_AFTER_MS = 30_000L
        /** No news for this long once the install began: drop the connection and ask the TV afresh (LCH-22). */
        const val STALLED_AFTER_MS = 180_000L
    }

    fun turnOffDebugging() {
        val target = TVAddress.parse(address) ?: return
        debuggingClosed = null
        perform {
            val client = adb
            adb = null
            debuggingClosed = SetupSequence.turnOffDebugging(client, SetupPlatform.connector(target), target.host, target.port)
        }
    }
}

/** Undo TV setup (UndoSetupView): pick a saved record, connect, restore, report what the TV says. */
class UndoController(app: Context, private val status: TVSetupStatus, host: String) : SetupWork(app) {
    val store = SetupPlatform.store(app)
    var records by mutableStateOf<List<RecoveryStore.Saved>>(emptyList()); private set
    var selected by mutableStateOf<File?>(null)
    var address by mutableStateOf(host)
    var done by mutableStateOf(false); private set

    /** Read again on every visit, so a record saved by a setup since is listed. */
    fun reload() {
        scope.launch { records = withContext(Dispatchers.IO) { store.all() } }
    }

    fun select(saved: RecoveryStore.Saved) { selected = saved.file; address = saved.record.host }

    fun restore() {
        val file = selected ?: return
        val target = TVAddress.parse(address) ?: return
        done = false; message = ""
        perform {
            val record = withContext(Dispatchers.IO) { store.load(file) } ?: throw UserMessage(s(R.string.problem_other))
            val client = SetupPlatform.open(target, 120_000) { approvalAsked() }
            adb = client
            waitingForApproval = false
            val stock = withContext(Dispatchers.IO) {
                runCatching { DebloatProfile.load(AssetProfileSource(app.assets), record.list) }.getOrNull()?.manifest?.stockLauncher
            } ?: Debloater.DEFAULT_STOCK
            val report = try { Debloater(client).restore(record, stock) } finally { adb = null; client.close() }
            done = report.complete
            if (report.complete) status.restored(target.host)
            message = restoreSummary(app, report)
        }
    }
}
