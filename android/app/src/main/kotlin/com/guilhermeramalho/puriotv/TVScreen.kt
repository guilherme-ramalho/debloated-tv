package com.guilhermeramalho.puriotv

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.RectF
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Crop
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Collections
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material.icons.outlined.WbCloudy
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.guilhermeramalho.puriotv.core.HomeLayout
import com.guilhermeramalho.puriotv.core.LauncherHome
import com.guilhermeramalho.puriotv.core.RemoteApp
import com.guilhermeramalho.puriotv.core.TVKey
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** The TV tab's screens (TVHomeView's NavigationLinks). */
sealed interface TVRoute {
    data object Wallpaper : TVRoute
    data object Look : TVRoute
    data object Apps : TVRoute
    data object Profiles : TVRoute
    data object Setup : TVRoute
    data object Undo : TVRoute
    data object Manage : TVRoute
    data object HomeUpdate : TVRoute
}

@Composable
fun wallpaperName(id: String) = stringResource(when (id) {
    "quiet-night" -> R.string.wallpaper_quiet_night; "aurora" -> R.string.wallpaper_aurora; "dusk" -> R.string.wallpaper_dusk
    else -> R.string.wallpaper_photo
})

/**
 * The Home editor, shown once the new Home screen is on the TV (TVHomeView.editorContent): profile, preview, dock,
 * wallpaper, look, weather, apps, profiles, then where the draft stands and the editor's connection.
 */
