package com.guilhermeramalho.puriotv.core

import org.junit.Assert.assertEquals
import org.junit.Test

/** REM-20: the remote's app buttons follow the TV Home dock, then the shortcuts list (as PreferencesTests.swift). */
class RemoteShortcutsTest {
    private val netflix = "com.netflix.ninja"; private val youtube = "com.google.android.youtube.tv"
    private val prime = "com.amazon.amazonvideo.livingroom"; private val disney = "com.disney.disneyplus"
    private val max = "com.wbd.stream"; private val crunchyroll = "com.crunchyroll.crunchyroid"; private val spotify = "com.spotify.tv.android"

    @Test fun followTheDockThenTheList() {
        var preferences = RemotePreferences()
        assertEquals("no TV Home: the list", listOf(netflix, youtube, prime, disney, max, crunchyroll), preferences.remoteShortcutIDs(null))
        assertEquals("a 3-app dock leads, then the list without repeats",
            listOf(spotify, youtube, netflix, prime, disney, max), preferences.remoteShortcutIDs(listOf(spotify, youtube, netflix)))
        assertEquals(youtube, preferences.remoteShortcutIDs(listOf(youtube, "com.unknown.app")).first())
        preferences = preferences.copy(remoteCount = 2)
        assertEquals(listOf(spotify, youtube), preferences.remoteShortcutIDs(listOf(spotify, youtube, netflix)))
        preferences = preferences.copy(remoteOrder = listOf(crunchyroll, netflix), remoteCount = 4)
        assertEquals("the reordered list fills in", listOf(youtube, crunchyroll, netflix), preferences.remoteShortcutIDs(listOf(youtube)))
    }

    @Test fun theRemoteUsesTheDockOnlyOnceATVHomeConnected() {
        val layout = HomeLayout(dockCount = 2, order = listOf(spotify, youtube, netflix))
        val profile = HomeProfile(name = "Personal", layout = layout)
        val base = RemotePreferences(profiles = listOf(profile), profileID = profile.id)
        assertEquals(netflix, base.remoteApps.first().id)
        assertEquals(listOf(spotify, youtube, netflix), base.copy(editorHost = "192.168.0.13").remoteApps.take(3).map { it.id })
    }
}
