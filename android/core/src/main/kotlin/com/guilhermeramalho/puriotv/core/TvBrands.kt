package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder

/**
 * Roku, LG and Samsung remotes from the phone (BrandRemote.swift and its three drivers; docs/tv-brands.md).
 * Calls from the main thread; events come back on the scope given (the main thread in the app).
 */
sealed interface BrandEvent {
    /** The TV shows a prompt asking to allow this phone. */
    data object ApprovalNeeded : BrandEvent
    /** Allowed: keep [credential]; next time no prompt. */
    class Approved(val credential: ByteArray) : BrandEvent {
        override fun equals(other: Any?) = other is Approved && other.credential.contentEquals(credential)
        override fun hashCode() = credential.contentHashCode()
        override fun toString() = "Approved(${String(credential)})"
    }
    data object Connected : BrandEvent
    data class Power(val on: Boolean) : BrandEvent
    /** The app on screen, by its name on the TV. */
    data class Foreground(val name: String) : BrandEvent
    data class Volume(val level: Int, val maximum: Int, val muted: Boolean) : BrandEvent
    data class Error(val problem: Problem, val detail: String? = null) : BrandEvent
}

data class BrandApp(val id: String, val name: String)

interface BrandRemote {
    val kind: TvKind
    var onEvent: ((BrandEvent) -> Unit)?
    fun connect(credential: ByteArray?)
    fun disconnect()
    /** direction: 1 pressed, 2 released, 3 tap. */
    fun key(key: TVKey, direction: Long)
    fun supports(key: TVKey): Boolean = kind.supports(key)
    suspend fun writeKey(key: TVKey)
    suspend fun apps(): List<BrandApp>
    suspend fun launch(app: BrandApp)
    /** The TV's field becomes [text] (the whole value typed so far). */
    suspend fun writeText(text: String)
    suspend fun alive(): Boolean

    /** Opens the TV's app with this name; false when it isn't on the TV. */
    suspend fun launch(named: String): Boolean {
        val app = BrandApps.match(named, apps()) ?: return false
        launch(app); return true
    }
}

object BrandRemotes {
    fun make(kind: TvKind, host: String, scope: CoroutineScope, name: String = "Purio TV"): BrandRemote? = when (kind) {
        TvKind.ROKU -> RokuRemote(host, scope)
        TvKind.LG -> LgRemote(host, scope)
        TvKind.SAMSUNG -> SamsungRemote(host, scope, name)
        TvKind.ANDROID_TV, TvKind.CHROMECAST -> null
    }
}

/** Whether this kind of TV has a button for the key (the remote hides the ones it doesn't). */
fun TvKind.supports(key: TVKey): Boolean = when (this) {
    TvKind.ROKU -> RokuRemote.keyName(key) != null
    TvKind.SAMSUNG -> key == TVKey.PLAY_PAUSE || SamsungRemote.code(key) != null
    else -> true
}

object BrandApps {
    private val aliases = mapOf(
        "primevideo" to listOf("amazonprimevideo", "amazonvideo", "primevideo", "amazon"),
        "hbomax" to listOf("max", "hbomax", "hbo"),
        "disney" to listOf("disney", "disneyplus"),
        "appletv" to listOf("appletv", "appletvplus"),
        "youtube" to listOf("youtube"),
    )
    fun plain(name: String) = name.lowercase().replace("+", "plus").filter { it.isLetterOrDigit() }
    fun match(name: String, apps: List<BrandApp>): BrandApp? {
        val wanted = plain(name).ifEmpty { return null }
        apps.firstOrNull { plain(it.name) == wanted }?.let { return it }
        val names = aliases.entries.firstOrNull { (key, values) -> key == wanted || wanted in values }?.let { listOf(it.key) + it.value } ?: emptyList()
        apps.firstOrNull { plain(it.name) in names }?.let { return it }
        return apps.filter { plain(it.name).startsWith(wanted) }.minByOrNull { it.name.length }
    }
}

