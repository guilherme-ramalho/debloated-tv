package com.guilhermeramalho.puriotv

import android.content.Context
import com.guilhermeramalho.puriotv.core.EditorLink
import com.guilhermeramalho.puriotv.core.HomeLayout
import com.guilhermeramalho.puriotv.core.LauncherClient
import com.guilhermeramalho.puriotv.core.LauncherHome
import com.guilhermeramalho.puriotv.core.LauncherSnapshot
import com.guilhermeramalho.puriotv.core.PreferencesJson
import com.guilhermeramalho.puriotv.core.RemoteApp
import com.guilhermeramalho.puriotv.core.TVSession
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.util.Base64

/**
 * TV Home editing through the launcher (HomeEditor.swift). The key travels through the remote's pairing, so there is
 * no second pairing. Opening a session briefly shows an invisible screen on the TV, which can pause what's playing,
 * so it opens by itself only when Home is in front; with an app or input on screen the person confirms first.
 */
class HomeEditor(private val context: Context, private val scope: CoroutineScope, private val remote: RemoteModel, private val settings: AppSettings) {
    data class State(
        val ready: Boolean = false,
        val busy: Boolean = false,
        val message: String = "",
        val snapshot: LauncherSnapshot? = null,
        /** Set when an app or input is in front: the name to show in the "Connect now?" prompt. */
        val waitingFor: String? = null,
        /** The current draft isn't on the TV yet. */
        val unapplied: Boolean = false,
        val applying: Boolean = false,
    )

    private val _state = MutableStateFlow(State(message = context.getString(R.string.editor_turn_on)))
    val state: StateFlow<State> = _state
    private val client = LauncherClient()
    private var operation: Job? = null
    private var generation = 0
    /** True while the TV tab wants a session: a dropped one reconnects by itself (at most three times a minute). */
    private var wanted = false
    private val reconnects = ArrayDeque<Long>()
    private var pendingAuto = false
    private var editStamp = 0
    private var applyAgain = false
    private var backedUp = false

    private fun s(id: Int, vararg args: Any) = context.getString(id, *args)
    private val ready get() = _state.value.ready
    private val busy get() = _state.value.busy

    fun close() {
        generation++; wanted = false; operation?.cancel(); operation = null; client.close(); backedUp = false
        _state.update { it.copy(snapshot = null, ready = false, busy = false, waitingFor = null, message = s(R.string.editor_opens_with_tab)) }
    }

    /** Called whenever the TV's state changes while the TV tab is visible. */
    fun autoConnect() {
        if (ready || busy) return
        val tv = remote.state.value
        if (!tv.ready) { _state.update { it.copy(waitingFor = null, message = s(R.string.editor_waiting)) }; return }
        if (tv.power == false) { _state.update { it.copy(waitingFor = null, message = s(R.string.editor_standby)) }; return }
        if (tv.foreground == HOME_PACKAGE) { connect(); return }
        // The remote reports the app in front, not whether it is playing, so any app or input asks first.
        val pkg = tv.foreground.orEmpty()
        val name = TVSession.appName(pkg) ?: Brand.nameOf(pkg) ?: if (pkg.isEmpty()) s(R.string.the_tv) else s(R.string.an_app_or_input)
        _state.update { it.copy(waitingFor = name, message = s(R.string.editor_app_on_screen, name)) }
    }

    /** Opens a session unless one is open or opening. [force] starts over (Try again, Connect now). */
    fun connect(force: Boolean = false) {
        if (!force && (ready || busy)) return
        close()
        val token = generation
        wanted = true
        if (!remote.state.value.ready) { _state.update { it.copy(message = s(R.string.editor_waiting)) }; return }
        _state.update { it.copy(waitingFor = null, busy = true, message = s(R.string.editor_connecting)) }
        client.onDisconnected = { failure ->
            scope.launch {
                if (generation != token) return@launch
                _state.update { it.copy(ready = false, busy = false, snapshot = null, message = s(failure.problem.message())) }
                reconnectIfWanted()
            }
        }
        val host = remote.state.value.host
        operation = scope.launch {
            var last: Throwable? = null
            // Up to three tries, each with a fresh key: the remote may need a moment after the phone wakes.
            for (attempt in 1..3) {
                try {
                    if (!remote.freshen()) throw UserMessage(s(R.string.remote_not_responding))
                    val key = EditorLink.newKey()
                    remote.sendLink(EditorLink.url(key))
                    client.open(host, key)
                    refresh()
                    if (generation == token) _state.update { it.copy(busy = false) }
                    return@launch
                } catch (e: CancellationException) {
                    if (generation == token) _state.update { it.copy(busy = false) }
                    return@launch
                } catch (e: Exception) {
                    if (generation != token) return@launch
                    last = e
                    if (attempt < 3) delay(1500)
                }
            }
            if (generation != token) return@launch
            client.close()
            _state.update { it.copy(ready = false, busy = false, message = s(R.string.editor_unreachable, errorText(context, last))) }
        }
    }

    private fun reconnectIfWanted() {
        if (!wanted) return
        val now = System.currentTimeMillis()
        while (reconnects.isNotEmpty() && now - reconnects.first() > 60_000) reconnects.removeFirst()
        reconnects.addLast(now)
        if (reconnects.size > 3) { _state.update { it.copy(message = it.message + " " + s(R.string.tap_try_again)) }; return }
        val token = generation
        scope.launch {
            delay(1000)
            if (generation == token && wanted && !ready && !busy) autoConnect()
        }
    }

