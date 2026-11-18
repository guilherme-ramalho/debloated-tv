package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.nio.file.Files

/** The safety rules that live in the iPhone's DebloatFlow / HomeUpdateFlow, ported into SetupSequence. */
@OptIn(ExperimentalCoroutinesApi::class)
class SetupSequenceTest {
    private val launcherx = "com.google.android.apps.tv.launcherx"

    @Test fun applyGoesGroupByGroupAndStopsWhenTheTVStopsAnswering() = runTest {
        val profile = DebloatProfile(DebloatProfile.load(profileSource, "tcl-43c645").manifest,
            DebloatList.parse("# 1. A\na.a\nb.b\n# 2. B\nc.c\n"), kotlinx.serialization.json.JsonObject(emptyMap()))
        val tv = FakeTV(setOf("a.a", "b.b", "c.c"))
        val groups = mutableListOf<Int>()
        val result = SetupSequence.applyGroups(tv, profile, DebloatPlan(listOf("a.a", "c.c")), onGroup = { _, _, size -> groups += size })
        assertEquals(listOf(1, 1), groups)
        assertEquals(listOf("a.a", "c.c"), result.disabled)
        assertTrue("the TV is asked to answer after each group", tv.sent.count { it == "echo ok" } == 2)

        val down = ScriptedTV().apply { failing += "pm disable-user --user 0 a.a"; exact["pm list packages -e --user 0"] = "package:a.a" }
        val e = failure { SetupSequence.applyGroups(down, profile, DebloatPlan(listOf("a.a", "c.c"))) }
        assertEquals(SetupIssue.STOPPED_DURING_GROUP, e.issue)
        assertFalse("nothing after the failing group is touched", down.sent.contains("pm disable-user --user 0 c.c"))
    }

    @Test fun wifiIsSavedAgainAndChecked() = runTest {
        val network = WifiNetwork(3, "Casa", "wpa2", DebloatRules.SETUPWRAITH)
        val moved = "Dump of WifiConfigManager\n  ID: 5 SSID: \"Casa\" PROVIDER-NAME: null\n KeyMgmt: WPA_PSK\n cuid=2000 cname=com.android.shell luid=2000\n"
        // The first connection drops with the old network; the phone reconnects and reads the new copy.
        val first = ScriptedTV().apply { failing += "dumpsys wifi" }
        val second = ScriptedTV().apply { prefixes += "dumpsys wifi" to moved }
        val client = SetupSequence.resaveWifi(first, listOf(network), mapOf("Casa" to "secret"), TVConnector { _, _ -> second })
        assertTrue(client === second)
        assertTrue(first.sent.first().startsWith("nohup sh -c 'cmd wifi forget-network 3 && "))
        assertEquals(1, first.closed)
        // Still the wizard's after the attempt: refused, nothing else changes.
        val stuck = ScriptedTV().apply { prefixes += "dumpsys wifi" to DebloatTest.wizardWifi.replace("Casa 'Ramalho'", "Casa") }
        assertEquals(SetupIssue.WIFI_NOT_SAVED, failure { SetupSequence.resaveWifi(stuck, listOf(network), emptyMap(), TVConnector { _, _ -> stuck }) }.issue)
        // Never back: the person is told to join it on the TV.
        val gone = ScriptedTV().apply { failing += "dumpsys wifi" }
        assertEquals(SetupIssue.WIFI_NOT_BACK, failure {
            SetupSequence.resaveWifi(gone, listOf(network), emptyMap(), TVConnector { _, _ -> throw SetupFailure(SetupIssue.ADB_REFUSED) })
        }.issue)
    }

    /** The 20 s wait before the restart (Android saves package and Home changes ~10 s later), then the check. */
    @Test fun restartWaitsBeforeRebootingAndChecksHome() = runTest {
        val before = ScriptedTV()
        val after = ScriptedTV().apply {
            exact["getprop sys.boot_completed"] = "1"
            prefixes += DebloatRules.HOME_QUERY to "com.gathin.tvhome/.MainActivity"
            exact["pm list packages -e --user 0"] = "package:com.tcl.usercenter\npackage:com.gathin.tvhome"
        }
        var rebootAt = -1L
        val watching = object : TVDevice by before {
            override suspend fun shell(command: String, timeoutMs: Long): AdbClient.ShellResult {
                if (command == "reboot") rebootAt = currentTime
                return before.shell(command, timeoutMs)
            }
        }
        val outcome = SetupSequence.restartAndCheck(watching, TVConnector { _, _ -> after }, listOf("com.tcl.bi", "com.tcl.usercenter"), LauncherInstaller.PACKAGE)
        assertTrue("at least 20 s pass before the reboot", rebootAt >= 20_000)
        assertEquals(listOf("sync", "reboot"), before.sent)
        assertTrue(outcome.check!!.homeOK)
        assertEquals(listOf("com.tcl.usercenter"), outcome.check!!.reEnabled)

        val unreachable = SetupSequence.restartAndCheck(ScriptedTV(), TVConnector { _, _ -> throw SetupFailure(SetupIssue.ADB_REFUSED) }, emptyList(), null)
        assertNull("the TV didn't let the phone back in", unreachable.check)
    }