/** Repeats a held key for TVs with no press-and-hold (LG): once at once, then every 0.2 s. */
internal class KeyRepeater(private val scope: CoroutineScope) {
    private val jobs = mutableMapOf<TVKey, Job>()
    fun press(key: TVKey, tap: (TVKey) -> Unit) {
        if (key in jobs) return
        tap(key)
        jobs[key] = scope.launch { delay(450); while (isActive) { tap(key); delay(200) } }
    }
    fun release(key: TVKey) { jobs.remove(key)?.cancel() }
    fun releaseAll() { jobs.values.forEach { it.cancel() }; jobs.clear() }
}

private fun JsonElement?.obj(): JsonObject? = this as? JsonObject
private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.contentOrNull
private fun JsonElement?.int(): Int? = (this as? JsonPrimitive)?.intOrNull
private fun JsonElement?.bool(): Boolean? = (this as? JsonPrimitive)?.booleanOrNull
private fun parse(text: String): JsonObject? = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull()

// ---------------------------------------------------------------------------------------------------- Roku

/** Roku's ECP: HTTP on 8060, no pairing; commands go out one at a time, in order (RokuRemote.swift). */
class RokuRemote(host: String, private val scope: CoroutineScope, private val base: String = "http://$host:8060/") : BrandRemote {
    override val kind = TvKind.ROKU
    override var onEvent: ((BrandEvent) -> Unit)? = null
    private var generation = 0
    private var cachedApps: List<BrandApp>? = null
    private var sent = ""
    private var powerOn: Boolean? = null
    private val order = Mutex()

    companion object {
        val CREDENTIAL = "roku".toByteArray()
        fun keyName(key: TVKey): String? = when (key) {
            TVKey.HOME -> "Home"; TVKey.BACK -> "Back"; TVKey.UP -> "Up"; TVKey.DOWN -> "Down"; TVKey.LEFT -> "Left"; TVKey.RIGHT -> "Right"
            TVKey.SELECT -> "Select"; TVKey.DELETE -> "Backspace"; TVKey.VOLUME_UP -> "VolumeUp"; TVKey.VOLUME_DOWN -> "VolumeDown"
            TVKey.MUTE -> "VolumeMute"; TVKey.POWER -> "Power"; TVKey.PLAY_PAUSE, TVKey.PLAY, TVKey.PAUSE -> "Play"
            TVKey.REWIND -> "Rev"; TVKey.FAST_FORWARD -> "Fwd"; TVKey.SETTINGS -> "Info"
            TVKey.CHANNEL_UP -> "ChannelUp"; TVKey.CHANNEL_DOWN -> "ChannelDown"
            // Roku remotes have no number keys (Lit_ types into a field, not a channel number).
            else -> null
        }
        fun tag(name: String, xml: String): String? {
            val open = xml.indexOf("<$name").takeIf { it >= 0 } ?: return null
            val start = xml.indexOf('>', open).takeIf { it >= 0 } ?: return null
            val close = xml.indexOf("</$name>", start).takeIf { it >= 0 } ?: return null
            return unescape(xml.substring(start + 1, close)).trim()
        }
        fun apps(xml: String): List<BrandApp> =
            Regex("<app [^>]*id=\"([^\"]+)\"[^>]*>(.*?)</app>", RegexOption.DOT_MATCHES_ALL).findAll(xml)
                .map { BrandApp(it.groupValues[1], unescape(it.groupValues[2])) }.filter { it.name.isNotEmpty() }.toList()
        private fun unescape(text: String) = text.replace("&amp;", "&").replace("&apos;", "'").replace("&quot;", "\"").replace("&lt;", "<").replace("&gt;", ">")
    }

    class Limited : Exception("403")

