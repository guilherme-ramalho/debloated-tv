package com.guilhermeramalho.puriotv

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.guilhermeramalho.puriotv.core.RemoteApp

/** Streaming brands: colour behind the logo and the logo itself (StreamingBrand in QuietStyle.swift). */
object Brand {
    fun color(id: String): Color = when (id) {
        "com.netflix.ninja" -> Color(0xFFE50914)
        "com.google.android.youtube.tv" -> Color(0xFFFF3B30)
        "com.amazon.amazonvideo.livingroom" -> Color(0xFF0083BA)
        "com.disney.disneyplus" -> Color(0xFF005C63)
        "com.crunchyroll.crunchyroid" -> Color(0xFFFF640A)
        "com.spotify.tv.android" -> Color(0xFF17683D)
        "com.surfshark.vpnclient.android" -> Color(0xFF176E78)
        "live.abplayer.brsilveira" -> Color(0xFF294B83)
        "com.cbs.ott", "com.cbs.ca" -> Color(0xFF0050FF)
        "tv.twitch.android.app", "tv.twitch.android.viewer" -> Color(0xFF6441A5)
        else -> Color(0xFF151518)
    }

    @DrawableRes
    fun logo(id: String): Int? = when (id) {
        "com.netflix.ninja" -> R.drawable.logo_netflix
        "com.google.android.youtube.tv" -> R.drawable.logo_youtube
        "com.amazon.amazonvideo.livingroom" -> R.drawable.logo_primevideo
        "com.disney.disneyplus" -> R.drawable.logo_disneyplus
        "com.wbd.stream" -> R.drawable.logo_hbomax
        "com.crunchyroll.crunchyroid" -> R.drawable.logo_crunchyroll
        "com.spotify.tv.android" -> R.drawable.logo_spotify
        "com.plexapp.android" -> R.drawable.logo_plex
        "tv.twitch.android.app", "tv.twitch.android.viewer" -> R.drawable.logo_twitch
        "com.tubitv" -> R.drawable.logo_tubi
        "com.dazn" -> R.drawable.logo_dazn
        "com.apple.atve.androidtv.appletv", "com.apple.atve.sony.appletv" -> R.drawable.logo_appletv
        "com.cbs.ott", "com.cbs.ca" -> R.drawable.logo_paramountplus
        else -> null
    }

    /** Logo height in the remote's button, as on the iPhone (wordmarks differ in weight). */
    fun logoHeight(id: String): Int = when (id) { "com.disney.disneyplus" -> 42; "com.wbd.stream" -> 36; else -> 33 }

    /** A readable name for the app on the TV's screen, or null for unknown ones. */
    fun nameOf(pkg: String?): String? = pkg?.let { p -> RemoteApp.known.firstOrNull { it.id == p }?.name ?: names[p] }

    private val names = mapOf(
        "com.hbo.hbonow" to "HBO Max", "com.google.android.tvlauncher" to "Home", "com.google.android.apps.tv.launcherx" to "Home",
        "com.gathin.tvhome" to "Home", "com.android.tv.settings" to "Settings", "com.plexapp.android" to "Plex",
        "com.apple.atve.androidtv.appletv" to "Apple TV", "tv.twitch.android.app" to "Twitch", "com.dazn" to "DAZN", "com.tubitv" to "Tubi",
    )
}

/** The app's logo (white) or its name, sized to fit (StreamingLogo). */
@Composable
fun StreamingLogo(app: RemoteApp?, modifier: Modifier = Modifier, fontSize: Int = 11) {
    val logo = app?.let { Brand.logo(it.id) }
    Box(modifier, contentAlignment = Alignment.Center) {
        if (logo != null) Image(painterResource(logo), null, colorFilter = ColorFilter.tint(Color.White), modifier = Modifier.fillMaxSize())
        else Text(app?.name ?: "?", color = Color.White, fontSize = fontSize.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, textAlign = TextAlign.Center)
    }
}

/** A small brand tile for lists (AppBadge). */
@Composable
fun AppBadge(app: RemoteApp?) {
    Box(Modifier.size(36.dp).background(Brand.color(app?.id ?: "").copy(alpha = 0.7f), RoundedCornerShape(10.dp)).padding(5.dp)) {
        StreamingLogo(app, Modifier.fillMaxSize(), fontSize = 9)
    }
}
