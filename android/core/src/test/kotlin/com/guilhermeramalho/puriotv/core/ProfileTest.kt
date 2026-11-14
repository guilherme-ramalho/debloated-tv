package com.guilhermeramalho.puriotv.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Ports of ios/Tests/ProfileTests.swift and ProfileSafetyTests.swift, over the iPhone's bundled Profiles folder. */
class ProfileTest {
    companion object {
        val loaded: List<DebloatProfile> by lazy { DebloatProfile.loadAll(profileSource, includeDevelopment = false) }
        val all: List<DebloatProfile> by lazy { DebloatProfile.loadAll(profileSource, includeDevelopment = true) }
    }

    private fun config(p: DebloatProfile, dock: List<String> = emptyList()): JsonObject =
        Json.parseToJsonElement(p.themeConfig(dock).decodeToString()).jsonObject
    private fun strings(o: JsonObject, key: String) = o[key]!!.jsonArray.map { it.jsonPrimitive.content }

    @Test fun bundledProfilesLoadAndMatchTheirTVs() {
        assertTrue(all.map { it.id }.containsAll(listOf("tcl-43c645", "dev-android-tv-emulator")))
        assertEquals(listOf("dev-android-tv-emulator", "tcl-43c645"), all.filter { !it.isCommunity }.map { it.id }.sorted())
        // The maintainer's TCL, as its getprop reads (recovery kit, 2026-10-22).
        val mine = mapOf("ro.product.device" to "BeyondTV4", "ro.product.name" to "G03_4K_GB", "ro.build.version.incremental" to "AR11",
            "ro.build.version.sdk" to "30", "ro.product.model" to "Smart TV Pro")
        val tcl = DebloatProfile.match(mine, all)!!
        assertEquals("tcl-43c645", tcl.id)
        assertTrue(tcl.list.entries.any { it.packageName == "com.tcl.bi" })
        // Upstream #3533: a 43C641 rebooted on every wake from standby with the TCL account app off.
        assertFalse(tcl.list.entries.any { it.packageName == "com.tcl.usercenter" })
        assertFalse("keeps the remote's app buttons working inside apps", tcl.list.entries.any { it.packageName == "com.tcl.keyhelp" })
        for ((key, other) in listOf("ro.product.name" to "G03_4K_US", "ro.build.version.incremental" to "AR09")) {
            assertNull("$key=$other", DebloatProfile.match(mine + (key to other), all))
        }
        assertTrue("com.tcl.tvinput" in tcl.list.neverDisable)
        assertTrue(tcl.manifest.launcher.homeKeyService)
        assertNull("another Android version is not the tested firmware",
            DebloatProfile.match(mapOf("ro.product.device" to "BeyondTV4", "ro.build.version.sdk" to "31"), all))
        assertEquals("dev-android-tv-emulator", DebloatProfile.match(mapOf("ro.product.model" to "sdk_google_atv64_arm64"), all)?.id)
        assertFalse(loaded.any { it.id == "dev-android-tv-emulator" })
    }

    @Test fun themeGetsTheChosenDock() {
        val tcl = DebloatProfile.load(profileSource, "tcl-43c645")
        val c = config(tcl, listOf("com.netflix.ninja", "not a package"))
        assertEquals(listOf("com.netflix.ninja"), strings(c, "dock_apps"))
        assertEquals(true, c["correct_prehandled_volume_keys"]!!.jsonPrimitive.boolean)
        assertEquals("com.tcl.tv", c["live_tv_package"]!!.jsonPrimitive.content)
        assertEquals("the phone arranges Home; the TV's tile menu stays off", false, c["tile_menu"]!!.jsonPrimitive.boolean)
        assertEquals("no full-screen glow fade on the TCL's GPU", true, c["glow_snap"]!!.jsonPrimitive.boolean)
        assertEquals(listOf("KEYCODE_TCL_NETFLIX:com.netflix.ninja", "KEYCODE_TCL_YOUTUBE:com.google.android.youtube.tv",
            "4099:com.amazon.amazonvideo.livingroom"), strings(c, "app_keys"))
        assertEquals("keys sorted, as the iPhone writes them", c.keys.sorted(), c.keys.toList())
    }

    /** LCH-17: a model whose profile doesn't name remote buttons etc. gets none, never the launcher's built-in TCL ones. */
    @Test fun otherModelsDontInheritTheLaunchersTCLDefaults() {
        val c = config(DebloatProfile.load(profileSource, "dev-android-tv-emulator"))
        assertEquals(emptyList<String>(), strings(c, "app_keys"))
        assertEquals(emptyList<String>(), strings(c, "settings_key_keycodes"))
        assertEquals(emptyList<String>(), strings(c, "hidden_apps"))
        assertEquals("", c["live_tv_package"]!!.jsonPrimitive.content)
        assertEquals("the profile's own values still apply", 5, c["columns"]!!.jsonPrimitive.int)
    }

    /** SET-20 / PRO-*: every folder loads, its id matches the folder, its list parses, and the importer's Home rule holds. */
    @Test fun everyProfileFolderLoads() {
        val folders = profilesRoot.listFiles()!!.filter { it.isDirectory }
        assertTrue(folders.size > 400)
        for (folder in folders) assertEquals("profile.json id matches its folder", folder.name, DebloatProfile.load(profileSource, folder.name).id)
        assertEquals("a folder whose profile or list doesn't load would vanish from setup", folders.size, all.size)
        val community = all.filter { it.isCommunity }
        assertTrue(community.size > 400)
        for (p in community) {
            assertFalse(p.id, p.list.entries.isEmpty())
            assertTrue("community lists are chosen by ProfileMatcher: ${p.id}", p.manifest.match.isEmpty())
            if (p.manifest.homeScreen == true) {
                assertTrue("Home screen only where the list ships a launcher config: ${p.id}", File(File(profilesRoot, p.id), "config.json").isFile)
                assertFalse(p.id, (p.manifest.brand ?: "").contains("amazon", ignoreCase = true))
                assertFalse("no Home screen on CVTE boards: ${p.id}", p.list.entries.any { it.packageName.startsWith("com.cvte.") })
            }
            assertNull(p.id, p.theme["dock_apps"])
        }
    }

    @Test fun noProfileCanDisableCoreOrTheNewHome() {
        for (p in all) {
            assertEquals("${p.id} lists core packages", emptyList<String>(), p.list.entries.map { it.packageName }.filter(DebloatRules::isCore))
            assertFalse(p.id, p.list.entries.any { it.packageName == DebloatRules.CUSTOM_LAUNCHER })
        }
    }

    @Test fun manifestsAreComplete() {
        for (p in all) {
            if (p.isCommunity) {
                assertTrue("${p.id}: a community list has no exact match", p.manifest.match.isEmpty())
                p.manifest.stockLauncher?.let { assertTrue(p.id, Pattern.isPackage(it)) }
            } else {
                assertFalse("${p.id}: an empty match would claim every TV", p.manifest.match.isEmpty())
                assertTrue(p.id, p.manifest.match.values.all { it.isNotEmpty() })
                p.manifest.stockLauncher?.let { assertTrue("${p.id}: unknown stock launcher $it", it in DebloatRules.stockLaunchers) }
            }
            assertTrue(p.id, p.manifest.dockCandidates.all(Pattern::isPackage))
            assertNotNull(p.id, config(p)["dock_apps"])
            assertFalse(p.id, p.list.entries.isEmpty())
        }
    }

    @Test fun noTwoProfilesClaimTheSameTV() {
        for (a in all.filter { !it.isCommunity }) {
            val props = a.manifest.match.mapValues { it.value[0] }
            assertEquals("${a.id} overlaps", listOf(a.id), all.filter { it.matches(props) }.map { it.id })
        }
    }

    @Test fun releaseBuildsHideDevelopmentProfiles() {
        assertTrue(loaded.all { it.manifest.developmentOnly != true })
        assertFalse(loaded.any { it.id.startsWith("dev-") })
    }

    // Community lists (scripts/import-tv-lists.py)

    private fun installed(id: String, extra: List<String> = emptyList()): Set<String> =
        (loaded.first { it.id == id }.list.entries.map { it.packageName } + listOf("com.android.systemui", "com.google.android.tvlauncher") + extra).toSet()

    /** SET-21: the tested TCL profile still wins on the TCL; without it, the lists naming its device come first. */
    @Test fun matcherPrefersTheTestedProfileThenTheModel() {
        val tcl = mapOf("ro.product.device" to "BeyondTV4", "ro.product.name" to "G03_4K_GB", "ro.product.model" to "Smart TV Pro",
            "ro.product.manufacturer" to "TCL", "ro.build.version.sdk" to "30", "ro.build.version.incremental" to "AR11")
        val pkgs = installed("tcl-43c645")
        val ranked = ProfileMatcher.rank(tcl, pkgs, profiles = loaded)
        assertEquals("tcl-43c645", ranked.first().id)
        assertEquals(ProfileMatch.Kind.TESTED, ranked.first().kind)
        val community = ProfileMatcher.rank(tcl, pkgs, profiles = loaded.filter { it.isCommunity })
        assertEquals(ProfileMatch.Kind.MODEL, community.first().kind)
        assertTrue(community.first().id, "BeyondTV4" in community.first().named)
        assertEquals("TCL", community.first().profile.manifest.brand)
    }

    /** SET-22: another brand's TV gets its own model's list. */
    @Test fun matcherFindsTheModelsOwnList() {
        val acer = mapOf("ro.product.device" to "R3", "ro.product.name" to "ACER", "ro.product.model" to "R3",
            "ro.product.manufacturer" to "ACER", "ro.build.version.sdk" to "34")
        val ranked = ProfileMatcher.rank(acer, installed("acer-ar3-r3"), profiles = loaded)
        assertEquals("acer-ar3-r3", ranked.first().id)
        assertEquals(ProfileMatch.Kind.MODEL, ranked.first().kind)
        assertFalse("a shared board name alone doesn't say which list is this TV's",
            ProfileMatcher.rank(acer - "ro.product.name", installed("acer-ar3-r3"), profiles = loaded).any { it.kind == ProfileMatch.Kind.MODEL })
    }

    /** SET-23: a model with no list of its own gets the closest list of its brand, marked as made for another model. */
    @Test fun matcherOffersTheClosestListForAnUnknownModel() {
        val pkgs = installed("tcl-43c645") - "com.tcl.bi"
        val ranked = ProfileMatcher.rank(mapOf("ro.product.device" to "NotARealBoard9", "ro.product.manufacturer" to "TCL"), pkgs,
            profiles = loaded.filter { it.isCommunity })
        assertTrue(ranked.isNotEmpty())
        assertTrue(ranked.all { it.kind == ProfileMatch.Kind.CLOSEST })
        assertEquals("TCL", ranked.first().profile.manifest.brand)
    }

    /** SET-24: nothing is offered for a TV no list resembles. */
    @Test fun matcherOffersNothingForAnUnrelatedTV() {
        val ranked = ProfileMatcher.rank(mapOf("ro.product.device" to "mystery", "ro.product.manufacturer" to "Nobody"),
            setOf("com.android.systemui", "com.google.android.youtube.tv", "org.example.app"), profiles = loaded)
        assertTrue(ranked.joinToString { it.id }, ranked.isEmpty())
    }

    /** SET-28: "made for this model" comes only from the names a list gives its own unit. */
    @Test fun modelClaimsComeFromTheListsOwnNames() {
        val community = loaded.filter { it.isCommunity }
        val us = mapOf("ro.product.device" to "BeyondTV4", "ro.product.name" to "G03_4K_US", "ro.product.manufacturer" to "TCL")
        val models = ProfileMatcher.rank(us, installed("tcl-55s546-us"), profiles = community).filter { it.kind == ProfileMatch.Kind.MODEL }.map { it.id }
        assertTrue("$models", "tcl-55s546-us" in models)
        assertFalse("product BeyondTV6 is another unit", "tcl-beyondtv4-uk" in models)
        assertFalse("product G03_4K_GB is another unit", "tcl-55c725" in models)
        assertEquals(listOf("R3"), community.first { it.id == "acer-ar3-r3" }.manifest.names?.get("device"))
    }

    /** The end-to-end community scenario: on the emulator its own list comes first, the other development list is closest. */
    @Test fun emulatorCommunityListsRankAsTheScenarioExpects() {
        val dev = all.filter { it.isCommunity }
        val emulator = mapOf("ro.product.device" to "emulator64_arm64", "ro.product.name" to "sdk_google_atv64_arm64",
            "ro.product.model" to "sdk_google_atv64_arm64", "ro.product.manufacturer" to "Google")
        val pkgs = setOf("com.google.android.feedback", "com.google.android.partnersetup", "com.google.android.tvrecommendations",
            "com.google.android.marvin.talkback", "com.google.android.tvlauncher", "com.google.android.youtube.tv")
        val ranked = ProfileMatcher.rank(emulator, pkgs, profiles = dev, limit = 50)
        assertEquals("dev-community-model", ranked.first().id)
        assertEquals(ProfileMatch.Kind.MODEL, ranked.first().kind)
        assertEquals(ProfileMatch.Kind.CLOSEST, ranked.first { it.id == "dev-community-closest" }.kind)
    }

    /** Setup loads every list when it opens: keep that quick. */
    @Test fun loadingAllListsIsQuick() {
        val start = System.nanoTime()
        DebloatProfile.loadAll(profileSource, includeDevelopment = false)
        assertTrue((System.nanoTime() - start) / 1e9 < 3)
    }
}