    override fun connect(credential: ByteArray?) {
        val token = ++generation
        scope.launch {
            try {
                val info = get("query/device-info")
                if (token != generation) return@launch
                if (credential == null) emit(BrandEvent.Approved(CREDENTIAL))
                emit(BrandEvent.Connected)
                tag("power-mode", info)?.let { val on = it == "PowerOn"; powerOn = on; emit(BrandEvent.Power(on)) }
                readActiveApp(token)
            } catch (e: Exception) { if (token == generation) emit(error(e)) }
        }
    }
    override fun disconnect() { generation++; cachedApps = null; sent = "" }

    private fun emit(event: BrandEvent) = onEvent?.invoke(event)
    private fun error(e: Exception) = if (e is Limited) BrandEvent.Error(Problem.ROKU_LIMITED) else BrandEvent.Error(Problem.CONNECT_FAILED, e.message)

    override fun key(key: TVKey, direction: Long) {
        // Launched at once, in call order; the mutex keeps them in that order on the wire.
        scope.launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
            try { order.withLock { send(key, direction) } } catch (e: Exception) { emit(error(e)) }
        }
    }
    override suspend fun writeKey(key: TVKey) = order.withLock { send(key, 3) }

    private suspend fun send(key: TVKey, direction: Long) {
        var name = keyName(key) ?: return
        if (key == TVKey.POWER) powerOn?.let { name = if (it) "PowerOff" else "PowerOn" }
        val verb = when (direction) { 1L -> "keydown"; 2L -> "keyup"; else -> "keypress" }
        post("$verb/$name")
        if (key == TVKey.POWER && direction != 1L) powerOn?.let { powerOn = !it; emit(BrandEvent.Power(!it)) }
        if (direction != 1L && (key == TVKey.HOME || key == TVKey.BACK)) refreshSoon()
    }

    override suspend fun apps(): List<BrandApp> = cachedApps ?: apps(get("query/apps")).also { cachedApps = it }
    override suspend fun launch(app: BrandApp) { order.withLock { post("launch/${app.id}") }; refreshSoon() }

    override suspend fun writeText(text: String) {
        val (deletes, insert) = TVSession.typingEdit(sent, text)
        sent = text
        order.withLock {
            repeat(deletes) { post("keypress/Backspace") }
            for (c in insert) post("keypress/Lit_" + URLEncoder.encode(c.toString(), "UTF-8").replace("+", "%20"))
        }
    }
    override suspend fun alive() = runCatching { get("query/device-info") }.isSuccess

    private fun refreshSoon() { val token = generation; scope.launch { delay(1500); readActiveApp(token) } }
    private suspend fun readActiveApp(token: Int) {
        val xml = runCatching { get("query/active-app") }.getOrNull() ?: return
        if (token == generation) tag("app", xml)?.let { emit(BrandEvent.Foreground(it)) }
    }

    private suspend fun get(path: String): String = request("GET", path)
    private suspend fun post(path: String) { request("POST", path) }
    private suspend fun request(method: String, path: String): String = withContext(Dispatchers.IO) {
        val c = URL(base + path).openConnection() as HttpURLConnection
        try {
            c.requestMethod = method; c.connectTimeout = 4000; c.readTimeout = 4000
            if (method == "POST") { c.doOutput = true; c.setFixedLengthStreamingMode(0); c.outputStream.close() }
            val status = c.responseCode
            if (status == 403) throw Limited()
            if (status !in 200..299) throw RemoteFailure(Problem.COMMAND_REJECTED, "HTTP $status")
            c.inputStream.readBytes().toString(Charsets.UTF_8)
        } finally { c.disconnect() }
    }
}

// ---------------------------------------------------------------------------------------------------- LG