@Composable
fun HomeEditorContent(model: RemoteModel, open: (TVRoute) -> Unit) {
    val settings = model.settings
    val editor = model.editor
    val prefs by settings.value.collectAsState()
    val ed by editor.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var importLayout by remember { mutableStateOf(false) }
    val profile = prefs.profile
    val layout = profile.layout

    Row(verticalAlignment = Alignment.CenterVertically) {
        Box {
            Surface(onClick = { menu = true }, shape = RoundedCornerShape(12.dp), color = Color(0xFF1D2D46), border = BorderStroke(1.dp, Quiet.edge),
                modifier = Modifier.heightIn(min = 44.dp).semantics { contentDescription = context.getString(R.string.launcher_profile) + ": " + profile.name }) {
                Row(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(profile.name, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                    Icon(Icons.Rounded.ArrowDropDown, null)
                }
            }
            DropdownMenu(menu, { menu = false }) {
                prefs.profiles.forEach { p ->
                    DropdownMenuItem(text = { Text(p.name) }, onClick = { menu = false; settings.selectProfile(p.id) },
                        trailingIcon = if (p.id == profile.id) ({ Icon(Icons.Rounded.Check, null) }) else null)
                }
            }
        }
        Spacer(Modifier.weight(1f))
        TextButton(onClick = { adding = true }, enabled = prefs.profiles.size < 20) {
            Icon(Icons.Rounded.Add, null, Modifier.size(18.dp)); Text(" " + stringResource(R.string.new_profile), color = Quiet.cyan, fontSize = 13.sp)
        }
    }
    HomePreview(layout, settings, profile.name)
    RowCard {
        ListItem(
            headlineContent = { Text(stringResource(R.string.dock_icons), fontWeight = FontWeight.Medium) },
            trailingContent = { Counter(layout.dockCount, 1..7, stringResource(R.string.fewer), stringResource(R.string.more)) { v -> settings.editLayout { it.copy(dockCount = v) } } },
            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        )
    }
    RowCard {
        NavRow(Icons.Outlined.Image, stringResource(R.string.wallpaper), value = wallpaperName(layout.wallpaper)) { open(TVRoute.Wallpaper) }
        ed.snapshot?.home?.takeIf { it.supports("looks") }?.let { home ->
            RowDivider()
            NavRow(Icons.Outlined.AutoAwesome, stringResource(R.string.look), stringResource(R.string.look_detail), value = lookName(home.look ?: "cinema")) { open(TVRoute.Look) }
        }
        ed.snapshot?.home?.takeIf { it.supports("weather") }?.let { home ->
            RowDivider()
            WeatherRow(home, model)
        }
        RowDivider()
        NavRow(Icons.Outlined.GridView, stringResource(R.string.apps_and_order), stringResource(R.string.apps_and_order_detail)) { open(TVRoute.Apps) }
        RowDivider()
        NavRow(Icons.Outlined.People, stringResource(R.string.profiles), stringResource(R.string.profiles_detail)) { open(TVRoute.Profiles) }
    }
    LayoutApplyStatus(model)
    RowCard {
        EditorConnection(model)
        if (ed.ready) {
            RowDivider()
            NavRow(Icons.Outlined.Refresh, stringResource(R.string.refresh_apps), chevron = false, tint = Quiet.cyan) {
                scope.launch { try { editor.refresh() } catch (e: Exception) { settings.notice.value = errorText(context, e) } }
            }
            NavRow(Icons.Outlined.FileDownload, stringResource(R.string.load_tv_layout), chevron = false, tint = Quiet.cyan) { importLayout = true }
        }
    }
    if (adding) NameDialog(stringResource(R.string.new_profile), stringResource(R.string.profile_name), stringResource(R.string.create), { adding = false }) { settings.addProfile(it) }
    if (importLayout) Confirm(stringResource(R.string.replace_with_tv_layout), confirm = stringResource(R.string.load_tv_layout_button), onDismiss = { importLayout = false }) {
        val snapshot = ed.snapshot ?: return@Confirm
        try {
            settings.backup(context.getString(R.string.backup_before_loading))
            var tv = snapshot.layout
            if (HomeLayout.validPhoto(tv.wallpaper)) {
                val data = snapshot.wallpaperJPEG ?: throw UserMessage(context.getString(R.string.tv_no_wallpaper))
                tv = tv.copy(wallpaper = settings.importPhoto(data))
            }
            settings.editLayout(LayoutApply.MATCHES_TV) { tv }
        } catch (e: Exception) { settings.notice.value = errorText(context, e) }
    }
}

/** A name prompt (the iPhone's alert with a text field). */
@Composable
fun NameDialog(title: String, label: String, confirm: String, onDismiss: () -> Unit, onDone: (String) -> Unit) {
    var name by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss, title = { Text(title) },
        text = { OutlinedTextField(name, { name = it }, label = { Text(label) }, singleLine = true) },
        confirmButton = { TextButton(enabled = name.isNotBlank(), onClick = { onDismiss(); onDone(name) }) { Text(confirm) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/**
 * TV Home connects by itself when Home is in front on the TV. With an app or input on screen it asks first, because
 * opening the editor can pause what's playing (EditorConnectionView).
 */
@Composable
fun EditorConnection(model: RemoteModel) {
    val editor = model.editor
    val ed by editor.state.collectAsState()
    val tv by model.state.collectAsState()
    LaunchedEffect(tv.ready, tv.power, tv.foreground) { if (tv.kind == com.guilhermeramalho.puriotv.core.TvKind.ANDROID_TV) editor.autoConnect() }
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(if (ed.ready) Icons.Outlined.VerifiedUser else Icons.Outlined.Tv, null)
            Text(stringResource(if (ed.ready) R.string.editor_connected else if (ed.busy) R.string.editor_connecting else R.string.tv_home), fontWeight = FontWeight.Medium)
            if (ed.busy) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
        }
        Caption(ed.message)
        if (ed.waitingFor != null) PrimaryButton(stringResource(R.string.connect_now), Icons.Outlined.Link) { editor.connect(force = true) }
        else if (!ed.ready && !ed.busy && tv.ready && tv.power != false) SecondaryButton(stringResource(R.string.retry), Icons.Outlined.Refresh) { editor.connect(force = true) }
        if (!tv.ready) Caption(stringResource(R.string.tv_unavailable_drafts))
    }
}

/** Where the draft stands against the TV: edits apply by themselves; Apply only after a profile switch, a restore or a failure. */
@Composable
fun LayoutApplyStatus(model: RemoteModel) {
    val ed by model.editor.state.collectAsState()
    when {
        ed.applying -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Rounded.Sync, null, tint = Quiet.muted, modifier = Modifier.size(16.dp)); Caption(stringResource(R.string.applying_to_tv))
        }
        ed.unapplied && ed.ready -> { PrimaryButton(stringResource(R.string.apply_to_tv), Icons.Rounded.Check) { model.editor.applyDraft() }; Caption(stringResource(R.string.draft_not_on_tv)) }
        ed.unapplied -> Caption(stringResource(R.string.not_on_tv_yet))
        else -> Caption(stringResource(R.string.changes_apply_automatically))
    }
}

