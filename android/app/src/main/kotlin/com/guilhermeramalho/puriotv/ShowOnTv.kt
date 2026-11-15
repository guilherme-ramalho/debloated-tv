package com.guilhermeramalho.puriotv

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.util.LruCache
import android.util.Size
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.StringRes
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Forward10
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.Replay10
import androidx.compose.material.icons.rounded.Slideshow
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.guilhermeramalho.puriotv.core.CastController
import com.guilhermeramalho.puriotv.core.CastFollower
import com.guilhermeramalho.puriotv.core.CastMediaStatus
import com.guilhermeramalho.puriotv.core.CastSession
import com.guilhermeramalho.puriotv.core.LocalAddress
import com.guilhermeramalho.puriotv.core.MediaServer
import com.guilhermeramalho.puriotv.core.Problem
import com.guilhermeramalho.puriotv.core.RemoteFailure
import com.guilhermeramalho.puriotv.core.TVKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.text.DateFormat
import java.util.Date
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// Show on TV (ShowOnTV.swift): the phone's photos and videos, browsed like a gallery; whatever is open full screen also
// appears on the TV through its built-in Cast player (core: Cast.kt, MediaServer.kt). Nothing runs until the library
// opens; closing it stops the TV's player, the local server and deletes the prepared photos.

private const val TAG = "ShowOnTV"

/** One photo or video from MediaStore. */
data class LibraryItem(
    val id: Long, val video: Boolean, val uri: Uri, val takenMillis: Long, val durationMillis: Long,
    val width: Int, val height: Int, val size: Long, val mime: String, val favourite: Boolean,
)

enum class LibrarySection(@StringRes val title: Int) { ALL(R.string.section_all), VIDEOS(R.string.section_videos), FAVOURITES(R.string.section_favourites) }

object PhoneLibrary {
    /** Oldest first, so the grid opens at the bottom on the newest, as in Photos. */
    fun load(context: Context, section: LibrarySection): List<LibraryItem> {
        val uri = MediaStore.Files.getContentUri("external")
        val columns = mutableListOf(MediaStore.Files.FileColumns._ID, MediaStore.Files.FileColumns.MEDIA_TYPE, MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DATE_TAKEN, MediaStore.MediaColumns.DURATION, MediaStore.MediaColumns.WIDTH, MediaStore.MediaColumns.HEIGHT,
            MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.MIME_TYPE)
        if (Build.VERSION.SDK_INT >= 30) columns += MediaStore.MediaColumns.IS_FAVORITE
        val image = MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE; val video = MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
        var where = when (section) {
            LibrarySection.VIDEOS -> "${MediaStore.Files.FileColumns.MEDIA_TYPE}=$video"
            else -> "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN ($image,$video)"
        }
        if (section == LibrarySection.FAVOURITES && Build.VERSION.SDK_INT >= 30) where += " AND ${MediaStore.MediaColumns.IS_FAVORITE}=1"
        val items = mutableListOf<LibraryItem>()
        context.contentResolver.query(uri, columns.toTypedArray(), where, null, "${MediaStore.MediaColumns.DATE_ADDED} ASC")?.use { c ->
            val favouriteColumn = if (Build.VERSION.SDK_INT >= 30) c.getColumnIndex(MediaStore.MediaColumns.IS_FAVORITE) else -1
            while (c.moveToNext()) {
                val id = c.getLong(0); val isVideo = c.getInt(1) == video
                val base = if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                val taken = if (c.isNull(3)) c.getLong(2) * 1000 else c.getLong(3)
                items += LibraryItem(id, isVideo, ContentUris.withAppendedId(base, id), taken, if (c.isNull(4)) 0 else c.getLong(4),
                    c.getInt(5), c.getInt(6), c.getLong(7), c.getString(8) ?: if (isVideo) "video/mp4" else "image/jpeg",
                    favouriteColumn >= 0 && c.getInt(favouriteColumn) == 1)
            }
        }
        return items
    }

    /** Grid thumbnails, kept for the cells around the screen (about 25 MB). */
    private val thumbnails = object : LruCache<Long, Bitmap>(24 * 1024 * 1024) {
        override fun sizeOf(key: Long, value: Bitmap) = value.byteCount
    }
    fun cachedThumbnail(item: LibraryItem): Bitmap? = thumbnails.get(item.id)
    suspend fun thumbnail(context: Context, item: LibraryItem, side: Int): Bitmap? = withContext(Dispatchers.IO) {
        thumbnails.get(item.id) ?: runCatching {
            if (Build.VERSION.SDK_INT >= 29) context.contentResolver.loadThumbnail(item.uri, Size(side, side), null)
            else if (item.video) @Suppress("DEPRECATION") MediaStore.Video.Thumbnails.getThumbnail(context.contentResolver, item.id, MediaStore.Video.Thumbnails.MINI_KIND, null)
            else @Suppress("DEPRECATION") MediaStore.Images.Thumbnails.getThumbnail(context.contentResolver, item.id, MediaStore.Images.Thumbnails.MINI_KIND, null)
        }.getOrNull()?.also { thumbnails.put(item.id, it) }
    }
    fun clearThumbnails() = thumbnails.evictAll()

