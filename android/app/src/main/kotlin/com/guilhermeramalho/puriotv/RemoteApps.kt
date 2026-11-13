package com.guilhermeramalho.puriotv

import androidx.annotation.DrawableRes
import androidx.compose.ui.graphics.Color

/** The remote's app shortcuts: the iPhone's default list (RemoteApp.known in Preferences.swift), same links. */
data class RemoteApp(val id: String, val name: String, val launchUrl: String, @DrawableRes val logo: Int? = null) {
    /** Brand colour behind the logo (StreamingBrand.color in QuietStyle.swift). */
    val color: Color get() = when (id) {
        "com.netflix.ninja" -> Color(0xFFE50914)
        "com.google.android.youtube.tv" -> Color(0xFFFF3B30)
        "com.amazon.amazonvideo.livingroom" -> Color(0xFF0083BA)
        "com.disney.disneyplus" -> Color(0xFF005C63)
        "com.crunchyroll.crunchyroid" -> Color(0xFFFF640A)
        "com.spotify.tv.android" -> Color(0xFF17683D)
        "com.surfshark.vpnclient.android" -> Color(0xFF176E78)
        "live.abplayer.brsilveira" -> Color(0xFF294B83)
        else -> Color(0xFF151518)
    }

    /** Logo height in the button, as on the iPhone (wordmarks differ in weight). */
    val logoHeight: Int get() = when (name) { "Disney+" -> 42; "HBO Max" -> 36; else -> 33 }

    companion object {
        private fun leanback(pkg: String) =
            "intent:#Intent;action=android.intent.action.MAIN;category=android.intent.category.LEANBACK_LAUNCHER;package=$pkg;end"

        val known = listOf(
            RemoteApp("com.netflix.ninja", "Netflix", "https://www.netflix.com/title", R.drawable.logo_netflix),
            RemoteApp("com.google.android.youtube.tv", "YouTube", "https://www.youtube.com", R.drawable.logo_youtube),
            RemoteApp("com.amazon.amazonvideo.livingroom", "Prime Video", "https://app.primevideo.com", R.drawable.logo_primevideo),
            RemoteApp("com.disney.disneyplus", "Disney+", "https://www.disneyplus.com", R.drawable.logo_disneyplus),
            RemoteApp("com.wbd.stream", "HBO Max", "https://play.max.com", R.drawable.logo_hbomax),
            RemoteApp("com.crunchyroll.crunchyroid", "Crunchyroll", "crunchyroll://", R.drawable.logo_crunchyroll),
            RemoteApp("com.spotify.tv.android", "Spotify", "spotify:", R.drawable.logo_spotify),
            RemoteApp("com.surfshark.vpnclient.android", "Surfshark", leanback("com.surfshark.vpnclient.android")),
            RemoteApp("live.abplayer.brsilveira", "AB Player", leanback("live.abplayer.brsilveira")),
        )

        /** A readable name for the app on the TV's screen, or null for system screens. */
        fun nameOf(pkg: String?): String? = pkg?.let { p -> known.firstOrNull { it.id == p }?.name ?: TVNames.of(p) }
    }
}

private object TVNames {
    private val names = mapOf(
        "com.hbo.hbonow" to "HBO Max", "com.google.android.tvlauncher" to "Home", "com.google.android.apps.tv.launcherx" to "Home",
        "com.gathin.tvhome" to "Home", "com.android.tv.settings" to "Settings", "com.plexapp.android" to "Plex",
        "com.apple.atve.androidtv.appletv" to "Apple TV", "tv.twitch.android.app" to "Twitch", "com.dazn" to "DAZN", "com.tubitv" to "Tubi",
    )
    fun of(pkg: String) = names[pkg]
}
