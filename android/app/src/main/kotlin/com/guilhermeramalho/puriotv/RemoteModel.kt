package com.guilhermeramalho.puriotv

import android.app.Application
import android.os.Build
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.guilhermeramalho.puriotv.core.BrandEvent
import com.guilhermeramalho.puriotv.core.BrandRemote
import com.guilhermeramalho.puriotv.core.BrandRemotes
import com.guilhermeramalho.puriotv.core.ClientIdentity
import com.guilhermeramalho.puriotv.core.RemoteApp
import com.guilhermeramalho.puriotv.core.TvKind
import com.guilhermeramalho.puriotv.core.supports
import com.guilhermeramalho.puriotv.core.ClientInfo
import com.guilhermeramalho.puriotv.core.Problem
import com.guilhermeramalho.puriotv.core.TVKey
import com.guilhermeramalho.puriotv.core.TVSession
import com.guilhermeramalho.puriotv.core.WakeRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The remote's state and the one session to the TV (RemoteModel.swift). Lives on the main thread (viewModelScope).
 * As on the iPhone: with a saved pairing the remote is always on screen, dimmed and "Offline · Retry" when the TV
 * can't be reached; pairing is a sheet over the Connect screen.
 */
class RemoteModel(application: Application) : AndroidViewModel(application) {
    enum class Link { IDLE, CONNECTING, READY, OFFLINE }

    sealed interface Pairing {
        /** Asking the TV to show its code. */
        data object Asking : Pairing
        /** The TV shows a code; [notice] says why the last one was refused. */
        data class Code(val notice: Problem? = null) : Pairing
        data class Failed(val problem: Problem) : Pairing
        /** A Roku/LG/Samsung TV shows its "Allow" prompt (instead of a code). */
        data object Allow : Pairing
    }

    data class State(
        val paired: Boolean = false,
        val host: String = "",
        val tvName: String = "",
        val link: Link = Link.IDLE,
        val problem: Problem? = null,
        val pairing: Pairing? = null,
        val power: Boolean? = null,
        val foreground: String? = null,
        val volume: TVSession.Event.Volume? = null,
        /** Counts new pairings, so the app can offer TV setup once right after one. */
        val pairings: Int = 0,
        /** Android TV, or a Roku / LG / Samsung driven by a BrandRemote. */
        val kind: TvKind = TvKind.ANDROID_TV,
        /** The app on screen on a Roku / LG TV, by its name there (Android TVs report a package in [foreground]). */
        val appName: String? = null,
    ) {
        val ready get() = link == Link.READY
        fun supports(key: TVKey) = kind.supports(key)
    }

    private val store = application.purio.store
    val settings = application.purio.settings
    /** TV Home editing (the TV tab and the sleep timer). */
    val editor by lazy { HomeEditor(application, viewModelScope, this, settings) }
    /** What the app knows about each TV's setup (TV tab cards, the offer after pairing). */
    val setup = com.guilhermeramalho.puriotv.core.TVSetupStatus(PrefsSetupStore(application), viewModelScope)
    /** Quick actions run from the Actions tab. */
    val actions by lazy { ActionController(application, viewModelScope, this) }
    val discovery = TVDiscovery(application)
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state
    private var identity: ClientIdentity? = null
    private var session: TVSession? = null
    private var brand: BrandRemote? = null
    private var inForeground = false
    private val wake = WakeRequest()
    private var retry: kotlinx.coroutines.Job? = null
    private var attempt = 0

    init {
        store.tv?.let { tv -> _state.update { it.copy(paired = tv.pin != null, host = tv.host, tvName = tv.name, kind = kindOf(tv)) } }
    }

    private suspend fun identity(): ClientIdentity = identity ?: withContext(Dispatchers.IO) {
        KeystoreIdentity.loadOrCreate(store.clientName)
    }.also { identity = it }

    private fun kindOf(tv: Store.PairedTV?) = tv?.kind?.let { k -> TvKind.entries.firstOrNull { it.name == k } } ?: TvKind.ANDROID_TV