    /** A picture at most [maxSide] pixels on its long side, upright. Videos give their cover frame. */
    suspend fun picture(context: Context, item: LibraryItem, maxSide: Int): Bitmap? = withContext(Dispatchers.IO) {
        runCatching {
            if (item.video) {
                if (Build.VERSION.SDK_INT >= 29) context.contentResolver.loadThumbnail(item.uri, Size(maxSide, maxSide), null)
                else @Suppress("DEPRECATION") MediaStore.Video.Thumbnails.getThumbnail(context.contentResolver, item.id, MediaStore.Video.Thumbnails.FULL_SCREEN_KIND, null)
            } else if (Build.VERSION.SDK_INT >= 28) {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, item.uri)) { decoder, info, _ ->
                    val scale = min(1f, maxSide.toFloat() / max(info.size.width, info.size.height))
                    decoder.setTargetSize(max(1, (info.size.width * scale).toInt()), max(1, (info.size.height * scale).toInt()))
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }
            } else decodeOld(context, item, maxSide)
        }.getOrNull()
    }
    private fun decodeOld(context: Context, item: LibraryItem, maxSide: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(item.uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        val bitmap = context.contentResolver.openInputStream(item.uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) } ?: return null
        val rotation = context.contentResolver.query(item.uri, arrayOf(MediaStore.Images.ImageColumns.ORIENTATION), null, null, null)?.use { if (it.moveToFirst()) it.getInt(0) else 0 } ?: 0
        if (rotation == 0) return bitmap
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(rotation.toFloat()) }, true)
    }
}

/** The video straight from MediaStore, read from any offset without going through the bytes before it. */
private class ContentSource(private val context: Context, private val uri: Uri, override val size: Long, override val contentType: String) : MediaServer.Source {
    override fun open(offset: Long): InputStream {
        val descriptor = context.contentResolver.openAssetFileDescriptor(uri, "r") ?: throw RemoteFailure(Problem.VIDEO_UNREADABLE)
        val stream = FileInputStream(descriptor.fileDescriptor)
        stream.channel.position(descriptor.startOffset + offset)
        return object : InputStream() {
            override fun read() = stream.read()
            override fun read(b: ByteArray, off: Int, len: Int) = stream.read(b, off, len)
            override fun close() { stream.close(); descriptor.close() }
        }
    }
}

/**
 * The TV side of the library (ShowOnTVModel): one Cast session, the server for what's on the TV, and the photo or video
 * that follows the phone. Lives only while the library is open.
 */
class ShowOnTvModel(private val context: Context, val host: String, val tvName: String, private val scope: CoroutineScope) {
    enum class Tv { OFF, OPENING, ON, PAUSED, FAILED }
    data class State(
        val tv: Tv = Tv.OFF, val media: CastMediaStatus? = null, val mediaAt: Long = 0, val shownId: Long? = null,
        val endedId: Long? = null, val problem: Problem? = null, val problemIsItem: Boolean = false, val failure: Problem? = null,
    )
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state
    private var session: CastSession? = null
    private val server = MediaServer()
    private val follower = CastFollower()
    private var focused: LibraryItem? = null
    private var neighbours: List<LibraryItem> = emptyList()
    private var shownItem: LibraryItem? = null
    private var settleJob: Job? = null
    private var sendJob: Job? = null
    private var prefetchJob: Job? = null
    private var refreshJob: Job? = null
    private var openedAt = 0L
    private var itemStarted = false
    private val prepared = mutableMapOf<Long, File>()
    private val folder = File(context.cacheDir, "ShowOnTV").apply { deleteRecursively() }   // left over if the app was killed

    init { server.requestLog = { method, shared, range -> Log.i(TAG, "TV fetched ($method${if (shared) "" else ", unknown path"}${range?.let { ", $it" } ?: ""})") } }