/** The TV's Home in miniature: wallpaper, clock, profile, dock (HomePreview). */
@Composable
fun HomePreview(layout: HomeLayout, settings: AppSettings, profileName: String, modifier: Modifier = Modifier) {
    val clock = remember { DateFormat.getTimeInstance(DateFormat.SHORT).format(Date()) }
    val shape = RoundedCornerShape(14.dp)
    Box(modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(shape).border(5.dp, Color(0xFF050B14), shape)
        .semantics { contentDescription = "TV Home preview" }) {
        WallpaperSurface(layout.wallpaper, settings, Modifier.fillMaxSize())
        Column(Modifier.fillMaxSize().padding(15.dp)) {
            Row {
                Text(clock, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Color.White)
                Spacer(Modifier.weight(1f))
                Text(profileName, fontSize = 12.sp, color = Color.White, maxLines = 1)
            }
            Spacer(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                layout.dock.forEach { id ->
                    Box(Modifier.weight(1f).height(28.dp).background(Brand.color(id), RoundedCornerShape(7.dp)).padding(horizontal = 5.dp, vertical = 5.dp)) {
                        StreamingLogo(settings.app(id), Modifier.fillMaxSize(), fontSize = 8)
                    }
                }
            }
        }
    }
}

@Composable
fun WallpaperSurface(id: String, settings: AppSettings, modifier: Modifier) {
    val file = settings.photoFile(id)
    val bitmap = remember(id) { file?.takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path, BitmapFactory.Options().apply { inSampleSize = 2 }) } }
    if (bitmap != null) Image(bitmap.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = modifier)
    else Box(modifier.background(Brush.linearGradient(when (id) {
        "aurora" -> listOf(Color(0.03f, 0.17f, 0.24f), Color(0.15f, 0.48f, 0.47f), Color(0.65f, 0.62f, 0.48f))
        "dusk" -> listOf(Color(0.15f, 0.19f, 0.33f), Color(0.53f, 0.35f, 0.47f), Color(0.83f, 0.61f, 0.5f))
        else -> listOf(Color(0.04f, 0.09f, 0.2f), Color(0.14f, 0.27f, 0.42f), Color(0.32f, 0.39f, 0.55f))
    })))
}

/** Wallpaper: three presets drawn by the TV, or a photo framed to 16:9 (WallpaperView). */
@Composable
fun WallpaperScreen(model: RemoteModel, onBack: () -> Unit) {
    val settings = model.settings
    val prefs by settings.value.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var loading by remember { mutableStateOf(false) }
    var framing by remember { mutableStateOf<Bitmap?>(null) }
    val layout = prefs.profile.layout
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        loading = true
        scope.launch {
            try {
                framing = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    val data = context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: throw UserMessage(context.getString(R.string.photo_load_failed))
                    Images.decode(data, 2560) ?: throw UserMessage(context.getString(R.string.image_unsupported))
                }
            } catch (e: Exception) { settings.notice.value = errorText(context, e) }
            loading = false
        }
    }
    SubPage(stringResource(R.string.wallpaper), onBack) {
        HomePreview(layout, settings, prefs.profile.name)
        val presets = listOf("quiet-night", "aurora", "dusk")
        (presets.map { it as String? } + listOf(null)).chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                pair.forEach { id ->
                    val shape = RoundedCornerShape(17.dp)
                    if (id != null) {
                        Box(Modifier.weight(1f).height(110.dp).clip(shape).clickable { settings.editLayout { it.copy(wallpaper = id) } }) {
                            WallpaperSurface(id, settings, Modifier.fillMaxSize())
                            Row(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(wallpaperName(id), color = Color.White, modifier = Modifier.weight(1f))
                                if (layout.wallpaper == id) Icon(Icons.Outlined.CheckCircle, null, tint = Color.White)
                            }
                        }
                    } else {
                        Box(Modifier.weight(1f).height(110.dp).clip(shape).background(Color.White.copy(alpha = 0.05f))
                            .clickable(enabled = !loading) { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                            contentAlignment = Alignment.Center) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Icon(Icons.Outlined.PhotoLibrary, null)
                                Text(stringResource(if (loading) R.string.preparing else R.string.choose_photo))
                            }
                        }
                    }
                }
            }
        }
        if (HomeLayout.validPhoto(layout.wallpaper)) SecondaryButton(stringResource(R.string.adjust_framing), Icons.Outlined.Crop) {
            framing = settings.framingSource(layout.wallpaper)
        }
        LayoutApplyStatus(model)
        Caption(stringResource(R.string.wallpaper_footer))
    }
    framing?.let { image ->
        FramingDialog(image, cancel = { framing = null }) { crop ->
            try {
                val id = settings.saveFramedPhoto(image, crop)
                settings.editLayout { it.copy(wallpaper = id) }
                framing = null
            } catch (e: Exception) { settings.notice.value = errorText(context, e) }
        }
    }
}

