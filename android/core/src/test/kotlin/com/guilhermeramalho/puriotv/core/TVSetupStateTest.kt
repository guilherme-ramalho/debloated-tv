package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

/** Ports of ios/Tests/TVSetupStateTests.swift (TESTING.md: SET-*). */
@OptIn(ExperimentalCoroutinesApi::class)
class TVSetupStateTest {
    private class MemoryStore(var json: String? = null) : SetupStatusStore {
        override fun load() = json
        override fun save(json: String) { this.json = json }
    }

    private fun TestScope.status(store: SetupStatusStore = MemoryStore()) = TVSetupStatus(store, this, offerDelayMs = 0)

    @Test fun unknownTVStartsUncheckedAndNotInstalled() = runTest {
        val info = status().info("192.168.0.13")
        assertFalse(info.homeInstalled)
        assertNull("the badge must say 'Check if my TV is supported' until a setup read the model", info.supported)
    }

    @Test fun statePersistsPerTVAndUndoResetsIt() = runTest {
        val store = MemoryStore()
        val s = status(store)
        s.sawHome("192.168.0.13")
        s.update("192.168.0.13") { it.copy(disabledCount = 35) }
        val reopened = status(store)
        assertTrue(reopened.info("192.168.0.13").homeInstalled)
        assertEquals(35, reopened.info("192.168.0.13").disabledCount)
        assertFalse("another TV is unaffected", reopened.info("192.168.0.14").homeInstalled)
        reopened.restored("192.168.0.13")
        assertFalse(reopened.info("192.168.0.13").homeInstalled)
        assertNull(reopened.info("192.168.0.13").disabledCount)
    }

    @Test fun backupSurvivesAReinstallAndCatchesUp() = runTest {
        val backup = MemoryStore()
        val first = TVSetupStatus(MemoryStore(), this, 0, backup)
        first.sawHome("tv")
        val reinstalled = TVSetupStatus(MemoryStore(), this, 0, backup)
        assertTrue("a reinstall still knows the TV has the new Home", reinstalled.info("tv").homeInstalled)
        val older = MemoryStore(backup.json)
        val fresh = MemoryStore()
        TVSetupStatus(older, this, 0, fresh)
        assertEquals("state from before the backup existed is copied over", older.json, fresh.json)
    }

    @Test fun emptyHostIsIgnored() = runTest {
        val s = status()
        s.sawHome("")
        assertFalse(s.info("").homeInstalled)
    }

    @Test fun inspectionNamesTheTVWithoutRepeatingTheBrand() = runTest {
        val s = status()
        s.inspected("a", mapOf("ro.product.manufacturer" to "TCL", "ro.product.model" to "Smart TV Pro",
            "ro.product.device" to "BeyondTV4", "ro.build.version.release" to "11"), null)
        assertEquals("TCL Smart TV Pro", s.info("a").model)
        assertEquals("BeyondTV4 · Android 11", s.info("a").detail)
        assertEquals(false, s.info("a").supported)
        s.inspected("b", mapOf("ro.product.manufacturer" to "Sony", "ro.product.model" to "Sony BRAVIA 4K"), null)
        assertEquals("Sony BRAVIA 4K", s.info("b").model)
        s.inspected("c", emptyMap(), null)
        assertEquals("empty: the app shows Unknown model", "", s.info("c").model)
        assertEquals("", s.info("c").detail)
        s.inspected("d", mapOf("ro.product.model" to "MiTV"), null, listsFound = true)
        assertEquals(true, s.info("d").supported)
    }

    @Test fun offerAppearsOnceWhenTheTVShowsAStockHome() = runTest {
        val s = status()
        s.offerAfterPairing("tv", "com.google.android.apps.tv.launcherx")
        advanceUntilIdle()
        assertEquals("tv", s.offerFor.value)
        s.offerFor.value = null
        s.offerAfterPairing("tv", "com.google.android.apps.tv.launcherx")
        s.sawForeground("tv", "com.google.android.tvlauncher")
        advanceUntilIdle()
        assertNull("only once per TV", s.offerFor.value)
    }

