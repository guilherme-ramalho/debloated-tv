package com.guilhermeramalho.puriotv.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import kotlinx.serialization.json.addJsonObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/** Show on TV, the Cast side (CastTests.swift): frames, the session steps, following swipes, the server. CST-14. */
class CastTest {
    private val photo = CastController.Load("http://192.168.0.14:5000/abc/IMG_1.jpg", "image/jpeg", "IMG_1")

    private fun status(withPlayer: Boolean) = CastMessage.of("receiver-0", "*", CastNamespace.RECEIVER, buildJsonObject {
        put("type", "RECEIVER_STATUS")
        putJsonObject("status") { putJsonArray("applications") {
            if (withPlayer) addJsonObject { put("appId", "CC1AD845"); put("transportId", "t-1"); put("sessionId", "s-1") }
        } }
    })
    private fun media(type: String, extra: JsonObject.() -> JsonObject = { this }) =
        CastMessage.of("t-1", "sender-purio", CastNamespace.MEDIA, buildJsonObject { put("type", type) }.extra())

    @Test fun messageRoundTripsThroughFrames() {
        val message = CastMessage.of("sender-purio", "receiver-0", CastNamespace.RECEIVER, buildJsonObject { put("type", "LAUNCH") })
        val decoder = CastFrameDecoder()
        val framed = message.framed + message.framed
        assertTrue(decoder.append(framed.copyOfRange(0, 7)).isEmpty())
        val bodies = decoder.append(framed.copyOfRange(7, framed.size))
        assertEquals(2, bodies.size)
        assertEquals(message, CastMessage.decode(bodies[0]))
        assertEquals("LAUNCH", CastMessage.decode(bodies[0]).type)
        assertArrayEquals(byteArrayOf(0, 0, 0, message.body.size.toByte()), message.framed.copyOfRange(0, 4))
        assertThrows(RemoteFailure::class.java) { CastFrameDecoder(16).append(byteArrayOf(0, 0, 1, 0) + ByteArray(4)) }
    }

    @Test fun firstLoadLaunchesThePlayerThenLoadsOnceItIsUp() {
        val cast = CastController()
        val launch = cast.load(photo)
        assertEquals(listOf("CONNECT", "LAUNCH"), launch.map { it.type })
        assertTrue("a second load while launching replaces the pending one", cast.load(photo).isEmpty())
        assertTrue(cast.receive(status(false)).send.isEmpty())
        val step = cast.receive(status(true))
        assertEquals(listOf<CastController.Event>(CastController.Event.Ready), step.events)
        assertEquals(listOf("CONNECT", "LOAD"), step.send.map { it.type })
        assertEquals("t-1", step.send[0].destination)
        assertEquals(photo.url, ((step.send[1].json["media"] as JsonObject)["contentId"] as JsonPrimitive).content)
    }

    @Test fun heartbeatAndMediaCommands() {
        val cast = CastController()
        assertEquals(listOf("PONG"), cast.receive(CastMessage.of("receiver-0", "sender-purio", CastNamespace.HEARTBEAT, buildJsonObject { put("type", "PING") })).send.map { it.type })
        cast.load(photo); cast.receive(status(true))
        assertTrue("no media session yet", cast.pause().isEmpty())
        val events = cast.receive(media("MEDIA_STATUS") { buildJsonObject { put("type", "MEDIA_STATUS"); putJsonArray("status") { addJsonObject {
            put("mediaSessionId", 7); put("playerState", "PLAYING"); put("currentTime", 3.5); putJsonObject("media") { put("duration", 72.0) } } } } }).events
        assertEquals(listOf<CastController.Event>(CastController.Event.Media(CastMediaStatus("PLAYING", 3.5, 72.0, null))), events)
        assertEquals("7", (cast.pause().first().json["mediaSessionId"] as JsonPrimitive).content)
        assertEquals(listOf("GET_STATUS"), cast.status().map { it.type })
    }

    @Test fun playerClosedOnTheTVIsReportedAndTheNextLoadRelaunches() {
        val cast = CastController()
        cast.load(photo); cast.receive(status(true))
        assertEquals(listOf<CastController.Event>(CastController.Event.ReceiverGone), cast.receive(status(false)).events)
        assertEquals(listOf("CONNECT", "LAUNCH"), cast.load(photo).map { it.type })
    }