    private fun newBrand(kind: TvKind, host: String): BrandRemote? {
        session?.disconnect(); session = null
        brand?.disconnect()
        brand = BrandRemotes.make(kind, host, viewModelScope)?.also { it.onEvent = ::handleBrand }
        return brand
    }

    private fun newSession(host: String, block: (TVSession) -> Unit) {
        brand?.disconnect(); brand = null
        session?.disconnect()
        session = null
        viewModelScope.launch {
            val id = try { identity() } catch (e: Exception) {
                Log.w(TAG, "identity: $e")
                onError(Problem.IDENTITY_UNAVAILABLE)
                return@launch
            }
            val s = TVSession(host, id, store.clientName, clientInfo(), viewModelScope)
            s.onEvent = ::handle
            session = s
            block(s)
        }
    }

    /** The person picked a TV (found on the Wi-Fi or typed): pair with it. A pairing already saved stays until this one succeeds. */
    fun choose(host: String, name: String, kind: TvKind = TvKind.ANDROID_TV) {
        _state.update { it.copy(pairing = Pairing.Asking, host = host, tvName = name, kind = kind, appName = null) }
        pendingTV = Store.PairedTV(host, name, null, kind.name)
        if (kind != TvKind.ANDROID_TV) { newBrand(kind, host)?.connect(null); return }
        newSession(host) { it.pair() }
    }
    private var pendingTV: Store.PairedTV? = null

    /** Ask the TV for a new code (it showed none, or the last one expired). */
    fun pairAgain() { pendingTV?.let { choose(it.host, it.name, kindOf(it)) } }

    fun submit(code: String) {
        _state.update { it.copy(pairing = Pairing.Code()) }
        session?.submit(code)
    }

    fun cancelPairing() {
        session?.disconnect(); session = null
        brand?.disconnect(); brand = null
        pendingTV = null
        val saved = store.tv
        _state.update {
            it.copy(pairing = null, host = saved?.host ?: "", tvName = saved?.name ?: "", paired = saved?.pin != null, link = Link.IDLE, kind = kindOf(saved))
        }
        if (saved?.pin != null) connect()
    }

    /** Settings › Connection › Save and connect: a new address for the paired TV keeps its pairing only if it's the same TV. */
    fun saveHost(address: String) {
        val tv = store.tv ?: return
        if (address == tv.host) return
        store.tv = tv.copy(host = address)
        _state.update { it.copy(host = address) }
        connect()
    }

    fun connect() {
        val tv = store.tv ?: return
        val pin = tv.pin ?: return
        if (!inForeground) return
        retry?.cancel(); retry = null
        val kind = kindOf(tv)
        _state.update { it.copy(link = Link.CONNECTING, problem = null, tvName = tv.name, host = tv.host, kind = kind) }
        if (kind != TvKind.ANDROID_TV) { newBrand(kind, tv.host)?.connect(pin); return }
        newSession(tv.host) { it.connect(pin) }
    }

    /** Forget the TV: back to the Connect screen. The TV keeps its side of the pairing until it is reset. */
    fun forget() {
        session?.disconnect(); session = null
        brand?.disconnect(); brand = null
        store.tv = null
        pendingTV = null
        _state.value = State()
    }

