package com.guilhermeramalho.puriotv

import android.app.Application
import android.os.Build
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.guilhermeramalho.puriotv.core.ClientIdentity
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
    ) {
        val ready get() = link == Link.READY
    }

    private val store = Store(application)
    val discovery = TVDiscovery(application)
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state
    private var identity: ClientIdentity? = null
    private var session: TVSession? = null
    private var inForeground = false
    private val wake = WakeRequest()

    init {
        store.tv?.let { tv -> _state.update { it.copy(paired = tv.pin != null, host = tv.host, tvName = tv.name) } }
    }

    private suspend fun identity(): ClientIdentity = identity ?: withContext(Dispatchers.IO) {
        KeystoreIdentity.loadOrCreate(store.clientName)
    }.also { identity = it }

    private fun newSession(host: String, block: (TVSession) -> Unit) {
        session?.disconnect()
        session = null
        viewModelScope.launch {
            val id = try { identity() } catch (e: Exception) {
                Log.w(TAG, "identity: $e")
                onError(Problem.IDENTITY_UNAVAILABLE)
                return@launch
            }
            val info = ClientInfo(Build.MODEL ?: "Android", getApplication<Application>().packageName, BuildInfo.versionName(getApplication()))
            val s = TVSession(host, id, store.clientName, info, viewModelScope)
            s.onEvent = ::handle
            session = s
            block(s)
        }
    }

    /** The person picked a TV (found on the Wi-Fi or typed): pair with it. A pairing already saved stays until this one succeeds. */
    fun choose(host: String, name: String) {
        _state.update { it.copy(pairing = Pairing.Asking, host = host, tvName = name) }
        pendingTV = Store.PairedTV(host, name, null)
        newSession(host) { it.pair() }
    }
    private var pendingTV: Store.PairedTV? = null

    /** Ask the TV for a new code (it showed none, or the last one expired). */
    fun pairAgain() { pendingTV?.let { choose(it.host, it.name) } }

    fun submit(code: String) {
        _state.update { it.copy(pairing = Pairing.Code()) }
        session?.submit(code)
    }

    fun cancelPairing() {
        session?.disconnect(); session = null
        pendingTV = null
        val saved = store.tv
        _state.update {
            it.copy(pairing = null, host = saved?.host ?: "", tvName = saved?.name ?: "", paired = saved?.pin != null, link = Link.IDLE)
        }
        if (saved?.pin != null) connect()
    }

    fun connect() {
        val tv = store.tv ?: return
        val pin = tv.pin ?: return
        if (!inForeground) return
        _state.update { it.copy(link = Link.CONNECTING, problem = null, tvName = tv.name, host = tv.host) }
        newSession(tv.host) { it.connect(pin) }
    }

    /** Forget the TV: back to the Connect screen. The TV keeps its side of the pairing until it is reset. */
    fun forget() {
        session?.disconnect(); session = null
        store.tv = null
        pendingTV = null
        _state.value = State()
    }

    fun tap(key: TVKey) { session?.key(key, 3) }
    fun press(key: TVKey) { session?.key(key, 1) }
    fun release(key: TVKey) { session?.key(key, 2) }
    fun launch(url: String) { session?.launch(url) }

    /** Power: a TV in standby or not answering gets a wake request that survives one reconnect. */
    fun power() {
        val s = _state.value
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
            session?.disconnect(); session = null
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
                _state.update { it.copy(paired = true, pairing = null, host = tv.host, tvName = tv.name) }
                connect()
            }
            TVSession.Event.Connected -> _state.update { it.copy(link = Link.READY, problem = null) }
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
    }

    override fun onCleared() { session?.disconnect(); discovery.stop() }

    private companion object {
        const val TAG = "PurioTV"
        val codeProblems = setOf(Problem.CODE_LENGTH, Problem.CODE_CHARACTERS, Problem.CODE_MISMATCH)
    }
}

object BuildInfo {
    fun versionName(app: Application): String =
        runCatching { app.packageManager.getPackageInfo(app.packageName, 0).versionName }.getOrNull() ?: "0"
}
