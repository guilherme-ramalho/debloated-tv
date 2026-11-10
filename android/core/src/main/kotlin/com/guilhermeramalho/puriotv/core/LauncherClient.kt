package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * An editing session with TV Home (docs/launcher-editor-contract.md, version 2; LauncherClient.swift). The caller
 * first sends [EditorLink.url] through the paired remote connection; the TV then listens briefly on port 9764.
 */
class LauncherClient(private val port: Int = 9764) {
    var onDisconnected: ((RemoteFailure) -> Unit)? = null
    val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    private class Session(val socket: Socket, val output: OutputStream, val outgoing: EditorCipher, val incoming: EditorCipher)

    @Volatile private var session: Session? = null
    private var scope: CoroutineScope? = null
    private val pending = ConcurrentHashMap<String, CompletableDeferred<JsonElement>>()
    @Volatile private var generation = 0

    val isOpen get() = session != null

    fun close() {
        generation++
        scope?.cancel(); scope = null
        session?.let { runCatching { it.socket.close() } }; session = null
        pending.values.forEach { it.completeExceptionally(CancellationException("closed")) }; pending.clear()
    }

    /**
     * Connects and completes the hello, retrying until [withinMillis] pass: the TV's listener may still be starting,
     * or one left from an earlier link may answer first and turn this key away.
     */
    suspend fun open(host: String, key: ByteArray, withinMillis: Long = 10_000) {
        close()
        val token = generation
        val deadline = System.currentTimeMillis() + withinMillis
        var last = RemoteFailure(Problem.EDITOR_NO_ANSWER)
        do {
            currentCoroutineContextCheck(token)
            try {
                val opened = withContext(Dispatchers.IO) { attempt(host, key, deadline) }
                if (token != generation) { runCatching { opened.socket.close() }; throw CancellationException("closed") }
                begin(opened, token)
                return
            } catch (e: RemoteFailure) {
                last = e
                delay(400)
            }
        } while (System.currentTimeMillis() < deadline)
        throw last
    }

    private suspend fun currentCoroutineContextCheck(token: Int) {
        kotlin.coroutines.coroutineContext.ensureActive()
        if (token != generation) throw CancellationException("closed")
    }

    private fun attempt(host: String, key: ByteArray, deadline: Long): Session {
        val socket = Socket()
        try {
            val remaining = (deadline - System.currentTimeMillis()).coerceIn(500, 3000).toInt()
            socket.tcpNoDelay = true
            socket.connect(InetSocketAddress(host, port), remaining)
            socket.soTimeout = 3000
            val output = socket.getOutputStream()
            val phoneNonce = EditorLink.random(16)
            output.write(Wire.frame(MAGIC + phoneNonce + EditorLink.keyId(key))); output.flush()
            val reply = readFrame(socket.getInputStream(), FrameDecoder(64))
                ?: throw RemoteFailure(Problem.EDITOR_CLOSED)
            if (reply.size != 20 || !reply.copyOfRange(0, 4).contentEquals(MAGIC)) throw RemoteFailure(Problem.EDITOR_OLD)
            val tvNonce = reply.copyOfRange(4, 20)
            socket.soTimeout = 0
            return Session(socket, output,
                EditorCipher(key, phoneNonce, tvNonce, EditorCipher.PHONE_TO_TV),
                EditorCipher(key, phoneNonce, tvNonce, EditorCipher.TV_TO_PHONE))
        } catch (e: IOException) {
            runCatching { socket.close() }
            throw RemoteFailure(Problem.EDITOR_NO_ANSWER, e.message)
        } catch (e: RemoteFailure) {
            runCatching { socket.close() }
            throw e
        }
    }

    /** Reads exactly one frame (the hello reply), byte by byte so nothing after it is consumed. */
    private fun readFrame(input: InputStream, decoder: FrameDecoder): ByteArray? {
        while (true) {
            val b = input.read()
            if (b < 0) return null
            decoder.append(byteArrayOf(b.toByte())).firstOrNull()?.let { return it }
        }
    }

