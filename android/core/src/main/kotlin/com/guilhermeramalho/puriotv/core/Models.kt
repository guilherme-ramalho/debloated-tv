package com.guilhermeramalho.puriotv.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.util.Base64
import java.util.UUID

/** The editor wire schema (LauncherSnapshot and friends in ios/Sources/Core/Preferences.swift). */

/** Swift's Codable writes Data as standard base64. */
object Base64Bytes : KSerializer<ByteArray> {
    override val descriptor = PrimitiveSerialDescriptor("Base64Bytes", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: ByteArray) = encoder.encodeString(Base64.getEncoder().encodeToString(value))
    override fun deserialize(decoder: Decoder): ByteArray = Base64.getDecoder().decode(decoder.decodeString())
}

private val packagePattern = Regex("^[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+$")

@Serializable
data class RemoteApp(
    val id: String,
    val name: String,
    val launchURL: String,
    val logo: String? = null,
    val installed: Boolean? = null,
    val system: Boolean = false,
) {
    companion object {
        fun validPackage(value: String) = value.isNotEmpty() && value.toByteArray().size <= 180 && packagePattern.matches(value)

        val known = listOf(
            RemoteApp("com.netflix.ninja", "Netflix", "https://www.netflix.com/title", "NetflixLogo"),
            RemoteApp("com.google.android.youtube.tv", "YouTube", "https://www.youtube.com", "YouTubeLogo"),
            RemoteApp("com.amazon.amazonvideo.livingroom", "Prime Video", "https://app.primevideo.com", "PrimeVideoLogo"),
            RemoteApp("com.disney.disneyplus", "Disney+", "https://www.disneyplus.com", "DisneyPlusLogo"),
            RemoteApp("com.wbd.stream", "HBO Max", "https://play.max.com", "HBOMaxLogo"),
            RemoteApp("com.crunchyroll.crunchyroid", "Crunchyroll", "crunchyroll://", "CrunchyrollLogo"),
            RemoteApp("com.spotify.tv.android", "Spotify", "spotify:"),
            RemoteApp("com.surfshark.vpnclient.android", "Surfshark", leanback("com.surfshark.vpnclient.android")),
            RemoteApp("live.abplayer.brsilveira", "AB Player", leanback("live.abplayer.brsilveira")),
        )

        private fun leanback(pkg: String) =
            "intent:#Intent;action=android.intent.action.MAIN;category=android.intent.category.LEANBACK_LAUNCHER;package=$pkg;end"
    }
}

@Serializable
data class HomeLayout(
    val dockCount: Int = 5,
    val order: List<String> = RemoteApp.known.map { it.id },
    val hidden: List<String> = emptyList(),
    val wallpaper: String = "quiet-night",
) {
    val dock get() = order.filter { it !in hidden }.take(dockCount)

    fun validate() {
        val ok = dockCount in 1..7 && order.size <= 200 && hidden.size <= 200 &&
            order.toSet().size == order.size && hidden.toSet().size == hidden.size &&
            (order + hidden).all(RemoteApp::validPackage) &&
            (wallpaper in presets || validPhoto(wallpaper))
        if (!ok) throw RemoteFailure(Problem.INVALID_LAYOUT)
    }

    companion object {
        val presets = listOf("quiet-night", "aurora", "dusk")
        fun validPhoto(value: String): Boolean {
            if (!value.startsWith("photo-")) return false
            val rest = value.removePrefix("photo-")
            return rest.length == 36 && runCatching { UUID.fromString(rest) }.isSuccess
        }
    }
}

@Serializable
data class TVInput(val id: String, val name: String, val launchURL: String)

/** The `home` part of a snapshot (1.1+ launchers); null from older ones. */
@Serializable
data class LauncherHome(
    val features: List<String>? = null,
    val weather: Boolean? = null,
    val weatherAuto: Boolean? = null,
    val weatherPlace: String? = null,
    val locationAllowed: Boolean? = null,
    val look: String? = null,
    val version: Int? = null,
) {
    fun supports(feature: String) = features?.contains(feature) ?: false

    companion object {
        val looks = listOf("cinema", "calm", "glass", "gallery")
    }
}

@Serializable
class LauncherSnapshot(
    val revision: String,
    val layout: HomeLayout,
    val apps: List<RemoteApp>,
    val inputs: List<TVInput>,
    val sleepDeadline: Double? = null,
    @Serializable(with = Base64Bytes::class) val wallpaperJPEG: ByteArray? = null,
    val home: LauncherHome? = null,
) {
    fun validate() {
        layout.validate()
        home?.let { h ->
            if ((h.weatherPlace?.length ?: 0) > 60 || (h.features?.size ?: 0) > 32 || (h.look != null && h.look !in LauncherHome.looks))
                throw RemoteFailure(Problem.EDITOR_INVALID, "Invalid TV editor response")
        }
        val ok = revision.length <= 120 && apps.size <= 200 && inputs.size <= 40 && (wallpaperJPEG?.size ?: 0) <= 1_000_000 &&
            apps.all { RemoteApp.validPackage(it.id) && it.name.length <= 120 && it.launchURL.toByteArray().size <= 2048 } &&
            inputs.all { it.id.toByteArray().size <= 512 && it.name.length <= 120 && it.launchURL.toByteArray().size <= 2048 }
        if (!ok) throw RemoteFailure(Problem.EDITOR_INVALID, "Invalid TV editor response")
    }
}
