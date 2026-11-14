package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** Ports of RecoveryCompatibilityTests, UndoSafetyTests and RestartCheckTests (TESTING.md: UND-*, DBL-18), plus the store. */
class RecoveryTest {
    companion object {
        /** The shape recovery.py writes: Python's ISO time with a +0200 offset, a list given as a file path. */
        const val UPSTREAM_RECORD = """
        {"created": "2026-10-22T22:14:37+0200", "home": "com.google.android.apps.tv.launcherx/.home.HomeActivity",
         "host": "192.0.2.21", "list": "/path/to/batches/04-preloads.txt",
         "packages": {"com.google.android.apps.tv.launcherx": "enabled", "com.tcl.guard": "enabled",
                      "com.tcl.ocean.instructions": "enabled", "com.tcl.stan": "disabled", "com.tcl.gone": "absent"},
         "settings": {"animator_duration_scale": "1.0", "transition_animation_scale": "null", "window_animation_scale": "0.5"},
         "version": 1}
        """
    }

    private fun upstream() = RecoveryStore.decode(UPSTREAM_RECORD.toByteArray())
    private val launcherx = "com.google.android.apps.tv.launcherx"
    private val tcl = TVIdentity("3f2a9c01d4e5b677", "0123456789ABCDEF", "Smart TV Pro", "BeyondTV4")

    // RecoveryCompatibilityTests

    @Test fun decodesUpstreamRecords() {
        val record = upstream()
        assertEquals(1, record.version)
        assertEquals(5, record.packages.size)
        assertEquals("com.google.android.apps.tv.launcherx/.home.HomeActivity", record.home)
    }

    @Test fun restoreTurnsBackOnlyWhatWasOnAndPutsHomeBack() {
        val commands = Debloater.restoreCommands(upstream(), launcherx)
        assertEquals(listOf("pm enable com.google.android.apps.tv.launcherx", "pm enable com.tcl.guard", "pm enable com.tcl.ocean.instructions"), commands.take(3))
        assertFalse("it was off before the cleanup", commands.contains("pm enable com.tcl.stan"))
        assertFalse(commands.any { it.contains("com.tcl.gone") })
        assertTrue(commands.contains("cmd package set-home-activity --user 0 com.google.android.apps.tv.launcherx/.home.HomeActivity"))
        assertTrue(commands.contains("settings delete global transition_animation_scale"))
        assertTrue(commands.contains("settings put global window_animation_scale 0.5"))
    }

    @Test fun restoreNeverRunsInjectedSettingValues() {
        val record = upstream().let { it.copy(settings = it.settings + ("window_animation_scale" to "1; reboot")) }
        assertFalse(Debloater.restoreCommands(record).any { it.contains("reboot") })
    }

    @Test fun restoreNeverRunsInjectedPackagesOrHome() {
        val record = upstream().let { it.copy(packages = it.packages + ("com.ok; reboot" to "enabled") + ("\$(reboot)" to "enabled"), home = "com.x/.Main; reboot") }
        val commands = Debloater.restoreCommands(record)
        assertFalse(commands.joinToString("\n"), commands.any { it.contains("reboot") })
        assertTrue("valid entries still restore", commands.contains("pm enable com.tcl.guard"))
    }

    @Test fun ourRecordsUseUpstreamKeys() {
        val record = RecoveryRecord(created = "2026-11-01T10:00:00Z", host = "192.0.2.1", list = "tcl-43c645", packages = mapOf("a.b" to "enabled"))
        val json = Json.parseToJsonElement(RecoveryStore.encode(record).decodeToString()).jsonObject
        assertEquals("home is omitted when null, as recovery.py reads it", setOf("version", "created", "host", "list", "settings", "packages"), json.keys)
    }

