package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ports of ios/Tests/LauncherInstallTests.swift and LauncherInstallEdgeTests (TESTING.md: LCH-*). */
class LauncherInstallTest {
    private val apk = ByteArray(1000) { 7 }
    private val answers = listOf("getprop ro.build.version.sdk" to "30\n", "pm install" to "Success\n",
        "am start -W" to "Starting: Intent\nStatus: ok\nComplete\n")

    @Test fun installsStartsThenHandsHomeOver() = runBlocking {
        val tv = FakeDevice(answers)
        val home = LauncherInstaller(tv).install(apk, LauncherOptions(homeKeyService = true))
        assertEquals("com.gathin.tvhome/.MainActivity", home)
        val start = tv.sent.indexOfFirst { it.startsWith("am start -W") }
        val disable = tv.sent.indexOf("pm disable-user --user 0 com.google.android.apps.tv.launcherx")
        assertTrue("the stock launcher goes only after the new one started", start in 0 until disable)
        assertTrue(tv.sent.any { it.contains("enabled_accessibility_services") && it.contains("HomeKeyService enabled") })
        assertFalse(tv.sent.any { it.contains("InputKeyService") })
    }

    /** LCH-22: finishing a cut-off update repeats only the last steps: nothing sent, installed or disabled, no layout. */
    @Test fun finishingACutOffUpdateRepeatsOnlyTheLastSteps() = runBlocking {
        val tv = FakeDevice(answers)
        val home = LauncherInstaller(tv).finishUpdate(LauncherOptions(homeKeyService = true, restoreKeyServices = true))
        assertEquals("com.gathin.tvhome/.MainActivity", home)
        assertTrue(tv.pushed.isEmpty())
        assertFalse(tv.sent.any { it.startsWith("pm install") || it.startsWith("pm disable-user") || it.contains("config.json") })
        assertEquals(LauncherInstaller.RESTART_WITH_HELPERS, tv.sent.first())
        assertTrue(tv.sent.contains("cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity"))
        assertTrue(tv.sent.any { it.contains("HomeKeyService enabled") })
    }

    /** LCH-21: STOCK_LAUNCHER=none keeps the stock launcher on, starts the new one without claiming Home first, still makes it Home. */
    @Test fun keepStockLauncherDisablesNothing() = runBlocking {
        val options = LauncherOptions(keepStockLauncher = true)
        val tv = FakeDevice(answers)
        assertEquals("com.gathin.tvhome/.MainActivity", LauncherInstaller(tv).install(apk, options, listedStock = "com.google.android.apps.tv.launcherx"))
        assertFalse(tv.sent.any { it.startsWith("pm disable-user") })
        assertTrue(tv.sent.contains("am start -W -n com.gathin.tvhome/.MainActivity"))
        assertTrue(tv.sent.contains("cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity"))
        val failed = FakeDevice(answers, homeAfterHandover = "com.google.android.apps.tv.launcherx/.home.HomeActivity")
        val e = failure { LauncherInstaller(failed).install(apk, options) }
        assertEquals(SetupIssue.HOME_STAYED, e.issue)
        assertTrue(e.message!!.contains("never turned off"))
        assertFalse(failed.sent.any { it.startsWith("pm enable") || it.startsWith("pm disable-user") })
        // Older profile.json files without the key still load.
        assertEquals(LauncherOptions(homeKeyService = true), Json.decodeFromString(LauncherOptions.serializer(), """{"homeKeyService": true}"""))
    }

    @Test fun secureSettingsFollowTheProfile() = runBlocking {
        // Upstream #2458: an install that doesn't ask for WRITE_SECURE_SETTINGS takes back one an earlier install left.
        val revoke = FakeDevice(answers)
        LauncherInstaller(revoke).install(apk, LauncherOptions())
        assertTrue(revoke.sent.any { it.startsWith("pm revoke com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS") })
        assertFalse(revoke.sent.any { it.startsWith("pm grant com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS") })
        val grant = FakeDevice(answers)
        LauncherInstaller(grant).install(apk, LauncherOptions(restoreKeyServices = true))
        assertTrue(grant.sent.any { it.startsWith("pm grant com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS") })
        // The step's own text contains the marker; only a line that is the marker counts.
        val silent = FakeDevice(answers).apply { secureSettingsAnswer = "" }
        val e = failure { LauncherInstaller(silent).install(apk, LauncherOptions()) }
        assertTrue(e.message!!.contains("system settings"))
        assertFalse(LauncherInstaller.secureSettingsDone(LauncherInstaller.secureSettingsStep(false), false))
        assertTrue(LauncherInstaller.secureSettingsDone("secure-settings-revoked\r\n", false))
    }