    fun focus(item: LibraryItem, around: List<LibraryItem>) {
        focused = item; neighbours = around
        follower.focused(item.id.toString())
        settleJob?.cancel()
        settleJob = scope.launch { delay(360); sendIfDue() }
    }
    fun toggleSending() {
        when (_state.value.tv) {
            Tv.PAUSED, Tv.FAILED -> { _state.update { it.copy(tv = if (it.shownId == null) Tv.OFF else Tv.ON, failure = null) }; follower.forget(); sendIfDue() }
            else -> _state.update { it.copy(tv = Tv.PAUSED) }
        }
    }
    fun play() = session?.play()
    fun pause() = session?.pause()
    fun seek(seconds: Double) {
        val media = _state.value.media
        val target = seconds.coerceIn(0.0, media?.duration ?: seconds)
        session?.seek(target)
        if (media != null) _state.update { it.copy(media = media.copy(currentTime = target), mediaAt = System.currentTimeMillis()) }
    }
    fun skip(seconds: Double) = seek(position(System.currentTimeMillis()) + seconds)
    fun position(now: Long): Double {
        val s = _state.value; val media = s.media ?: return 0.0
        val moved = if (media.playerState == "PLAYING") (now - s.mediaAt) / 1000.0 else 0.0
        return min(media.currentTime + moved, media.duration ?: Double.MAX_VALUE)
    }
    fun dismissProblem() = _state.update { it.copy(problem = null) }
    fun stopOnTv() {
        sendJob?.cancel(); session?.stop(); session = null
        follower.forget()
        _state.update { it.copy(tv = Tv.PAUSED, shownId = null, media = null, endedId = null) }
    }
    fun close() {
        settleJob?.cancel(); sendJob?.cancel(); prefetchJob?.cancel(); refreshJob?.cancel()
        session?.stop(); session = null
        server.close()
        folder.deleteRecursively(); prepared.clear()
        PhoneLibrary.clearThumbnails()
    }
    fun playAgain() {
        val item = shownItem ?: return
        if (_state.value.endedId != item.id) return
        _state.update { it.copy(endedId = null) }
        follower.forget()
        sendJob?.cancel()
        sendJob = scope.launch { send(item) }
    }

    private fun sendIfDue() {
        val s = _state.value
        if (s.tv == Tv.PAUSED || s.tv == Tv.FAILED) return
        val item = focused ?: return
        if (follower.due() != item.id.toString()) return
        sendJob?.cancel()
        sendJob = scope.launch { send(item) }
    }

    private suspend fun send(item: LibraryItem) {
        if (session == null) { _state.update { it.copy(tv = Tv.OPENING) }; openedAt = System.currentTimeMillis() }
        Log.i(TAG, "send ${if (item.video) "video ${item.durationMillis / 1000} s ${item.width}x${item.height}" else "photo ${item.width}x${item.height}"}")
        try {
            val address = withContext(Dispatchers.IO) { LocalAddress.current(host) } ?: throw RemoteFailure(Problem.NOT_ON_TV_WIFI)
            val port = withContext(Dispatchers.IO) { server.start() }
            val (path, type) = if (item.video) {
                server.share(ContentSource(context, item.uri, item.size, item.mime), "video.${if (item.mime.contains("quicktime")) "mov" else "mp4"}") to item.mime
            } else {
                val file = photoFile(item, ahead = false)
                server.share(MediaServer.FileSource(file, "image/jpeg"), "photo.jpg") to "image/jpeg"
            }
            val session = session ?: CastSession(host) { event -> scope.launch { handle(event) } }.also { session = it }
            shownItem = item
            itemStarted = false
            _state.update { it.copy(shownId = item.id, endedId = null, media = null) }
            session.load(CastController.Load("http://$address:$port$path", type, DateFormat.getDateTimeInstance().format(Date(item.takenMillis))))
            if (!item.video) prefetch(item)
        } catch (e: RemoteFailure) {
            report(e.problem, item = true)
        } catch (e: kotlinx.coroutines.CancellationException) { throw e
        } catch (e: Exception) { Log.w(TAG, "send failed", e); report(if (item.video) Problem.VIDEO_UNREADABLE else Problem.PHOTO_UNREADABLE, item = true) }
    }
    private fun report(problem: Problem, item: Boolean) {
        follower.forget()
        _state.update { it.copy(tv = if (it.tv == Tv.OPENING) (if (it.shownId == null) Tv.OFF else Tv.ON) else it.tv, problem = problem, problemIsItem = item) }
    }