    suspend fun refresh() {
        val token = generation
        val result = client.snapshot()
        if (generation != token) throw CancellationException()
        _state.update { it.copy(snapshot = result, ready = true, message = s(R.string.editor_connected)) }
        settings.merge(result, remote.state.value.host)
    }

    private suspend fun apply(layout: HomeLayout, wallpaper: ByteArray?) {
        layout.validate()
        val snapshot = _state.value.snapshot
        if (!ready || snapshot == null) throw UserMessage(s(R.string.wait_editor_apply))
        val payload = buildJsonObject {
            put("expectedRevision", snapshot.revision)
            put("layout", PreferencesJson.encodeToJsonElement(HomeLayout.serializer(), layout))
            // The photo travels only when the TV doesn't have it yet, so reordering apps doesn't resend the wallpaper.
            val tvHasPhoto = snapshot.layout.wallpaper == layout.wallpaper && snapshot.wallpaperJPEG != null
            if (wallpaper != null && HomeLayout.validPhoto(layout.wallpaper) && !tvHasPhoto) {
                put("wallpaperJPEG", Base64.getEncoder().encodeToString(Images.tvWallpaper(wallpaper, s(R.string.photo_not_wallpaper))))
            }
        }
        val token = generation
        val result = client.request<LauncherSnapshot>("applyLayout", payload).also { it.validate() }
        if (generation != token) throw CancellationException()
        _state.update { it.copy(snapshot = result, message = s(R.string.editor_updated)) }
    }

    /** A change to the draft. Edits reach the TV by themselves after a short pause (one Home rebuild per burst). */
    fun layoutChanged(change: LayoutChange) {
        when (change.apply) {
            LayoutApply.MATCHES_TV -> { _state.update { it.copy(unapplied = false) }; pendingAuto = false }
            LayoutApply.MANUAL -> { _state.update { it.copy(unapplied = true) }; pendingAuto = false }
            LayoutApply.AUTO -> {
                _state.update { it.copy(unapplied = true) }; pendingAuto = true
                val stamp = ++editStamp
                scope.launch { delay(800); if (stamp == editStamp) applyNow() }
            }
        }
    }

    /** TV Home just connected: edits made while it was away reach it now. */
    fun connectedApplyPending() { if (pendingAuto) scope.launch { applyNow() } }

    /** The Apply button: a profile switch, a restored backup, or after a failed automatic apply. */
    fun applyDraft() { _state.update { it.copy(unapplied = true) }; scope.launch { applyNow() } }

    /** One apply at a time; edits made meanwhile follow in one more. The first apply of a session backs the draft up. */
    private suspend fun applyNow() {
        if (!_state.value.unapplied || !ready) return
        if (_state.value.applying) { applyAgain = true; return }
        _state.update { it.copy(applying = true, unapplied = false) }; pendingAuto = false
        if (!backedUp && runCatching { settings.backup(s(R.string.backup_before_editing, settings.profile.name)) }.isSuccess) backedUp = true
        try { apply(settings.layout, settings.wallpaperData(settings.layout)) }
        catch (e: CancellationException) { _state.update { it.copy(unapplied = true) } }
        catch (e: Exception) { _state.update { it.copy(unapplied = true) }; settings.notice.value = errorText(context, e) }
        _state.update { it.copy(applying = false) }
        if (applyAgain) { applyAgain = false; applyNow() }
    }

    suspend fun uninstall(app: RemoteApp) {
        if (!ready || app.installed != true || app.system || !RemoteApp.validPackage(app.id)) throw UserMessage(s(R.string.sync_before_uninstall))
        val token = generation
        val result = client.requestRaw("uninstall", buildJsonObject { put("package", app.id) })
        if (generation != token) throw CancellationException()
        val status = (result.jsonObject["status"] as? JsonPrimitive)?.content
        if (status != "confirmationRequired") throw UserMessage(s(R.string.uninstall_unexpected))
        _state.update { it.copy(message = s(R.string.uninstall_confirm_on_tv)) }
    }

    suspend fun sleepTimer(minutes: Int) {
        if (!ready || minutes !in 0..240) throw UserMessage(s(R.string.wait_editor_timer))
        update("sleepTimer", buildJsonObject { put("minutes", minutes) })
    }

    /** A look is a preset of Home switches the launcher already has. Applies at once. */
    suspend fun setLook(look: String) {
        if (!ready || _state.value.snapshot?.home?.supports("looks") != true || look !in LauncherHome.looks) throw UserMessage(s(R.string.wait_editor_look))
        update("homeSettings", buildJsonObject { put("look", look) })
    }

    /** Weather by the clock on TV Home, placed by the TV itself. Applies at once. */
    suspend fun setWeather(on: Boolean) {
        if (!ready || _state.value.snapshot?.home?.supports("weather") != true) throw UserMessage(s(R.string.wait_editor_weather))
        update("homeSettings", buildJsonObject { put("weather", on) })
    }

    private suspend fun update(operation: String, payload: kotlinx.serialization.json.JsonObject) {
        val token = generation
        val result = client.request<LauncherSnapshot>(operation, payload).also { it.validate() }
        if (generation != token) throw CancellationException()
        _state.update { it.copy(snapshot = result) }
    }

    companion object { const val HOME_PACKAGE = "com.gathin.tvhome" }
}