    /** A record as the iPhone writes it (JSONEncoder, pretty, sorted, every Purio field) decodes and survives a round trip. */
    @Test fun iPhoneRecordsRoundTrip() {
        val iphone = """
        {
          "accessibility" : { "accessibility_enabled" : "0", "enabled_accessibility_services" : "null" },
          "created" : "2026-11-12T19:02:11Z",
          "home" : "com.google.android.apps.tv.launcherx\/.home.HomeActivity",
          "host" : "192.168.0.13",
          "list" : "tcl-43c645",
          "lists" : [ "tcl-43c645" ],
          "packages" : { "com.tcl.bi" : "enabled" },
          "settings" : { "window_animation_scale" : "1.0" },
          "tv" : { "androidId" : "3f2a9c01d4e5b677", "device" : "BeyondTV4", "model" : "Smart TV Pro", "serial" : "0123456789ABCDEF" },
          "version" : 1
        }
        """
        val record = RecoveryStore.decode(iphone.toByteArray())
        assertEquals(tcl, record.tv)
        assertEquals("com.google.android.apps.tv.launcherx/.home.HomeActivity", record.home)
        assertEquals(record, RecoveryStore.decode(RecoveryStore.encode(record)))
    }

    // UndoSafetyTests

    private fun inventory(installed: Set<String>, disabled: Set<String> = emptySet(), home: String) =
        TVInventory(emptyMap(), installed, disabled, true, home, mapOf("window_animation_scale" to "1.0"), "1")

    /** UND-07: list A then list B: the record keeps the state before A, adds B's new apps, and lists both. */
    @Test fun oneRecordPerTVAcrossLists() {
        val a = DebloatList.parse("# 1. A\ncom.tcl.bi\ncom.tcl.ota\n")
        val b = DebloatList.parse("# 1. B\ncom.tcl.bi\ncom.tcl.weather\n")
        val engine = Debloater(ScriptedTV())
        val before = inventory(setOf("com.tcl.bi", "com.tcl.ota", "com.tcl.weather", launcherx), home = "$launcherx/.home.HomeActivity")
        val first = engine.record(a, "list-a", "192.168.0.13", before, null, tcl,
            mapOf("enabled_accessibility_services" to "null", "accessibility_enabled" to "0"))
        val after = inventory(before.installed + "com.gathin.tvhome", setOf("com.tcl.bi", "com.tcl.ota", launcherx), "com.gathin.tvhome/.MainActivity")
        val second = engine.record(b, "list-b", "192.168.0.20", after, first, tcl,
            mapOf("enabled_accessibility_services" to "com.gathin.tvhome/.HomeKeyService", "accessibility_enabled" to "1"))
        assertEquals("the state before the first setup wins", "enabled", second.packages["com.tcl.bi"])
        assertEquals("enabled", second.packages[launcherx])
        assertEquals("enabled", second.packages["com.tcl.weather"])
        assertEquals("$launcherx/.home.HomeActivity", second.home)
        assertEquals("null", second.accessibility?.get("enabled_accessibility_services"))
        assertEquals(listOf("list-a", "list-b"), second.lists)
        assertEquals("list-b", second.lastList)
        assertEquals("192.168.0.20", second.host)
        assertNull("our own launcher is never something to turn back on", second.packages["com.gathin.tvhome"])
    }

    /** UND-08: records from builds before this one fold into one, oldest state first. */
    @Test fun olderRecordsMergeOldestFirst() {
        val old = RecoveryRecord(created = "2026-11-01T10:00:00Z", host = "h", list = "a", home = "$launcherx/.Home",
            packages = mapOf("x" to "enabled", launcherx to "enabled"))
        val newer = RecoveryRecord(created = "2026-11-02T10:00:00Z", host = "h2", list = "b", home = "com.gathin.tvhome/.MainActivity",
            packages = mapOf("x" to "disabled", "y" to "enabled", launcherx to "disabled"))
        val merged = newer.mergedWithOlder(old)
        assertEquals(mapOf("x" to "enabled", "y" to "enabled", launcherx to "enabled"), merged.packages)
        assertEquals("$launcherx/.Home", merged.home)
        assertEquals(listOf("a", "b"), merged.lists)
        assertEquals("h2", merged.host)
        RecoveryStore.decode("""{"version":1,"created":"c","host":"h","list":"l","home":null,"settings":{},"packages":{"x":"enabled"}}""".toByteArray())
    }