    private fun handle(event: CastController.Event) {
        when (event) {
            CastController.Event.Ready -> { Log.i(TAG, "TV player ready after ${System.currentTimeMillis() - openedAt} ms"); _state.update { if (it.tv == Tv.OPENING) it.copy(tv = Tv.ON) else it } }
            is CastController.Event.Media -> {
                val status = event.status
                if (status.playerState != _state.value.media?.playerState) Log.i(TAG, "TV ${status.playerState} ${status.idleReason ?: ""} at ${status.currentTime.toInt()} s")
                _state.update { it.copy(tv = if (it.tv == Tv.OPENING) Tv.ON else it.tv, media = status, mediaAt = System.currentTimeMillis()) }
                if (status.playerState != "IDLE" || status.idleReason == "FINISHED") itemStarted = true
                val item = shownItem
                if (item?.video == true && status.playing) startRefreshing()
                if (status.idleReason == "ERROR") loadFailed()
                if (item?.video == true && status.idleReason == "FINISHED" && _state.value.endedId != item.id) videoEnded(item)
            }
            CastController.Event.LoadFailed -> if (!itemStarted) loadFailed()
            CastController.Event.ReceiverGone -> {
                session = null; follower.forget()
                _state.update { it.copy(tv = if (it.tv == Tv.PAUSED) Tv.PAUSED else Tv.OFF, shownId = null, media = null) }
            }
            is CastController.Event.Failed -> {
                val wasOn = _state.value.tv == Tv.ON
                session = null; follower.forget()
                if (wasOn) { _state.update { it.copy(tv = Tv.OFF, shownId = null, media = null) }; sendIfDue(); return }
                _state.update { it.copy(tv = Tv.FAILED, failure = event.problem, problem = event.problem, problemIsItem = false, shownId = null, media = null) }
            }
        }
    }
    private fun loadFailed() {
        val video = shownItem?.video == true
        _state.update { it.copy(problem = if (video) Problem.VIDEO_UNREADABLE else Problem.PHOTO_UNREADABLE, problemIsItem = true, shownId = null) }
    }
    /** The video ended: show its cover frame on the TV rather than a black screen, and offer Play again. */
    private fun videoEnded(item: LibraryItem) {
        Log.i(TAG, "video finished: showing its cover frame on the TV")
        _state.update { it.copy(endedId = item.id, media = null) }
        sendJob?.cancel()
        sendJob = scope.launch {
            val bitmap = PhoneLibrary.picture(context, item, 1920) ?: return@launch
            val file = withContext(Dispatchers.IO) { File(folder.apply { mkdirs() }, "cover-${item.id}.jpg").also { f -> f.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) } } }
            val address = withContext(Dispatchers.IO) { LocalAddress.current(host) } ?: return@launch
            val port = server.port ?: return@launch
            itemStarted = false
            session?.load(CastController.Load("http://$address:$port${server.share(MediaServer.FileSource(file, "image/jpeg"), "cover.jpg")}", "image/jpeg", ""))
        }
    }
    private fun startRefreshing() {
        if (refreshJob?.isActive == true) return
        refreshJob = scope.launch {
            while (isActive) {
                delay(5_000)
                if (_state.value.media?.playing != true) break
                session?.refresh()
            }
        }
    }

    /** The photo as a JPEG at most 1920 px (the TV's apps draw at 1920 × 1080), upright, without metadata. */
    private suspend fun photoFile(item: LibraryItem, ahead: Boolean): File {
        prepared[item.id]?.takeIf { it.exists() }?.let { Log.i(TAG, "photo ready (prepared ahead)"); return it }
        val started = System.currentTimeMillis()
        val bitmap = PhoneLibrary.picture(context, item, 1920) ?: throw RemoteFailure(Problem.PHOTO_UNREADABLE)
        val file = withContext(Dispatchers.IO) {
            File(folder.apply { mkdirs() }, "${item.id}.jpg").also { f -> f.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) } }
        }
        Log.i(TAG, "${if (ahead) "prepared ahead: " else ""}photo converted in ${System.currentTimeMillis() - started} ms (${file.length() / 1024} KB)")
        prepared[item.id] = file
        return file
    }
    private fun prefetch(item: LibraryItem) {
        prefetchJob?.cancel()
        val keep = (listOf(item) + neighbours).map { it.id }.toSet()
        prepared.keys.filter { it !in keep }.forEach { prepared.remove(it)?.delete() }
        val todo = neighbours.filter { !it.video && prepared[it.id] == null }
        if (todo.isEmpty()) return
        prefetchJob = scope.launch { for (photo in todo) runCatching { photoFile(photo, ahead = true) } }
    }
}

// MARK: - Screens

/** The library and its viewer, full screen over the remote (ShowOnTVView). */
@Composable
fun ShowOnTvScreen(remote: RemoteModel, remoteState: RemoteModel.State, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val tv = remember { ShowOnTvModel(context.applicationContext, remoteState.host, remoteState.tvName.ifEmpty { remoteState.host }, scope) }
    DisposableEffect(Unit) { onDispose { tv.close() } }
    val close = { tv.close(); onClose() }
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize(), color = Quiet.background) {
            var access by remember { mutableStateOf(MediaAccess.check(context)) }
            val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { access = MediaAccess.check(context) }
            LaunchedEffect(Unit) { if (access == MediaAccess.State.UNKNOWN) ask.launch(MediaAccess.permissions) }
            when (access) {
                MediaAccess.State.FULL, MediaAccess.State.PARTIAL -> Library(tv, remote, remoteState, access == MediaAccess.State.PARTIAL, { ask.launch(MediaAccess.permissions) }, close)
                MediaAccess.State.DENIED -> NoAccess(close) { ask.launch(MediaAccess.permissions) }
                MediaAccess.State.UNKNOWN -> Box(Modifier.fillMaxSize())
            }
        }
    }
}

object MediaAccess {
    enum class State { UNKNOWN, FULL, PARTIAL, DENIED }
    val permissions: Array<String> = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }
    private var asked = false
    fun check(context: Context): State {
        fun granted(p: String) = context.checkSelfPermission(p) == android.content.pm.PackageManager.PERMISSION_GRANTED
        return when {
            Build.VERSION.SDK_INT >= 33 && granted(Manifest.permission.READ_MEDIA_IMAGES) -> State.FULL
            Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> State.PARTIAL
            Build.VERSION.SDK_INT < 33 && granted(Manifest.permission.READ_EXTERNAL_STORAGE) -> State.FULL
            !asked -> { asked = true; State.UNKNOWN }
            else -> State.DENIED
        }
    }
}

@Composable
private fun Library(tv: ShowOnTvModel, remote: RemoteModel, remoteState: RemoteModel.State, partial: Boolean, chooseMore: () -> Unit, close: () -> Unit) {
    val context = LocalContext.current
    var section by remember { mutableStateOf(LibrarySection.ALL) }
    var items by remember { mutableStateOf<List<LibraryItem>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var viewer by remember { mutableStateOf<Pair<List<LibraryItem>, Int>?>(null) }
    var slideshow by remember { mutableStateOf(false) }
    var lastOpened by remember { mutableStateOf<Long?>(null) }
    var selecting by remember { mutableStateOf(false) }
    val selected = remember { mutableStateListOf<Long>() }
    LaunchedEffect(section, partial) { items = withContext(Dispatchers.IO) { PhoneLibrary.load(context, section) }; loaded = true }
    BackHandler(viewer == null) { close() }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).clip(CircleShape).clickable(onClick = close).semantics { contentDescription = "close" }, contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Close, stringResource(R.string.close), tint = Quiet.cyan)
            }
            Text(stringResource(R.string.show_on_tv), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White, modifier = Modifier.weight(1f).padding(start = 4.dp))
            TvPill(tv)
        }
        val sections = if (Build.VERSION.SDK_INT >= 30) LibrarySection.entries else listOf(LibrarySection.ALL, LibrarySection.VIDEOS)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 8.dp)) {
            sections.forEachIndexed { i, s ->
                SegmentedButton(selected = section == s, onClick = { section = s }, shape = SegmentedButtonDefaults.itemShape(i, sections.size)) { Text(stringResource(s.title)) }
            }
        }
        if (partial) TextButton(onClick = chooseMore, modifier = Modifier.align(Alignment.CenterHorizontally)) { Text(stringResource(R.string.choose_more_photos), fontSize = 13.sp) }
        if (loaded && items.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Text(stringResource(if (section == LibrarySection.FAVOURITES) R.string.no_favourites else R.string.no_media), color = Quiet.muted)
            }
        } else {
            val grid = rememberLazyGridState()
            LaunchedEffect(items) { if (items.isNotEmpty()) grid.scrollToItem(items.lastIndex) }
            LazyVerticalGrid(GridCells.Fixed(4), state = grid, modifier = Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(2.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                itemsIndexed(items, key = { _, item -> item.id }) { index, item ->
                    Thumbnail(item, item.id == lastOpened && !selecting, if (selecting) item.id in selected else null) {
                        if (selecting) { if (item.id in selected) selected.remove(item.id) else if (!item.video) selected.add(item.id) }
                        else { slideshow = false; viewer = items to index }
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().background(Quiet.background).padding(horizontal = 18.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            val canSlideshow = if (selecting) selected.isNotEmpty() else items.any { !it.video }
            TextButton(enabled = canSlideshow, onClick = {
                if (selecting) {
                    val chosen = selected.mapNotNull { id -> items.firstOrNull { it.id == id } }
                    selecting = false; selected.clear()
                    if (chosen.isNotEmpty()) { slideshow = true; viewer = chosen to 0 }
                } else {
                    val start = items.indexOfFirst { it.id == lastOpened }.takeIf { it >= 0 } ?: items.indexOfFirst { !it.video }.coerceAtLeast(0)
                    slideshow = true; viewer = items to start
                }
            }) { Text(if (selecting && selected.isNotEmpty()) stringResource(R.string.slideshow_count, selected.size) else stringResource(R.string.slideshow)) }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { selecting = !selecting; selected.clear() }) { Text(stringResource(if (selecting) R.string.cancel else R.string.select)) }
        }
    }
    viewer?.let { (list, start) ->
        Viewer(tv, remote, remoteState, list, start, slideshow, { id -> if (list === items) lastOpened = id }) { viewer = null }
    }
}

@Composable
private fun Thumbnail(item: LibraryItem, outlined: Boolean, selected: Boolean?, onClick: () -> Unit) {
    val context = LocalContext.current
    var bitmap by remember(item.id) { mutableStateOf(PhoneLibrary.cachedThumbnail(item)) }
    LaunchedEffect(item.id) { if (bitmap == null) bitmap = PhoneLibrary.thumbnail(context, item, 256) }
    Box(Modifier.aspectRatio(1f).background(Quiet.panel).clickable(onClick = onClick)
        .then(if (outlined) Modifier.border(2.dp, Quiet.cyan) else Modifier)) {
        bitmap?.let { Image(it.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
        if (item.video) Text(formatDuration(item.durationMillis / 1000.0), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
            modifier = Modifier.align(Alignment.BottomStart).padding(4.dp))
        if (selected != null) Icon(if (selected) Icons.Rounded.CheckCircle else Icons.Rounded.Add, null, tint = if (selected) Quiet.cyan else Color.White,
            modifier = Modifier.align(Alignment.BottomEnd).padding(4.dp).size(20.dp))
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Viewer(tv: ShowOnTvModel, remote: RemoteModel, remoteState: RemoteModel.State, items: List<LibraryItem>, start: Int, slideshowAtStart: Boolean,
                   opened: (Long) -> Unit, close: () -> Unit) {
    val state by tv.state.collectAsState()
    val pager = rememberPagerState(initialPage = start) { items.size }
    var chrome by remember { mutableStateOf(true) }
    var slideshow by remember { mutableStateOf(slideshowAtStart) }
    var pull by remember { mutableFloatStateOf(0f) }
    val view = LocalView.current
    BackHandler { close() }
    LaunchedEffect(pager) {
        snapshotFlow { pager.settledPage }.collect { page ->
            val item = items[page]
            opened(item.id)
            tv.focus(item, listOfNotNull(items.getOrNull(page - 1), items.getOrNull(page + 1)))
        }
    }
    // Slideshow: every 5 seconds to the next photo; videos skipped; the end stops it.
    LaunchedEffect(slideshow) {
        while (slideshow) {
            delay(5_000)
            val next = ((pager.currentPage + 1) until items.size).firstOrNull { !items[it].video } ?: break
            pager.animateScrollToPage(next)
        }
        slideshow = false
    }
    val current = items[pager.currentPage]
    val castingPlaying = current.video && state.shownId == current.id && state.media?.playing == true
    DisposableEffect(castingPlaying) { view.keepScreenOn = castingPlaying; onDispose { view.keepScreenOn = false } }

    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 1f - min(pull, 300f) / 400f))
            .pointerInput(Unit) {
                // Pull down to go back, like the gallery: the photo follows the finger and shrinks, the black fades.
                detectVerticalDragGestures(onDragEnd = { if (pull > 280f) close() else pull = 0f }, onDragCancel = { pull = 0f }) { _, drag -> pull = max(0f, pull + drag) }
            }) {
            HorizontalPager(pager, beyondViewportPageCount = 1, modifier = Modifier.fillMaxSize().graphicsLayer {
                translationY = pull; val scale = 1f - min(pull, 600f) / 2400f; scaleX = scale; scaleY = scale
            }.clickable(interactionSource = null, indication = null) { chrome = !chrome }) { page ->
                val item = items[page]
                val casting = if (item.video && state.shownId == item.id) state.media?.playerState else null
                Page(item, casting, tv.tvName, animates = !chrome)
            }
            AnimatedVisibility(chrome && pull == 0f, enter = fadeIn(), exit = fadeOut()) {
                Overlay(tv, state, remote, remoteState, current, slideshow, { slideshow = !slideshow }, close,
                    next = { if (pager.currentPage + 1 < items.size) tv.dismissProblem() })
            }
        }
    }
    state.problem?.let { problem ->
        AlertDialog(onDismissRequest = tv::dismissProblem, title = { Text("Purio TV") }, text = { Text(stringResource(problem.message())) },
            confirmButton = { TextButton(onClick = tv::dismissProblem) { Text(stringResource(R.string.keep_browsing)) } })
    }
}

@Composable
private fun Page(item: LibraryItem, casting: String?, tvName: String, animates: Boolean) {
    val context = LocalContext.current
    var bitmap by remember(item.id) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(item.id) { bitmap = PhoneLibrary.picture(context, item, 2048) }
    DisposableEffect(item.id) { onDispose { bitmap = null } }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val castingNow = casting == "PLAYING" || casting == "BUFFERING" || casting == "PAUSED"
        bitmap?.let { Image(it.asImageBitmap(), null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize()
            .then(if (castingNow) Modifier.blur(24.dp).alpha(0.45f) else Modifier)) } ?: CircularProgressIndicator(color = Color.White)
        if (castingNow) { if (animates) CastingAnimation(casting != "PAUSED", tvName) }
        else if (item.video) Box(Modifier.size(64.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Tv, null, tint = Color.White.copy(alpha = 0.9f), modifier = Modifier.size(30.dp))
        }
    }
}

@Composable
private fun Overlay(tv: ShowOnTvModel, state: ShowOnTvModel.State, remote: RemoteModel, remoteState: RemoteModel.State, item: LibraryItem,
                    slideshow: Boolean, toggleSlideshow: () -> Unit, close: () -> Unit, next: () -> Unit) {
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).background(Color.White.copy(alpha = 0.12f), CircleShape).clip(CircleShape).clickable(onClick = close), contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back_to_library), tint = Color.White)
            }
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(item.takenMillis)), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                Text(DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(item.takenMillis)), fontSize = 12.sp, color = Color.White.copy(alpha = 0.7f))
            }
            TvPill(tv)
        }
        if (state.tv == ShowOnTvModel.Tv.OPENING) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp).background(Quiet.panel.copy(alpha = 0.96f), RoundedCornerShape(14.dp)).padding(12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Quiet.cyan)
                Column {
                    Text(stringResource(R.string.opening_on, tv.tvName), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    Text(stringResource(R.string.opening_detail), fontSize = 12.sp, color = Quiet.muted)
                }
            }
        }
        // While the controls show, the casting animation sits in the space above them (it overlapped on iPhone).
        val casting = item.video && state.shownId == item.id && state.media?.playerState in setOf("PLAYING", "BUFFERING", "PAUSED")
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            if (casting) Box(Modifier.graphicsLayer { val s = min(1f, maxHeight.toPx() / 300.dp.toPx()); scaleX = s; scaleY = s }) {
                CastingAnimation(state.media?.playerState != "PAUSED", tv.tvName)
            }
        }
        Column(Modifier.fillMaxWidth().background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.75f))))
            .padding(horizontal = 18.dp).padding(top = 24.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (item.video) VideoControls(tv, state, remote, remoteState, item)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Action(if (slideshow) R.string.stop_slideshow else R.string.slideshow, Icons.Rounded.Slideshow, hot = slideshow, enabled = !item.video || slideshow, onClick = toggleSlideshow)
                Spacer(Modifier.weight(1f))
                Action(R.string.stop_on_tv, Icons.Rounded.Stop, hot = false, enabled = state.shownId != null) { tv.stopOnTv() }
            }
        }
    }
}

@Composable
private fun VideoControls(tv: ShowOnTvModel, state: ShowOnTvModel.State, remote: RemoteModel, remoteState: RemoteModel.State, item: LibraryItem) {
    if (state.endedId == item.id) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Surface(onClick = tv::playAgain, shape = CircleShape, color = Quiet.cyan) {
                Row(Modifier.padding(horizontal = 24.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Rounded.Replay, null, tint = Color(0xFF0A2930)); Text(stringResource(R.string.play_again), color = Color(0xFF0A2930), fontWeight = FontWeight.SemiBold)
                }
            }
            Text(stringResource(R.string.finished_first_frame), fontSize = 12.sp, color = Quiet.muted)
        }
        return
    }
    if (state.shownId != item.id) return
    val duration = state.media?.duration ?: (item.durationMillis / 1000.0)
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(500); now = System.currentTimeMillis() } }
    var scrub by remember { mutableStateOf<Float?>(null) }
    val time = scrub?.toDouble() ?: tv.position(now)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Slider(value = min(time, duration).toFloat(), onValueChange = { scrub = it }, valueRange = 0f..max(duration, 1.0).toFloat(),
            onValueChangeFinished = { scrub?.let { tv.seek(it.toDouble()) }; scrub = null },
            colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Quiet.cyan), modifier = Modifier.semantics { contentDescription = "position" })
        Row { Text(formatDuration(time), fontSize = 11.sp, color = Quiet.muted); Spacer(Modifier.weight(1f)); Text(formatDuration(duration), fontSize = 11.sp, color = Quiet.muted) }
    }
    val playing = state.media?.playing == true
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(30.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
        RoundAction(Icons.Rounded.Replay10, R.string.back_10) { tv.skip(-10.0) }
        Surface(onClick = { if (playing) tv.pause() else if (state.media?.idleReason == "FINISHED") tv.playAgain() else tv.play() }, shape = CircleShape, color = Quiet.cyan, modifier = Modifier.size(60.dp)) {
            Box(contentAlignment = Alignment.Center) { Icon(if (playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, stringResource(if (playing) R.string.pause else R.string.play), tint = Color(0xFF0A2930)) }
        }
        RoundAction(Icons.Rounded.Forward10, R.string.forward_10) { tv.skip(10.0) }
    }
    Row(Modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.1f), CircleShape).alpha(if (remoteState.ready) 1f else 0.45f), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(56.dp, 40.dp).clickable(enabled = remoteState.ready) { remote.tap(TVKey.VOLUME_DOWN) }, contentAlignment = Alignment.Center) { Icon(Icons.Rounded.Remove, stringResource(R.string.key_volume_down), tint = Color.White) }
        val v = remoteState.volume
        Text(when { v == null -> stringResource(R.string.volume_title); v.muted -> stringResource(R.string.muted); v.maximum == 100 -> stringResource(R.string.volume, v.level); else -> stringResource(R.string.volume_of, v.level, v.maximum) },
            fontSize = 13.sp, color = Color.White, modifier = Modifier.weight(1f), textAlign = TextAlign.Center)
        Box(Modifier.size(56.dp, 40.dp).clickable(enabled = remoteState.ready) { remote.tap(TVKey.VOLUME_UP) }, contentAlignment = Alignment.Center) { Icon(Icons.Rounded.Add, stringResource(R.string.key_volume_up), tint = Color.White) }
    }
    Text(stringResource(R.string.keep_open_while_playing), fontSize = 12.sp, color = Quiet.muted, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
}