    private fun begin(opened: Session, token: Int) {
        session = opened
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO).also { this.scope = it }
        scope.launch {
            val decoder = FrameDecoder(4_194_304)
            val input = opened.socket.getInputStream()
            val buffer = ByteArray(65536)
            try {
                while (isActive) {
                    val count = input.read(buffer)
                    if (count < 0) throw RemoteFailure(Problem.EDITOR_CLOSED)
                    for (frame in decoder.append(buffer.copyOf(count))) received(opened.incoming.open(frame))
                }
            } catch (e: IOException) {
                drop(token, RemoteFailure(Problem.EDITOR_CLOSED, e.message))
            } catch (e: RemoteFailure) {
                drop(token, e)
            }
        }
        scope.launch {
            while (isActive) {
                delay(15_000)
                send(buildJsonObject { put("type", "ping") })
            }
        }
    }

    private fun drop(token: Int, failure: RemoteFailure) {
        if (token != generation) return
        val callback = onDisconnected
        close()
        callback?.invoke(failure)
    }

    private fun received(plain: ByteArray) {
        val obj = try { json.parseToJsonElement(plain.decodeToString()).jsonObject } catch (e: Exception) {
            throw RemoteFailure(Problem.EDITOR_INVALID, "Invalid TV editor response")
        }
        when ((obj["type"] as? JsonPrimitive)?.contentOrNull) {
            "response" -> {
                val id = (obj["id"] as? JsonPrimitive)?.contentOrNull ?: return
                val waiting = pending.remove(id) ?: return
                if ((obj["ok"] as? JsonPrimitive)?.booleanOrNull == true) waiting.complete(obj["result"] ?: JsonObject(emptyMap()))
                else waiting.completeExceptionally(RemoteFailure(Problem.EDITOR_REJECTED,
                    (obj["error"] as? JsonPrimitive)?.contentOrNull ?: "The TV rejected this change"))
            }
            "error" -> throw RemoteFailure(Problem.EDITOR_CLOSED, (obj["message"] as? JsonPrimitive)?.contentOrNull)
            "pong" -> Unit
            else -> throw RemoteFailure(Problem.EDITOR_INVALID, "Unsupported TV editor response")
        }
    }

    private fun send(message: JsonObject) {
        val s = session ?: return
        try {
            synchronized(s) {
                s.output.write(Wire.frame(s.outgoing.seal(message.toString().toByteArray())))
                s.output.flush()
            }
        } catch (e: IOException) {
            drop(generation, RemoteFailure(Problem.INTERRUPTED, e.message))
        }
    }

    /** Sends one request and waits up to 20 seconds. Mutations are never retried automatically. */
    suspend fun requestRaw(operation: String, payload: JsonObject = JsonObject(emptyMap())): JsonElement {
        if (session == null) throw RemoteFailure(Problem.EDITOR_NOT_CONNECTED)
        val id = UUID.randomUUID().toString().uppercase()
        val waiting = CompletableDeferred<JsonElement>()
        pending[id] = waiting
        try {
            withContext(Dispatchers.IO) {
                send(buildJsonObject {
                    put("type", "request"); put("id", id); put("operation", operation); put("payload", payload)
                })
            }
            return withTimeoutOrNull(20_000) { waiting.await() } ?: throw RemoteFailure(Problem.EDITOR_TIMEOUT)
        } finally {
            pending.remove(id)
        }
    }

    suspend inline fun <reified T> request(operation: String, payload: JsonObject = JsonObject(emptyMap())): T =
        json.decodeFromJsonElement(requestRaw(operation, payload).takeUnless { it is JsonNull } ?: JsonObject(emptyMap()))

    suspend fun snapshot(): LauncherSnapshot = request<LauncherSnapshot>("snapshot").also { it.validate() }

    companion object {
        val MAGIC = "TVH2".toByteArray()
    }
}