/** LG webOS SSAP over a WebSocket (3001 TLS, then 3000), LG's signed manifest, a pointer socket for buttons (LGRemote.swift). */
class LgRemote(host: String, private val scope: CoroutineScope, private val urls: List<URI> = listOf(URI("wss://$host:3001"), URI("ws://$host:3000"))) : BrandRemote {
    override val kind = TvKind.LG
    override var onEvent: ((BrandEvent) -> Unit)? = null
    private var link: WebSocketClient? = null
    private var pointer: WebSocketClient? = null
    private var generation = 0
    private var registered = false
    private var secure = false
    private var clientKey: String? = null
    private var nextId = 0
    private val pending = mutableMapOf<String, CompletableDeferred<JsonObject>>()
    private var launchPoints: List<BrandApp>? = null
    private var muted = false
    private var playing = true
    private var sent = ""
    private val repeater = KeyRepeater(scope)

    companion object {
        fun button(key: TVKey): String? = when (key) {
            TVKey.HOME -> "HOME"; TVKey.BACK -> "BACK"; TVKey.UP -> "UP"; TVKey.DOWN -> "DOWN"; TVKey.LEFT -> "LEFT"; TVKey.RIGHT -> "RIGHT"
            TVKey.SELECT -> "ENTER"; TVKey.PLAY -> "PLAY"; TVKey.PAUSE -> "PAUSE"; TVKey.REWIND -> "REWIND"; TVKey.FAST_FORWARD -> "FASTFORWARD"
            TVKey.CAPTIONS -> "CC"; TVKey.SETTINGS -> "MENU"; TVKey.INPUTS -> "INPUT_HUB"
            TVKey.CHANNEL_UP -> "CHANNELUP"; TVKey.CHANNEL_DOWN -> "CHANNELDOWN"
            else -> key.digit?.toString()
        }
        const val SIGNATURE = "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw=="
        private val PERMISSIONS = listOf("LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED", "CONTROL_AUDIO",
            "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV",
            "CONTROL_POWER", "CONTROL_TV_SCREEN", "READ_APP_STATUS", "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE",
            "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE", "READ_COUNTRY_INFO",
            "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS", "READ_SETTINGS")
        private val SIGNED_PERMISSIONS = listOf("TEST_SECURE", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS",
            "READ_LGE_SDX", "READ_NOTIFICATIONS", "SEARCH", "WRITE_SETTINGS", "WRITE_NOTIFICATION_ALERT", "CONTROL_POWER",
            "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS", "READ_UPDATE_INFO", "UPDATE_FROM_REMOTE_APP", "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME")

        fun registration(clientKey: String?): JsonObject = buildJsonObject {
            put("type", "register"); put("id", "register_0")
            putJsonObject("payload") {
                put("forcePairing", false); put("pairingType", "PROMPT")
                clientKey?.let { put("client-key", it) }
                putJsonObject("manifest") {
                    put("appVersion", "1.1"); put("manifestVersion", 1)
                    putJsonArray("permissions") { PERMISSIONS.forEach { add(it) } }
                    putJsonArray("signatures") { addJsonObject { put("signature", SIGNATURE); put("signatureVersion", 1) } }
                    putJsonObject("signed") {
                        put("appId", "com.lge.test"); put("created", "20140509")
                        putJsonObject("localizedAppNames") { put("", "LG Remote App"); put("ko-KR", "리모컨 앱"); put("zxx-XX", "ЛГ Rэмotэ AПП") }
                        putJsonObject("localizedVendorNames") { put("", "LG Electronics") }
                        putJsonArray("permissions") { SIGNED_PERMISSIONS.forEach { add(it) } }
                        put("serial", "2f930e2d2cfe083771f68e4fe7bb07"); put("vendorId", "com.lge")
                    }
                }
            }
        }
    }

    override fun connect(credential: ByteArray?) {
        disconnect()
        clientKey = credential?.toString(Charsets.UTF_8)
        open(urls, generation)
    }