    /** UND-09: a dummy serial says nothing; android_id tells TVs apart. */
    @Test fun identityIgnoresDummySerials() {
        val other = tcl.copy(androidId = "aaaabbbbccccdddd")
        assertFalse("same dummy serial, different android_id", tcl.sameTV(other))
        assertTrue(tcl.sameTV(tcl))
        assertNull(tcl.realSerial)
        assertEquals("id-3f2a9c01d4e5b677", tcl.key)
        val noId = TVIdentity("", "0123456789ABCDEF", "M", "D")
        assertNull("nothing identifies it: the record is keyed by address instead", noId.key)
        assertTrue(noId.sameTV(TVIdentity("", "unknown", "M", "D")))
        assertFalse(noId.sameTV(TVIdentity("", "", "N", "D")))
    }

    private fun record(accessibility: Map<String, String>? = null) = RecoveryRecord(created = "c", host = "h", list = "l",
        home = "$launcherx/.home.HomeActivity", packages = mapOf("com.tcl.bi" to "enabled", "com.tcl.old" to "disabled", launcherx to "enabled"),
        tv = tcl, lists = listOf("l"), accessibility = accessibility)

    private fun tv(identity: TVIdentity, enabled: List<String>, home: String) = ScriptedTV().apply {
        exact["settings get secure android_id"] = identity.androidId
        exact["getprop ro.serialno"] = identity.serial
        exact["getprop ro.product.model"] = identity.model
        exact["getprop ro.product.device"] = identity.device
        exact["pm list packages --user 0"] = listOf("com.tcl.bi", "com.tcl.old", launcherx, "com.gathin.tvhome").joinToString("\n") { "package:$it" }
        exact["pm list packages -e --user 0"] = enabled.joinToString("\n") { "package:$it" }
        prefixes += DebloatRules.HOME_QUERY to home
    }

    /** UND-10: a record from another TV is refused before any command. */
    @Test fun restoreRefusesAnotherTV() = runBlocking {
        val scripted = tv(tcl.copy(androidId = "aaaabbbbccccdddd"), emptyList(), "")
        val e = failure { Debloater(scripted).restore(record()) }
        assertEquals(SetupIssue.RESTORE_OTHER_TV, e.issue)
        assertTrue(e.message!!.contains("another TV"))
        assertFalse(scripted.sent.any { it.startsWith("pm enable") || it.startsWith("cmd package set-home-activity") })
    }

    /** UND-11: the restore reads the TV back and says what didn't come back. */
    @Test fun restoreChecksItsResult() = runBlocking {
        val ok = Debloater(tv(tcl, listOf("com.tcl.bi", launcherx, "com.gathin.tvhome"), "$launcherx/.home.HomeActivity")).restore(record(), launcherx)
        assertTrue(ok.complete)
        assertEquals(listOf("com.tcl.old"), ok.keptOff)
        val report = Debloater(tv(tcl, listOf(launcherx), "com.gathin.tvhome/.MainActivity")).restore(record(), launcherx)
        assertFalse(report.complete)
        assertEquals(listOf("com.tcl.bi"), report.notBack)
        assertFalse(report.homeOK)
        assertEquals(launcherx, report.expectedHome)
        val e = failure { Debloater(tv(tcl, emptyList(), "")).restore(record()) }
        assertTrue(e.message!!.contains("couldn't be checked"))
    }

    /** UND-12: the helpers go back to the accessibility settings from before setup; unreadable values never reach the shell. */
    @Test fun restorePutsTheHelpersBack() {
        val none = Debloater.restoreCommands(record(mapOf("enabled_accessibility_services" to "null", "accessibility_enabled" to "0")))
        assertTrue(none.contains("settings delete secure enabled_accessibility_services"))
        assertTrue(none.contains("settings put secure accessibility_enabled 0"))
        assertTrue(none.any { it.startsWith("pm revoke com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS") })
        val talkback = Debloater.restoreCommands(record(mapOf("enabled_accessibility_services" to "com.google.android.marvin.talkback/.TalkBackService",
            "accessibility_enabled" to "1")))
        assertTrue(talkback.contains("settings put secure enabled_accessibility_services com.google.android.marvin.talkback/.TalkBackService"))
        val hostile = Debloater.restoreCommands(record(mapOf("enabled_accessibility_services" to "x; reboot", "accessibility_enabled" to "1; reboot")))
        assertFalse(hostile.any { it.contains("reboot") })
        assertFalse("a record from before this field leaves them alone", Debloater.restoreCommands(record()).any { it.contains("accessibility") })
        assertFalse(Debloater.restoreCommands(record(), "x; reboot").any { it.contains("reboot") })
    }

