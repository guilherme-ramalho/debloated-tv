package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What the phone tells the TV about itself in the remote handshake. */
data class ClientInfo(val model: String, val appId: String, val appVersion: String, val vendor: String = "Personal")

/**
 * The Android TV Remote v2 session (TVSession.swift): pairing on port 6467, remote control on 6466.
 * Call it only from [scope], which must run on one thread (the app's main thread); events arrive there too.
 */
class TVSession(
    private val host: String,
    private val identity: ClientIdentity,
    private val clientName: String,
    private val client: ClientInfo,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val pairingPort: Int = 6467,
    private val remotePort: Int = 6466,
) {
    sealed interface Event {
        data object PairingCodeNeeded : Event
        class Paired(val pin: ByteArray) : Event
        data object Connected : Event
        data class Power(val on: Boolean) : Event
        data class Foreground(val packageName: String) : Event
        data class Volume(val level: Int, val maximum: Int, val muted: Boolean) : Event
        data class Error(val problem: Problem) : Event
    }

    var onEvent: ((Event) -> Unit)? = null
    /** When the TV last sent anything (it pings every few seconds); spots a socket that died while the phone slept. */
    var lastInbound = 0L
        private set
    private var channel: TVConnection? = null
    private var inbox: Channel<ByteArray>? = null
    private var pairMode = false
    private var waitingCode = false
    private var secretSent = false
    private var commandReady = false
    private var negotiated = 615L // ping, keys, IME app identity, power, volume, app links
    private var imeCounter = 0L
    private var fieldCounter = 0L
    private var generation = 0

    val isReady get() = commandReady && !pairMode

    fun pair() = open(pairingPort, null, true)
    fun connect(pin: ByteArray) = open(remotePort, pin, false)

    fun disconnect() {
        generation++
        channel?.close(); channel = null
        inbox?.close(); inbox = null
        waitingCode = false; secretSent = false; commandReady = false
    }

    private fun emit(event: Event) = onEvent?.invoke(event)

    private fun open(port: Int, pin: ByteArray?, pairing: Boolean) {
        disconnect()
        pairMode = pairing
        val token = generation
        val connection = TVConnection(host, port, identity, pin, allowUnpaired = pairing)
        channel = connection
        val inbox = Channel<ByteArray>(Channel.UNLIMITED)
        this.inbox = inbox
        scope.launch {
            try {
                connection.open()
            } catch (e: RemoteFailure) {
                if (token == generation) { disconnect(); emit(Event.Error(e.problem)) }
                return@launch
            }
            if (token != generation) { connection.close(); return@launch }
            connection.start(
                onFrame = { inbox.trySend(it) },
                onFailed = { failure ->
                    scope.launch { if (token == generation) { disconnect(); emit(Event.Error(failure.problem)) } }
                },
            )
            if (pairing) sendPair(10, Wire.string(1, "atvremote") + Wire.string(2, clientName))
            for (frame in inbox) {
                if (token != generation) break
                lastInbound = clock()
                try { receive(frame) } catch (e: RemoteFailure) { disconnect(); emit(Event.Error(e.problem)); break }
            }
        }
        scope.launch {
            delay(if (pairing) 90_000 else 15_000)
            if (token == generation && (pairMode || !commandReady)) {
                disconnect()
                emit(Event.Error(if (pairing) Problem.PAIRING_EXPIRED else Problem.HANDSHAKE_INCOMPLETE))
            }
        }
    }

    fun submit(code: String) {
        val server = channel?.peerCertificate?.publicKey
        if (!pairMode || !waitingCode || server == null) { emit(Event.Error(Problem.START_PAIRING_FIRST)); return }
        try {
            val secret = ClientIdentity.secret(code, identity.publicKey, server)
            secretSent = true
            sendPair(40, Wire.bytes(1, secret))
        } catch (e: RemoteFailure) { emit(Event.Error(e.problem)) }
    }

    /** direction: 1 press, 2 release, 3 short (press and release). */
    fun key(key: TVKey, direction: Long = 3) {
        if (!isReady) return
        channel?.send(keyMessage(key, direction))
    }

    fun launch(url: String) {
        if (!isReady || url.isEmpty()) return
        channel?.send(Wire.bytes(90, Wire.string(1, url)))
    }

    suspend fun writeKey(key: TVKey) {
        val c = channel
        if (!isReady || c == null) throw RemoteFailure(Problem.NOT_READY)
        c.write(keyMessage(key, 3))
    }

    suspend fun writeLaunch(url: String) {
        val c = channel
        if (!isReady || c == null || url.isEmpty() || url.toByteArray().size > 2048) throw RemoteFailure(Problem.INVALID_LINK)
        c.write(Wire.bytes(90, Wire.string(1, url)))
    }

    suspend fun writeText(text: String) {
        val c = channel
        if (!isReady || negotiated and 4 == 0L || c == null) throw RemoteFailure(Problem.NO_KEYBOARD)
        c.write(textMessage(text, imeCounter, fieldCounter))
    }

    private fun sendPair(field: Int, body: ByteArray) {
        channel?.send(Wire.int(1, 2) + Wire.int(2, 200) + Wire.bytes(field, body))
    }

    private fun receive(payload: ByteArray) {
        val fields = Wire.fields(payload)
        if (pairMode) {
            if (fields.firstOrNull { it.number == 2 }?.integer != 200L) throw RemoteFailure(Problem.PAIRING_REFUSED)
            val has = { n: Int -> fields.any { it.number == n } }
            when {
                has(11) -> sendPair(20, Wire.bytes(1, Wire.int(1, 3) + Wire.int(2, 6)) + Wire.int(3, 1))
                has(20) -> sendPair(30, Wire.bytes(1, Wire.int(1, 3) + Wire.int(2, 6)) + Wire.int(2, 1))
                has(31) -> { waitingCode = true; emit(Event.PairingCodeNeeded) }
                has(41) && secretSent -> {
                    val certificate = channel?.peerCertificate ?: throw RemoteFailure(Problem.IDENTITY_UNAVAILABLE)
                    val pin = sha256(certificate.encoded)
                    disconnect(); emit(Event.Paired(pin))
                }
            }
            return
        }
        for (field in fields) {
            val body = field.bytes ?: continue
            when (field.number) {
                1 -> {
                    negotiated = Wire.number(1, body) and 615
                    if (negotiated and 2 == 0L) throw RemoteFailure(Problem.NO_KEY_COMMANDS)
                    val info = Wire.string(1, client.model) + Wire.string(2, client.vendor) + Wire.int(3, 1) +
                        Wire.string(4, "1") + Wire.string(5, client.appId) + Wire.string(6, client.appVersion)
                    channel?.send(Wire.bytes(1, Wire.int(1, negotiated) + Wire.bytes(2, info)))
                }
                2 -> channel?.send(Wire.bytes(2, Wire.int(1, negotiated)))
                8 -> channel?.send(Wire.bytes(9, Wire.int(1, Wire.number(1, body))))
                40 -> {
                    if (!commandReady) { commandReady = true; emit(Event.Connected) }
                    emit(Event.Power(Wire.number(1, body) != 0L))
                }
                20 -> foregroundPackage(body)?.let { emit(Event.Foreground(it)) }
                21 -> { imeCounter = Wire.number(1, body); fieldCounter = Wire.number(2, body) }
                50 -> emit(Event.Volume(Wire.number(7, body).toInt(), Wire.number(6, body).toInt(), Wire.number(8, body) != 0L))
                3 -> throw RemoteFailure(Problem.COMMAND_REJECTED)
            }
        }
    }

    companion object {
        fun keyMessage(key: TVKey, direction: Long): ByteArray = Wire.bytes(10, Wire.int(1, key.code) + Wire.int(2, direction))

        private val appNames = mapOf(
            "com.google.android.youtube.tv" to "YouTube", "com.netflix.ninja" to "Netflix",
            "com.amazon.amazonvideo.livingroom" to "Prime Video", "com.disney.disneyplus" to "Disney+",
            "com.wbd.stream" to "HBO Max", "com.hbo.hbonow" to "HBO Max", "com.crunchyroll.crunchyroid" to "Crunchyroll",
            "com.spotify.tv.android" to "Spotify",
        )
        fun appName(packageName: String): String? = appNames[packageName]

        fun foregroundPackage(body: ByteArray): String? {
            val info = Wire.fields(body).firstOrNull { it.number == 1 }?.bytes ?: return null
            val raw = Wire.fields(info).firstOrNull { it.number == 12 }?.bytes ?: return null
            val decoder = Charsets.UTF_8.newDecoder()
            val value = try { decoder.decode(java.nio.ByteBuffer.wrap(raw)).toString() } catch (_: Exception) { return null }
            return value.takeIf { it.length <= 180 }
        }

        /**
         * How to bring the TV's field from [sent] to [value]. The TV inserts what it is sent at its cursor instead of
         * replacing the field, so keep the shared start, delete the rest, insert the new tail.
         */
        fun typingEdit(sent: String, value: String): Pair<Int, String> {
            val shared = sent.zip(value).takeWhile { it.first == it.second }.size
            return (sent.length - shared) to value.drop(shared)
        }

        fun textMessage(text: String, imeCounter: Long, fieldCounter: Long): ByteArray {
            // Swift counts UTF-16 units; so do Kotlin strings.
            if (text.isEmpty() || text.length > 4096) throw RemoteFailure(Problem.TEXT_LENGTH)
            val end = (text.length - 1).toLong()
            val obj = Wire.int(1, end) + Wire.int(2, end) + Wire.string(3, text)
            val edit = Wire.int(1, 1) + Wire.bytes(2, obj)
            return Wire.bytes(21, Wire.int(1, imeCounter) + Wire.int(2, fieldCounter) + Wire.bytes(3, edit))
        }
    }
}
