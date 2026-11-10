package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import kotlin.concurrent.thread

/** Ports of ios/Tests/EditorCipherTests.swift (same vectors as the launcher's EditorTest) and a loopback session. */
class EditorTest {
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun seq(start: Int, count: Int) = ByteArray(count) { ((start + it) and 255).toByte() }

    @Test fun knownAnswerMatchesTheTV() {
        val key = seq(0, 32); val phone = seq(0xA0, 16); val tv = seq(0x10, 16)
        val up = EditorCipher(key, phone, tv, EditorCipher.PHONE_TO_TV)
        val down = EditorCipher(key, phone, tv, EditorCipher.TV_TO_PHONE)
        assertArrayEquals(hex("808e96a4f5f0966171716166ce7e116430013d94af4bed4d845529c15a0ea928"), up.key)
        assertArrayEquals(hex("95675c6bcf2e89294a67840934b28d17c7f8c0b2c0cec457a6afe1ebba83ce06"), down.key)
        up.seal("{}".toByteArray())
        assertArrayEquals(hex("0000000000000000000000017366b6b673f5a4667f0689292c9b5871f16ac83ed0a5f65738929a7877ab14"),
            up.seal("{\"type\":\"ping\"}".toByteArray()))
    }

    @Test fun keyIdMatchesTheTV() {
        assertArrayEquals(hex("c3c8a36d671339dd"), EditorLink.keyId(seq(0, 32)))
    }

    @Test fun linkIsBase64UrlWithoutPadding() {
        val url = EditorLink.url(ByteArray(32) { -1 })
        assertTrue(url.startsWith("tvhome://phone-edit?k="))
        val value = url.substringAfter("?k=")
        assertEquals(43, value.length)
        assertTrue('=' !in value && '+' !in value && '/' !in value)
    }

    @Test fun framesMustArriveInOrderAndUntouched() {
        val key = seq(1, 32); val phone = seq(2, 16); val tv = seq(3, 16)
        val seal = EditorCipher(key, phone, tv, EditorCipher.TV_TO_PHONE)
        val first = seal.seal("a".toByteArray()); val second = seal.seal("b".toByteArray())
        assertThrows(RemoteFailure::class.java) { EditorCipher(key, phone, tv, EditorCipher.TV_TO_PHONE).open(second) }
        val tampered = first.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        assertThrows(RemoteFailure::class.java) { EditorCipher(key, phone, tv, EditorCipher.TV_TO_PHONE).open(tampered) }
        val open = EditorCipher(key, phone, tv, EditorCipher.TV_TO_PHONE)
        assertArrayEquals("a".toByteArray(), open.open(first))
        assertArrayEquals("b".toByteArray(), open.open(second))
        assertThrows(RemoteFailure::class.java) { open.open(second) }
    }

    @Test fun snapshotDecodesTheIPhoneSchema() {
        val text = """{"revision":"r1","layout":{"dockCount":3,"order":["com.netflix.ninja"],"hidden":[],"wallpaper":"dusk"},
            "apps":[{"id":"com.netflix.ninja","name":"Netflix","launchURL":"https://www.netflix.com/title","system":false}],
            "inputs":[{"id":"hdmi1","name":"HDMI 1","launchURL":"content://android.media.tv/passthrough/x"}],
            "wallpaperJPEG":"/9j/","home":{"features":["weather","looks"],"look":"cinema","version":13,"extra":1}}"""
        val snapshot = LauncherClient().json.decodeFromString(LauncherSnapshot.serializer(), text)
        snapshot.validate()
        assertEquals(3, snapshot.layout.dockCount)
        assertArrayEquals(byteArrayOf(-1, -40, -1), snapshot.wallpaperJPEG)
        assertTrue(snapshot.home!!.supports("looks"))
        assertEquals(13, snapshot.home!!.version)
    }

    @Test fun layoutValidation() {
        HomeLayout().validate()
        HomeLayout(wallpaper = "photo-123e4567-e89b-12d3-a456-426614174000").validate()
        assertThrows(RemoteFailure::class.java) { HomeLayout(dockCount = 8).validate() }
        assertThrows(RemoteFailure::class.java) { HomeLayout(order = listOf("a.b", "a.b")).validate() }
        assertThrows(RemoteFailure::class.java) { HomeLayout(order = listOf("nodot")).validate() }
        assertThrows(RemoteFailure::class.java) { HomeLayout(wallpaper = "photo-nope").validate() }
    }

    /** A fake TV Home that speaks the hello and answers one snapshot request, as EditorServer does. */
    @Test fun sessionAgainstAFakeTVHome() = runBlocking {
        val key = EditorLink.newKey()
        val server = ServerSocket(0)
        val tv = thread {
            server.accept().use { socket ->
                val input = socket.getInputStream(); val output = socket.getOutputStream()
                val decoder = FrameDecoder(4_194_304)
                fun next(): ByteArray {
                    while (true) {
                        val buf = ByteArray(4096); val n = input.read(buf)
                        check(n > 0)
                        decoder.append(buf.copyOf(n)).firstOrNull()?.let { return it }
                    }
                }
                val hello = next()
                check(hello.copyOfRange(0, 4).contentEquals("TVH2".toByteArray()))
                val phoneNonce = hello.copyOfRange(4, 20)
                check(hello.copyOfRange(20, 28).contentEquals(EditorLink.keyId(key)))
                val tvNonce = EditorLink.random(16)
                output.write(Wire.frame("TVH2".toByteArray() + tvNonce))
                val down = EditorCipher(key, phoneNonce, tvNonce, EditorCipher.TV_TO_PHONE)
                val up = EditorCipher(key, phoneNonce, tvNonce, EditorCipher.PHONE_TO_TV)
                val request = Json.parseToJsonElement(up.open(next()).decodeToString()).jsonObject
                check(request["operation"]!!.jsonPrimitive.content == "snapshot")
                val id = request["id"]!!.jsonPrimitive.content
                val reply = """{"type":"response","id":"$id","ok":true,"result":{"revision":"7",
                    "layout":{"dockCount":2,"order":["com.netflix.ninja"],"hidden":[],"wallpaper":"aurora"},"apps":[],"inputs":[]}}"""
                output.write(Wire.frame(down.seal(reply.toByteArray())))
                output.flush()
                Thread.sleep(200)
            }
        }
        val client = LauncherClient(server.localPort)
        client.open("127.0.0.1", key)
        val snapshot = client.snapshot()
        assertEquals("7", snapshot.revision)
        assertEquals("aurora", snapshot.layout.wallpaper)
        client.close()
        tv.join(2000)
        server.close()
    }
}
