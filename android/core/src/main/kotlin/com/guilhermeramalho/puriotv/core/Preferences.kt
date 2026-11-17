package com.guilhermeramalho.puriotv.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.util.UUID

/**
 * The app's saved preferences (Preferences.swift), in the iPhone's JSON format: IDs are upper-case UUID strings and
 * dates are seconds since 1 Jan 2001, as Swift's JSONEncoder writes them, so a Home backup moves between the apps.
 */

fun newId(): String = UUID.randomUUID().toString().uppercase()

/** Swift's default Date coding: a Double of seconds since 2001-01-01T00:00:00Z. Held here as epoch milliseconds. */
object ReferenceDate : KSerializer<Long> {
    const val OFFSET_SECONDS = 978_307_200L
    override val descriptor = PrimitiveSerialDescriptor("ReferenceDate", PrimitiveKind.DOUBLE)
    override fun serialize(encoder: Encoder, value: Long) = encoder.encodeDouble(value / 1000.0 - OFFSET_SECONDS)
    override fun deserialize(decoder: Decoder): Long = ((decoder.decodeDouble() + OFFSET_SECONDS) * 1000).toLong()
}

@Serializable
data class HomeProfile(val id: String = newId(), val name: String, val layout: HomeLayout = HomeLayout())

@Serializable
data class FavoriteInput(val id: String = newId(), val name: String, val inputID: String? = null)

@Serializable
data class ActionStep(val id: String = newId(), val kind: Kind, val argument: String = "") {
    /** `key` (1.1) presses one remote key, its Android keycode in `argument`, from [keys] only. */
    @Serializable
    enum class Kind {
        @SerialName("wake") WAKE, @SerialName("sleep") SLEEP, @SerialName("openApp") OPEN_APP, @SerialName("input") INPUT,
        @SerialName("home") HOME, @SerialName("mute") MUTE, @SerialName("playPause") PLAY_PAUSE, @SerialName("pause") PAUSE,
        @SerialName("volumeUp") VOLUME_UP, @SerialName("volumeDown") VOLUME_DOWN, @SerialName("key") KEY,
    }

    /** The key a `key` step presses, if it is one of [keys]. */
    val key: TVKey? get() = if (kind != Kind.KEY) null else argument.toLongOrNull()?.let(TVKey::of)?.takeIf { it in keys }

    companion object {
        fun of(kind: Kind, argument: String = "") = ActionStep(kind = kind, argument = argument)
        fun key(key: TVKey) = ActionStep(kind = Kind.KEY, argument = key.code.toString())
        val keys = setOf(TVKey.UP, TVKey.DOWN, TVKey.LEFT, TVKey.RIGHT, TVKey.SELECT, TVKey.BACK, TVKey.POWER,
            TVKey.REWIND, TVKey.FAST_FORWARD, TVKey.CAPTIONS, TVKey.SETTINGS)
    }
}

@Serializable
data class QuickAction(val id: String = newId(), val name: String, val steps: List<ActionStep>) {
    fun validate() {
        val ok = name.isNotBlank() && name.length <= 60 && steps.size in 1..12 &&
            steps.all {
                it.argument.toByteArray().size <= 1024 && (it.kind != ActionStep.Kind.OPEN_APP || RemoteApp.validPackage(it.argument)) &&
                    (it.kind != ActionStep.Kind.INPUT || it.argument.isNotEmpty()) && (it.kind != ActionStep.Kind.KEY || it.key != null)
            } &&
            steps.dropLast(1).none { it.kind == ActionStep.Kind.SLEEP }
        if (!ok) throw RemoteFailure(Problem.INVALID_ACTION)
    }
}

@Serializable
data class HomeBackup(
    val version: Int = 1,
    val id: String = newId(),
    val name: String,
    @Serializable(with = ReferenceDate::class) val date: Long = System.currentTimeMillis(),
    val layout: HomeLayout,
    @Serializable(with = Base64Bytes::class) val wallpaperJPEG: ByteArray? = null,
) {
    override fun equals(other: Any?) = other is HomeBackup && other.id == id
    override fun hashCode() = id.hashCode()

    companion object {
        fun decode(data: ByteArray): HomeBackup {
            if (data.size > 2_000_000) throw RemoteFailure(Problem.INVALID_BACKUP, "Backup exceeds 2 MB")
            val backup = try { PreferencesJson.decodeFromString(serializer(), data.decodeToString()) } catch (e: Exception) {
                throw RemoteFailure(Problem.INVALID_BACKUP, e.message)
            }
            backup.layout.validate()
            if (backup.version != 1 || backup.name.length > 80 || (backup.wallpaperJPEG?.size ?: 0) > 1_000_000 ||
                (HomeLayout.validPhoto(backup.layout.wallpaper) && backup.wallpaperJPEG == null)) {
                throw RemoteFailure(Problem.INVALID_BACKUP, "Unsupported or incomplete backup")
            }
            return backup
        }
    }
}

@Serializable
data class RemotePreferences(
    val version: Int = 1,
    val remoteOrder: List<String> = RemoteApp.known.take(6).map { it.id },
    val remoteCount: Int = 6,
    val haptics: Boolean = true,
    val autoReconnect: Boolean = true,
    val profiles: List<HomeProfile> = listOf(HomeProfile(name = "Personal"), HomeProfile(name = "Family")),
    val profileID: String? = null,
    val inputs: List<FavoriteInput> = listOf(FavoriteInput(name = "PlayStation 5"), FavoriteInput(name = "Nintendo Switch")),
    val actions: List<QuickAction> = emptyList(),
    val apps: List<RemoteApp> = RemoteApp.known,
    val tvInputs: List<TVInput> = emptyList(),
    val editorHost: String? = null,
    /** Swipes on the pad move the other way (reverseSwipe in Preferences.swift; missing in older files). */
    val reverseSwipe: Boolean = false,
) {
    fun validate() {
        val ok = version == 1 && remoteCount in 1..12 && remoteOrder.size <= 200 && remoteOrder.toSet().size == remoteOrder.size &&
            remoteOrder.all(RemoteApp::validPackage) && profiles.size in 1..20 && actions.size <= 30 && inputs.size <= 20 &&
            apps.size <= 200 && apps.all { RemoteApp.validPackage(it.id) && it.name.length <= 120 && it.launchURL.toByteArray().size <= 2048 } &&
            inputs.all { it.name.isNotEmpty() && it.name.length <= 60 } &&
            profiles.all { it.name.isNotEmpty() && it.name.length <= 60 } &&
            tvInputs.size <= 40 && tvInputs.all { it.id.toByteArray().size <= 512 && it.name.length <= 120 && it.launchURL.toByteArray().size <= 2048 } &&
            profiles.map { it.id }.toSet().size == profiles.size
        if (!ok) throw RemoteFailure(Problem.INVALID_PREFERENCES)
        profiles.forEach { it.layout.validate() }
        actions.forEach { it.validate() }
    }

    val profile: HomeProfile get() = profiles.firstOrNull { it.id == profileID } ?: profiles[0]
    fun app(id: String): RemoteApp? = apps.firstOrNull { it.id == id }
    /**
     * The remote's app buttons (1.3, remoteShortcutIDs in Preferences.swift): the TV Home dock's apps first, in the
     * dock's order, then the Remote shortcuts list for the rest, no repeats, [remoteCount] in all. [dock] is null
     * when no TV Home has connected (no real dock to follow).
     */
    fun remoteShortcutIDs(dock: List<String>?): List<String> {
        val ids = mutableListOf<String>()
        for (id in (dock ?: emptyList()) + remoteOrder) if (id !in ids && app(id) != null) ids += id
        return ids.take(remoteCount)
    }
    val remoteApps: List<RemoteApp> get() = remoteShortcutIDs(if (editorHost == null) null else profile.layout.dock).mapNotNull(::app)
    /** The shortcuts list only (Roku, LG and Samsung TVs have no Purio Home dock to follow). */
    val shortcutApps: List<RemoteApp> get() = remoteShortcutIDs(null).mapNotNull(::app)

    companion object {
        /** First launch: "Movie time" (wake, then Netflix) with its name in the phone's language. */
        fun initial(movieTime: String): RemotePreferences {
            val base = RemotePreferences()
            return base.copy(profileID = base.profiles.first().id, actions = listOf(
                QuickAction(name = movieTime, steps = listOf(ActionStep.of(ActionStep.Kind.WAKE), ActionStep.of(ActionStep.Kind.OPEN_APP, "com.netflix.ninja"))),
            ))
        }

        /** Copies the TV's app list and inputs, keeping the phone's logos and launch links for known apps (AppSettings.merge). */
        fun merged(value: RemotePreferences, snapshot: LauncherSnapshot, host: String) = value.copy(
            tvInputs = snapshot.inputs, editorHost = host,
            apps = snapshot.apps.map { item ->
                val known = RemoteApp.known.firstOrNull { it.id == item.id }
                item.copy(logo = known?.logo, launchURL = known?.launchURL ?: item.launchURL)
            },
        )
    }
}

val PreferencesJson = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }
