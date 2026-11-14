package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ports of ios/Tests/DebloatTests.swift and the debloat half of EngineEdgeTests.swift (TESTING.md: DBL-*). */
class DebloatTest {
    companion object {
        val tcl = "﻿# TCL G03 / BeyondTV4 firmware (AR11), reports as \"Smart TV Pro\"\n" +
            "# Never disable: com.tcl.providers.config com.tcl.initsetup com.tcl.tvinput com.tcl.tv\n" +
            "# com.tcl.settings com.google.android.gms\n" +
            "# Kept by choice on both: Cast receiver (mediashell), Live TV (com.tcl.tv).\n\n" +
            "# 1. Telemetry, promos, content rows\ncom.tcl.bi\ncom.tcl.partnercustomizer\n\n" +
            "# 1b. Google TV first-run wizard (claims HOME once the stock launcher is off)\ncom.google.android.tungsten.setupwraith\n\n" +
            "# 3. Off by choice (the 60C635 kept both)\n" +
            "com.tcl.versionUpdateApp                    # firmware updater\ncom.tcl.miracast\r\n"

        val wizardWifi = """
            Dump of WifiConfigManager
            Configured networks Begin ----
              ID: 3 SSID: "Casa 'Ramalho'" PROVIDER-NAME: null BSSID: null FQDN: null PRIO: 0 HIDDEN: false
             NetworkSelectionStatus NETWORK_SELECTION_ENABLED
             KeyMgmt: WPA_PSK Protocols: WPA RSN
             cuid=10071 cname=com.google.android.tungsten.setupwraith luid=1000 lname=android.uid.system:1000
              ID: 4 SSID: "Guest" PROVIDER-NAME: null BSSID: null FQDN: null PRIO: 0 HIDDEN: false
             KeyMgmt: NONE Protocols: RSN
             cuid=1000 cname=android.uid.system:1000 luid=1000
        """.trimIndent()
    }

    private fun inventory(installed: Set<String>, home: String? = "com.google.android.apps.tv.launcherx/.home.HomeActivity",
                          secure: String = "1") = TVInventory(emptyMap(), installed, emptySet(), true, home,
        mapOf("window_animation_scale" to "1.0", "transition_animation_scale" to "null", "animator_duration_scale" to "0.5"), secure)

    @Test fun parsesUpstreamListFormat() {
        val list = DebloatList.parse(tcl)
        assertEquals(listOf("com.tcl.bi", "com.tcl.partnercustomizer", "com.google.android.tungsten.setupwraith", "com.tcl.versionUpdateApp", "com.tcl.miracast"),
            list.entries.map { it.packageName })
        assertEquals(listOf("Telemetry, promos, content rows", "Google TV first-run wizard (claims HOME once the stock launcher is off)",
            "Off by choice (the 60C635 kept both)"), list.groups)
        assertEquals("firmware updater", list.entries[3].note)
        assertEquals(setOf("com.tcl.providers.config", "com.tcl.initsetup", "com.tcl.tvinput", "com.tcl.tv", "com.tcl.settings", "com.google.android.gms"),
            list.neverDisable)
        assertThrows(SetupFailure::class.java) { DebloatList.parse("com.ok.app\nrm -rf /\n") }
    }

    @Test fun listsRejectNonPackageLines() {
        assertThrows(SetupFailure::class.java) { DebloatList.parse("com.ok.app\n\$(reboot)\n") }
        assertThrows(SetupFailure::class.java) { DebloatList.parse("com.ok.app; reboot\n") }
    }

    @Test fun onlyWellFormedPackageNamesComeBackFromTheTV() {
        val answer = "package:com.netflix.ninja\npackage:com.tcl.x;reboot\npackage:com.example.\$(id)\npackage:android\npackage:com.ok_app.tv2 installer=x\nnoise"
        assertEquals(setOf("com.netflix.ninja", "android", "com.ok_app.tv2"), Pattern.packageNames(answer))
    }

    @Test fun corePackagesAreNeverDisabled() {
        assertTrue(DebloatRules.isCore("com.android.systemui"))
        assertTrue(DebloatRules.isCore("com.android.providers.settings"))
        assertFalse(DebloatRules.isCore("com.android.providers.calendar"))
        assertTrue(DebloatRules.isCore("com.google.android.overlay.modules.ext.services"))
        assertTrue("boot-looped a TCL 43S5400A (upstream #2803)", DebloatRules.isCore("com.android.location.fused"))
        assertFalse(DebloatRules.isCore("com.tcl.bi"))
    }

    @Test fun guardsSkipWifiOwnerHomeOwnerInputDriversAndSettings() = runBlocking {
        val list = DebloatList.parse(tcl + "\n# 6. Launcher\ncom.google.android.apps.tv.launcherx\ncom.tcl.tvhdmi\ncom.tcl.settings.extra\n")
        val installed = list.entries.map { it.packageName }.toSet()
        val tv = FakeTV(installed, listOf(
            "dumpsys wifi" to "Dump of WifiConfigManager\nID: 0 SSID: \"Office\" PROVIDER-NAME: null BSSID: null\n KeyMgmt: WPA_EAP IEEE8021X Protocols: RSN\n cuid=10071 cname=com.google.android.tungsten.setupwraith luid=1000\n",
            DebloatRules.CLAIM_QUERY to "com.google.android.apps.tv.launcherx/.home.HomeActivity\ncom.google.android.tungsten.setupwraith/.RecoveryActivity",
            "s=\$(getprop" to "com.tcl.tvhdmi\n",
            "cmd package query-activities --brief -a android.intent.action.VIEW" to "\n==\ncom.tcl.settings.extra/.Main\n",
        ))
        val plan = Debloater(tv).plan(list.entries.map { it.packageName }, list, inventory(installed))
        val skipped = plan.skipped.associate { it.packageName to it.reason }
        assertEquals("its enterprise Wi-Fi can't be saved again", SkipReason.WIFI_ENTERPRISE, skipped["com.google.android.tungsten.setupwraith"])
        assertEquals(SkipReason.HOME_OWNER_ALONE, skipped["com.google.android.apps.tv.launcherx"])
        assertEquals(SkipReason.INPUT_DRIVER, skipped["com.tcl.tvhdmi"])
        assertEquals(SkipReason.OPENS_SETTINGS, skipped["com.tcl.settings.extra"])
        assertEquals(setOf("com.tcl.bi", "com.tcl.partnercustomizer", "com.tcl.versionUpdateApp", "com.tcl.miracast"), plan.disable.toSet())
    }

    @Test fun neverDisableAndAlreadyDisabledAreLeftAlone() = runBlocking {
        val list = DebloatList.parse(tcl)
        val inv = inventory(setOf("com.tcl.bi", "com.tcl.tv", "com.tcl.miracast")).copy(disabled = setOf("com.tcl.miracast"))
        val plan = Debloater(FakeTV(inv.installed)).plan(listOf("com.tcl.bi", "com.tcl.tv", "com.tcl.miracast"), list, inv)
        assertEquals(listOf("com.tcl.bi"), plan.disable)
        assertEquals(listOf("com.tcl.tv"), plan.skipped.map { it.packageName })
    }

    @Test fun applyReadsTheTVBack() = runBlocking {
        val tv = FakeTV(setOf("com.tcl.bi", "com.tcl.guard"))
        val result = Debloater(tv).apply(DebloatPlan(listOf("com.tcl.bi")))
        assertEquals(listOf("com.tcl.bi"), result.disabled)
        assertEquals(emptyList<String>(), result.stillEnabled)
        assertTrue(tv.sent.contains("pm disable-user --user 0 com.tcl.bi"))
    }

    @Test fun applyStopsWhenTheTVStopsAnswering() = runBlocking {
        val tv = ScriptedTV()
        tv.failing += "pm disable-user --user 0 b.b"
        tv.exact["pm list packages -e --user 0"] = "package:b.b\npackage:c.c"
        val result = Debloater(tv).apply(DebloatPlan(listOf("a.a", "b.b", "c.c")))
        assertTrue(result.stoppedEarly)
        assertEquals(listOf("a.a"), result.disabled)
        assertEquals(listOf("b.b", "c.c"), result.stillEnabled)
        assertFalse("nothing after the failure is touched", tv.sent.contains("pm disable-user --user 0 c.c"))
    }

    /** DBL-11b: an empty answer after disabling is a check that didn't run, not "everything is off". */
    @Test fun applyRefusesAnEmptyReadback() = runBlocking {
        val e = failure { Debloater(ScriptedTV()).apply(DebloatPlan(listOf("com.tcl.bi"))) }
        assertEquals(SetupIssue.APPLY_UNCHECKED, e.issue)
        assertTrue(e.message!!.contains("couldn't be checked"))
    }