    private fun open(remaining: List<URI>, token: Int) {
        val url = remaining.firstOrNull() ?: return
        val socket = WebSocketClient(url, scope)
        link = socket
        var answered = false
        socket.onOpen = { if (token == generation) { answered = true; secure = url.scheme == "wss"; socket.send(registration(clientKey).toString()) } }
        socket.onText = { text -> if (token == generation) parse(text)?.let(::handle) }
        socket.onClose = { reason ->
            if (token == generation) {
                if (!answered && remaining.size > 1) open(remaining.drop(1), token)
                else { val was = registered; disconnect(); emit(BrandEvent.Error(if (was) Problem.CLOSED else Problem.CONNECT_FAILED, reason)) }
            }
        }
        socket.open()
    }

    override fun disconnect() {
        generation++
        link?.close(); link = null
        pointer?.close(); pointer = null
        registered = false
        repeater.releaseAll()
        pending.values.forEach { it.completeExceptionally(RemoteFailure(Problem.CLOSED)) }
        pending.clear()
        launchPoints = null; sent = ""
    }

    private fun emit(event: BrandEvent) = onEvent?.invoke(event)

    private fun handle(m: JsonObject) {
        val id = m["id"].str() ?: ""
        val type = m["type"].str() ?: ""
        val payload = m["payload"].obj() ?: JsonObject(emptyMap())
        if (id == "register_0") {
            when {
                type == "response" && payload["pairingType"].str() == "PROMPT" -> emit(BrandEvent.ApprovalNeeded)
                type == "registered" -> {
                    registered = true
                    payload["client-key"].str()?.let { if (it != clientKey) { clientKey = it; emit(BrandEvent.Approved(it.toByteArray())) } }
                    emit(BrandEvent.Connected)
                    subscribe()
                }
                type == "error" -> { disconnect(); emit(BrandEvent.Error(Problem.LG_REFUSED, m["error"].str())) }
            }
            return
        }
        when (id) {
            "fg" -> payload["appId"].str()?.takeIf { it.isNotEmpty() }?.let(::foreground)
            "vol" -> volume(payload)
            "power" -> payload["state"].str()?.let { emit(BrandEvent.Power(it == "Active" || it == "Screen Saver")) }
            else -> pending.remove(id)?.let { waiting ->
                if (type == "error" || payload["returnValue"].bool() == false) waiting.completeExceptionally(RemoteFailure(Problem.COMMAND_REJECTED, m["error"].str() ?: payload["errorText"].str()))
                else waiting.complete(payload)
            }
        }
    }

    private fun subscribe() {
        link?.send("""{"id":"fg","type":"subscribe","uri":"ssap://com.webos.applicationManager/getForegroundAppInfo"}""")
        link?.send("""{"id":"vol","type":"subscribe","uri":"ssap://audio/getVolume"}""")
        link?.send("""{"id":"power","type":"subscribe","uri":"ssap://com.webos.service.tvpower/power/getPowerState"}""")
        val token = generation
        scope.launch {
            var path = runCatching { request("com.webos.service.networkinput/getPointerInputSocket")["socketPath"].str() }.getOrNull() ?: return@launch
            if (token != generation) return@launch
            // A TV reached over TLS hands out a plain ws:// path that it only serves over TLS on 3001.
            if (secure && path.startsWith("ws://") && path.contains(":3000/")) path = path.replace("ws://", "wss://").replace(":3000/", ":3001/")
            val p = WebSocketClient(URI(path), scope)
            p.onClose = { if (token == generation) pointer = null }
            p.open()
            pointer = p
        }
    }

    private fun foreground(appId: String) {
        val token = generation
        scope.launch {
            val name = runCatching { apps() }.getOrNull()?.firstOrNull { it.id == appId }?.name
            if (token == generation) emit(BrandEvent.Foreground(name ?: appId))
        }
    }
    private fun volume(payload: JsonObject) {
        val status = payload["volumeStatus"].obj() ?: payload
        val level = status["volume"].int() ?: return
        muted = status["muteStatus"].bool() ?: status["muted"].bool() ?: muted
        emit(BrandEvent.Volume(level, status["maxVolume"].int() ?: 100, muted))
    }

