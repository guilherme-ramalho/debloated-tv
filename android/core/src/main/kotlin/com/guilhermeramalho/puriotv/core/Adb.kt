package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.math.BigInteger
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.RSAPublicKey
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A small Android Debug Bridge client (Adb.swift): enough to inspect a TV, disable packages, push and install an APK
 * and restore it all, from the phone with no computer. Speaks the plain TCP transport (network debugging, usually
 * port 5555). Reference: AOSP packages/modules/adb/protocol.txt.
 */
object Adb {
    const val CNXN = 0x4e584e43
    const val AUTH = 0x48545541
    const val OPEN = 0x4e45504f
    const val OKAY = 0x59414b4f
    const val CLSE = 0x45534c43
    const val WRTE = 0x45545257
    const val VERSION = 0x01000001
    const val MAX_DATA = 256 * 1024
    const val AUTH_TOKEN = 1
    const val AUTH_SIGNATURE = 2
    const val AUTH_PUBLIC_KEY = 3

    class Message(val command: Int, val arg0: Int, val arg1: Int, val payload: ByteArray = ByteArray(0)) {
        override fun equals(other: Any?) = other is Message && command == other.command && arg0 == other.arg0 &&
            arg1 == other.arg1 && payload.contentEquals(other.payload)
        override fun hashCode() = ((command * 31 + arg0) * 31 + arg1) * 31 + payload.contentHashCode()
        override fun toString() = "Message(${String(le(command), Charsets.ISO_8859_1)}, $arg0, $arg1, ${payload.size} bytes)"
    }

    fun le(value: Int) = byteArrayOf(value.toByte(), (value ushr 8).toByte(), (value ushr 16).toByte(), (value ushr 24).toByte())
    fun readLE(bytes: ByteArray, offset: Int): Int =
        (0 until 4).fold(0) { v, i -> v or ((bytes[offset + i].toInt() and 255) shl (8 * i)) }

    /** 24-byte header (command, arg0, arg1, length, byte sum, command ^ 0xffffffff), then the payload. */
    fun encode(m: Message): ByteArray {
        val sum = m.payload.fold(0) { s, b -> s + (b.toInt() and 255) }
        return le(m.command) + le(m.arg0) + le(m.arg1) + le(m.payload.size) + le(sum) + le(m.command xor -1) + m.payload
    }

    class Decoder {
        private var buffer = ByteArray(0)
        fun append(data: ByteArray): List<Message> {
            buffer += data
            val out = mutableListOf<Message>()
            while (buffer.size >= 24) {
                val command = readLE(buffer, 0)
                val length = readLE(buffer, 12).toUInt().toLong()
                if (readLE(buffer, 20) != command xor -1) throw RemoteFailure(Problem.INVALID_PROTOCOL, "The TV sent an invalid debugging message")
                if (length > MAX_DATA.toLong() * 4) throw RemoteFailure(Problem.INVALID_PROTOCOL, "The TV sent an oversized debugging message")
                if (buffer.size < 24 + length) break
                out += Message(command, readLE(buffer, 4), readLE(buffer, 8), buffer.copyOfRange(24, 24 + length.toInt()))
                buffer = buffer.copyOfRange(24 + length.toInt(), buffer.size)
            }
            return out
        }
    }

    /** The TV's identity from the CNXN banner, e.g. "device::ro.product.name=…;ro.product.model=…;features=…". */
    fun bannerProperties(payload: ByteArray): Map<String, String> {
        val end = payload.indexOf(0).let { if (it < 0) payload.size else it }
        val text = String(payload, 0, end, Charsets.UTF_8)
        val at = text.indexOf("::")
        if (at < 0) return emptyMap()
        val props = mutableMapOf<String, String>()
        for (item in text.substring(at + 2).split(";").filter { it.isNotEmpty() }) {
            val parts = item.split("=", limit = 2)
            if (parts.size == 2 && parts[0].isNotEmpty() && parts[1].isNotEmpty()) props[parts[0]] = parts[1]
        }
        return props
    }
}

/**
 * The phone's ADB key. The TV shows "Allow USB debugging?" for it once; "Always allow" keeps it authorized. On the
 * phone, back it with an Android Keystore RSA-2048 key (signature padding PKCS1, digest NONE) so it never leaves the
 * device; [JcaAdbSigner] is the plain java.security version for tests and tools.
 */
interface AdbSigner {
    val publicKey: RSAPublicKey

    /**
     * adb signs the 20-byte token as if it were a SHA-1 digest: a PKCS#1 v1.5 signature over
     * [AdbKeys.digestInfo] (the SHA-1 DigestInfo prefix + the token), i.e. "NONEwithRSA" over those 35 bytes.
     */
    fun sign(token: ByteArray): ByteArray
}