    @Test fun inspectFallsBackWhenUserScopedListingIsEmpty() = runBlocking {
        val tv = ScriptedTV()
        tv.exact["pm list packages --user 0"] = ""
        tv.exact["pm list packages"] = "package:a.a\npackage:b.b"
        tv.exact["pm list packages -d"] = "package:b.b"
        val inv = Debloater(tv).inspect()
        assertFalse(inv.userScoped)
        assertEquals(setOf("a.a", "b.b"), inv.installed)
        assertEquals(setOf("b.b"), inv.disabled)
    }

    @Test fun inspectRefusesATVThatListsNothing() = runBlocking {
        val e = failure { Debloater(ScriptedTV()).inspect() }
        assertEquals(SetupIssue.NO_APPS_LISTED, e.issue)
        assertTrue(e.message!!.contains("no apps"))
    }

    @Test fun setupWizardFollowsTheWifiCheck() = runBlocking {
        val list = DebloatList.parse("# 1. Setup\ncom.google.android.tungsten.setupwraith\ncom.tcl.bi\n")
        val inv = inventory(setOf("com.google.android.tungsten.setupwraith", "com.tcl.bi", "com.google.android.apps.tv.launcherx"))
        val claims = DebloatRules.CLAIM_QUERY to "com.google.android.apps.tv.launcherx/.home.HomeActivity\ncom.google.android.tungsten.setupwraith/.RecoveryActivity"
        val wizard = DebloatRules.SETUPWRAITH
        val chosen = list.entries.map { it.packageName }

        // Unreadable: the wizard stays, and the Home step is warned that it keeps Home.
        val unknown = ScriptedTV().apply { prefixes += claims }
        val kept = Debloater(unknown).plan(chosen, list, inv)
        assertEquals(listOf("com.tcl.bi"), kept.disable)
        assertTrue(kept.setupKeepsHome)

        // Readable, no network of the wizard's (a TV on a cable): disabled, nothing to ask.
        val cable = ScriptedTV().apply { prefixes += "dumpsys wifi" to "Dump of WifiConfigManager\nConfigured networks Begin ----\n"; prefixes += claims }
        val off = Debloater(cable).plan(chosen, list, inv)
        assertEquals(setOf(wizard, "com.tcl.bi"), off.disable.toSet())
        assertTrue(off.wifiToResave.isEmpty())
        assertFalse(off.setupKeepsHome)

        // The wizard owns a WPA2 network and the TV can save networks from the shell: saved again first.
        val wifi = ScriptedTV().apply {
            prefixes += "dumpsys wifi" to wizardWifi
            prefixes += "cmd wifi help" to "connect-network <ssid> open|owe|wpa2|wpa3 [<passphrase>]\nforget-network <networkId>\n"
            prefixes += claims
        }
        val resave = Debloater(wifi).plan(chosen, list, inv)
        assertEquals(setOf(wizard, "com.tcl.bi"), resave.disable.toSet())
        assertEquals(listOf(WifiNetwork(3, "Casa 'Ramalho'", "wpa2", wizard)), resave.wifiToResave)

        // Without connect-network on the TV: the wizard stays, with the rejoin-on-the-TV explanation.
        val old = ScriptedTV().apply { prefixes += "dumpsys wifi" to wizardWifi; prefixes += "cmd wifi help" to "status\n"; prefixes += claims }
        val noShell = Debloater(old).plan(chosen, list, inv)
        assertEquals(listOf("com.tcl.bi"), noShell.disable)
        assertTrue(noShell.skipped.any { it.packageName == wizard && it.reason == SkipReason.WIFI_NO_SHELL && it.reason.english.contains("join it again") })

        // DBL-10d: a wizard network the parser can't read (an SSID printed as hex) keeps the wizard, as upstream's raw grep would.
        val hex = wizardWifi.replace("SSID: \"Casa 'Ramalho'\"", "SSID: 4361736120f0")
        assertEquals(1, DebloatRules.wizardOwnerCount(hex))
        val odd = ScriptedTV().apply { prefixes += "dumpsys wifi" to hex; prefixes += "cmd wifi help" to "connect-network\nforget-network\n"; prefixes += claims }
        val unparsed = Debloater(odd).plan(chosen, list, inv)
        assertEquals(listOf("com.tcl.bi"), unparsed.disable)
        assertTrue(unparsed.wifiToResave.isEmpty())
    }

