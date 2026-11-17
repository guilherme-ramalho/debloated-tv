package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket

/** Telling the TV type on Connect (TVKindTests.swift). CON-17..20. */
class TvKindTest {
    @Test fun portsTellTheKindAndTheRemoteServicesWinOverCast() {
        assertEquals(TvKind.ANDROID_TV, TvPorts.kind(setOf(6466, 6467, 8009)))
        assertEquals(TvKind.ROKU, TvPorts.kind(setOf(8060, 8009)))
        assertEquals(TvKind.LG, TvPorts.kind(setOf(3001)))
        assertEquals(TvKind.LG, TvPorts.kind(setOf(3000, 8009)))
        assertEquals(TvKind.SAMSUNG, TvPorts.kind(setOf(8002)))
        assertEquals(TvKind.CHROMECAST, TvPorts.kind(setOf(8009)))
        assertNull(TvPorts.kind(emptySet()))
        assertNull(TvPorts.kind(setOf(7000)))
        assertFalse("ADB is never knocked", 5555 in TvPorts.ALL)
    }

    @Test fun whatPurioCanDoOnEachKind() {
        assertEquals(TvSupport.Full(true), TvPorts.support(TvKind.ANDROID_TV, setOf(6466, 8009)))
        assertEquals(TvSupport.Full(false), TvPorts.support(TvKind.ANDROID_TV, setOf(6466)))
        for (kind in listOf(TvKind.ROKU, TvKind.LG, TvKind.SAMSUNG)) assertEquals(TvSupport.Remote, TvPorts.support(kind, emptySet()))
        assertEquals(TvSupport.NotYet, TvPorts.support(TvKind.CHROMECAST, setOf(8009)))
        assertTrue(TvSupport.Full(false).canPair)
        assertTrue(TvSupport.Remote.canPair)
        assertFalse(TvSupport.NotYet.canPair)
    }

    @Test fun onlyVideoCastDevicesAndOtherMakersAirPlayAreChecked() {
        val cast = TvSighting.Service.CAST; val air = TvSighting.Service.AIRPLAY
        assertTrue(TvSighting(TvSighting.Service.ANDROID_TV, "TV").worthChecking)
        assertTrue(TvSighting(cast, "Chromecast-1", rawTxt = mapOf("ca" to "4101", "fn" to "Bedroom")).worthChecking)
        assertFalse("speaker", TvSighting(cast, "Google-Home-1", rawTxt = mapOf("ca" to "2052")).worthChecking)
        assertFalse("group", TvSighting(cast, "Group", rawTxt = mapOf("ca" to "4133")).worthChecking)
        assertFalse(TvSighting(cast, "x").worthChecking)
        assertTrue(TvSighting(air, "[LG] webOS TV", rawTxt = mapOf("Manufacturer" to "LG Electronics")).worthChecking)
        assertFalse(TvSighting(air, "Living Room", rawTxt = mapOf("model" to "AppleTV14,1")).worthChecking)
        assertFalse(TvSighting(air, "MacBook", rawTxt = mapOf("manufacturer" to "Apple Inc.")).worthChecking)
        assertEquals("Bedroom", TvSighting(cast, "Chromecast-1", rawTxt = mapOf("fn" to "Bedroom")).displayName)
    }

    @Test fun oneRowPerTvAndOthersOnlyOnceChecked() {
        val tcl = TvSighting(TvSighting.Service.ANDROID_TV, "Living Room TV", "192.168.0.13")
        val tclCast = TvSighting(TvSighting.Service.CAST, "TCL-abc", "192.168.0.13", mapOf("ca" to "4101", "fn" to "Living Room TV"))
        val lgAir = TvSighting(TvSighting.Service.AIRPLAY, "[LG] webOS TV OLED55", "192.168.0.20", mapOf("manufacturer" to "LG Electronics"))
        val lgCast = TvSighting(TvSighting.Service.CAST, "LG-123", "192.168.0.20", mapOf("ca" to "4101", "fn" to "LG cast"))
        val speaker = TvSighting(TvSighting.Service.AIRPLAY, "Kitchen", "192.168.0.30", mapOf("manufacturer" to "Sonos"))
        val resolving = TvSighting(TvSighting.Service.ANDROID_TV, "Bedroom TV")
        val all = listOf(tcl, tclCast, lgAir, lgCast, speaker, resolving)

        val before = TvSightings.merge(all, emptyMap())
        assertEquals("Android TVs show at once; others wait for the knock", listOf("Bedroom TV", "Living Room TV"), before.map { it.name })
        assertNull(before[1].support)

        val after = TvSightings.merge(all, mapOf("192.168.0.13" to setOf(6466, 8009), "192.168.0.20" to setOf(3001, 8009), "192.168.0.30" to emptySet()))
        assertEquals(listOf("[LG] webOS TV OLED55", "Bedroom TV", "Living Room TV"), after.map { it.name })
        assertEquals(TvKind.LG, after[0].kind); assertEquals(TvSupport.Remote, after[0].support); assertEquals("192.168.0.20", after[0].host)
        assertEquals(TvSupport.Full(true), after[2].support)
        assertNull(after[1].host)
    }

    @Test fun knockFindsOpenAndClosedPorts() = runBlocking {
        ServerSocket(0).use { server ->
            val closed = ServerSocket(0).let { val p = it.localPort; it.close(); p }
            assertEquals(setOf(server.localPort), PortKnock.openPorts("127.0.0.1", listOf(server.localPort, closed), 1000))
        }
    }

    /** CST-27: only a refusal means "no Chromecast built in". */
    @Test fun castAnswerTellsRefusedFromSilent() = runBlocking {
        val closed = ServerSocket(0).let { val p = it.localPort; it.close(); p }
        assertEquals(PortKnock.Answer.REFUSED, PortKnock.answer("127.0.0.1", closed, 1000))
        assertEquals(PortKnock.Answer.SILENT, PortKnock.answer("192.0.2.10", 8009, 1000))
        ServerSocket(0).use { assertEquals(PortKnock.Answer.OPEN, PortKnock.answer("127.0.0.1", it.localPort, 1000)) }
    }
}