    @Test fun offerWaitsWhileAnAppIsOnScreen() = runTest {
        val s = status()
        s.offerAfterPairing("tv", "com.netflix.ninja")
        advanceUntilIdle()
        assertNull("nothing is known while Netflix plays", s.offerFor.value)
        s.sawForeground("tv", "com.google.android.youtube.tv")
        advanceUntilIdle()
        assertNull(s.offerFor.value)
        s.sawForeground("tv", "com.google.android.tvlauncher")   // the user pressed Home
        advanceUntilIdle()
        assertEquals("tv", s.offerFor.value)
    }

    @Test fun noOfferWhenTheTVShowsTheNewHome() = runTest {
        val s = status()
        s.offerAfterPairing("tv", "com.netflix.ninja")
        s.sawForeground("tv", TVSetupStatus.HOME_PACKAGE)
        s.sawForeground("tv", "com.google.android.tvlauncher")   // e.g. after an undo, later
        advanceUntilIdle()
        assertNull("the one-time offer was settled by the new Home", s.offerFor.value)
        assertFalse("the stock Home back in front means the TV was put back (SET-08d)", s.info("tv").homeInstalled)
        val already = status()
        already.sawHome("tv2")
        already.offerAfterPairing("tv2", "com.google.android.tvlauncher")
        advanceUntilIdle()
        assertNull(already.offerFor.value)
    }

    @Test fun aStockLauncherInFrontMeansTheTVWasPutBack() = runTest {
        val s = status()
        s.sawForeground("tv", TVSetupStatus.HOME_PACKAGE)
        s.update("tv") { it.copy(disabledCount = 35) }
        assertTrue(s.info("tv").homeInstalled)
        s.sawForeground("tv", "com.netflix.ninja")
        assertTrue("an app in front says nothing about Home", s.info("tv").homeInstalled)
        s.sawForeground("tv", "com.google.android.apps.tv.launcherx")
        assertFalse("the stock Home is back: restored outside the app", s.info("tv").homeInstalled)
        assertNull(s.info("tv").disabledCount)
    }

    @Test fun launcherNames() {
        assertTrue(TVSetupStatus.isLauncher("com.google.android.apps.tv.launcherx"))
        assertTrue(TVSetupStatus.isLauncher("com.mitv.tvhome"))
        assertTrue(TVSetupStatus.isLauncher("com.sony.dtv.home"))
        assertFalse(TVSetupStatus.isLauncher("com.netflix.ninja"))
        assertFalse(TVSetupStatus.isLauncher("com.tcl.tv"))
    }

    @Test fun tvAddressParsing() {
        assertEquals(5555, TVAddress.parse("192.168.0.13")?.port)
        assertEquals("192.168.0.13", TVAddress.parse(" 192.168.0.13 ")?.host)
        assertEquals(15555, TVAddress.parse("192.168.0.11:15555")?.port)
        assertEquals("Mac.local", TVAddress.parse("Mac.local:15555")?.host)
        for (bad in listOf("", ":5555", "a:b:c", "tv:0", "tv:70000", "tv:", "my tv", "tv:abc")) assertNull(bad, TVAddress.parse(bad))
    }

    @Test fun typedAddressesAcceptRegionalKeyboards() {
        assertEquals("comma keyboards (Spain, Brazil…)", "192.168.0.13", TVAddress.typed("192,168,0,13"))
        assertEquals("192.168.0.13", TVAddress.typed(" 192.168.0.13 "))
        assertTrue(TVAddress.isIPv4("192.168.0.13"))
        for (bad in listOf("192.168.0", "192.168.0.256", "a.b.c.d", "192.168..13", "1.2.3.4.5", "١٢.١.١.١", "")) assertFalse(bad, TVAddress.isIPv4(bad))
    }

    @Test fun modelRequestCarriesOnlyModelDetailsAndNeedsHTTPS() {
        val info = TVSetupInfo(supported = false, model = "Acme TV", detail = "acme1 · Android 12")
        assertNull(ModelRequest.url(info, null))
        assertNull("never send over plain HTTP", ModelRequest.url(info, "http://forms.example/x"))
        val url = ModelRequest.url(info, "https://forms.example/x?usp=pp_url")
        assertNotNull(url)
        val items = URI(url).query.split("&").associate { it.substringBefore("=") to it.substringAfter("=") }
        assertEquals("Acme TV", items["model"])
        assertEquals("keeps the form's own parameters", "pp_url", items["usp"])
        assertTrue(ModelRequest.text(info).contains("Acme TV"))
        assertFalse("no address or other personal data", ModelRequest.text(info).contains("192.168"))
    }
}