    @Test fun wifiParsingAndTheResaveCommand() {
        val networks = DebloatRules.wifiNetworks(wizardWifi) ?: emptyList()
        assertEquals(listOf("Casa 'Ramalho'", "Guest"), networks.map { it.ssid })
        assertEquals(listOf("wpa2", "open"), networks.map { it.security })
        assertNull(DebloatRules.wifiNetworks("Service dumps disabled due to hung system process."))
        // Forget first (connect-network keeps an existing network's creator), detached so a TV on Wi-Fi finishes it.
        assertEquals("""nohup sh -c 'cmd wifi forget-network 3 && cmd wifi connect-network '\''Casa '\''\'\'''\''Ramalho'\''\'\'''\'''\'' wpa2 '\''it'\''\'\'''\''s ${'$'}ecret'\''' >/dev/null 2>&1 &""",
            DebloatRules.resaveWifiCommand(networks[0], "it's \$ecret"))
        assertFalse("open networks take no password", DebloatRules.resaveWifiCommand(networks[1], "ignored").contains("ignored"))
    }

    @Test fun openDebuggingPortIsCalledOut() = runBlocking {
        val list = DebloatList.parse("com.tcl.bi\n")
        val plan = Debloater(ScriptedTV()).plan(listOf("com.tcl.bi"), list, inventory(setOf("com.tcl.bi"), secure = "0"))
        assertTrue(PlanNote.OPEN_DEBUGGING_PORT in plan.notes)
        assertTrue(plan.notes.any { it.english.contains("without asking") })
    }

    @Test fun firmwareWithoutPermissionsKeepsThePackage() = runBlocking {
        val list = DebloatList.parse("com.tcl.mystery\n")
        val tv = ScriptedTV().apply { prefixes += "s=\$(getprop" to "NOCHK com.tcl.mystery\n" }
        val plan = Debloater(tv).plan(listOf("com.tcl.mystery"), list, inventory(setOf("com.tcl.mystery")))
        assertEquals(emptyList<String>(), plan.disable)
        assertTrue(plan.skipped.first().reason.english.contains("stays enabled"))
    }

    @Test fun recordKeepsTheStateBeforeTheFirstRunAndRestoreReplaysIt() {
        val list = DebloatList.parse(tcl)
        var inv = inventory(setOf("com.tcl.bi", "com.tcl.miracast", "com.google.android.apps.tv.launcherx")).copy(disabled = setOf("com.tcl.miracast"))
        val debloater = Debloater(FakeTV(emptySet()))
        val first = debloater.record(list, "tcl-43c645", "192.168.0.13", inv, null)
        assertEquals("enabled", first.packages["com.tcl.bi"])
        assertEquals("disabled", first.packages["com.tcl.miracast"])
        assertEquals("absent", first.packages["com.tcl.partnercustomizer"])
        assertEquals("enabled", first.packages["com.google.android.apps.tv.launcherx"])   // Home's owner
        // A retry after cleanup must not record the cleaned state as the original.
        inv = inv.copy(disabled = inv.disabled + "com.tcl.bi")
        val again = debloater.record(list, "tcl-43c645", "192.168.0.13", inv, first)
        assertEquals("enabled", again.packages["com.tcl.bi"])
        val commands = Debloater.restoreCommands(first)
        assertTrue(commands.contains("pm enable com.tcl.bi"))
        assertFalse("was already off before cleanup", commands.contains("pm enable com.tcl.miracast"))
        assertTrue(commands.contains("cmd package set-home-activity --user 0 com.google.android.apps.tv.launcherx/.home.HomeActivity"))
        assertTrue(commands.contains("settings delete global transition_animation_scale"))
        assertTrue(commands.contains("settings put global animator_duration_scale 0.5"))
    }

    @Test fun homeChooserAndFallbackHomeAreNotRecorded() {
        assertTrue(DebloatRules.isChooser("android/com.android.internal.app.ResolverActivity"))
        assertTrue(DebloatRules.notALauncher("com.tcl.keycustomfunctionservice/.FallbackHome"))
        assertTrue(DebloatRules.notALauncher("com.google.android.tungsten.setupwraith/.RecoveryActivity"))
        assertFalse(DebloatRules.notALauncher("com.gathin.tvhome/.MainActivity"))
        assertEquals(setOf("com.gathin.tvhome"), DebloatRules.launchers(listOf("com.gathin.tvhome/.MainActivity",
            "com.android.tv.settings/.system.FallbackHome", "com.google.android.tungsten.setupwraith/.RecoveryActivity")))
    }
}