    @Test fun failedHandoverPutsTheStockLauncherBack() = runBlocking {
        val tv = FakeDevice(answers, homeAfterHandover = "com.google.android.tungsten.setupwraith/.RecoveryActivity")
        val e = failure { LauncherInstaller(tv).install(apk, LauncherOptions()) }
        assertTrue(tv.sent.contains("pm enable --user 0 com.google.android.apps.tv.launcherx"))
        assertTrue(e.message!!.contains("setup wizard"))
    }

    @Test fun refusesOldAndroidBeforeTouchingAnything() = runBlocking {
        val tv = FakeDevice(listOf("getprop ro.build.version.sdk" to "25"))
        assertEquals(SetupIssue.OLD_ANDROID, failure { LauncherInstaller(tv).install(apk, LauncherOptions()) }.issue)
        assertTrue(tv.pushed.isEmpty())
        assertFalse(tv.sent.any { it.startsWith("pm ") })
    }

    @Test fun startFailureLeavesStockLauncherAlone() = runBlocking {
        val tv = FakeDevice(listOf("getprop ro.build.version.sdk" to "30", "pm install" to "Success", "am start -W" to "Error: Activity not started"))
        assertEquals(SetupIssue.HOME_DID_NOT_START, failure { LauncherInstaller(tv).install(apk, LauncherOptions()) }.issue)
        assertFalse(tv.sent.any { it.startsWith("pm disable-user") })
    }

    // Edge cases (LauncherInstallEdgeTests)

    private val apk2 = ByteArray(2048) { 9 }
    private fun scripted() = ScriptedTV().apply {
        exact["getprop ro.build.version.sdk"] = "30"
        prefixes += DebloatRules.HOME_QUERY to "com.google.android.apps.tv.launcherx/.home.HomeActivity"
    }

    @Test fun damagedUploadInstallsNothing() = runBlocking {
        val tv = scripted().apply { md5Override = "0".repeat(32) }
        assertTrue(failure { LauncherInstaller(tv).install(apk2, LauncherOptions()) }.message!!.contains("damaged"))
        assertFalse(tv.sent.any { it.startsWith("pm install") })
        assertTrue("the damaged file is removed", tv.sent.any { it.startsWith("rm -f") })
    }

    @Test fun differentlySignedBuildIsExplained() = runBlocking {
        val tv = scripted().apply { prefixes.add(0, "pm install" to "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]") }
        assertTrue(failure { LauncherInstaller(tv).install(apk2, LauncherOptions()) }.message!!.contains("another key"))
        assertFalse(tv.sent.any { it.startsWith("pm disable-user") })
    }

    /** LCH-16: a TV with a newer launcher than the app carries refuses the install; the message says so. */
    @Test fun newerBuildOnTheTVIsExplained() = runBlocking {
        val tv = scripted().apply { prefixes.add(0, "pm install" to "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]") }
        assertTrue(failure { LauncherInstaller(tv).install(apk2, LauncherOptions()) }.message!!.contains("newer Home screen"))
        assertFalse(tv.sent.any { it.startsWith("pm disable-user") })
    }

    /** LCH-15: the update reads the installed launcher's version over ADB before installing anything. */
    @Test fun installedVersionComesFromDumpsys() = runBlocking {
        val tv = ScriptedTV().apply { prefixes += "dumpsys package com.gathin.tvhome" to "    versionCode=12 minSdk=26 targetSdk=34" }
        assertEquals(12, LauncherInstaller(tv).installedVersion())
        assertNull("not installed", LauncherInstaller(ScriptedTV()).installedVersion())
        assertNull(LauncherVersion.fromDumpsys("versionCode="))
    }

    @Test fun bundledVersionAndUpdateOffer() {
        assertEquals(13, LauncherVersion.bundled("""{"versionCode": 13}""".toByteArray()))
        assertNull(LauncherVersion.bundled("""{"versionCode": 0}""".toByteArray()))
        assertNull(LauncherVersion.bundled("nope".toByteArray()))
        assertNull(LauncherVersion.bundled(null))
        assertTrue(LauncherVersion.updateAvailable(12, 13))
        assertFalse(LauncherVersion.updateAvailable(13, 13))
        assertFalse(LauncherVersion.updateAvailable(12, null))
    }