class JcaAdbSigner(private val keyPair: KeyPair) : AdbSigner {
    override val publicKey: RSAPublicKey get() = keyPair.public as RSAPublicKey
    override fun sign(token: ByteArray): ByteArray = Signature.getInstance("NONEwithRSA").run {
        initSign(keyPair.private)
        update(AdbKeys.digestInfo(token))
        sign()
    }

    companion object {
        fun generate(): JcaAdbSigner =
            JcaAdbSigner(KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair())
    }
}

object AdbKeys {
    private val sha1DigestInfo = byteArrayOf(0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14)

    /** The bytes a PKCS#1 v1.5 "SHA-1" signature covers: DigestInfo prefix + the 20-byte token. */
    fun digestInfo(token: ByteArray): ByteArray {
        if (token.size != 20) throw RemoteFailure(Problem.INVALID_PROTOCOL, "The TV sent an unexpected authorization token")
        return sha1DigestInfo + token
    }

    /** The public key as the TV stores it in /data/misc/adb/adb_keys: base64 of Android's RSAPublicKey struct, a name, NUL. */
    fun publicKeyLine(key: RSAPublicKey, name: String): ByteArray {
        val encoded = androidEncoding(key.modulus.toByteArray(), key.publicExponent.toInt())
        return (Base64.getEncoder().encodeToString(encoded) + " " + name).toByteArray(Charsets.UTF_8) + byteArrayOf(0)
    }

    /** Android's struct { len = 64; n0inv; n[64] (LE words); rr[64]; exponent } for a 2048-bit modulus (big-endian bytes). */
    fun androidEncoding(modulus: ByteArray, exponent: Int): ByteArray {
        var start = 0
        while (modulus.size - start > 256 && modulus[start] == 0.toByte()) start++
        if (modulus.size - start != 256) throw SetupFailure(SetupIssue.ADB_KEY_SIZE)
        val n = BigInteger(1, modulus.copyOfRange(start, modulus.size))
        val two32 = BigInteger.ONE.shiftLeft(32)
        val n0inv = two32.subtract(n.mod(two32).modInverse(two32)).mod(two32).toLong().toInt()
        val rr = BigInteger.ONE.shiftLeft(4096).mod(n)
        val mask = two32.subtract(BigInteger.ONE)
        fun words(v: BigInteger) = (0 until 64).flatMap { Adb.le(v.shiftRight(32 * it).and(mask).toLong().toInt()).toList() }
        return (Adb.le(64) + Adb.le(n0inv) + words(n).toByteArray() + words(rr).toByteArray() + Adb.le(exponent))
    }
}

/**
 * One ADB connection over a blocking socket, used from coroutines (the blocking work runs on Dispatchers.IO and a
 * cancelled call closes the socket). Use it from one coroutine at a time: a second concurrent call throws.
 */
class AdbClient(val host: String, val port: Int = 5555, private val signer: AdbSigner) : TVDevice {
    data class ShellResult(val output: String, val status: Int)
    enum class State { CONNECTING, WAITING_FOR_APPROVAL, CONNECTED, CLOSED }

    @Volatile var state = State.CLOSED; private set
    @Volatile var properties: Map<String, String> = emptyMap(); private set
    /** Optional step-by-step trace of the connection, for diagnostics. */
    var log: ((String) -> Unit)? = null

    @Volatile private var socket: Socket? = null
    private var input: InputStream? = null
    private var output: OutputStream? = null
    private var decoder = Adb.Decoder()
    private val inbox = ArrayDeque<Adb.Message>()
    private val busy = AtomicBoolean(false)
    private var nextLocalID = 1
    private var remoteMaxData = Adb.MAX_DATA

