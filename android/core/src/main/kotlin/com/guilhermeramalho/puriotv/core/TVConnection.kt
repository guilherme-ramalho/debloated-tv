package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager

/**
 * One framed, certificate-bound TLS connection to the TV's remote service (TVConnection.swift). The TV's
 * certificate is accepted only if its SHA-256 matches the pin saved at pairing; while pairing, any certificate is
 * accepted and remembered so the session can pin it. Writes go through one writer in order; frames are read on
 * an IO thread and handed to [onFrame] in arrival order.
 */
class TVConnection(
    private val host: String,
    private val port: Int,
    private val identity: ClientIdentity,
    private val pin: ByteArray?,
    private val allowUnpaired: Boolean = false,
    maxFrameSize: Int = 65536,
) {
    @Volatile var peerCertificate: X509Certificate? = null
        private set
    @Volatile private var validationFailure: Problem? = null
    private val decoder = FrameDecoder(maxFrameSize)
    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val outgoing = Channel<Pair<ByteArray, CompletableDeferred<Unit>?>>(Channel.UNLIMITED)
    private val closed = AtomicBoolean(false)
    @Volatile private var socket: SSLSocket? = null
    private var onFailed: ((RemoteFailure) -> Unit)? = null

    /** Connects and completes the TLS handshake, or throws [RemoteFailure]. */
    suspend fun open() = withContext(Dispatchers.IO) {
        val plain = Socket()
        try {
            plain.tcpNoDelay = true
            plain.keepAlive = true
            plain.connect(InetSocketAddress(host, port), if (allowUnpaired) 30_000 else 8_000)
            val context = SSLContext.getInstance("TLS")
            context.init(arrayOf(KeyManager()), arrayOf(PinningTrust()), null)
            val tls = context.socketFactory.createSocket(plain, host, port, true) as SSLSocket
            tls.enabledProtocols = tls.supportedProtocols.filter { it == "TLSv1.2" || it == "TLSv1.3" }.toTypedArray()
            tls.soTimeout = if (allowUnpaired) 35_000 else 10_000
            tls.startHandshake()
            tls.soTimeout = 0
            if (closed.get()) { tls.close(); throw RemoteFailure(Problem.CLOSED) }
            socket = tls
        } catch (e: RemoteFailure) {
            plain.close(); throw e
        } catch (e: SocketTimeoutException) {
            plain.close(); throw RemoteFailure(validationFailure ?: Problem.TIMED_OUT, describe(e))
        } catch (e: IOException) {
            plain.close(); throw RemoteFailure(validationFailure ?: classify(e), describe(e))
        }
    }

    /** Starts the reader and writer. [onFrame] and [onFailed] are called from IO threads; [onFailed] at most once. */
    fun start(onFrame: (ByteArray) -> Unit, onFailed: (RemoteFailure) -> Unit) {
        val tls = socket ?: return onFailed(RemoteFailure(Problem.NOT_READY))
        this.onFailed = onFailed
        io.launch {
            val input = tls.inputStream
            val buffer = ByteArray(8192)
            try {
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) { fail(RemoteFailure(Problem.CLOSED)); return@launch }
                    val frames = try { decoder.append(buffer.copyOf(count)) } catch (e: RemoteFailure) { fail(e); return@launch }
                    frames.forEach(onFrame)
                }
            } catch (e: IOException) {
                fail(RemoteFailure(classify(e), e.message))
            }
        }
        io.launch {
            val output = tls.outputStream
            for ((payload, done) in outgoing) {
                try {
                    output.write(Wire.frame(payload)); output.flush(); done?.complete(Unit)
                } catch (e: IOException) {
                    done?.completeExceptionally(RemoteFailure(Problem.INTERRUPTED, e.message))
                    fail(RemoteFailure(Problem.INTERRUPTED, e.message)); return@launch
                }
            }
        }
    }

    /** Queues a message; a failed write ends the connection. */
    fun send(payload: ByteArray) { if (!closed.get()) outgoing.trySend(payload to null) }

    /** Sends a message and waits until it has been written. */
    suspend fun write(payload: ByteArray) {
        if (closed.get() || socket == null) throw RemoteFailure(Problem.NOT_READY)
        val done = CompletableDeferred<Unit>()
        outgoing.trySend(payload to done)
        done.await()
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        onFailed = null
        outgoing.close()
        runCatching { socket?.close() }
        io.cancel()
    }

    private fun fail(failure: RemoteFailure) {
        if (closed.get()) return
        val callback = onFailed
        close()
        callback?.invoke(failure)
    }

    private fun classify(e: IOException): Problem = when {
        e is SSLException && tvRejectedPairing(e) -> Problem.PAIRING_REJECTED_BY_TV
        else -> Problem.CONNECT_FAILED
    }

    private inner class PinningTrust : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
            throw CertificateException("Client certificates are not accepted")
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            val certificate = chain?.firstOrNull() ?: run {
                validationFailure = Problem.IDENTITY_UNAVAILABLE
                throw CertificateException("No TV certificate")
            }
            val fingerprint = sha256(certificate.encoded)
            val accepted = pin?.contentEquals(fingerprint) ?: allowUnpaired
            if (!accepted) {
                validationFailure = Problem.IDENTITY_CHANGED
                throw CertificateException("Paired TV certificate mismatch")
            }
            peerCertificate = certificate
        }
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    private inner class KeyManager : X509ExtendedKeyManager() {
        private val alias = "client"
        override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(alias)
        override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = alias
        override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null
        override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? = null
        override fun getCertificateChain(alias: String?) = arrayOf(identity.certificate)
        override fun getPrivateKey(alias: String?): PrivateKey = identity.privateKey
    }

    companion object {
        /** The exception and its causes in one line, for the log. */
        fun describe(e: Throwable): String = generateSequence(e) { it.cause }.take(4).joinToString(" <- ") { it.toString() }

        /** The TV turned this phone's certificate away in the handshake: it no longer holds this pairing. */
        fun tvRejectedPairing(e: SSLException): Boolean {
            val text = generateSequence<Throwable>(e) { it.cause }.mapNotNull { it.message?.lowercase() }.joinToString(" ")
            return listOf("bad_certificate", "certificate_unknown", "unknown_ca", "access_denied",
                "certificate_revoked", "unsupported_certificate", "certificate_required").any { it in text }
        }
    }
}
