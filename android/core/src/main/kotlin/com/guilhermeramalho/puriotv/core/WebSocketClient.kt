package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/**
 * A small text WebSocket client (RFC 6455) for the LG and Samsung remotes, so the app needs no WebSocket library.
 * `wss://` accepts the TV's self-signed certificate, as the Cast sender does: TVs have no certificate a phone could
 * check. Callbacks run on [scope] (the main thread in the app), in order; the socket itself lives on IO threads.
 */
class WebSocketClient(private val url: URI, private val scope: CoroutineScope, private val timeoutMs: Int = 6000) {
    var onOpen: (() -> Unit)? = null
    var onText: ((String) -> Unit)? = null
    /** The reason, or null when closed on purpose. */
    var onClose: ((String?) -> Unit)? = null
    @Volatile var lastInbound = 0L
        private set

    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val outbox = Channel<ByteArray>(Channel.UNLIMITED)
    private val closed = AtomicBoolean(false)
    @Volatile private var socket: Socket? = null

    fun open() {
        io.launch {
            try {
                val s = connect()
                socket = s
                val input = BufferedInputStream(s.getInputStream())
                val output = s.getOutputStream()
                handshake(input, output)
                deliver { onOpen?.invoke() }
                io.launch { for (frame in outbox) { output.write(frame); output.flush() } }
                read(input, output)
            } catch (e: Exception) {
                fail(e.message ?: e.javaClass.simpleName)
            }
        }
    }

    fun send(text: String) { if (!closed.get()) outbox.trySend(frame(0x1, text.toByteArray())) }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket?.close() }
        outbox.close(); io.cancel()
    }

    private fun fail(reason: String) {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket?.close() }
        outbox.close()
        deliver { onClose?.invoke(reason) }
        io.cancel()
    }

    private fun deliver(block: () -> Unit) { scope.launch { block() } }

    private fun connect(): Socket {
        val secure = url.scheme == "wss"
        val port = if (url.port > 0) url.port else if (secure) 443 else 80
        val plain = Socket().apply { tcpNoDelay = true; connect(InetSocketAddress(url.host, port), timeoutMs); soTimeout = 0 }
        if (!secure) return plain
        val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(TrustAll), null) }
        return (context.socketFactory.createSocket(plain, url.host, port, true) as SSLSocket).also { it.soTimeout = timeoutMs; it.startHandshake(); it.soTimeout = 0 }
    }

    private fun handshake(input: InputStream, output: OutputStream) {
        val key = Base64.getEncoder().encodeToString(ByteArray(16).also { SecureRandom().nextBytes(it) })
        val path = (url.rawPath?.ifEmpty { "/" } ?: "/") + (url.rawQuery?.let { "?$it" } ?: "")
        val hostHeader = if (url.port > 0) "${url.host}:${url.port}" else url.host
        output.write(("GET $path HTTP/1.1\r\nHost: $hostHeader\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n").toByteArray())
        output.flush()
        val head = HttpRequestHead.read(input) ?: throw RemoteFailure(Problem.CLOSED, "no handshake answer")
        // The status line comes back as method/path: "HTTP/1.1" "101".
        if (head.path != "101") throw RemoteFailure(Problem.CONNECT_FAILED, "handshake ${head.method} ${head.path}")
        val expected = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1").digest((key + MAGIC).toByteArray()))
        if (head.headers["sec-websocket-accept"] != expected) throw RemoteFailure(Problem.INVALID_PROTOCOL, "bad accept")
    }

    private fun read(input: InputStream, output: OutputStream) {
        val message = ByteArrayOutputStream()
        var messageOpcode = 0
        while (!closed.get()) {
            val b0 = input.read(); val b1 = input.read()
            if (b0 < 0 || b1 < 0) { fail("closed"); return }
            val fin = b0 and 0x80 != 0
            val opcode = b0 and 0x0f
            var length = (b1 and 0x7f).toLong()
            if (length == 126L) length = ((input.read() shl 8) or input.read()).toLong()
            else if (length == 127L) { length = 0; repeat(8) { length = (length shl 8) or input.read().toLong() } }
            if (length > MAX) { fail("frame too large"); return }
            val mask = if (b1 and 0x80 != 0) ByteArray(4).also { readFully(input, it) } else null
            val payload = ByteArray(length.toInt()).also { readFully(input, it) }
            if (mask != null) for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
            lastInbound = System.currentTimeMillis()
            when (opcode) {
                0x8 -> { fail("The TV closed the remote connection."); return }
                0x9 -> outbox.trySend(frame(0xA, payload))
                0xA -> Unit
                0x0, 0x1, 0x2 -> {
                    if (opcode != 0x0) { message.reset(); messageOpcode = opcode }
                    message.write(payload)
                    if (message.size() > MAX) { fail("message too large"); return }
                    if (fin && messageOpcode == 0x1) { val text = message.toString(Charsets.UTF_8.name()); deliver { onText?.invoke(text) } }
                }
            }
        }
    }

    private fun readFully(input: InputStream, into: ByteArray) {
        var at = 0
        while (at < into.size) { val n = input.read(into, at, into.size - at); if (n < 0) throw RemoteFailure(Problem.CLOSED); at += n }
    }

    companion object {
        private const val MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        private const val MAX = 8L * 1024 * 1024

        /** One masked client frame (a client must mask everything it sends). */
        fun frame(opcode: Int, payload: ByteArray): ByteArray {
            val out = ByteArrayOutputStream()
            out.write(0x80 or opcode)
            when {
                payload.size < 126 -> out.write(0x80 or payload.size)
                payload.size < 65536 -> { out.write(0x80 or 126); out.write(payload.size shr 8); out.write(payload.size and 0xff) }
                else -> { out.write(0x80 or 127); for (shift in 56 downTo 0 step 8) out.write(((payload.size.toLong() shr shift) and 0xff).toInt()) }
            }
            val mask = ByteArray(4).also { SecureRandom().nextBytes(it) }
            out.write(mask)
            out.write(ByteArray(payload.size) { (payload[it].toInt() xor mask[it % 4].toInt()).toByte() })
            return out.toByteArray()
        }
    }

    private object TrustAll : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
}