@Composable
private fun RoundAction(icon: androidx.compose.ui.graphics.vector.ImageVector, @StringRes label: Int, onClick: () -> Unit) {
    Box(Modifier.size(46.dp).background(Color.White.copy(alpha = 0.13f), CircleShape).clip(CircleShape).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, stringResource(label), tint = Color.White)
    }
}

@Composable
private fun Action(@StringRes title: Int, icon: androidx.compose.ui.graphics.vector.ImageVector, hot: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Column(Modifier.alpha(if (enabled) 1f else 0.4f).clip(RoundedCornerShape(12.dp)).clickable(enabled = enabled, onClick = onClick).padding(4.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(44.dp).background(if (hot) Quiet.cyan.copy(alpha = 0.22f) else Color.White.copy(alpha = 0.13f), CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = if (hot) Quiet.cyan else Color.White, modifier = Modifier.size(18.dp))
        }
        Text(stringResource(title), fontSize = 11.sp, color = Color.White.copy(alpha = 0.85f))
    }
}

/** Rings going out from a TV with a little level meter on its screen; still when paused (CastingAnimation). */
@Composable
private fun CastingAnimation(moving: Boolean, tvName: String) {
    val transition = rememberInfiniteTransition(label = "casting")
    val phase by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(2400, easing = LinearEasing)), label = "rings")
    val bars by transition.animateFloat(0f, (2 * Math.PI).toFloat(), infiniteRepeatable(tween(2400, easing = LinearEasing)), label = "bars")
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Box(Modifier.size(240.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize()) {
                for (ring in 0 until 3) {
                    val p = if (moving) (phase + ring / 3f) % 1f else 0.3f + ring * 0.3f
                    val radius = (104.dp.toPx() + 130.dp.toPx() * p) / 2
                    drawCircle(Quiet.cyan.copy(alpha = if (moving) 0.6f * (1 - p) else 0.14f), radius, style = Stroke(2.dp.toPx()))
                }
                drawCircle(Quiet.cyan.copy(alpha = 0.15f), 52.dp.toPx())
            }
            Icon(Icons.Rounded.Tv, null, tint = Quiet.cyan, modifier = Modifier.size(48.dp))
            Row(Modifier.padding(bottom = 6.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                for (bar in 0 until 4) Box(Modifier.width(3.5.dp).height(if (moving) (5 + 9 * abs(sin(bars * 2 + bar * 0.9f))).dp else 4.dp).background(Quiet.cyan, RoundedCornerShape(2.dp)))
            }
        }
        Text(stringResource(if (moving) R.string.playing_on else R.string.paused_on, tvName), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
    }
}