    /** LCH-15: the update finds the TV's profile like setup does; the ADB banner has no Android version. */
    @Test fun updateMatchesTheProfileFromBannerPlusGetprop() = runBlocking {
        val banner = mapOf("ro.product.name" to "G03_4K_GB", "ro.product.model" to "Smart_TV_Pro", "ro.product.device" to "BeyondTV4")
        val profiles = DebloatProfile.loadAll(profileSource, includeDevelopment = false)
        assertNull("the banner alone isn't enough", DebloatProfile.match(banner, profiles))
        val tv = ScriptedTV().apply { exact["getprop ro.build.version.sdk"] = "30"; exact["getprop ro.build.version.incremental"] = "AR11" }
        val props = Debloater(tv).profileProperties(banner)
        assertEquals("tcl-43c645", DebloatProfile.match(props, profiles)?.id)
        assertFalse("banner values aren't read again", tv.sent.contains("getprop ro.product.device"))
    }

    /** LCH-15: an update without a theme leaves config.json alone. */
    @Test fun updateWithoutAThemeKeepsTheTVsLayout() = runBlocking {
        val tv = ScriptedTV().apply {
            exact["getprop ro.build.version.sdk"] = "30"
            prefixes += "pm install" to "Success"; prefixes += "am start -W" to "Status: ok"
            prefixes += DebloatRules.HOME_QUERY to "com.gathin.tvhome/.MainActivity"
        }
        LauncherInstaller(tv).install(apk2, LauncherOptions(homeKeyService = true))
        assertNull(tv.pushed["/data/local/tmp/tvhome-config.json"])
        assertFalse(tv.sent.any { it.contains("content write") || it.contains("config.json") })
        assertFalse("Home is already ours: no stock launcher to disable", tv.sent.any { it.startsWith("pm disable-user") })
        assertTrue("the profile's helpers stay on", tv.sent.any { it.contains("HomeKeyService") })
    }

    @Test fun homeChooserWithOneStockLauncherIsResolved() = runBlocking {
        val tv = ScriptedTV().apply {
            prefixes += DebloatRules.HOME_QUERY to "android/com.android.internal.app.ResolverActivity"
            prefixes += DebloatRules.CLAIM_QUERY to "com.google.android.tvlauncher/.MainActivity\ncom.android.tv.settings/.system.FallbackHome"
        }
        assertEquals("com.google.android.tvlauncher", LauncherInstaller(tv).stockLauncher())
    }

    /** LCH-19: a vendor launcher the TV's list names as its stock Home is the one to disable; nothing else unknown is. */
    @Test fun listedVendorLauncherIsTreatedAsStock() = runBlocking {
        val tv = ScriptedTV().apply { prefixes += DebloatRules.HOME_QUERY to "com.xgimi.home/.MainActivity" }
        assertEquals("com.xgimi.home", LauncherInstaller(tv).stockLauncher("com.xgimi.home"))
        assertTrue(failure { LauncherInstaller(tv).stockLauncher("com.other.home") }.message!!.contains("com.xgimi.home"))
        assertTrue(failure { LauncherInstaller(tv).stockLauncher("not a package; reboot") }.message!!.contains("isn't a stock launcher"))
        val chooser = ScriptedTV().apply {
            prefixes += DebloatRules.HOME_QUERY to "android/com.android.internal.app.ResolverActivity"
            prefixes += DebloatRules.CLAIM_QUERY to "com.xgimi.home/.MainActivity\ncom.android.tv.settings/.system.FallbackHome"
        }
        assertEquals("com.xgimi.home", LauncherInstaller(chooser).stockLauncher("com.xgimi.home"))
    }

    @Test fun setupWizardOwningHomeStopsBeforeAnyChange() = runBlocking {
        val tv = ScriptedTV().apply {
            exact["getprop ro.build.version.sdk"] = "30"
            prefixes += DebloatRules.HOME_QUERY to "com.google.android.tungsten.setupwraith/.RecoveryActivity"
        }
        assertTrue(failure { LauncherInstaller(tv).install(apk2, LauncherOptions()) }.message!!.contains("setup wizard"))
        assertTrue(tv.pushed.isEmpty())
    }

    @Test fun themeMustBeAJSONObjectAndAcceptedByTheTV() = runBlocking {
        assertEquals(SetupIssue.INVALID_THEME, failure { LauncherInstaller(ScriptedTV()).applyTheme("[1,2]".toByteArray()) }.issue)
        val refusing = ScriptedTV().apply { prefixes += "{ o=\$(content write" to "theme-rc=1" }
        assertTrue(failure { LauncherInstaller(refusing).applyTheme("{}".toByteArray()) }.message!!.contains("refused"))
    }
}
