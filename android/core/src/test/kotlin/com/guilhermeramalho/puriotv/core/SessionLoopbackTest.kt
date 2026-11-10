package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.newSingleThreadContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.cert.X509Certificate
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread

/**
 * The whole pairing and remote handshake against a fake TV on localhost: TLS with client certificates, the
 * six-character code, the certificate pin, and a key press. No real TV involved.
 */
@OptIn(ExperimentalCoroutinesApi::class, kotlinx.coroutines.DelicateCoroutinesApi::class)
class SessionLoopbackTest {
    private val main = newSingleThreadContext("session")
    private val scope = CoroutineScope(main)
    @After fun tearDown() { scope.cancel(); main.close() }

    private fun identity(name: String): ClientIdentity {
        val keys = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        return ClientIdentity(keys.private, Certificates.selfSigned(keys, name))
    }

    private val tvIdentity = identity("Fake TV")
    private val phone = identity("Purio TV Android TEST")

    /** A TLS server that asks for the client's certificate and accepts any, like the TV. */
    private fun server(): SSLServerSocket {
        val store = KeyStore.getInstance("PKCS12").apply {
            load(null); setKeyEntry("tv", tvIdentity.privateKey, CharArray(0), arrayOf(tvIdentity.certificate))
        }
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, CharArray(0)) }
        val trustAll = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
            override fun getAcceptedIssuers() = emptyArray<X509Certificate>()
        }
        val context = SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, arrayOf(trustAll), null) }
        return (context.serverSocketFactory.createServerSocket(0) as SSLServerSocket).apply { needClientAuth = true }
    }

    private class Peer(val socket: SSLSocket) {
        private val decoder = FrameDecoder()
        private val queue = ArrayDeque<ByteArray>()
        fun next(): ByteArray {
            while (queue.isEmpty()) {
                val buf = ByteArray(8192); val n = socket.inputStream.read(buf)
                check(n > 0) { "phone closed" }
                queue.addAll(decoder.append(buf.copyOf(n)))
            }
            return queue.removeFirst()
        }
        fun send(payload: ByteArray) { socket.outputStream.write(Wire.frame(payload)); socket.outputStream.flush() }
        fun has(message: ByteArray, field: Int) = Wire.fields(message).any { it.number == field }
    }

    private val ok = Wire.int(1, 2) + Wire.int(2, 200)
    private val info = ClientInfo("Test phone", "com.guilhermeramalho.puriotv", "1.0")

    @Test fun pairsWithTheCodeAndPinsTheTV() = runBlocking {
        val code = CompletableDeferred<String>()
        val server = server()
        val tv = thread {
            Peer(server.accept() as SSLSocket).run {
                check(has(next(), 10)); send(ok + Wire.bytes(11, ByteArray(0)))
                check(has(next(), 20)); send(ok + Wire.bytes(20, ByteArray(0)))
                check(has(next(), 30))
                // The TV shows a code: its first byte checks the secret, the last two go into it.
                val clientKey = (socket.session.peerCertificates[0] as X509Certificate).publicKey
                val tail = "BEEF"
                val digest = sha256(ClientIdentity.components(clientKey) + ClientIdentity.components(tvIdentity.publicKey) +
                    byteArrayOf(0xBE.toByte(), 0xEF.toByte()))
                code.complete("%02X".format(digest[0].toInt() and 255) + tail)
                send(ok + Wire.bytes(31, ByteArray(0)))
                val secret = Wire.fields(Wire.fields(next()).first { it.number == 40 }.bytes!!)[0].bytes!!
                check(secret.contentEquals(digest))
                send(ok + Wire.bytes(41, ByteArray(0)))
                Thread.sleep(200)
                socket.close()
            }
        }
        val paired = CompletableDeferred<ByteArray>()
        withContext(main) {
            val session = TVSession("127.0.0.1", phone, "Purio TV Android TEST", info, scope, pairingPort = server.localPort)
            session.onEvent = { event ->
                when (event) {
                    TVSession.Event.PairingCodeNeeded -> { scope.launch { session.submit(code.await()) } }
                    is TVSession.Event.Paired -> paired.complete(event.pin)
                    is TVSession.Event.Error -> paired.completeExceptionally(RemoteFailure(event.problem))
                    else -> Unit
                }
            }
            session.pair()
        }
        val pin = withTimeout(10_000) { paired.await() }
        assertArrayEquals(sha256(tvIdentity.certificate.encoded), pin)
        tv.join(2000); server.close()
    }

    @Test fun connectsWithThePinAndSendsKeys() = runBlocking {
        val server = server()
        val pressed = CompletableDeferred<Long>()
        val tv = thread {
            Peer(server.accept() as SSLSocket).run {
                send(Wire.bytes(1, Wire.int(1, 615)))
                check(has(next(), 1))
                send(Wire.bytes(2, Wire.int(1, 615)))
                check(has(next(), 2))
                send(Wire.bytes(40, Wire.int(1, 1)))
                val key = Wire.fields(next()).first { it.number == 10 }.bytes!!
                pressed.complete(Wire.number(1, key))
                Thread.sleep(200)
                socket.close()
            }
        }
        val events = mutableListOf<TVSession.Event>()
        val connected = CompletableDeferred<Unit>()
        lateinit var session: TVSession
        withContext(main) {
            session = TVSession("127.0.0.1", phone, "x", info, scope, remotePort = server.localPort)
            session.onEvent = { events += it; if (it == TVSession.Event.Connected) connected.complete(Unit) }
            session.connect(sha256(tvIdentity.certificate.encoded))
        }
        withTimeout(10_000) { connected.await() }
        withContext(main) { session.key(TVKey.HOME) }
        assertEquals(3L, withTimeout(5_000) { pressed.await() })
        assertEquals(TVSession.Event.Power(true), events[1])
        withContext(main) { session.disconnect() }
        tv.join(2000); server.close()
    }

    @Test fun refusesATVWhoseCertificateChanged() = runBlocking {
        val server = server()
        thread { runCatching { server.accept().use { it.inputStream.read() } } }
        val error = CompletableDeferred<Problem>()
        withContext(main) {
            val session = TVSession("127.0.0.1", phone, "x", info, scope, remotePort = server.localPort)
            session.onEvent = { if (it is TVSession.Event.Error) error.complete(it.problem) }
            session.connect(ByteArray(32))
        }
        assertEquals(Problem.IDENTITY_CHANGED, withTimeout(10_000) { error.await() })
        server.close()
    }
}