/** Which TV the taps go to and whether it's following: tap to pause or resume sending. */
@Composable
private fun TvPill(tv: ShowOnTvModel) {
    val state by tv.state.collectAsState()
    val on = state.tv == ShowOnTvModel.Tv.ON
    Row(Modifier.clip(CircleShape).background(if (on) Quiet.cyan.copy(alpha = 0.16f) else Quiet.panel).clickable(onClick = tv::toggleSending)
        .padding(horizontal = 10.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        val color = if (on || state.tv == ShowOnTvModel.Tv.OPENING) Quiet.cyan else Quiet.muted
        when (state.tv) {
            ShowOnTvModel.Tv.OPENING -> CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = Quiet.cyan)
            ShowOnTvModel.Tv.FAILED -> Icon(Icons.Rounded.Warning, null, tint = Quiet.amber, modifier = Modifier.size(12.dp))
            else -> Box(Modifier.size(7.dp).background(color, CircleShape))
        }
        Text(when (state.tv) {
            ShowOnTvModel.Tv.OPENING -> stringResource(R.string.opening)
            ShowOnTvModel.Tv.ON -> stringResource(R.string.on_tv)
            ShowOnTvModel.Tv.PAUSED -> stringResource(R.string.not_on_tv)
            ShowOnTvModel.Tv.FAILED -> "TV"
            ShowOnTvModel.Tv.OFF -> tv.tvName
        }, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = color, maxLines = 1)
    }
}

@Composable
private fun NoAccess(close: () -> Unit, ask: () -> Unit) {
    val context = LocalContext.current
    Column(Modifier.fillMaxSize().statusBarsPadding().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically)) {
        Icon(Icons.Rounded.Tv, null, tint = Quiet.cyan, modifier = Modifier.size(44.dp))
        Text(stringResource(R.string.cant_see_photos), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        Text(stringResource(R.string.cant_see_photos_detail), fontSize = 14.sp, color = Quiet.muted, textAlign = TextAlign.Center)
        Surface(onClick = {
            context.startActivity(android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
        }, shape = CircleShape, color = Quiet.cyan) { Text(stringResource(R.string.open_settings), color = Color(0xFF0A2930), fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 22.dp, vertical = 11.dp)) }
        TextButton(onClick = close) { Text(stringResource(R.string.close)) }
    }
}

private fun formatDuration(seconds: Double): String {
    val s = max(0, seconds.toInt())
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}