    private suspend fun request(uri: String, payload: JsonObject = JsonObject(emptyMap())): JsonObject {
        val socket = link
        if (!registered || socket == null) throw RemoteFailure(Problem.NOT_READY)
        val id = "c${++nextId}"
        val answer = CompletableDeferred<JsonObject>()
        pending[id] = answer
        socket.send(buildJsonObject { put("id", id); put("type", "request"); put("uri", "ssap://$uri"); put("payload", payload) }.toString())
        return try { withTimeout(6000) { answer.await() } } catch (e: kotlinx.coroutines.TimeoutCancellationException) { throw RemoteFailure(Problem.TIMED_OUT) } finally { pending.remove(id) }
    }
    private fun command(uri: String, payload: JsonObject = JsonObject(emptyMap())) {
        if (!registered) return
        link?.send(buildJsonObject { put("id", "c${++nextId}"); put("type", "request"); put("uri", "ssap://$uri"); put("payload", payload) }.toString())
    }

    override fun key(key: TVKey, direction: Long) {
        when {
            direction == 1L && key in setOf(TVKey.UP, TVKey.DOWN, TVKey.LEFT, TVKey.RIGHT, TVKey.VOLUME_UP, TVKey.VOLUME_DOWN) -> repeater.press(key, ::tap)
            direction == 2L -> repeater.release(key)
            else -> tap(key)
        }
    }
    override suspend fun writeKey(key: TVKey) { if (!registered) throw RemoteFailure(Problem.NOT_READY); tap(key) }

    private fun tap(key: TVKey) {
        when (key) {
            TVKey.VOLUME_UP -> command("audio/volumeUp")
            TVKey.VOLUME_DOWN -> command("audio/volumeDown")
            TVKey.MUTE -> command("audio/setMute", buildJsonObject { put("mute", !muted) })
            TVKey.POWER -> command("system/turnOff")
            TVKey.PLAY_PAUSE -> { playing = !playing; button(if (playing) "PLAY" else "PAUSE") }
            TVKey.DELETE -> command("com.webos.service.ime/deleteCharacters", buildJsonObject { put("count", 1) })
            else -> button(key)?.let(::button)
        }
    }
    private fun button(name: String) { pointer?.send("type:button\nname:$name\n\n") }

    override suspend fun apps(): List<BrandApp> = launchPoints ?: (request("com.webos.applicationManager/listLaunchPoints")["launchPoints"] as? JsonArray ?: JsonArray(emptyList()))
        .mapNotNull { p -> p.obj()?.let { o -> o["id"].str()?.let { BrandApp(it, o["title"].str() ?: it) } } }.also { launchPoints = it }
    override suspend fun launch(app: BrandApp) { request("system.launcher/launch", buildJsonObject { put("id", app.id) }) }

    override suspend fun writeText(text: String) {
        val (deletes, insert) = TVSession.typingEdit(sent, text)
        if (deletes > 0) request("com.webos.service.ime/deleteCharacters", buildJsonObject { put("count", deletes) })
        if (insert.isNotEmpty()) request("com.webos.service.ime/insertText", buildJsonObject { put("text", insert); put("replace", 0) })
        sent = text
    }
    override suspend fun alive() = runCatching { request("com.webos.applicationManager/getForegroundAppInfo") }.isSuccess
}

// ---------------------------------------------------------------------------------------------------- Samsung