    @Test fun turningDebuggingOffChecksThePortRefuses() = runTest {
        val port = ServerSocket(0).use { it.localPort }   // nothing listens there afterwards
        val tv = ScriptedTV()
        val closed = SetupSequence.turnOffDebugging(tv, TVConnector { _, _ -> tv }, "127.0.0.1", port)
        assertEquals(true, closed)
        assertTrue(tv.sent.contains("settings put global adb_wifi_enabled 0; settings put global adb_enabled 0"))
        val e = failure { SetupSequence.turnOffDebugging(null, TVConnector { _, _ -> throw SetupFailure(SetupIssue.ADB_REFUSED) }, "127.0.0.1", port) }
        assertEquals(SetupIssue.DEBUGGING_UNREACHABLE, e.issue)
    }

    @Test fun choicesAndHomeScreenRules() {
        val profile = DebloatProfile.load(profileSource, "tcl-43c645")
        val inv = TVInventory(mapOf("ro.product.manufacturer" to "TCL"), setOf("com.tcl.bi", "com.tcl.tv", "com.netflix.ninja"),
            emptySet(), true, null, emptyMap(), "1")
        assertEquals(listOf("com.tcl.bi"), SetupSequence.choices(profile, inv, ProfileMatch.Kind.TESTED).map { it.packageName })
        assertNull(SetupSequence.homeScreenBlock(profile, inv))
        assertEquals(HomeScreenBlock.FIRE_OS, SetupSequence.homeScreenBlock(profile, inv.copy(properties = mapOf("ro.product.manufacturer" to "Amazon"))))
        assertEquals(HomeScreenBlock.CVTE, SetupSequence.homeScreenBlock(profile, inv.copy(installed = inv.installed + "com.cvte.tv.launcher")))
        assertEquals(listOf("com.netflix.ninja"), SetupSequence.defaultDock(profile, inv))
        val plan = DebloatPlan(emptyList(), wifiToResave = listOf(WifiNetwork(1, "Casa", "wpa2", DebloatRules.SETUPWRAITH)))
        assertFalse(SetupSequence.wifiReady(plan, mapOf("Casa" to "a"), mapOf("Casa" to "b")))
        assertTrue(SetupSequence.wifiReady(plan, mapOf("Casa" to "a"), mapOf("Casa" to "a")))
    }

    /** LCH-15: the update refuses a TV whose Home isn't ours, and skips a TV that is already current. */
    @Test fun homeUpdateGuards() = runTest {
        val store = RecoveryStore(Files.createTempDirectory("recovery").toFile())
        val profiles = DebloatProfile.loadAll(profileSource, includeDevelopment = false)
        val banner = mapOf("ro.product.name" to "G03_4K_GB", "ro.product.model" to "Smart TV Pro", "ro.product.device" to "BeyondTV4")
        fun tv(home: String, version: Int) = ScriptedTV().apply {
            exact["getprop ro.build.version.sdk"] = "30"; exact["getprop ro.build.version.incremental"] = "AR11"
            prefixes += DebloatRules.HOME_QUERY to home
            prefixes += "dumpsys package com.gathin.tvhome" to "versionCode=$version minSdk=26"
        }
        val stock = tv("$launcherx/.home.HomeActivity", 12)
        assertEquals(SetupIssue.UPDATE_HOME_NOT_OURS, failure { SetupSequence.updateHome(stock, banner, ByteArray(10), 13, profiles, store, "h") }.issue)
        assertFalse(stock.sent.any { it.startsWith("pm ") })
        val current = tv("com.gathin.tvhome/.MainActivity", 13)
        assertFalse(SetupSequence.updateHome(current, banner, ByteArray(10), 13, profiles, store, "h"))
        assertTrue(current.pushed.isEmpty())
        // LCH-22: a retry after a cut-off install finishes the last steps on a TV that has the build, installing nothing.
        val resumed = tv("com.gathin.tvhome/.MainActivity", 13).apply {
            prefixes += "am start -W" to "Status: ok"
            prefixes += "pm grant com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS" to "restore-granted"
            prefixes += "pm revoke com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS" to "secure-settings-revoked"
        }
        assertTrue(SetupSequence.updateHome(resumed, banner, ByteArray(10), 13, profiles, store, "h", resume = true))
        assertTrue(resumed.pushed.isEmpty())
        assertFalse(resumed.sent.any { it.startsWith("pm install") || it.startsWith("pm disable-user") })
        assertTrue(resumed.sent.contains("cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity"))
    }
}
