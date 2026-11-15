package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.IOException
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.Socket
import java.security.cert.X509Certificate
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

// Show on TV (Cast.swift): a minimal Google Cast v2 sender, no SDK. The TV's built-in Cast player (the Default Media
// Receiver) plays what the phone serves (MediaServer.kt). Frames are a 4-byte big-endian length and a protobuf
// CastMessage carrying a JSON payload, over TLS on port 8009 (docs/cast.md).

object CastNamespace {
    const val CONNECTION = "urn:x-cast:com.google.cast.tp.connection"
    const val HEARTBEAT = "urn:x-cast:com.google.cast.tp.heartbeat"
    const val RECEIVER = "urn:x-cast:com.google.cast.receiver"
    const val MEDIA = "urn:x-cast:com.google.cast.media"
}

/** One CastMessage (cast_channel.proto): protocol version 0, string payload. */
data class CastMessage(val source: String, val destination: String, val namespace: String, val payload: String) {
    val body: ByteArray
        get() = Wire.int(1, 0) + Wire.string(2, source) + Wire.string(3, destination) + Wire.string(4, namespace) +
            Wire.int(5, 0) + Wire.string(6, payload)
    /** The body behind its 4-byte big-endian length. */
    val framed: ByteArray
        get() {
            val body = body
            val n = body.size
            return byteArrayOf((n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte()) + body
        }
    val json: JsonObject get() = runCatching { Json.parseToJsonElement(payload).jsonObject }.getOrDefault(JsonObject(emptyMap()))
    val type: String get() = json.string("type") ?: ""

    companion object {
        fun of(source: String, destination: String, namespace: String, json: JsonObject) =
            CastMessage(source, destination, namespace, json.toString())

        fun decode(body: ByteArray): CastMessage {
            var source = ""; var destination = ""; var namespace = ""; var payload = ""
            for (field in Wire.fields(body)) {
                val text = field.bytes?.toString(Charsets.UTF_8) ?: continue
                when (field.number) { 2 -> source = text; 3 -> destination = text; 4 -> namespace = text; 6 -> payload = text }
            }
            return CastMessage(source, destination, namespace, payload)
        }
    }
}

/** Splits the incoming stream into CastMessage bodies. */
class CastFrameDecoder(private val maxFrameSize: Int = 65536) {
    private var buffer = ByteArray(0)
    fun append(incoming: ByteArray): List<ByteArray> {
        buffer += incoming
        val frames = mutableListOf<ByteArray>()
        while (buffer.size >= 4) {
            val length = (buffer[0].toInt() and 0xff shl 24) or (buffer[1].toInt() and 0xff shl 16) or
                (buffer[2].toInt() and 0xff shl 8) or (buffer[3].toInt() and 0xff)
            if (length < 0 || length > maxFrameSize) throw RemoteFailure(Problem.FRAME_LIMIT)
            if (buffer.size < 4 + length) break
            frames += buffer.copyOfRange(4, 4 + length)
            buffer = buffer.copyOfRange(4 + length, buffer.size)
        }
        return frames
    }
}

data class CastMediaStatus(val playerState: String, val currentTime: Double, val duration: Double?, val idleReason: String?) {
    val playing: Boolean get() = playerState == "PLAYING" || playerState == "BUFFERING"
}

/**
 * The sender's side of one Cast session as a pure state machine (CastController in Cast.swift): commands and the
 * TV's messages in, what to send and what happened out. No sockets, so every step is unit-tested (CastTest).
 */
class CastController(val sender: String = "sender-purio") {
    enum class State { IDLE, LAUNCHING, READY, STOPPED, FAILED }
    sealed interface Event {
        data object Ready : Event
        data class Media(val status: CastMediaStatus) : Event
        data object LoadFailed : Event
        /** The player went away on the TV (another app, Home, Stop): the next load launches it again. */
        data object ReceiverGone : Event
        data class Failed(val problem: Problem) : Event
    }
    data class Load(val url: String, val contentType: String, val title: String, val hls: Boolean = false)
    data class Step(val send: List<CastMessage>, val events: List<Event>)

    var state = State.IDLE; private set
    var transport: String? = null; private set
    var session: String? = null; private set
    var mediaSession: Int? = null; private set
    var pending: Load? = null; private set
    private var requestId = 0
    /** The newest LOAD's id: the TV answers a LOAD it dropped for a newer one with LOAD_FAILED (1.2 test). */
    private var lastLoad = 0

    fun start(): List<CastMessage> {
        state = State.LAUNCHING
        return listOf(message("receiver-0", CastNamespace.CONNECTION, obj("type" to "CONNECT")),
            request("receiver-0", CastNamespace.RECEIVER, obj("type" to "LAUNCH", "appId" to MEDIA_RECEIVER)))
    }