    /** Runs blocking socket work on IO; cancelling the caller closes the socket so a blocked read ends. */
    private suspend fun <T> io(block: () -> T): T = withContext(Dispatchers.IO) {
        val finished = AtomicBoolean(false)
        val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
            try { awaitCancellation() } finally { if (!finished.get()) closeNow() }
        }
        try { block() } finally { finished.set(true); watcher.cancel() }
    }

    // MARK: transport

    private fun send(m: Adb.Message) {
        val out = output ?: throw RemoteFailure(Problem.CLOSED, "The TV closed the debugging connection")
        try { synchronized(out) { out.write(Adb.encode(m)); out.flush() } } catch (e: IOException) {
            closeNow(); throw RemoteFailure(Problem.CLOSED, "The TV closed the debugging connection")
        }
    }

    private fun next(timeoutMs: Long): Adb.Message {
        inbox.removeFirstOrNull()?.let { return it }
        val s = socket ?: throw RemoteFailure(Problem.CLOSED, "The TV closed the debugging connection")
        val stream = input ?: throw RemoteFailure(Problem.CLOSED, "The TV closed the debugging connection")
        val deadline = System.currentTimeMillis() + timeoutMs
        val buffer = ByteArray(65536)
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) throw RemoteFailure(Problem.TIMED_OUT, "The TV stopped answering")
            val count = try {
                s.soTimeout = remaining.coerceIn(1, Int.MAX_VALUE.toLong()).toInt()
                stream.read(buffer)
            } catch (e: SocketTimeoutException) {
                throw RemoteFailure(Problem.TIMED_OUT, "The TV stopped answering")
            } catch (e: IOException) {
                closeNow(); throw RemoteFailure(Problem.CLOSED, "The TV closed the debugging connection")
            }
            if (count < 0) { closeNow(); throw RemoteFailure(Problem.CLOSED, "The TV closed the debugging connection") }
            val messages = try { decoder.append(buffer.copyOf(count)) } catch (e: RemoteFailure) { closeNow(); throw e }
            inbox.addAll(messages)
            inbox.removeFirstOrNull()?.let { return it }
        }
    }

    // MARK: connect and authorize

    /**
     * Connects and authorizes. If the TV doesn't know this phone yet, [onApproval] is called while the TV shows
     * "Allow USB debugging?", and the call waits up to [approvalTimeoutMs] for the user to accept it.
     * Returns the banner properties.
     */
    suspend fun connect(name: String = "Purio TV@Android", approvalTimeoutMs: Long = 90_000,
                        onApproval: () -> Unit = {}): Map<String, String> = io {
        closeNow()
        if (!busy.compareAndSet(false, true)) throw SetupFailure(SetupIssue.ADB_BUSY)
        try {
            handshake(name, approvalTimeoutMs, onApproval)
        } catch (e: Throwable) {
            if (state != State.CONNECTED) closeNow()
            throw e
        } finally {
            busy.set(false)
        }
    }

    private fun handshake(name: String, approvalTimeoutMs: Long, onApproval: () -> Unit): Map<String, String> {
        decoder = Adb.Decoder(); inbox.clear(); state = State.CONNECTING
        val s = Socket()
        try {
            s.tcpNoDelay = true; s.keepAlive = true
            s.connect(InetSocketAddress(host, port), 8_000)
        } catch (e: IOException) {
            try { s.close() } catch (_: IOException) {}
            state = State.CLOSED
            throw SetupFailure(SetupIssue.ADB_UNREACHABLE, port.toString(), e.message ?: e.javaClass.simpleName)
        }
        socket = s; input = s.getInputStream(); output = s.getOutputStream()
        log?.invoke("TCP connected to $host:$port")
        send(Adb.Message(Adb.CNXN, Adb.VERSION, Adb.MAX_DATA, "host::debloated-tv".toByteArray() + byteArrayOf(0)))
        log?.invoke("sent CNXN")
        var signed = false
        var offered = false
        while (true) {
            val m = next(if (offered) approvalTimeoutMs else 10_000)
            log?.invoke("received $m")
            if (m.command == Adb.CNXN) {
                remoteMaxData = maxOf(4096L, minOf(m.arg1.toUInt().toLong(), Adb.MAX_DATA.toLong())).toInt()
                properties = Adb.bannerProperties(m.payload)
                state = State.CONNECTED
                return properties
            }
            if (m.command != Adb.AUTH || m.arg0 != Adb.AUTH_TOKEN) continue
            when {
                !signed -> {
                    signed = true
                    AdbKeys.digestInfo(m.payload)   // checks the token is 20 bytes
                    send(Adb.Message(Adb.AUTH, Adb.AUTH_SIGNATURE, 0, signer.sign(m.payload)))
                }
                !offered -> {
                    offered = true; state = State.WAITING_FOR_APPROVAL
                    send(Adb.Message(Adb.AUTH, Adb.AUTH_PUBLIC_KEY, 0, AdbKeys.publicKeyLine(signer.publicKey, name)))
                    log?.invoke("signature not known to the TV; sent the public key, waiting for approval on the TV")
                    onApproval()
                }
                else -> throw SetupFailure(SetupIssue.ADB_REFUSED)
            }
        }
    }

    private fun closeNow() {
        val s = socket
        socket = null; input = null; output = null
        state = State.CLOSED
        if (s != null) try { s.close() } catch (_: IOException) {}
    }

    override suspend fun close() = closeNow()

    // MARK: streams

    private fun begin() {
        if (state != State.CONNECTED) throw RemoteFailure(Problem.NOT_READY, "Not connected to the TV")
        if (!busy.compareAndSet(false, true)) throw SetupFailure(SetupIssue.ADB_BUSY)
    }

    private fun openStream(service: String): Pair<Int, Int> {
        val local = nextLocalID++
        send(Adb.Message(Adb.OPEN, local, 0, service.toByteArray() + byteArrayOf(0)))
        while (true) {
            val m = next(15_000)
            if (m.command == Adb.OKAY && m.arg1 == local) return local to m.arg0
            if (m.command == Adb.CLSE && m.arg1 == local) throw SetupFailure(SetupIssue.ADB_STREAM_REFUSED, service.substringBefore(":"))
        }
    }

    /** Runs a shell command and returns its output (CRLF folded to LF) and exit status (-1 when unknown). */
    override suspend fun shell(command: String, timeoutMs: Long): ShellResult = io {
        begin()
        try {
            val marker = "__DTV_EXIT__"
            val (local, remote) = openStream("shell:$command; echo $marker$?")
            val output = java.io.ByteArrayOutputStream()
            var closed = false
            while (!closed) {
                val m = next(timeoutMs)
                if (m.arg1 != local) continue
                when (m.command) {
                    Adb.WRTE -> { output.write(m.payload); send(Adb.Message(Adb.OKAY, local, remote)) }
                    Adb.CLSE -> { closed = true; send(Adb.Message(Adb.CLSE, local, remote)) }
                }
            }
            var text = output.toString(Charsets.UTF_8).replace("\r\n", "\n")
            var status = -1
            val at = text.lastIndexOf(marker)
            if (at >= 0) {
                status = text.substring(at + marker.length).trim().toIntOrNull() ?: -1
                text = text.substring(0, at)
            }
            ShellResult(text, status)
        } finally { busy.set(false) }
    }

    /** Sends a file with the sync service ("adb push"). Each WRTE waits for the TV's OKAY before the next one. */
    override suspend fun push(data: ByteArray, path: String, mode: Int, progress: ((Double) -> Unit)?) = io {
        begin()
        try {
            val (local, remote) = openStream("sync:")
            fun write(payload: ByteArray) {
                send(Adb.Message(Adb.WRTE, local, remote, payload))
                while (true) {
                    val m = next(30_000)
                    if (m.arg1 != local) continue
                    if (m.command == Adb.OKAY) return
                    if (m.command == Adb.CLSE) throw SetupFailure(SetupIssue.ADB_FILE_REFUSED, "closed")
                    if (m.command == Adb.WRTE) {   // an early FAIL
                        send(Adb.Message(Adb.OKAY, local, remote))
                        throw SetupFailure(SetupIssue.ADB_FILE_REFUSED, syncFailure(m.payload))
                    }
                }
            }
            fun packet(id: String, value: Int, body: ByteArray = ByteArray(0)) = id.toByteArray() + Adb.le(value) + body
            val header = "$path,${mode or 32768}".toByteArray()   // 32768 = 0o100000, a regular file
            write(packet("SEND", header.size, header))
            val chunk = minOf(64 * 1024, remoteMaxData - 8)
            var offset = 0
            while (offset < data.size) {
                val piece = data.copyOfRange(offset, minOf(data.size, offset + chunk))
                write(packet("DATA", piece.size, piece))
                offset += piece.size
                progress?.invoke(offset.toDouble() / maxOf(1, data.size))
            }
            write(packet("DONE", (System.currentTimeMillis() / 1000).toInt()))
            val reply = java.io.ByteArrayOutputStream()
            while (reply.size() < 8) {
                val m = next(30_000)
                if (m.arg1 != local) continue
                if (m.command == Adb.WRTE) { reply.write(m.payload); send(Adb.Message(Adb.OKAY, local, remote)) }
                if (m.command == Adb.CLSE) break
            }
            send(Adb.Message(Adb.CLSE, local, remote))
            val bytes = reply.toByteArray()
            if (bytes.size < 8 || String(bytes, 0, 4, Charsets.ISO_8859_1) != "OKAY") {
                throw SetupFailure(SetupIssue.ADB_FILE_REFUSED, syncFailure(bytes))
            }
        } finally { busy.set(false) }
    }

    companion object {
        fun syncFailure(reply: ByteArray): String {
            if (reply.size < 8 || String(reply, 0, 4, Charsets.ISO_8859_1) != "FAIL") return "unexpected reply"
            return String(reply, 8, reply.size - 8, Charsets.UTF_8)
        }
    }
}