    fun tap(key: TVKey) { brand?.key(key, 3) ?: session?.key(key, 3) }
    fun press(key: TVKey) { brand?.key(key, 1) ?: session?.key(key, 1) }
    fun release(key: TVKey) { brand?.key(key, 2) ?: session?.key(key, 2) }
    fun launch(url: String) { session?.launch(url) }
    /** An app button: its link on Android TVs, its name among the TV's own apps on Roku, LG and Samsung. */
    fun open(app: RemoteApp) {
        val b = brand ?: run { session?.launch(app.launchURL); return }
        viewModelScope.launch {
            try { if (!b.launch(app.name)) _state.update { it.copy(problem = Problem.ACTION_APP_UNAVAILABLE) } }
            catch (e: Exception) { Log.w(TAG, "open ${app.name}: $e") }
        }
    }
    /** Every app a Roku, LG or Samsung TV reports (All apps); null on Android TV, where Purio's Home lists them. */
    suspend fun brandApps(): List<com.guilhermeramalho.puriotv.core.BrandApp>? = brand?.apps()
    fun launch(app: com.guilhermeramalho.puriotv.core.BrandApp) {
        val b = brand ?: return
        viewModelScope.launch { try { b.launch(app) } catch (e: Exception) { Log.w(TAG, "launch ${app.name}: $e") } }
    }
    /** Opens an app by name on any TV (quick actions): false when the TV doesn't have it. */
    suspend fun open(name: String, link: String): Boolean {
        brand?.let { return it.launch(name) }
        sendLink(link); return true
    }

    /** Power: a TV in standby or not answering gets a wake request that survives one reconnect. */
    fun power() {
        val s = _state.value
        if (brand != null || s.kind != TvKind.ANDROID_TV) {
            // Roku turns on over the network; LG and Samsung only off (on needs Wake-on-LAN).
            if (s.ready && (s.power != false || s.kind == TvKind.ROKU)) tap(TVKey.POWER)
            else if (!s.ready) { _state.update { it.copy(problem = Problem.TURN_ON_WITH_REMOTE) }; connect() }
            return
        }
        if (s.ready) { tap(TVKey.POWER); return }
        wake.begin()
        connect()
    }

    /** The app came to the front: reconnect. It went to the back: close the connection; nothing runs in the background. */
    fun foreground(visible: Boolean) {
        inForeground = visible
        if (visible) {
            if (_state.value.paired && _state.value.pairing == null) connect()
        } else {
            if (_state.value.pairing != null) cancelPairing()
            retry?.cancel(); retry = null
            editor.close(); actions.cancel()
            session?.disconnect(); session = null
            brand?.disconnect(); brand = null
            _state.update { it.copy(link = Link.IDLE) }
        }
    }

    private fun handle(event: TVSession.Event) {
        when (event) {
            TVSession.Event.PairingCodeNeeded -> _state.update { it.copy(pairing = Pairing.Code()) }
            is TVSession.Event.Paired -> {
                val tv = (pendingTV ?: return).copy(pin = event.pin)
                store.tv = tv
                pendingTV = null
                _state.update { it.copy(paired = true, pairing = null, host = tv.host, tvName = tv.name, pairings = it.pairings + 1) }
                connect()
            }
            TVSession.Event.Connected -> { attempt = 0; _state.update { it.copy(link = Link.READY, problem = null) } }
            is TVSession.Event.Power -> {
                _state.update { it.copy(power = event.on) }
                wake.consume(event.on)?.let { tap(it) }
            }
            is TVSession.Event.Foreground -> _state.update { it.copy(foreground = event.packageName) }
            is TVSession.Event.Volume -> _state.update { it.copy(volume = event) }
            is TVSession.Event.Error -> {
                Log.w(TAG, "${event.problem}: ${event.detail}")
                onError(event.problem)
            }
        }
    }

    private fun handleBrand(event: BrandEvent) {
        when (event) {
            BrandEvent.ApprovalNeeded -> _state.update { it.copy(pairing = Pairing.Allow) }
            is BrandEvent.Approved -> {
                val tv = (pendingTV ?: store.tv ?: return).copy(pin = event.credential)
                store.tv = tv
                val fresh = pendingTV != null
                pendingTV = null
                _state.update { it.copy(paired = true, pairing = null, host = tv.host, tvName = tv.name, pairings = if (fresh) it.pairings + 1 else it.pairings) }
            }
            BrandEvent.Connected -> { attempt = 0; _state.update { it.copy(link = Link.READY, problem = null, pairing = null) } }
            is BrandEvent.Power -> _state.update { it.copy(power = event.on) }
            is BrandEvent.Foreground -> _state.update { it.copy(appName = event.name) }
            is BrandEvent.Volume -> _state.update { it.copy(volume = TVSession.Event.Volume(event.level, event.maximum, event.muted)) }
            is BrandEvent.Error -> { Log.w(TAG, "${event.problem}: ${event.detail}"); onError(event.problem) }
        }
    }