    fun load(item: Load): List<CastMessage> = when (state) {
        State.READY -> { pending = null; listOf(loadMessage(item)) }
        State.LAUNCHING -> { pending = item; emptyList() }
        else -> { pending = item; start() }
    }
    fun play() = mediaCommand(obj("type" to "PLAY"))
    fun pause() = mediaCommand(obj("type" to "PAUSE"))
    fun seek(seconds: Double) = mediaCommand(obj("type" to "SEEK", "currentTime" to maxOf(0.0, seconds)))
    fun heartbeat() = listOf(message("receiver-0", CastNamespace.HEARTBEAT, obj("type" to "PING")))
    /** Asks where the player is (it reports only on changes). */
    fun status(): List<CastMessage> {
        val transport = transport ?: return emptyList()
        if (state != State.READY) return emptyList()
        return listOf(request(transport, CastNamespace.MEDIA, obj("type" to "GET_STATUS")))
    }

    /** Closes the player on the TV (it returns to Home) and ends the session. */
    fun stop(): List<CastMessage> {
        val out = mutableListOf<CastMessage>()
        session?.let { out += request("receiver-0", CastNamespace.RECEIVER, obj("type" to "STOP", "sessionId" to it)) }
        if (session != null) transport?.let { out += message(it, CastNamespace.CONNECTION, obj("type" to "CLOSE")) }
        state = State.STOPPED; transport = null; session = null; mediaSession = null; pending = null
        return out
    }

    fun receive(incoming: CastMessage): Step {
        val json = incoming.json
        val type = json.string("type") ?: ""
        return when {
            incoming.namespace == CastNamespace.HEARTBEAT && type == "PING" ->
                Step(listOf(message(incoming.source, CastNamespace.HEARTBEAT, obj("type" to "PONG"))), emptyList())
            incoming.namespace == CastNamespace.RECEIVER && type == "RECEIVER_STATUS" -> receiverStatus(json)
            incoming.namespace == CastNamespace.RECEIVER && type == "LAUNCH_ERROR" -> {
                state = State.FAILED
                Step(emptyList(), listOf(Event.Failed(Problem.CAST_LAUNCH_FAILED)))
            }
            incoming.namespace == CastNamespace.MEDIA && type == "MEDIA_STATUS" -> {
                val status = (json["status"] as? JsonArray)?.firstOrNull() as? JsonObject ?: return Step(emptyList(), emptyList())
                status.int("mediaSessionId")?.let { mediaSession = it }
                val media = status["media"] as? JsonObject
                Step(emptyList(), listOf(Event.Media(CastMediaStatus(status.string("playerState") ?: "IDLE",
                    status.double("currentTime") ?: 0.0, media?.double("duration"), status.string("idleReason")))))
            }
            incoming.namespace == CastNamespace.MEDIA && (type == "LOAD_FAILED" || type == "INVALID_REQUEST") -> {
                val id = json.int("requestId")
                if (id != null && id != lastLoad) Step(emptyList(), emptyList()) else Step(emptyList(), listOf(Event.LoadFailed))
            }
            incoming.namespace == CastNamespace.CONNECTION && type == "CLOSE" && incoming.source == transport -> playerGone()
            else -> Step(emptyList(), emptyList())
        }
    }

    private fun receiverStatus(json: JsonObject): Step {
        val apps = ((json["status"] as? JsonObject)?.get("applications") as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
        val player = apps.firstOrNull { it.string("appId") == MEDIA_RECEIVER }
        val newTransport = player?.string("transportId"); val newSession = player?.string("sessionId")
        if (newTransport == null || newSession == null) return if (state == State.READY) playerGone() else Step(emptyList(), emptyList())
        if (state != State.LAUNCHING && newTransport == transport) return Step(emptyList(), emptyList())
        state = State.READY; transport = newTransport; session = newSession; mediaSession = null
        val out = mutableListOf(message(newTransport, CastNamespace.CONNECTION, obj("type" to "CONNECT")))
        pending?.let { out += loadMessage(it); pending = null }
        return Step(out, listOf(Event.Ready))
    }
    private fun playerGone(): Step {
        if (state != State.READY) return Step(emptyList(), emptyList())
        state = State.IDLE; transport = null; session = null; mediaSession = null
        return Step(emptyList(), listOf(Event.ReceiverGone))
    }
    private fun loadMessage(item: Load): CastMessage {
        mediaSession = null
        val media = mutableMapOf<String, JsonElement>("contentId" to JsonPrimitive(item.url), "contentType" to JsonPrimitive(item.contentType),
            "streamType" to JsonPrimitive("BUFFERED"), "metadata" to obj("metadataType" to 0, "title" to item.title))
        if (item.hls) { media["hlsSegmentFormat"] = JsonPrimitive("fmp4"); media["hlsVideoSegmentFormat"] = JsonPrimitive("fmp4") }
        lastLoad = requestId + 1
        return request(transport ?: "", CastNamespace.MEDIA, obj("type" to "LOAD", "sessionId" to (session ?: ""), "autoplay" to true,
            "currentTime" to 0, "media" to JsonObject(media)))
    }
    private fun mediaCommand(json: JsonObject): List<CastMessage> {
        val transport = transport ?: return emptyList()
        val id = mediaSession ?: return emptyList()
        if (state != State.READY) return emptyList()
        return listOf(request(transport, CastNamespace.MEDIA, JsonObject(json + ("mediaSessionId" to JsonPrimitive(id)))))
    }
    private fun request(destination: String, namespace: String, json: JsonObject): CastMessage {
        requestId += 1
        return message(destination, namespace, JsonObject(json + ("requestId" to JsonPrimitive(requestId))))
    }
    private fun message(destination: String, namespace: String, json: JsonObject) = CastMessage.of(sender, destination, namespace, json)

    companion object { const val MEDIA_RECEIVER = "CC1AD845" }
}

/** Only the photo you stop on for [settleMillis] goes to the TV, never the same one twice in a row (CST-03). */
class CastFollower(private val settleMillis: Long = 350) {
    var shown: String? = null; private set
    private var focus: Pair<String, Long>? = null
    fun focused(id: String, now: Long = System.currentTimeMillis()) { focus = id to now }
    fun due(now: Long = System.currentTimeMillis()): String? {
        val (id, at) = focus ?: return null
        if (now - at < settleMillis - 1 || id == shown) return null
        shown = id
        return id
    }
    fun forget() { shown = null }
}

/**
 * A Cast session with the TV: [CastController] over TLS with the 5-second heartbeat. Runs only while Show on TV is
 * open; [stop] ends it. Events are delivered on the IO dispatcher; the app hops to the main thread itself.
 */
class CastSession(private val host: String, private val onEvent: (CastController.Event) -> Unit) {
    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val commands = Channel<(CastController) -> List<CastMessage>>(Channel.UNLIMITED)
    private val controller = CastController()
    private val decoder = CastFrameDecoder()
    private val closed = AtomicBoolean(false)
    @Volatile private var socket: SSLSocket? = null
    private var loop: Job? = null