    @Test fun failureOfAReplacedLoadIsIgnored() {
        val cast = CastController()
        cast.load(photo); cast.receive(status(true))
        val first = cast.load(CastController.Load("http://x/long.m3u8", "application/x-mpegURL", "long", hls = true))
        val second = cast.load(photo)
        assertEquals("fmp4", ((first[0].json["media"] as JsonObject)["hlsSegmentFormat"] as JsonPrimitive).content)
        fun failed(id: JsonPrimitive) = media("LOAD_FAILED") { buildJsonObject { put("type", "LOAD_FAILED"); put("requestId", id) } }
        assertTrue(cast.receive(failed(first[0].json["requestId"] as JsonPrimitive)).events.isEmpty())
        assertEquals(listOf<CastController.Event>(CastController.Event.LoadFailed), cast.receive(failed(second[0].json["requestId"] as JsonPrimitive)).events)
    }

    @Test fun stopClosesThePlayer() {
        val cast = CastController()
        assertTrue(cast.stop().isEmpty())
        cast.load(photo); cast.receive(status(true))
        assertEquals(listOf("STOP", "CLOSE"), cast.stop().map { it.type })
        assertEquals(CastController.State.STOPPED, cast.state)
    }

    @Test fun fastSwipesSendOnlyThePhotoYouStopOn() {
        val follow = CastFollower(350)
        for (i in 0 until 20) follow.focused("photo-$i", i * 100L)
        assertNull(follow.due(2_100))
        assertEquals("photo-19", follow.due(2_250))
        assertNull("never twice", follow.due(3_000))
        follow.forget()
        assertEquals("photo-19", follow.due(3_000))
    }

    @Test fun byteRangesAndRequestHeads() {
        assertEquals(ByteRange(0, 999), ByteRange.resolve(null, 1000))
        assertEquals(ByteRange(100, 199), ByteRange.resolve("bytes=100-199", 1000))
        assertEquals(ByteRange(900, 999), ByteRange.resolve("bytes=-100", 1000))
        assertEquals(ByteRange(900, 999), ByteRange.resolve("bytes=900-5000", 1000))
        assertNull(ByteRange.resolve("bytes=1000-", 1000))
        assertNull(ByteRange.resolve("bytes=0-1,5-6", 1000))
        val head = HttpRequestHead.parse("GET /abc/IMG_1.jpg HTTP/1.1\r\nRange: bytes=0-\r\n\r\n")
        assertEquals("/abc/IMG_1.jpg", head.path); assertEquals("bytes=0-", head.headers["range"])
    }

    @Test fun serverServesOnlySharedFilesWithRanges() {
        val file = File.createTempFile("cast-test", ".bin").apply { writeBytes(ByteArray(200_000) { (it % 251).toByte() }); deleteOnExit() }
        val server = MediaServer()
        val port = server.start()
        try {
            val path = server.share(MediaServer.FileSource(file, "video/mp4"), "clip.mp4")
            val partial = URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection
            partial.setRequestProperty("Range", "bytes=100000-100009")
            assertEquals(206, partial.responseCode)
            assertEquals("bytes 100000-100009/200000", partial.getHeaderField("Content-Range"))
            assertArrayEquals(ByteArray(10) { ((100000 + it) % 251).toByte() }, partial.inputStream.readBytes())
            assertEquals(200_000, (URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection).inputStream.readBytes().size)
            assertEquals(404, (URL("http://127.0.0.1:$port/nothing/here.jpg").openConnection() as HttpURLConnection).responseCode)
            repeat(3) { server.share(MediaServer.FileSource(file, "video/mp4"), "clip.mp4") }
            assertEquals("older shares are dropped", 404, (URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection).responseCode)
        } finally { server.close() }
    }

    @Test fun localAddressPrefersTheTVsSubnet() {
        val interfaces = listOf(LocalAddress.Interface("lo", "127.0.0.1", 8), LocalAddress.Interface("rmnet0", "10.20.30.40", 32),
            LocalAddress.Interface("wlan0", "192.168.0.14", 24))
        assertEquals("192.168.0.14", LocalAddress.pick("192.168.0.13", interfaces))
        assertEquals("192.168.0.14", LocalAddress.pick("tv.local", interfaces))
        assertNull(LocalAddress.pick("192.168.0.13", interfaces.take(2)))
    }
}
