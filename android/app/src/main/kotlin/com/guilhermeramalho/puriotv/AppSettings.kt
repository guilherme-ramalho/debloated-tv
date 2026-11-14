package com.guilhermeramalho.puriotv

import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.media.ExifInterface
import com.guilhermeramalho.puriotv.core.HomeBackup
import com.guilhermeramalho.puriotv.core.HomeLayout
import com.guilhermeramalho.puriotv.core.HomeProfile
import com.guilhermeramalho.puriotv.core.LauncherSnapshot
import com.guilhermeramalho.puriotv.core.PreferencesJson
import com.guilhermeramalho.puriotv.core.RemoteApp
import com.guilhermeramalho.puriotv.core.RemoteFailure
import com.guilhermeramalho.puriotv.core.RemotePreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

/** The app process: one settings store shared by the screens, widgets and the quick-settings tile. */
class PurioApp : Application() {
    val settings by lazy { AppSettings(this) }
    val store by lazy { Store(this) }
}

val Context.purio get() = applicationContext as PurioApp

/**
 * How a change to the Home draft reaches the TV: edits apply by themselves; switching profile or restoring a backup
 * waits for Apply; loading the TV's own layout needs nothing (LayoutApply in AppSettings.swift).
 */
enum class LayoutApply { AUTO, MANUAL, MATCHES_TV }
data class LayoutChange(val count: Int = 0, val apply: LayoutApply = LayoutApply.AUTO)

/**
 * Saved preferences (AppSettings.swift): `preferences.json` in the app's private files, the iPhone's format. Home
 * backups and wallpaper photos sit beside it. Nothing here leaves the phone except through the TV editor.
 */
class AppSettings(private val context: Context) {
    private val directory = File(context.filesDir, "TVRemote").apply { mkdirs() }
    private val file = File(directory, "preferences.json")
    private val _value: MutableStateFlow<RemotePreferences>
    val value: StateFlow<RemotePreferences>
    private val _layoutChange = MutableStateFlow(LayoutChange())
    /** Bumped on every change to the current profile's layout; the Home editor applies it. */
    val layoutChange: StateFlow<LayoutChange> = _layoutChange
    private val _backups = MutableStateFlow<List<HomeBackup>>(emptyList())
    val backups: StateFlow<List<HomeBackup>> = _backups
    /** A message for an alert (the iPhone's settings.notice); empty when there's none. */
    val notice = MutableStateFlow("")

    init {
        var initial = RemotePreferences.initial(context.getString(R.string.movie_time))
        try {
            if (file.exists()) {
                if (file.length() > 2_000_000) throw UserMessage(context.getString(R.string.preferences_too_large))
                val restored = PreferencesJson.decodeFromString(RemotePreferences.serializer(), file.readText())
                restored.validate(); initial = restored
            } else write(initial)
            _backups.value = directory.listFiles { f -> f.name.startsWith("backup-") }.orEmpty()
                .sortedByDescending { it.lastModified() }.take(20)
                .mapNotNull { f -> runCatching { if (f.length() <= 2_000_000) HomeBackup.decode(f.readBytes()) else null }.getOrNull() }
                .sortedByDescending { it.date }
        } catch (e: Exception) {
            notice.value = context.getString(R.string.preferences_unreadable, e.message ?: "")
        }
        _value = MutableStateFlow(initial)
        value = _value
    }

    private fun write(v: RemotePreferences) {
        val tmp = File(directory, "preferences.json.tmp")
        tmp.writeText(PreferencesJson.encodeToString(RemotePreferences.serializer(), v))
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
    }

    val current get() = _value.value

    fun update(change: (RemotePreferences) -> RemotePreferences) {
        val next = change(_value.value)
        try { next.validate(); write(next); _value.value = next } catch (e: Exception) { notice.value = errorText(context, e); return }
        Widgets.actionsChanged(context)
    }

    val profile: HomeProfile get() = current.profile
    val layout: HomeLayout get() = profile.layout

    fun editLayout(apply: LayoutApply = LayoutApply.AUTO, change: (HomeLayout) -> HomeLayout) {
        val id = profile.id
        val before = layout
        update { s -> s.copy(profiles = s.profiles.map { if (it.id == id) it.copy(layout = change(it.layout)) else it }) }
        if (layout != before || apply != LayoutApply.AUTO) bump(apply)
    }

    private fun bump(apply: LayoutApply) { _layoutChange.value = LayoutChange(_layoutChange.value.count + 1, apply) }

    fun deleteProfile(id: String) {
        if (current.profiles.size <= 1) { notice.value = context.getString(R.string.keep_one_profile); return }
        val before = profile.id
        update { s ->
            val left = s.profiles.filterNot { it.id == id }
            s.copy(profiles = left, profileID = if (left.any { it.id == s.profileID }) s.profileID else left.first().id)
        }
        if (profile.id != before) bump(LayoutApply.MANUAL)
    }

    fun selectProfile(id: String) {
        if (id == current.profileID) return
        update { it.copy(profileID = id) }
        bump(LayoutApply.MANUAL)
    }

    fun addProfile(raw: String) {
        val name = raw.trim()
        if (name.isEmpty() || name.length > 60 || current.profiles.any { it.name.equals(name, ignoreCase = true) }) {
            notice.value = context.getString(R.string.profile_name_rule); return
        }
        val new = HomeProfile(name = name, layout = layout)
        update { it.copy(profiles = it.profiles + new, profileID = new.id) }
    }

    fun app(id: String): RemoteApp? = current.app(id)

    fun merge(snapshot: LauncherSnapshot, host: String) = update { RemotePreferences.merged(it, snapshot, host) }

    // Wallpaper photos: the 16:9 picture sent to the TV, and the uncropped original kept to change the framing later.
    fun photoFile(id: String): File? = if (HomeLayout.validPhoto(id)) File(directory, "$id.jpg") else null
    fun sourceFile(id: String): File? = if (HomeLayout.validPhoto(id)) File(directory, "$id-source.jpg") else null
    fun wallpaperData(layout: HomeLayout): ByteArray? = photoFile(layout.wallpaper)?.takeIf { it.exists() }?.readBytes()

    /** A JPEG at most 1 MB, at most 1920 px: the wallpaper as saved in a backup or imported. */
    fun importPhoto(data: ByteArray): String {
        val bitmap = Images.decode(data, 1920) ?: throw UserMessage(context.getString(R.string.image_unsupported))
        val encoded = Images.jpegUnder(bitmap, 1_000_000) ?: throw UserMessage(context.getString(R.string.image_too_big))
        val id = "photo-" + UUID.randomUUID().toString().uppercase()
        photoFile(id)!!.writeBytes(encoded)
        return id
    }

    /** The photo to frame for this wallpaper: its saved original, or the wallpaper itself for older ones. */
    fun framingSource(id: String): Bitmap? =
        (sourceFile(id)?.takeIf { it.exists() } ?: photoFile(id)?.takeIf { it.exists() })?.let { BitmapFactory.decodeFile(it.path) }

    /** Saves the framed part of [source] ([crop] in its pixels) as a new 1920×1080 wallpaper, keeping the original. */
    fun saveFramedPhoto(source: Bitmap, crop: RectF): String {
        val bounds = Rect(0, 0, source.width, source.height)
        val r = Rect(crop.left.toInt(), crop.top.toInt(), crop.right.toInt(), crop.bottom.toInt())
        if (!r.intersect(bounds) || r.width() < 2 || r.height() < 2) throw UserMessage(context.getString(R.string.frame_failed))
        val out = Bitmap.createBitmap(1920, 1080, Bitmap.Config.ARGB_8888)
        Canvas(out).drawBitmap(source, r, Rect(0, 0, 1920, 1080), Paint(Paint.FILTER_BITMAP_FLAG))
        val encoded = Images.jpegUnder(out, 1_000_000) ?: throw UserMessage(context.getString(R.string.image_too_big))
        out.recycle()
        val id = "photo-" + UUID.randomUUID().toString().uppercase()
        photoFile(id)!!.writeBytes(encoded)
        sourceFile(id)!!.writeBytes(Images.jpeg(source, 85))
        return id
    }

    fun backup(name: String? = null): HomeBackup {
        val b = HomeBackup(name = (name ?: context.getString(R.string.home_backup_name, profile.name)).take(80), layout = layout, wallpaperJPEG = wallpaperData(layout))
        val data = PreferencesJson.encodeToString(HomeBackup.serializer(), b).toByteArray()
        HomeBackup.decode(data)
        File(directory, "backup-${b.id}.json").writeBytes(data)
        _backups.value = (listOf(b) + _backups.value).take(20)
        return b
    }

    fun encode(backup: HomeBackup): ByteArray = PreferencesJson.encodeToString(HomeBackup.serializer(), backup).toByteArray()

    fun restore(backup: HomeBackup) {
        HomeBackup.decode(encode(backup))
        var restored = backup.layout
        backup.wallpaperJPEG?.let { restored = restored.copy(wallpaper = importPhoto(it)) }
        editLayout(LayoutApply.MANUAL) { restored }
    }
}

/** Photo decoding and JPEG sizing for wallpapers (ImageIO in AppSettings.swift / HomeEditor.swift). */
object Images {
    /** Decodes [data] upright, at most [maxSide] px on its longer side. */
    fun decode(data: ByteArray, maxSide: Int): Bitmap? {
        if (data.size > 40_000_000) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        val raw = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val rotation = runCatching {
            when (ExifInterface(data.inputStream()).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f; ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f; else -> 0f
            }
        }.getOrDefault(0f)
        val scale = minOf(1f, maxSide.toFloat() / maxOf(raw.width, raw.height))
        if (rotation == 0f && scale >= 1f) return raw
        val m = Matrix().apply { postScale(scale, scale); postRotate(rotation) }
        return Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, m, true).also { if (it != raw) raw.recycle() }
    }

    fun jpeg(bitmap: Bitmap, quality: Int): ByteArray =
        ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()

    fun jpegUnder(bitmap: Bitmap, limit: Int): ByteArray? = listOf(85, 70, 55, 40).asSequence().map { jpeg(bitmap, it) }.firstOrNull { it.size <= limit }

    /** The photo as the TV shows it: centre-cropped to 16:9 at 1280×720 (HomeEditor.tvWallpaper). */
    fun tvWallpaper(data: ByteArray, failText: String): ByteArray {
        val full = decode(data, 4096) ?: throw UserMessage(failText)
        val out = Bitmap.createBitmap(1280, 720, Bitmap.Config.ARGB_8888)
        val scale = maxOf(1280f / full.width, 720f / full.height)
        val w = full.width * scale; val h = full.height * scale
        Canvas(out).drawBitmap(full, null, RectF((1280 - w) / 2, (720 - h) / 2, (1280 + w) / 2, (720 + h) / 2), Paint(Paint.FILTER_BITMAP_FLAG))
        full.recycle()
        return jpeg(out, 85).also { out.recycle() }.takeIf { it.size <= 1_000_000 }
            ?: throw UserMessage(failText)
    }
}