/**
 * Drag and pinch a photo inside the TV's 16:9 frame, with the clock and dock sketched on top (WallpaperFramingView).
 * Hands back the visible part as a rect in the image's pixels.
 */
@Composable
private fun FramingDialog(image: Bitmap, cancel: () -> Unit, done: (RectF) -> Unit) {
    var zoom by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var frameWidth by remember { mutableFloatStateOf(1f) }
    val bitmap = remember(image) { image.asImageBitmap() }
    fun k(width: Float) = maxOf(width / image.width, width * 9f / 16f / image.height) * zoom
    fun clamp(p: Offset, width: Float): Offset {
        val kk = k(width)
        val maxX = maxOf(0f, (image.width * kk - width) / 2); val maxY = maxOf(0f, (image.height * kk - width * 9f / 16f) / 2)
        return Offset(p.x.coerceIn(-maxX, maxX), p.y.coerceIn(-maxY, maxY))
    }
    Dialog(onDismissRequest = cancel, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(color = Quiet.background, modifier = Modifier.fillMaxSize()) {
            Column(Modifier.statusBarsPadding().navigationBarsPadding().padding(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = cancel) { Text(stringResource(R.string.cancel)) }
                    Text(stringResource(R.string.frame_wallpaper), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                }
                Caption(stringResource(R.string.framing_hint))
                BoxWithConstraints(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(12.dp))
                    .border(1.dp, Color.White.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
                    .onSizeChanged { frameWidth = it.width.toFloat(); offset = clamp(offset, frameWidth) }
                    .pointerInput(Unit) {
                        detectTransformGestures { _, pan, gestureZoom, _ ->
                            zoom = (zoom * gestureZoom).coerceIn(1f, 4f)
                            offset = clamp(offset + pan, frameWidth)
                        }
                    }) {
                    val kk = k(frameWidth)
                    val density = LocalDensity.current
                    Image(bitmap, null, contentScale = ContentScale.FillBounds,
                        modifier = Modifier.align(Alignment.Center).size(with(density) { (image.width * kk).toDp() }, with(density) { (image.height * kk).toDp() })
                            .graphicsLayer { translationX = offset.x; translationY = offset.y })
                    FramingGuide()
                }
                TextButton(onClick = { zoom = 1f; offset = Offset.Zero }) {
                    Icon(Icons.Rounded.RestartAlt, null, tint = Quiet.cyan); Text(" " + stringResource(R.string.reset_framing), color = Quiet.cyan)
                }
                Spacer(Modifier.weight(1f))
                PrimaryButton(stringResource(R.string.use_photo), Icons.Rounded.Check) {
                    val kk = k(frameWidth)
                    val w = frameWidth / kk; val h = frameWidth * 9f / 16f / kk
                    val cx = image.width / 2f - offset.x / kk; val cy = image.height / 2f - offset.y / kk
                    done(RectF(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2))
                }
            }
        }
    }
}

/** A light sketch of Home over the photo: the clock corner and the dock row. */
@Composable
private fun FramingGuide() = Canvas(Modifier.fillMaxSize()) {
    val pad = size.width * 0.04f
    drawRoundRect(Color.White.copy(alpha = 0.55f), Offset(pad, pad), Size(size.width * 0.12f, size.height * 0.05f), CornerRadius(3.dp.toPx()))
    val gap = size.width * 0.012f
    val tileW = (size.width - 2 * pad - 4 * gap) / 5; val tileH = size.height * 0.16f
    repeat(5) { i ->
        val o = Offset(pad + i * (tileW + gap), size.height - pad - tileH)
        drawRoundRect(Color.White.copy(alpha = 0.22f), o, Size(tileW, tileH), CornerRadius(4.dp.toPx()))
        drawRoundRect(Color.White.copy(alpha = 0.35f), o, Size(tileW, tileH), CornerRadius(4.dp.toPx()), style = Stroke(0.5.dp.toPx()))
    }
}

@Composable
fun lookName(look: String) = stringResource(when (look) { "calm" -> R.string.look_calm; "glass" -> R.string.look_glass; "gallery" -> R.string.look_gallery; else -> R.string.look_cinema })

/** How TV Home looks (LookView): each look switches on features Home already has; apps, order and wallpaper stay. */
@Composable
fun LookScreen(model: RemoteModel, onBack: () -> Unit) {
    val ed by model.editor.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf<String?>(null) }
    val current = ed.snapshot?.home?.look ?: "cinema"
    SubPage(stringResource(R.string.look), onBack) {
        Caption(stringResource(R.string.look_intro))
        LauncherHome.looks.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                pair.forEach { look ->
                    val selected = current == look
                    Surface(
                        onClick = {
                            if (look == current) return@Surface
                            working = look
                            scope.launch {
                                try { model.editor.setLook(look) } catch (e: Exception) { model.settings.notice.value = errorText(context, e) }
                                working = null
                            }
                        },
                        enabled = working == null && ed.ready, shape = RoundedCornerShape(16.dp), color = Quiet.panel,
                        border = BorderStroke(if (selected) 2.dp else 1.dp, if (selected) Quiet.cyan else Quiet.edge),
                        modifier = Modifier.weight(1f).heightIn(min = 128.dp),
                    ) {
                        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row {
                                Icon(when (look) { "calm" -> Icons.Outlined.Schedule; "glass" -> Icons.Outlined.Layers; "gallery" -> Icons.Outlined.Collections; else -> Icons.Outlined.AutoAwesome }, null)
                                Spacer(Modifier.weight(1f))
                                if (working == look) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                                else if (selected) Icon(Icons.Rounded.Check, null, tint = Quiet.cyan)
                            }
                            Text(lookName(look), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                            Text(stringResource(when (look) {
                                "calm" -> R.string.look_calm_detail; "glass" -> R.string.look_glass_detail; "gallery" -> R.string.look_gallery_detail
                                else -> R.string.look_cinema_detail
                            }), fontSize = 11.sp, color = Quiet.muted)
                        }
                    }
                }
            }
        }
        Caption(stringResource(R.string.changes_apply_right_away))
    }
}

/** Weather by the clock on TV Home; the TV finds its own rough location (WeatherRow). */
@Composable
fun WeatherRow(home: LauncherHome, model: RemoteModel) {
    val ed by model.editor.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf(false) }
    val detail = when {
        home.weather != true -> stringResource(R.string.off)
        home.locationAllowed == false -> stringResource(R.string.weather_no_location)
        !home.weatherPlace.isNullOrEmpty() -> stringResource(R.string.weather_from_tv, home.weatherPlace!!)
        else -> stringResource(R.string.weather_location_from_tv)
    }
    SwitchRow(stringResource(R.string.weather_on_tv), detail, home.weather == true, Icons.Outlined.WbCloudy, enabled = !working && ed.ready) { on ->
        working = true
        scope.launch {
            try { model.editor.setWeather(on) } catch (e: Exception) { model.settings.notice.value = errorText(context, e) }
            working = false
        }
    }
}