    fun load(item: CastController.Load) = run { it.load(item) }
    fun play() = run { it.play() }
    fun pause() = run { it.pause() }
    fun seek(seconds: Double) = run { it.seek(seconds) }
    fun refresh() = run { it.status() }
    fun stop() {
        run { it.stop() }
        io.launch { delay(500); close() }
    }

    private fun run(step: (CastController) -> List<CastMessage>) {
        if (closed.get()) return
        commands.trySend(step)
        if (loop == null) loop = io.launch { connectAndServe() }
    }

    private suspend fun connectAndServe() {
        val tls = try {
            val plain = Socket().apply { tcpNoDelay = true; connect(InetSocketAddress(host, 8009), 8_000) }
            // Cast devices present a self-signed certificate that changes over time and don't ask senders for one;
            // the session carries only commands and links to this phone's own server, so the TLS is for privacy.
            val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(TrustAll), null) }
            (context.socketFactory.createSocket(plain, host, 8009, true) as SSLSocket).also { it.startHandshake() }
        } catch (e: ConnectException) {
            fail(if (e.message?.contains("refused", ignoreCase = true) == true) Problem.CAST_NO_CHROMECAST else Problem.CAST_UNREACHABLE); return
        } catch (e: IOException) { fail(Problem.CAST_UNREACHABLE); return }
        socket = tls
        val output = tls.outputStream
        io.launch { // reader
            val input = tls.inputStream
            val buffer = ByteArray(16384)
            try {
                while (isActive) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    for (body in decoder.append(buffer.copyOf(n))) {
                        val (send, events) = synchronized(controller) { controller.receive(CastMessage.decode(body)) }
                        write(send)
                        events.forEach(onEvent)
                    }
                }
            } catch (_: Exception) {}
            if (!closed.get()) { onEvent(CastController.Event.ReceiverGone); close() }
        }
        io.launch { // heartbeat
            while (isActive) { delay(5_000); write(synchronized(controller) { controller.heartbeat() }) }
        }
        for (step in commands) write(synchronized(controller) { step(controller) })
    }
    private fun write(messages: List<CastMessage>) {
        val out = socket?.outputStream ?: return
        try { synchronized(out) { for (m in messages) out.write(m.framed); out.flush() } }
        catch (_: IOException) { if (!closed.get()) { onEvent(CastController.Event.Failed(Problem.CAST_INTERRUPTED)); close() } }
    }
    private fun fail(problem: Problem) { if (!closed.get()) { onEvent(CastController.Event.Failed(problem)); close() } }
    private fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket?.close() }
        commands.close()
        io.cancel()
    }

    private object TrustAll : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
}

private fun obj(vararg pairs: Pair<String, Any>): JsonObject = JsonObject(pairs.associate { (k, v) ->
    k to when (v) { is JsonElement -> v; is String -> JsonPrimitive(v); is Number -> JsonPrimitive(v); is Boolean -> JsonPrimitive(v); else -> JsonPrimitive(v.toString()) }
})
internal fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
internal fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
internal fun JsonObject.double(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull
