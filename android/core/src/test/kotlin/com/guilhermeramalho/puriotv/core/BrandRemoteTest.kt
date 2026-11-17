package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/** Roku, LG and Samsung remotes against stand-in TVs (BrandRemoteTests.swift). REM-21..24. */
class BrandRemoteTest {
    /** One thread plays the app's main thread: events and calls happen on it, in order. */
    private val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + main)
    private val events = CopyOnWriteArrayList<BrandEvent>()

    @After fun close() { scope.cancel(); main.close() }

    private fun <T> onMain(block: suspend CoroutineScope.() -> T): T = runBlocking { withContext(main, block) }
    private fun waitFor(timeoutMs: Long = 5000, what: String = "", check: () -> Boolean) {
        val end = System.currentTimeMillis() + timeoutMs
        while (!check()) { if (System.currentTimeMillis() > end) fail("timed out: $what $events"); Thread.sleep(20) }
    }
    private fun firstError(): BrandEvent.Error { waitFor(what = "an error") { events.any { it is BrandEvent.Error } }; return events.first { it is BrandEvent.Error } as BrandEvent.Error }

    @Test fun appsAreFoundByTheirNameOnTheTv() {
        val apps = listOf(BrandApp("12", "Netflix"), BrandApp("13", "Amazon Prime Video"), BrandApp("a", "YouTube TV"),
            BrandApp("b", "YouTube"), BrandApp("c", "Max"), BrandApp("d", "Disney Plus"))
        assertEquals("12", BrandApps.match("Netflix", apps)?.id)
        assertEquals("13", BrandApps.match("Prime Video", apps)?.id)
        assertEquals("b", BrandApps.match("YouTube", apps)?.id)
        assertEquals("c", BrandApps.match("HBO Max", apps)?.id)
        assertEquals("d", BrandApps.match("Disney+", apps)?.id)
        assertEquals(null, BrandApps.match("Spotify", apps))
    }

    @Test fun webSocketFramesAreMaskedAndSized() {
        val small = WebSocketClient.frame(1, "hi".toByteArray())
        assertEquals(0x81, small[0].toInt() and 0xff); assertEquals(0x80 or 2, small[1].toInt() and 0xff); assertEquals(2 + 4 + 2, small.size)
        val mid = WebSocketClient.frame(1, ByteArray(300))
        assertEquals(0x80 or 126, mid[1].toInt() and 0xff); assertEquals(300, ((mid[2].toInt() and 0xff) shl 8) or (mid[3].toInt() and 0xff))
    }

    @Test fun rokuConnectsWithoutAPromptAndSendsKeysAppsAndText() {
        FakeHttp { req ->
            when (req) {
                "GET /query/device-info" -> 200 to "<device-info><power-mode>PowerOn</power-mode></device-info>"
                "GET /query/active-app" -> 200 to "<active-app><app id=\"12\">Netflix</app></active-app>"
                "GET /query/apps" -> 200 to "<apps><app id=\"12\" type=\"appl\" version=\"5\">Netflix</app><app id=\"837\" type=\"appl\">YouTube</app><app id=\"2285\">Hulu &amp; Co</app></apps>"
                else -> 200 to ""
            }
        }.use { tv ->
            val roku = RokuRemote("127.0.0.1", scope, tv.base)
            onMain { roku.onEvent = { events += it }; roku.connect(null) }
            waitFor(what = "foreground") { BrandEvent.Foreground("Netflix") in events }
            assertEquals(listOf(BrandEvent.Approved(RokuRemote.CREDENTIAL), BrandEvent.Connected, BrandEvent.Power(true)), events.take(3))
            onMain {
                roku.key(TVKey.UP, 3); roku.key(TVKey.VOLUME_UP, 1); roku.key(TVKey.VOLUME_UP, 2)
                roku.writeKey(TVKey.POWER)
                assertEquals(listOf("Netflix", "YouTube", "Hulu & Co"), roku.apps().map { it.name })
                assertTrue(roku.launch("YouTube"))
                roku.writeText("hi "); roku.writeText("h")
            }
            assertEquals(listOf("POST /keypress/Up", "POST /keydown/VolumeUp", "POST /keyup/VolumeUp", "POST /keypress/PowerOff", "POST /launch/837",
                "POST /keypress/Lit_h", "POST /keypress/Lit_i", "POST /keypress/Lit_%20", "POST /keypress/Backspace", "POST /keypress/Backspace"),
                tv.requests.filter { it.startsWith("POST") })
            assertFalse(roku.supports(TVKey.CAPTIONS))
        }
    }

    @Test fun aRokuLimitingMobileAppsIsExplained() {
        FakeHttp { 403 to "" }.use { tv ->
            val roku = RokuRemote("127.0.0.1", scope, tv.base)
            onMain { roku.onEvent = { events += it }; roku.connect(RokuRemote.CREDENTIAL) }
            assertEquals(Problem.ROKU_LIMITED, firstError().problem)
        }
    }

    @Test fun lgAsksToAcceptThenKeepsTheKeyAndSendsButtons() {
        FakeWebSocket { emptyList() }.use { pointer ->
            FakeWebSocket { text ->
                val m = Json.parseToJsonElement(text).jsonObject
                val id = (m["id"] as? JsonPrimitive)?.content ?: ""
                val type = (m["type"] as? JsonPrimitive)?.content
                val uri = (m["uri"] as? JsonPrimitive)?.content
                when {
                    type == "register" -> {
                        val payload = m["payload"]!!.jsonObject
                        assertNotNull("LG's signed manifest", payload["manifest"]!!.jsonObject["signatures"])
                        if ((payload["client-key"] as? JsonPrimitive)?.content == "key-1") listOf("""{"type":"registered","id":"register_0","payload":{"client-key":"key-1"}}""")
                        else listOf("""{"type":"response","id":"register_0","payload":{"pairingType":"PROMPT","returnValue":true}}""",
                            """{"type":"registered","id":"register_0","payload":{"client-key":"key-1"}}""")
                    }
                    type == "subscribe" && uri == "ssap://com.webos.applicationManager/getForegroundAppInfo" ->
                        listOf("""{"type":"response","id":"fg","payload":{"appId":"netflix","returnValue":true}}""")
                    type == "subscribe" && uri == "ssap://audio/getVolume" ->
                        listOf("""{"type":"response","id":"vol","payload":{"volumeStatus":{"volume":12,"muteStatus":false,"maxVolume":100},"returnValue":true}}""")
                    uri == "ssap://com.webos.service.networkinput/getPointerInputSocket" ->
                        listOf("""{"type":"response","id":"$id","payload":{"socketPath":"${pointer.url}/resources/x/netinput.pointer.sock","returnValue":true}}""")
                    uri == "ssap://com.webos.applicationManager/listLaunchPoints" ->
                        listOf("""{"type":"response","id":"$id","payload":{"launchPoints":[{"id":"netflix","title":"Netflix"},{"id":"youtube.leanback.v4","title":"YouTube"}],"returnValue":true}}""")
                    type == "request" -> listOf("""{"type":"response","id":"$id","payload":{"returnValue":true}}""")
                    else -> emptyList()
                }
            }.use { tv ->
                val lg = LgRemote("127.0.0.1", scope, listOf(URI(tv.url)))
                onMain { lg.onEvent = { events += it }; lg.connect(null) }
                waitFor(what = "foreground") { BrandEvent.Foreground("Netflix") in events }
                assertEquals(listOf(BrandEvent.ApprovalNeeded, BrandEvent.Approved("key-1".toByteArray()), BrandEvent.Connected), events.take(3))
                assertTrue(BrandEvent.Volume(12, 100, false) in events)
                waitFor(what = "pointer socket") { pointer.clients > 0 }
                Thread.sleep(100)
                onMain {
                    lg.key(TVKey.UP, 3); lg.key(TVKey.SELECT, 3); lg.key(TVKey.VOLUME_UP, 3); lg.key(TVKey.MUTE, 3)
                    assertTrue(lg.launch("YouTube"))
                    lg.writeText("ab"); lg.writeText("a")
                }
                waitFor(what = "ENTER") { "type:button\nname:ENTER\n\n" in pointer.received }
                assertEquals(listOf("type:button\nname:UP\n\n", "type:button\nname:ENTER\n\n"), pointer.received.toList())
                val uris = tv.received.mapNotNull { runCatching { (Json.parseToJsonElement(it).jsonObject["uri"] as? JsonPrimitive)?.content }.getOrNull() }
                for (uri in listOf("ssap://audio/volumeUp", "ssap://audio/setMute", "ssap://system.launcher/launch", "ssap://com.webos.service.ime/insertText",
                        "ssap://com.webos.service.ime/deleteCharacters")) assertTrue(uri, uri in uris)
                onMain { lg.disconnect(); events.clear(); lg.connect("key-1".toByteArray()) }
                waitFor(what = "connected again") { BrandEvent.Connected in events }
                assertFalse(BrandEvent.ApprovalNeeded in events)
                onMain { lg.disconnect() }
            }
        }
    }

    @Test fun lgThatSaysNoIsExplained() {
        FakeWebSocket { listOf("""{"type":"error","id":"register_0","error":"403 User denied access"}""") }.use { tv ->
            val lg = LgRemote("127.0.0.1", scope, listOf(URI(tv.url)))
            onMain { lg.onEvent = { events += it }; lg.connect(null) }
            assertEquals(Problem.LG_REFUSED, firstError().problem)
        }
    }

    @Test fun samsungAsksToAllowThenSendsKeysAndOpensAppsOverRest() {
        FakeHttp { req ->
            when (req) {
                "GET /api/v2/" -> 200 to """{"device":{"PowerState":"on","name":"Samsung TV"}}"""
                "POST /api/v2/applications/111299001912" -> 200 to "true"
                else -> 404 to ""
            }
        }.use { rest ->
            FakeWebSocket(greeting = listOf("""{"event":"ms.channel.connect","data":{"token":"tok-9"}}""")) { text ->
                if (text.contains("ed.installedApp.get")) listOf("""{"event":"ed.installedApp.get","data":{"data":[{"appId":"111299001912","name":"YouTube"},{"appId":"3201907018807","name":"Netflix"}]}}""")
                else emptyList()
            }.use { tv ->
                val samsung = SamsungRemote("127.0.0.1", scope, "Purio test", tv.url, rest.base)
                assertTrue(samsung.socketUrl.contains("api/v2/channels/samsung.remote.control?name=UHVyaW8gdGVzdA%3D%3D"))
                onMain { samsung.onEvent = { events += it }; samsung.connect(null) }
                waitFor(what = "power") { BrandEvent.Power(true) in events }
                assertEquals(listOf(BrandEvent.ApprovalNeeded, BrandEvent.Approved("tok-9".toByteArray()), BrandEvent.Connected), events.take(3))
                onMain {
                    samsung.key(TVKey.UP, 3); samsung.key(TVKey.VOLUME_UP, 1); samsung.key(TVKey.VOLUME_UP, 2)
                    assertTrue(samsung.launch("YouTube"))
                    samsung.writeText("hello")
                }
                waitFor(what = "SendInputEnd") { tv.received.any { it.contains("SendInputEnd") } }
                val keys = tv.received.mapNotNull { runCatching { Json.parseToJsonElement(it).jsonObject["params"]?.jsonObject }.getOrNull() }
                    .filter { (it["TypeOfRemote"] as? JsonPrimitive)?.content == "SendRemoteKey" }
                    .map { "${(it["Cmd"] as JsonPrimitive).content} ${(it["DataOfCmd"] as JsonPrimitive).content}" }
                assertEquals(listOf("Click KEY_UP", "Press KEY_VOLUP", "Release KEY_VOLUP"), keys)
                assertTrue("text goes base64", tv.received.any { it.contains("aGVsbG8=") })
                assertTrue("POST /api/v2/applications/111299001912" in rest.requests)
                assertTrue(SamsungRemote("x", scope, "n").socketUrl.startsWith("wss://x:8002/"))
            }
        }
    }
}

/** An HTTP server answering each "METHOD /path" with a status and body; keeps the requests. */
class FakeHttp(private val answer: (String) -> Pair<Int, String>) : AutoCloseable {
    private val server = ServerSocket(0)
    val base = "http://127.0.0.1:${server.localPort}/"
    val requests = CopyOnWriteArrayList<String>()
    init {
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val client = runCatching { server.accept() }.getOrNull() ?: break
                thread(isDaemon = true) {
                    client.use { c ->
                        val head = HttpRequestHead.read(c.getInputStream()) ?: return@use
                        val request = "${head.method} ${head.path}"
                        requests += request
                        val (status, body) = answer(request)
                        val bytes = body.toByteArray()
                        c.getOutputStream().write("HTTP/1.1 $status X\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray() + bytes)
                    }
                }
            }
        }
    }
    override fun close() = server.close()
}

/** A WebSocket server: sends [greeting] to each client and answers each text message with zero or more texts. */
class FakeWebSocket(private val greeting: List<String> = emptyList(), private val answer: (String) -> List<String>) : AutoCloseable {
    private val server = ServerSocket(0)
    val url = "ws://127.0.0.1:${server.localPort}"
    val received = CopyOnWriteArrayList<String>()
    @Volatile var clients = 0
    private val sockets = CopyOnWriteArrayList<Socket>()
    init {
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val client = runCatching { server.accept() }.getOrNull() ?: break
                sockets += client
                thread(isDaemon = true) { runCatching { serve(client) } }
            }
        }
    }
    private fun serve(socket: Socket) {
        val input = BufferedInputStream(socket.getInputStream()); val output = socket.getOutputStream()
        val head = HttpRequestHead.read(input) ?: return
        val accept = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1").digest((head.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray()))
        output.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n".toByteArray())
        clients++
        greeting.forEach { send(output, it) }
        while (true) {
            val text = readFrame(input) ?: return
            received += text
            answer(text).forEach { send(output, it) }
        }
    }
    @Synchronized private fun send(output: OutputStream, text: String) {
        val bytes = text.toByteArray()
        val out = ByteArrayOutputStream()
        out.write(0x81)
        if (bytes.size < 126) out.write(bytes.size) else { out.write(126); out.write(bytes.size shr 8); out.write(bytes.size and 0xff) }
        out.write(bytes)
        output.write(out.toByteArray()); output.flush()
    }
    private fun readFrame(input: InputStream): String? {
        val b0 = input.read(); val b1 = input.read()
        if (b0 < 0 || b1 < 0 || b0 and 0x0f == 0x8) return null
        var length = b1 and 0x7f
        if (length == 126) length = (input.read() shl 8) or input.read()
        val mask = ByteArray(4).also { input.readNBytes(it, 0, 4) }
        val payload = ByteArray(length).also { input.readNBytes(it, 0, length) }
        for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
        return String(payload)
    }
    override fun close() { server.close(); sockets.forEach { runCatching { it.close() } } }
}