/** Apps & order (HomeAppsView): reorder, hide, uninstall. */
@Composable
fun HomeAppsScreen(model: RemoteModel, onBack: () -> Unit) {
    val settings = model.settings
    val prefs by settings.value.collectAsState()
    var selected by remember { mutableStateOf<RemoteApp?>(null) }
    val layout = prefs.profile.layout
    SubPage(stringResource(R.string.apps_and_order), onBack) {
        SectionTitle(stringResource(R.string.order))
        RowCard {
            val shown = layout.order.mapNotNull { id -> prefs.app(id)?.let { id to it } }
            shown.forEachIndexed { i, (id, app) ->
                if (i > 0) RowDivider()
                val at = layout.order.indexOf(id)
                ReorderRow(
                    leading = { AppBadge(app) }, title = app.name,
                    detail = stringResource(when { id in layout.hidden -> R.string.hidden_on_tv; id in layout.dock -> R.string.in_tv_dock; else -> R.string.not_in_dock }),
                    canUp = at > 0, canDown = at < layout.order.size - 1,
                    onMove = { d -> settings.editLayout { it.copy(order = it.order.moved(at, at + d)) } },
                    onClick = { selected = app },
                )
            }
        }
        val extra = prefs.apps.filter { it.id !in layout.order }
        if (extra.isNotEmpty()) {
            SectionTitle(stringResource(R.string.more_apps))
            RowCard {
                extra.forEachIndexed { i, app ->
                    if (i > 0) RowDivider()
                    NavRow(Icons.Rounded.Add, stringResource(R.string.add_named, app.name), chevron = false) { settings.editLayout { it.copy(order = it.order + app.id) } }
                }
            }
        }
        Caption(stringResource(R.string.apps_order_footer))
    }
    selected?.let { HomeAppSheet(it, model) { selected = null } }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HomeAppSheet(app: RemoteApp, model: RemoteModel, onDismiss: () -> Unit) {
    val settings = model.settings
    val prefs by settings.value.collectAsState()
    val ed by model.editor.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var confirm by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    val layout = prefs.profile.layout
    fun move(d: Int) = settings.editLayout { l -> val i = l.order.indexOf(app.id); l.copy(order = l.order.moved(i, (i + d).coerceIn(0, l.order.size - 1))) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Quiet.panel) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { AppBadge(app); Text(app.name, style = MaterialTheme.typography.titleLarge) }
            SwitchRow(stringResource(R.string.show_on_tv_home), checked = app.id !in layout.hidden) { visible ->
                settings.editLayout { l -> l.copy(hidden = l.hidden.filterNot { it == app.id } + if (visible) emptyList() else listOf(app.id)) }
            }
            NavRow(Icons.Rounded.ArrowUpward, stringResource(R.string.move_up), chevron = false) { move(-1) }
            NavRow(Icons.Rounded.ArrowDownward, stringResource(R.string.move_down), chevron = false) { move(1) }
            RowDivider()
            if (app.system) NavRow(null, stringResource(R.string.system_app_cannot_uninstall), chevron = false)
            else NavRow(Icons.Outlined.Delete, stringResource(R.string.uninstall_from_tv), chevron = false, tint = Quiet.amber,
                enabled = ed.ready && app.installed == true && !busy) { confirm = true }
            Caption(stringResource(if (ed.ready) R.string.uninstall_footer_ready else R.string.uninstall_footer_offline))
        }
    }
    if (confirm) Confirm(stringResource(R.string.uninstall_title, app.name), confirm = stringResource(R.string.continue_on_tv), destructive = true, onDismiss = { confirm = false }) {
        busy = true
        scope.launch {
            try { model.editor.uninstall(app); onDismiss() } catch (e: Exception) { settings.notice.value = errorText(context, e) }
            busy = false
        }
    }
}

/** Profiles (ProfilesView): a saved layout per person; switching applies nothing until Apply. */
@Composable
fun ProfilesScreen(settings: AppSettings, onBack: () -> Unit) {
    val prefs by settings.value.collectAsState()
    var adding by remember { mutableStateOf(false) }
    SubPage(stringResource(R.string.profiles), onBack) {
        RowCard {
            prefs.profiles.forEachIndexed { i, p ->
                if (i > 0) RowDivider()
                ListItem(
                    headlineContent = { Text(p.name) },
                    leadingContent = { Icon(Icons.Outlined.Person, null) },
                    trailingContent = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (prefs.profile.id == p.id) Icon(Icons.Rounded.Check, null, tint = Quiet.cyan)
                            IconButton(onClick = { settings.deleteProfile(p.id) }, enabled = prefs.profiles.size > 1) {
                                Icon(Icons.Outlined.Delete, stringResource(R.string.delete), tint = Quiet.muted)
                            }
                        }
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                    modifier = Modifier.clickable { settings.selectProfile(p.id) },
                )
            }
            RowDivider()
            NavRow(Icons.Rounded.Add, stringResource(R.string.new_profile), chevron = false, tint = Quiet.cyan, enabled = prefs.profiles.size < 20) { adding = true }
        }
        Caption(stringResource(R.string.profiles_footer))
    }
    if (adding) NameDialog(stringResource(R.string.new_profile), stringResource(R.string.profile_name), stringResource(R.string.create), { adding = false }) { settings.addProfile(it) }
}

/** Presses Home on the TV and reads which Home answers (TVHomeView.checkTV). */
suspend fun checkTV(model: RemoteModel, homeInstalled: () -> Boolean, say: (String?) -> Unit, text: (Int) -> String) {
    say(text(R.string.checking))
    model.tap(TVKey.HOME)
    delay(3000)
    if (homeInstalled()) { say(null); return }
    val shown = model.state.value.foreground.orEmpty()
    if (shown.isNotEmpty() && shown != HomeEditor.HOME_PACKAGE) { say(text(R.string.check_still_original)); return }
    // The TV didn't report a change (it may already have been on Home): ask our Home screen directly.
    model.editor.connect(force = true)
    delay(8000)
    say(if (homeInstalled()) null else text(R.string.check_no_answer))
}