/** Samsung Tizen: remote WebSocket on 8002 with a token, REST on 8001 for apps and power (SamsungRemote.swift). */
class SamsungRemote(host: String, private val scope: CoroutineScope, private val name: String,
                    private val socketBase: String = "wss://$host:8002", private val rest: String = "http://$host:8001/") : BrandRemote {
    override val kind = TvKind.SAMSUNG
    override var onEvent: ((BrandEvent) -> Unit)? = null
    private var link: WebSocketClient? = null
    private var generation = 0
    private var ready = false
    private var token: String? = null
    private var appsWaiting: CompletableDeferred<List<BrandApp>>? = null
    private var cachedApps: List<BrandApp>? = null
    private var playing = true

    companion object {
        fun code(key: TVKey): String? = when (key) {
            TVKey.HOME -> "KEY_HOME"; TVKey.BACK -> "KEY_RETURN"; TVKey.UP -> "KEY_UP"; TVKey.DOWN -> "KEY_DOWN"; TVKey.LEFT -> "KEY_LEFT"
            TVKey.RIGHT -> "KEY_RIGHT"; TVKey.SELECT -> "KEY_ENTER"; TVKey.VOLUME_UP -> "KEY_VOLUP"; TVKey.VOLUME_DOWN -> "KEY_VOLDOWN"
            TVKey.MUTE -> "KEY_MUTE"; TVKey.POWER -> "KEY_POWER"; TVKey.PLAY -> "KEY_PLAY"; TVKey.PAUSE -> "KEY_PAUSE"; TVKey.REWIND -> "KEY_REWIND"
            TVKey.FAST_FORWARD -> "KEY_FF"; TVKey.CAPTIONS -> "KEY_CAPTION"; TVKey.SETTINGS -> "KEY_MENU"; TVKey.INPUTS -> "KEY_SOURCE"
            TVKey.CHANNEL_UP -> "KEY_CHUP"; TVKey.CHANNEL_DOWN -> "KEY_CHDOWN"
            TVKey.PLAY_PAUSE, TVKey.DELETE -> null
            else -> key.digit?.let { "KEY_$it" }
        }
        /** Encoded strictly: a "+" in the base64 name would otherwise reach the TV as a space. */
        private fun encode(text: String) = URLEncoder.encode(text, "UTF-8").replace("+", "%20")
    }

    val socketUrl: String get() {
        var query = "name=" + encode(java.util.Base64.getEncoder().encodeToString(name.toByteArray()))
        token?.let { query += "&token=" + encode(it) }
        return "$socketBase/api/v2/channels/samsung.remote.control?$query"
    }

    override fun connect(credential: ByteArray?) {
        disconnect()
        token = credential?.toString(Charsets.UTF_8)
        val gen = generation
        val socket = WebSocketClient(URI(socketUrl), scope)
        link = socket
        socket.onOpen = { if (gen == generation && token == null) emit(BrandEvent.ApprovalNeeded) }
        socket.onText = { text -> if (gen == generation) parse(text)?.let(::handle) }
        socket.onClose = { reason -> if (gen == generation) { val was = ready; disconnect(); emit(BrandEvent.Error(if (was) Problem.CLOSED else Problem.CONNECT_FAILED, reason)) } }
        socket.open()
    }

    override fun disconnect() {
        generation++
        link?.close(); link = null
        ready = false
        appsWaiting?.completeExceptionally(RemoteFailure(Problem.CLOSED)); appsWaiting = null
        cachedApps = null
    }

    private fun emit(event: BrandEvent) = onEvent?.invoke(event)

    private fun handle(m: JsonObject) {
        val data = m["data"].obj()
        when (m["event"].str()) {
            "ms.channel.connect" -> {
                ready = true
                data?.get("token").str()?.let { if (it != token) { token = it; emit(BrandEvent.Approved(it.toByteArray())) } }
                emit(BrandEvent.Connected)
                readPower()
            }
            "ms.channel.unauthorized" -> { disconnect(); emit(BrandEvent.Error(Problem.SAMSUNG_REFUSED)) }
            "ms.channel.timeOut" -> { disconnect(); emit(BrandEvent.Error(Problem.SAMSUNG_ALLOW_TIMEOUT)) }
            "ed.installedApp.get" -> {
                val list = (data?.get("data") as? JsonArray ?: JsonArray(emptyList())).mapNotNull { a ->
                    val o = a.obj() ?: return@mapNotNull null
                    val id = o["appId"].str() ?: return@mapNotNull null
                    BrandApp(id, o["name"].str() ?: return@mapNotNull null)
                }
                cachedApps = list
                appsWaiting?.complete(list); appsWaiting = null
            }
        }
    }

    private fun readPower() {
        val gen = generation
        scope.launch {
            val text = runCatching { http("GET", "api/v2/") }.getOrNull() ?: return@launch
            val state = parse(text)?.get("device").obj()?.get("PowerState").str() ?: return@launch
            if (gen == generation) emit(BrandEvent.Power(state.equals("on", ignoreCase = true)))
        }
    }

    private fun remote(code: String, cmd: String) {
        link?.send(buildJsonObject {
            put("method", "ms.remote.control")
            putJsonObject("params") { put("Cmd", cmd); put("DataOfCmd", code); put("Option", "false"); put("TypeOfRemote", "SendRemoteKey") }
        }.toString())
    }

    override fun key(key: TVKey, direction: Long) {
        if (!ready) return
        if (key == TVKey.PLAY_PAUSE) { playing = !playing; remote(if (playing) "KEY_PLAY" else "KEY_PAUSE", "Click"); return }
        val code = code(key) ?: return
        remote(code, when (direction) { 1L -> "Press"; 2L -> "Release"; else -> "Click" })
    }
    override suspend fun writeKey(key: TVKey) { if (!ready) throw RemoteFailure(Problem.NOT_READY); key(key, 3) }

    override suspend fun apps(): List<BrandApp> {
        cachedApps?.let { return it }
        val socket = link
        if (!ready || socket == null) throw RemoteFailure(Problem.NOT_READY)
        val waiting = appsWaiting ?: CompletableDeferred<List<BrandApp>>().also {
            appsWaiting = it
            socket.send("""{"method":"ms.channel.emit","params":{"event":"ed.installedApp.get","to":"host"}}""")
        }
        return try { withTimeout(6000) { waiting.await() } } catch (e: kotlinx.coroutines.TimeoutCancellationException) { appsWaiting = null; throw RemoteFailure(Problem.TIMED_OUT) }
    }

    override suspend fun launch(app: BrandApp) {
        val answer = runCatching { http("POST", "api/v2/applications/${app.id}") }.getOrNull()
        if (answer?.trim() == "true") return
        if (!ready) throw RemoteFailure(Problem.NOT_READY)
        link?.send(buildJsonObject {
            put("method", "ms.channel.emit")
            putJsonObject("params") { put("event", "ed.apps.launch"); put("to", "host"); putJsonObject("data") { put("appId", app.id); put("action_type", "DEEP_LINK") } }
        }.toString())
    }

    /** Samsung's keyboard takes the whole text and replaces the field with it. */
    override suspend fun writeText(text: String) {
        val socket = link
        if (!ready || socket == null) throw RemoteFailure(Problem.NOT_READY)
        socket.send(buildJsonObject {
            put("method", "ms.remote.control")
            putJsonObject("params") { put("Cmd", java.util.Base64.getEncoder().encodeToString(text.toByteArray())); put("DataOfCmd", "base64"); put("TypeOfRemote", "SendInputString") }
        }.toString())
        socket.send("""{"method":"ms.remote.control","params":{"TypeOfRemote":"SendInputEnd"}}""")
    }

    override suspend fun alive() = ready && runCatching { http("GET", "api/v2/") }.isSuccess

    private suspend fun http(method: String, path: String): String = withContext(Dispatchers.IO) {
        val c = URL(rest + path).openConnection() as HttpURLConnection
        try {
            c.requestMethod = method; c.connectTimeout = 4000; c.readTimeout = 4000
            if (method == "POST") { c.doOutput = true; c.setFixedLengthStreamingMode(0); c.outputStream.close() }
            if (c.responseCode !in 200..299) throw RemoteFailure(Problem.COMMAND_REJECTED, "HTTP ${c.responseCode}")
            c.inputStream.readBytes().toString(Charsets.UTF_8)
        } finally { c.disconnect() }
    }
}
