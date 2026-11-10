package com.guilhermeramalho.puriotv

import android.app.Application
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.guilhermeramalho.puriotv.core.ClientIdentity
import com.guilhermeramalho.puriotv.core.ClientInfo
import com.guilhermeramalho.puriotv.core.Problem
import com.guilhermeramalho.puriotv.core.TVKey
import com.guilhermeramalho.puriotv.core.TVSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The remote's state and the one session to the TV. Lives on the main thread (viewModelScope). */
class RemoteModel(application: Application) : AndroidViewModel(application) {
    sealed interface Screen {
        data object Find : Screen
        data class Pairing(val waitingForCode: Boolean) : Screen
        data object Connecting : Screen
        data object Remote : Screen
        data class Failed(val problem: Problem, val needsPairing: Boolean) : Screen
    }

    data class State(
        val screen: Screen = Screen.Find,
        val tvName: String = "",
        val power: Boolean? = null,
        val foreground: String? = null,
        val volume: TVSession.Event.Volume? = null,
        /** A problem shown inline (wrong pairing code) without leaving the screen. */
        val notice: Problem? = null,
    )

    private val store = Store(application)
    val discovery = TVDiscovery(application)
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state
    private var identity: ClientIdentity? = null
    private var session: TVSession? = null
    private var inForeground = false

    init {
        store.tv?.let { tv ->
            _state.update { it.copy(tvName = tv.name, screen = if (tv.pin != null) Screen.Connecting else Screen.Find) }
        }
    }

    private suspend fun identity(): ClientIdentity = identity ?: withContext(Dispatchers.IO) {
        KeystoreIdentity.loadOrCreate(store.clientName)
    }.also { identity = it }

    private fun newSession(host: String, block: (TVSession) -> Unit) {
        session?.disconnect()
        viewModelScope.launch {
            val id = try { identity() } catch (e: Exception) {
                _state.update { it.copy(screen = Screen.Failed(Problem.IDENTITY_UNAVAILABLE, needsPairing = false)) }
                return@launch
            }
            val info = ClientInfo(Build.MODEL ?: "Android", getApplication<Application>().packageName, BuildInfo.versionName(getApplication()))
            val s = TVSession(host, id, store.clientName, info, viewModelScope)
            s.onEvent = ::handle
            session = s
            block(s)
        }
    }

    /** The person picked a TV (found on the Wi-Fi or typed): pair with it. */
    fun choose(host: String, name: String) {
        store.tv = Store.PairedTV(host, name, null)
        _state.update { State(screen = Screen.Pairing(waitingForCode = false), tvName = name) }
        newSession(host) { it.pair() }
    }

    fun submit(code: String) {
        _state.update { it.copy(notice = null) }
        session?.submit(code)
    }

    fun connect() {
        val tv = store.tv ?: return _state.update { it.copy(screen = Screen.Find) }
        val pin = tv.pin ?: return choose(tv.host, tv.name)
        _state.update { it.copy(screen = Screen.Connecting, tvName = tv.name, notice = null) }
        newSession(tv.host) { it.connect(pin) }
    }

    fun forget() {
        session?.disconnect(); session = null
        store.tv = null
        _state.value = State()
    }

    fun key(key: TVKey, direction: Long = 3) = session?.key(key, direction)

    /** The app came to the front: reconnect. It went to the back: close the connection, nothing runs in the background. */
    fun foreground(visible: Boolean) {
        inForeground = visible
        if (visible) {
            if (_state.value.screen == Screen.Connecting || _state.value.screen == Screen.Remote) connect()
        } else if (_state.value.screen == Screen.Remote || _state.value.screen == Screen.Connecting) {
            session?.disconnect()
            _state.update { it.copy(screen = Screen.Connecting) }
        }
    }

    private fun handle(event: TVSession.Event) {
        when (event) {
            TVSession.Event.PairingCodeNeeded -> _state.update { it.copy(screen = Screen.Pairing(waitingForCode = true)) }
            is TVSession.Event.Paired -> {
                store.tv = store.tv?.copy(pin = event.pin)
                connect()
            }
            TVSession.Event.Connected -> _state.update { it.copy(screen = Screen.Remote, notice = null) }
            is TVSession.Event.Power -> _state.update { it.copy(power = event.on) }
            is TVSession.Event.Foreground -> _state.update { it.copy(foreground = event.packageName) }
            is TVSession.Event.Volume -> _state.update { it.copy(volume = event) }
            is TVSession.Event.Error -> onError(event.problem)
        }
    }

    private fun onError(problem: Problem) {
        val screen = _state.value.screen
        if (screen is Screen.Pairing && screen.waitingForCode && problem in codeProblems) {
            _state.update { it.copy(notice = problem) }   // wrong code: stay and let them type it again
            return
        }
        val needsPairing = problem == Problem.IDENTITY_CHANGED || problem == Problem.PAIRING_REJECTED_BY_TV
        if (needsPairing) store.tv = store.tv?.copy(pin = null)
        if (!inForeground && screen != Screen.Remote) return
        _state.update { it.copy(screen = Screen.Failed(problem, needsPairing)) }
    }

    override fun onCleared() { session?.disconnect(); discovery.stop() }

    private companion object {
        val codeProblems = setOf(Problem.CODE_LENGTH, Problem.CODE_CHARACTERS, Problem.CODE_MISMATCH)
    }
}

object BuildInfo {
    fun versionName(app: Application): String =
        runCatching { app.packageManager.getPackageInfo(app.packageName, 0).versionName }.getOrNull() ?: "0"
}
