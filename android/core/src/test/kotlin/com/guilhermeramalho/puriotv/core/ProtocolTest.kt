package com.guilhermeramalho.puriotv.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator

/** Ports of ios/Tests/ProtocolTests.swift. */
class ProtocolTest {
    @Test fun foregroundNamesDoNotInventUnknownApps() {
        assertEquals("YouTube", TVSession.appName("com.google.android.youtube.tv"))
        assertEquals("Netflix", TVSession.appName("com.netflix.ninja"))
        assertNull(TVSession.appName("com.tcl.tv"))
        assertNull(TVSession.appName("com.gathin.tvhome"))
        assertNull(TVSession.appName(""))
    }

    @Test fun foregroundAppPayloadAndExplicitClear() {
        assertEquals("com.netflix.ninja", TVSession.foregroundPackage(Wire.bytes(1, Wire.string(12, "com.netflix.ninja"))))
        assertEquals("", TVSession.foregroundPackage(Wire.bytes(1, Wire.string(12, ""))))
        assertNull(TVSession.foregroundPackage(Wire.bytes(1, Wire.int(1, 3))))
        assertNull(TVSession.foregroundPackage(Wire.bytes(1, Wire.bytes(12, byteArrayOf(-1)))))
    }

    @Test fun wakeIntentExpiresAndCannotReplay() {
        val request = WakeRequest()
        val start = 1_000_000L
        assertNull(request.consume(false, start))
        request.begin(start)
        assertEquals(TVKey.POWER, request.consume(false, start + 29_000))
        assertNull(request.consume(false, start + 29_000))
        request.begin(start)
        assertNull(request.consume(false, start + 30_000))
        request.begin(start); request.cancel()
        assertNull(request.consume(false, start))
        request.begin(start)
        assertNull(request.consume(true, start))
        assertNull(request.consume(false, start))
        assertEquals(26L, TVKey.POWER.code)
    }

    @Test fun varintsIncludingMaximum() {
        for (value in listOf(0L, 127L, 128L, 16384L, -1L /* UInt64.max */)) {
            assertEquals(value, Wire.readVarint(Wire.varint(value), 0).first)
        }
        assertThrows(RemoteFailure::class.java) { Wire.readVarint(ByteArray(10) { -1 }, 0) }
    }

    @Test fun splitPrefixAndCoalescedFrames() {
        val payload = ByteArray(300) { 42 }
        val packet = Wire.frame(payload)
        val decoder = FrameDecoder()
        assertTrue(decoder.append(packet.copyOfRange(0, 1)).isEmpty())
        assertTrue(decoder.append(packet.copyOfRange(1, 16)).isEmpty())
        val out = decoder.append(packet.copyOfRange(16, packet.size) + packet)
        assertEquals(2, out.size)
        out.forEach { assertArrayEquals(payload, it) }
    }

    @Test fun everyFragmentBoundary() {
        val packet = TVSession.keyMessage(TVKey.UP, 3)
        val frame = Wire.frame(packet)
        for (offset in 0..frame.size) {
            val decoder = FrameDecoder()
            val all = decoder.append(frame.copyOfRange(0, offset)) + decoder.append(frame.copyOfRange(offset, frame.size))
            assertEquals(1, all.size)
            assertArrayEquals(packet, all[0])
        }
    }

    @Test fun frameSizeAndTruncationChecks() {
        assertThrows(RemoteFailure::class.java) { FrameDecoder().append(Wire.varint(65537)) }
        assertThrows(RemoteFailure::class.java) { Wire.fields(byteArrayOf(0x0a, 0x05, 0x01)) }
        assertThrows(RemoteFailure::class.java) { Wire.fields(byteArrayOf(0)) }
    }

    @Test fun nestedProtocolFields() {
        val data = Wire.bytes(10, Wire.int(1, 24) + Wire.int(2, 3)) + Wire.int(2, 200)
        val fields = Wire.fields(data)
        assertEquals(2, fields.size)
        assertEquals(24L, Wire.number(1, fields[0].bytes!!))
        assertEquals(200L, Wire.number(2, data))
    }

    @Test fun keyMessageBytesMatchTheIPhone() {
        // Wire.bytes(10, int(1, 19) + int(2, 3)) as the Swift code builds it.
        assertArrayEquals(byteArrayOf(0x52, 0x04, 0x08, 0x13, 0x10, 0x03), TVSession.keyMessage(TVKey.UP, 3))
    }

    private fun keys() = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()

    @Test fun generatedCertificateMatchesItsPrivateKey() {
        val pair = keys()
        val certificate = Certificates.selfSigned(pair)
        certificate.verify(pair.public)
        assertArrayEquals(ClientIdentity.components(pair.public), ClientIdentity.components(certificate.publicKey))
        assertEquals("CN=Personal TV Remote", certificate.subjectX500Principal.name)
    }

    @Test fun eachInstallsCertificateHasItsOwnSubject() {
        val name = RemoteClientName.create()
        val first = RemoteClientName.uniqueCommonName(name)
        val second = RemoteClientName.uniqueCommonName(name)
        assertNotEquals(first, second)
        assertTrue(first.startsWith(name))
        assertTrue(name.startsWith("Purio TV"))
        assertNotEquals(RemoteClientName.create(), name)
        assertEquals("CN=$first", Certificates.selfSigned(keys(), first).subjectX500Principal.name)
    }

    @Test fun pairingSecretBindsCodeToBothKeys() {
        val client = keys().public
        val server = keys().public
        val expected = sha256(ClientIdentity.components(client) + ClientIdentity.components(server) + byteArrayOf(0x12, 0x34))
        val first = expected[0].toInt() and 255
        assertArrayEquals(expected, ClientIdentity.secret("%02X1234".format(first), client, server))
        assertArrayEquals(expected, ClientIdentity.secret(" %02x1234 ".format(first), client, server))
        val wrong = "%02X1234".format(first xor 255)
        assertEquals(Problem.CODE_MISMATCH, assertThrows(RemoteFailure::class.java) { ClientIdentity.secret(wrong, client, server) }.problem)
        assertEquals(Problem.CODE_CHARACTERS, assertThrows(RemoteFailure::class.java) { ClientIdentity.secret("ZZ0000", client, server) }.problem)
        assertEquals(Problem.CODE_LENGTH, assertThrows(RemoteFailure::class.java) { ClientIdentity.secret("12345", client, server) }.problem)
    }

    @Test fun typingSendsOnlyTheChange() {
        assertEquals(0 to "ing", TVSession.typingEdit("test", "testing"))
        assertEquals(3 to "", TVSession.typingEdit("testing", "test"))
        assertEquals(2 to "x", TVSession.typingEdit("abc", "ax"))
        assertEquals(0 to "abc", TVSession.typingEdit("", "abc"))
    }

    @Test fun textMessageLimits() {
        assertThrows(RemoteFailure::class.java) { TVSession.textMessage("", 0, 0) }
        assertThrows(RemoteFailure::class.java) { TVSession.textMessage("a".repeat(4097), 0, 0) }
        val fields = Wire.fields(Wire.fields(TVSession.textMessage("hi", 7, 9))[0].bytes!!)
        assertEquals(7L, fields[0].integer); assertEquals(9L, fields[1].integer)
    }

    @Test fun swipeNeedsDistanceAndPicksTheLongerAxis() {
        assertNull(TVKey.swipeDirection(10.0, 27.0))
        assertEquals(TVKey.RIGHT, TVKey.swipeDirection(40.0, 10.0))
        assertEquals(TVKey.UP, TVKey.swipeDirection(5.0, -30.0))
        assertNull(TVKey.swipeDirection(Double.NaN, 100.0))
    }

    @Test fun swipeCancelsThePendingButton() {
        val pad = PadInteraction()
        pad.begin(TVKey.SELECT)
        assertTrue(pad.move(5.0, 5.0).isEmpty())
        assertTrue(pad.move(40.0, 0.0).isEmpty())
        assertTrue(pad.isSwiping)
        assertEquals(listOf(PadInteraction.Command.Tap(TVKey.RIGHT)), pad.end(40.0, 0.0))
        assertFalse(pad.isSwiping)
    }

    @Test fun holdPressesAndReleases() {
        val pad = PadInteraction()
        pad.begin(TVKey.UP)
        assertEquals(listOf(PadInteraction.Command.Press(TVKey.UP)), pad.hold())
        assertEquals(listOf(PadInteraction.Command.Release(TVKey.UP)), pad.move(0.0, 50.0))
        pad.begin(TVKey.DOWN); pad.hold()
        assertEquals(listOf(PadInteraction.Command.Release(TVKey.DOWN)), pad.end(0.0, 0.0))
        pad.begin(TVKey.SELECT)
        assertEquals(listOf(PadInteraction.Command.Tap(TVKey.SELECT)), pad.end(0.0, 0.0))
    }
}