    private fun onError(problem: Problem) {
        val pairing = _state.value.pairing
        if (pairing != null) {
            _state.update {
                it.copy(pairing = if (pairing is Pairing.Code && problem in codeProblems) Pairing.Code(problem) else Pairing.Failed(problem))
            }
            return
        }
        // The TV no longer holds this pairing: forget the pin, the Connect screen asks to pair again.
        if (problem == Problem.IDENTITY_CHANGED || problem == Problem.PAIRING_REJECTED_BY_TV) {
            store.tv = store.tv?.copy(pin = null)
            _state.update { it.copy(paired = false, link = Link.IDLE, problem = problem) }
            return
        }
        if (!inForeground) return
        _state.update { it.copy(link = Link.OFFLINE, problem = problem) }
        scheduleReconnect()
    }

    /** "Reconnect automatically": retries after 1, 2, 4, 8, then every 15 s, only while the app is in front. */
    private fun scheduleReconnect() {
        if (!inForeground || _state.value.pairing != null || !settings.current.autoReconnect) return
        retry?.cancel()
        val wait = minOf(15_000L, 1000L shl minOf(attempt, 4))
        attempt++
        retry = viewModelScope.launch { kotlinx.coroutines.delay(wait); retry = null; connect() }
    }

    /** Typing on the TV: the focused field gets [text] inserted at its cursor. */
    suspend fun sendText(text: String) {
        brand?.let { if (_state.value.ready) { it.writeText(text); return } }
        val s = session
        if (!_state.value.ready || s == null) throw UserMessage(getApplication<Application>().getString(R.string.connect_before_text))
        s.writeText(text)
    }

    /** Sends an app link through the paired connection and waits until it is written (TV Home editor key). */
    suspend fun sendLink(url: String) {
        val s = session
        if (!_state.value.ready || s == null) throw UserMessage(getApplication<Application>().getString(R.string.connect_tv_first))
        s.writeLaunch(url)
    }

    /** Connected and the TV spoke recently: after the phone sleeps a dead socket can still look connected. */
    private val remoteLooksAlive get() = _state.value.ready && session?.let { System.currentTimeMillis() - it.lastInbound < 12_000 } == true

    /** Reconnects the remote first if it went quiet (up to 10 s). False if it still isn't answering. */
    suspend fun freshen(): Boolean {
        brand?.let { if (_state.value.ready && it.alive()) return true }
        if (brand == null && remoteLooksAlive) return true
        attempt = 0; connect()
        repeat(40) { kotlinx.coroutines.delay(250); if (remoteLooksAlive || (brand != null && _state.value.ready)) return true }
        return false
    }

    /** The saved pairing for background runs (quick actions); null when there is none. */
    val pin: ByteArray? get() = store.tv?.pin
    suspend fun clientIdentity() = identity()
    fun clientInfo() = ClientInfo(Build.MODEL ?: "Android", getApplication<Application>().packageName, BuildInfo.versionName(getApplication()))
    val clientName get() = store.clientName

    override fun onCleared() { session?.disconnect(); brand?.disconnect(); discovery.stop() }

    private companion object {
        const val TAG = "PurioTV"
        val codeProblems = setOf(Problem.CODE_LENGTH, Problem.CODE_CHARACTERS, Problem.CODE_MISMATCH)
    }
}

object BuildInfo {
    fun versionName(app: Application): String =
        runCatching { app.packageManager.getPackageInfo(app.packageName, 0).versionName }.getOrNull() ?: "0"
}