    /** DBL-18: the restart at the end of apply. */
    @Test fun restartCheckJudgesHomeAndReEnabledApps() {
        val ours = RestartCheck.judge("com.gathin.tvhome/.MainActivity", setOf("com.tcl.usercenter"), listOf("com.tcl.bi", "com.tcl.usercenter"), "com.gathin.tvhome")
        assertTrue(ours.homeOK)
        assertEquals(listOf("com.tcl.usercenter"), ours.reEnabled)
        assertFalse(RestartCheck.judge("$launcherx/.home.HomeActivity", emptySet(), emptyList(), "com.gathin.tvhome").homeOK)
        assertFalse(RestartCheck.judge("com.google.android.tungsten.setupwraith/.RecoveryActivity", emptySet(), emptyList(), null).homeOK)
        assertFalse(RestartCheck.judge("com.android.tv.settings/.system.FallbackHome", emptySet(), emptyList(), null).homeOK)
        assertFalse(RestartCheck.judge("", emptySet(), emptyList(), null).homeOK)
        assertTrue("debloat only: the TV's own Home is fine", RestartCheck.judge("$launcherx/.home.HomeActivity", emptySet(), emptyList(), null).homeOK)
    }

    // RecoveryStore (RecoveryStore in DebloatFlow.swift)

    @Test fun storeKeepsOneRecordPerTVAndFoldsOlderOnesIn() {
        val store = RecoveryStore(Files.createTempDirectory("recovery").toFile())
        assertEquals("recovery-tv-id-3f2a9c01d4e5b677.json", store.file(tcl, "192.168.0.13").name)
        assertEquals("recovery-tv-host-192.168.0.13.json", store.file(TVIdentity("", "unknown", "M", "D"), "192.168.0.13").name)
        // An older build's per-list record of this TV, and another TV's record.
        val legacy = store.file("tcl-43c645", "192.168.0.13")
        store.save(RecoveryRecord(created = "2026-11-01T10:00:00Z", host = "192.168.0.13", list = "tcl-43c645",
            packages = mapOf("com.tcl.bi" to "enabled"), tv = tcl), legacy)
        val other = store.file("tcl-43c645", "192.168.0.99")
        store.save(RecoveryRecord(created = "2026-11-01T11:00:00Z", host = "192.168.0.99", list = "tcl-43c645",
            packages = mapOf("com.tcl.bi" to "enabled"), tv = tcl.copy(androidId = "aaaabbbbccccdddd")), other)
        val (file, existing, old) = store.forTV(tcl, "192.168.0.13")
        assertEquals(store.file(tcl, "192.168.0.13"), file)
        assertEquals(listOf(legacy), old)
        assertEquals(mapOf("com.tcl.bi" to "enabled"), existing?.packages)
        assertEquals(2, store.all().size)
    }

    @Test fun saveRecordWritesBeforeAnyChange() = runBlocking {
        val store = RecoveryStore(Files.createTempDirectory("recovery").toFile())
        val profile = DebloatProfile.load(profileSource, "tcl-43c645")
        val scripted = tv(tcl, emptyList(), "")
        val inv = inventory(setOf("com.tcl.bi", launcherx), home = "$launcherx/.home.HomeActivity")
        val file = SetupSequence.saveRecord(scripted, store, profile, inv, "192.168.0.13")
        val saved = store.load(file)!!
        assertEquals(tcl, saved.tv)
        assertEquals("enabled", saved.packages["com.tcl.bi"])
        assertTrue("only reads", scripted.sent.none { it.startsWith("pm ") || it.startsWith("settings put") || it.startsWith("cmd package set") })
    }
}
