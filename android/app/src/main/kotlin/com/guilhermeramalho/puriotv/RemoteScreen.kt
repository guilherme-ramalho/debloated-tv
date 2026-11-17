package com.guilhermeramalho.puriotv

import androidx.annotation.StringRes
import androidx.compose.animation.Crossfade
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Input
import androidx.compose.material.icons.automirrored.rounded.Undo
import androidx.compose.material.icons.outlined.ClosedCaption
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.runtime.collectAsState
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.FastForward
import androidx.compose.material.icons.rounded.FastRewind
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.automirrored.outlined.VolumeOff
import androidx.compose.material.icons.automirrored.outlined.VolumeUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.guilhermeramalho.puriotv.core.PadInteraction
import com.guilhermeramalho.puriotv.core.TVKey
import com.guilhermeramalho.puriotv.core.TvKind
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.hypot

/**
 * The remote (RemoteView in TVRemoteApp.swift), same layout as the iPhone: power, the TV and what's on it, inputs;
 * the round pad (tap, hold, or swipe anywhere on it); Back/Home/Play; media row; volume; app shortcuts.
 */
@Composable
fun RemoteScreen(state: RemoteModel.State, model: RemoteModel) {
    var details by rememberSaveable { mutableStateOf(false) }
    var keyboard by rememberSaveable { mutableStateOf(false) }
    var inputs by rememberSaveable { mutableStateOf(false) }
    var showOnTv by rememberSaveable { mutableStateOf(false) }
    val prefs by model.settings.value.collectAsState()
    val enabled = state.ready
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 30.dp).padding(top = 4.dp, bottom = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Header(state, model, { details = true }, { keyboard = true }, { inputs = true }, { showOnTv = true })
        DPad(enabled, prefs.reverseSwipe, model)
        Row(horizontalArrangement = Arrangement.spacedBy(25.dp)) {
            Command(Icons.AutoMirrored.Rounded.Undo, R.string.key_back, enabled) { model.tap(TVKey.BACK) }
            Command(Icons.Rounded.Home, R.string.key_home, enabled) { model.tap(TVKey.HOME) }
            Command(PlayPauseIcon, R.string.key_play_pause, enabled) { model.tap(TVKey.PLAY_PAUSE) }
        }
        // A key this TV doesn't have (a Roku has no subtitles button) is left out; the row stays centred.
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Command(Icons.Rounded.FastRewind, R.string.key_rewind, enabled) { model.tap(TVKey.REWIND) }
            Command(Icons.Rounded.FastForward, R.string.key_fast_forward, enabled) { model.tap(TVKey.FAST_FORWARD) }
            if (state.supports(TVKey.CAPTIONS)) Command(Icons.Outlined.ClosedCaption, R.string.key_captions, enabled) { model.tap(TVKey.CAPTIONS) }
            if (state.supports(TVKey.SETTINGS)) Command(Icons.Outlined.Settings, R.string.key_settings, enabled) { model.tap(TVKey.SETTINGS) }
        }
        Volume(state, model)
        Apps(enabled, if (state.kind == TvKind.ANDROID_TV) prefs.remoteApps else prefs.shortcutApps, model)
    }
    if (details) ConnectionSheet(state, model) { details = false }
    if (keyboard) KeyboardSheet(model) { keyboard = false }
    if (inputs) InputsSheet(model) { inputs = false }
    if (showOnTv) ShowOnTvScreen(model, state) { showOnTv = false }
}

@Composable
private fun Header(state: RemoteModel.State, model: RemoteModel, openDetails: () -> Unit, openKeyboard: () -> Unit, openInputs: () -> Unit, openShowOnTv: () -> Unit) {
    val powerAvailable = state.pairing == null && state.link != RemoteModel.Link.CONNECTING
    // Narrow phones get smaller round keys so the TV's name keeps its room (CST-01).
    val narrow = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp < 390
    val key = if (narrow) 40.dp else 46.dp
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(if (narrow) 8.dp else 12.dp)) {
        val powerLabel = stringResource(if (!state.ready || state.power == false) R.string.key_wake else R.string.key_power)
        RoundKey(Icons.Rounded.PowerSettingsNew, powerLabel, 48.dp, Quiet.power.copy(alpha = 0.11f), Quiet.power.copy(alpha = 0.25f), powerAvailable) { model.power() }
        ConnectionChip(state, model, openDetails, Modifier.weight(1f))
        RoundKey(Icons.Outlined.PhotoLibrary, stringResource(R.string.show_photos_on_tv), key, Quiet.inputs, null, true, Quiet.cyan, openShowOnTv)
        RoundKey(Icons.Outlined.Keyboard, stringResource(R.string.type_on_tv), key, Quiet.panel, null, true, onClick = openKeyboard)
        // Favourite inputs need Purio's TV Home (Android TV); other TVs get their own input menu, where they have one.
        if (state.kind == TvKind.ANDROID_TV) RoundKey(Icons.AutoMirrored.Outlined.Input, stringResource(R.string.favorite_inputs), key, Quiet.inputs, null, true, onClick = openInputs)
        else if (state.supports(TVKey.INPUTS)) RoundKey(Icons.AutoMirrored.Outlined.Input, stringResource(R.string.key_inputs), key, Quiet.inputs, null, state.ready) { model.tap(TVKey.INPUTS) }
    }
}

/** What the connection is doing, and the useful thing on tap (TVConnectionChip, block layout). */
@Composable
private fun ConnectionChip(state: RemoteModel.State, model: RemoteModel, openDetails: () -> Unit, modifier: Modifier) {
    var retried by remember { mutableStateOf(false) }
    LaunchedEffect(state.ready) { if (state.ready) retried = false }
    val standby = state.ready && state.power == false
    val busy = state.link == RemoteModel.Link.CONNECTING || state.link == RemoteModel.Link.IDLE
    val offline = state.link == RemoteModel.Link.OFFLINE
    val onTap = {
        when {
            standby -> model.power()
            offline -> if (retried) openDetails() else { retried = true; model.connect() }
            else -> openDetails()
        }
    }
    Column(modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).clickable(enabled = !busy, onClick = onTap).padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            when {
                busy -> { CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = Quiet.muted); ChipText(state.tvName, Quiet.muted) }
                offline -> { Dot(Quiet.amber); ChipText(stringResource(R.string.chip_offline), Quiet.amber) }
                standby -> { Dot(Quiet.muted); ChipText(stringResource(R.string.chip_standby), Color.White) }
                else -> { Dot(Quiet.green); ChipText(state.tvName, Color.White) }
            }
        }
        val app = if (state.kind == TvKind.ANDROID_TV) Brand.nameOf(state.foreground) else state.appName
        if (state.ready && !standby && app != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Icon(Icons.Outlined.Tv, null, tint = Quiet.muted, modifier = Modifier.size(13.dp))
                Text(app, fontSize = 13.sp, color = Quiet.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}


@Composable
private fun Dot(color: Color) = Box(Modifier.size(8.dp).background(color, CircleShape))

@Composable
private fun ChipText(text: String, color: Color) =
    Text(text, color = color, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)

@Composable
private fun RoundKey(icon: ImageVector, label: String, size: Dp, fill: Color, stroke: Color?, enabled: Boolean, tint: Color = Color.White, onClick: () -> Unit) {
    val haptics = rememberHaptics()
    Surface(
        onClick = { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); onClick() }, enabled = enabled, shape = CircleShape, color = fill,
        border = stroke?.let { androidx.compose.foundation.BorderStroke(1.dp, it) },
        modifier = Modifier.size(size).alpha(if (enabled) 1f else 0.45f).semantics { contentDescription = label },
    ) { Box(contentAlignment = Alignment.Center) { Icon(icon, null, tint = tint, modifier = Modifier.size(22.dp)) } }
}

/** Back, Home, Play and the media row: 65 × 50 rounded keys. */
@Composable
private fun Command(icon: ImageVector, @StringRes label: Int, enabled: Boolean, onClick: () -> Unit) {
    val haptics = rememberHaptics()
    val text = stringResource(label)
    Surface(
        onClick = { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); onClick() }, enabled = enabled,
        shape = RoundedCornerShape(21.dp), color = Quiet.ink, border = androidx.compose.foundation.BorderStroke(1.dp, Quiet.edge),
        modifier = Modifier.width(65.dp).height(50.dp).alpha(if (enabled) 1f else 0.45f).semantics { contentDescription = text },
    ) { Box(contentAlignment = Alignment.Center) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(25.dp)) } }
}

/**
 * The round pad. Like the iPhone, the whole circle is one touch surface driven by [PadInteraction]: a tap on an
 * arrow or OK sends it; holding it repeats (press, then release); a swipe anywhere sends that direction.
 */
@Composable
private fun DPad(enabled: Boolean, reversed: Boolean, model: RemoteModel) {
    val haptics = rememberHaptics()
    val scope = rememberCoroutineScope()
    val pad = remember { PadInteraction() }
    SideEffect { pad.reversed = reversed }
    var highlighted by remember { mutableStateOf<TVKey?>(null) }
    val density = LocalDensity.current
    fun run(commands: List<PadInteraction.Command>) = commands.forEach { c ->
        when (c) {
            is PadInteraction.Command.Tap -> { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); model.tap(c.key) }
            is PadInteraction.Command.Press -> { haptics.performHapticFeedback(HapticFeedbackType.LongPress); model.press(c.key) }
            is PadInteraction.Command.Release -> model.release(c.key)
        }
    }
    DisposableEffect(enabled) { onDispose { run(pad.cancel()); highlighted = null } }
    val labels = mapOf(
        TVKey.UP to stringResource(R.string.key_up), TVKey.DOWN to stringResource(R.string.key_down),
        TVKey.LEFT to stringResource(R.string.key_left), TVKey.RIGHT to stringResource(R.string.key_right),
        TVKey.SELECT to stringResource(R.string.key_select),
    )
    Box(
        Modifier.size(284.dp).alpha(if (enabled) 1f else 0.45f)
            .background(Quiet.ink, CircleShape).border(1.dp, Color.White.copy(alpha = 0.08f), CircleShape)
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                val radius = size.width / 2f
                val center = Offset(radius, radius)
                val okRadius = with(density) { 58.dp.toPx() }
                awaitEachGesture {
                    val down = awaitFirstDown()
                    val key = keyAt(down.position - center, okRadius)
                    run(pad.begin(key))
                    highlighted = key
                    var hold: Job? = scope.launch { delay(450); run(pad.hold()) }
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        val d = change.position - down.position
                        val dx = with(density) { d.x.toDp().value.toDouble() }
                        val dy = with(density) { d.y.toDp().value.toDouble() }
                        if (!change.pressed) {
                            hold?.cancel(); hold = null
                            run(pad.end(dx, dy)); highlighted = null
                            break
                        }
                        run(pad.move(dx, dy))
                        if (pad.isSwiping) { hold?.cancel(); hold = null; highlighted = TVKey.swipeDirection(dx, dy, pad.reversed) }
                        change.consume()
                    }
                    hold?.cancel()
                    run(pad.cancel()); highlighted = null
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        PadKey(Icons.Rounded.KeyboardArrowUp, highlighted == TVKey.UP, Modifier.offset(y = (-103).dp).size(100.dp, 66.dp), labels[TVKey.UP]!!) { model.tap(TVKey.UP) }
        PadKey(Icons.Rounded.KeyboardArrowDown, highlighted == TVKey.DOWN, Modifier.offset(y = 103.dp).size(100.dp, 66.dp), labels[TVKey.DOWN]!!) { model.tap(TVKey.DOWN) }
        PadKey(Icons.Rounded.KeyboardArrowLeft, highlighted == TVKey.LEFT, Modifier.offset(x = (-103).dp).size(66.dp, 100.dp), labels[TVKey.LEFT]!!) { model.tap(TVKey.LEFT) }
        PadKey(Icons.Rounded.KeyboardArrowRight, highlighted == TVKey.RIGHT, Modifier.offset(x = 103.dp).size(66.dp, 100.dp), labels[TVKey.RIGHT]!!) { model.tap(TVKey.RIGHT) }
        Box(
            Modifier.size(116.dp).background(Color.White.copy(alpha = if (highlighted == TVKey.SELECT) 0.18f else 0.09f), CircleShape)
                .border(1.dp, Color.White.copy(alpha = if (highlighted == TVKey.SELECT) 0.55f else 0.12f), CircleShape)
                .semantics { contentDescription = labels[TVKey.SELECT]!!; role = Role.Button; onClick { model.tap(TVKey.SELECT); true } },
            contentAlignment = Alignment.Center,
        ) { Text(labels[TVKey.SELECT]!!, fontSize = 26.sp, fontWeight = FontWeight.SemiBold) }
    }
}

/** OK in the middle; otherwise the arrow whose quarter of the circle the touch is in. */
private fun keyAt(p: Offset, okRadius: Float): TVKey? = when {
    hypot(p.x, p.y) <= okRadius -> TVKey.SELECT
    abs(p.x) > abs(p.y) -> if (p.x > 0) TVKey.RIGHT else TVKey.LEFT
    else -> if (p.y > 0) TVKey.DOWN else TVKey.UP
}

@Composable
private fun PadKey(icon: ImageVector, highlighted: Boolean, modifier: Modifier, label: String, onAccessibilityClick: () -> Unit) {
    Box(
        modifier.background(Color.White.copy(alpha = if (highlighted) 0.18f else 0f), RoundedCornerShape(24.dp))
            .border(1.dp, Color.White.copy(alpha = if (highlighted) 0.55f else 0f), RoundedCornerShape(24.dp))
            .semantics { contentDescription = label; role = Role.Button; onClick { onAccessibilityClick(); true } },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(34.dp)) }
}

/** Volume: hold − or + to keep changing it, the TV's level in the middle, mute on the right. */
@Composable
private fun Volume(state: RemoteModel.State, model: RemoteModel) {
    val enabled = state.ready
    Row(Modifier.fillMaxWidth().alpha(if (enabled) 1f else 0.45f).background(Quiet.ink, CircleShape).border(1.dp, Quiet.edge, CircleShape),
        verticalAlignment = Alignment.CenterVertically) {
        HoldKey(Icons.Rounded.Remove, stringResource(R.string.key_volume_down), TVKey.VOLUME_DOWN, enabled, model)
        val v = state.volume
        Text(
            when { v == null -> stringResource(R.string.volume_title); v.muted -> stringResource(R.string.muted)
                v.maximum == 100 -> stringResource(R.string.volume, v.level); else -> stringResource(R.string.volume_of, v.level, v.maximum) },
            fontSize = 15.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        HoldKey(Icons.Rounded.Add, stringResource(R.string.key_volume_up), TVKey.VOLUME_UP, enabled, model)
        val haptics = rememberHaptics()
        // Shows what a tap does, from the TV's own mute state: muted → speaker (unmute).
        val muted = v?.muted == true
        val mute = stringResource(if (muted) R.string.key_unmute else R.string.key_mute)
        Box(Modifier.size(48.dp, 56.dp).clip(CircleShape).clickable(enabled = enabled) { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); model.tap(TVKey.MUTE) }
            .semantics { contentDescription = mute }, contentAlignment = Alignment.Center) {
            Crossfade(muted, label = "mute") { m ->
                Icon(if (m) Icons.AutoMirrored.Outlined.VolumeUp else Icons.AutoMirrored.Outlined.VolumeOff, null, tint = Color.White, modifier = Modifier.size(21.dp))
            }
        }
    }
}

/** A key that stays pressed on the TV while the finger is down (HoldKey). */
@Composable
private fun HoldKey(icon: ImageVector, label: String, key: TVKey, enabled: Boolean, model: RemoteModel) {
    val haptics = rememberHaptics()
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    var down by remember { mutableStateOf(false) }
    DisposableEffect(Unit) { onDispose { if (down) model.release(key) } }
    Box(
        Modifier.size(64.dp, 56.dp).clip(CircleShape)
            .background(Color.White.copy(alpha = if (down || pressed) 0.13f else 0f))
            .semantics { contentDescription = label; role = Role.Button; onClick { model.tap(key); true } }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                awaitEachGesture {
                    awaitFirstDown()
                    down = true; haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); model.press(key)
                    do { val e = awaitPointerEvent() } while (e.changes.any { it.pressed })
                    down = false; model.release(key)
                }
            },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(24.dp)) }
}

/** Light haptics on presses, unless "Touch feedback" is off in Settings. */
@Composable
fun rememberHaptics(): androidx.compose.ui.hapticfeedback.HapticFeedback {
    val system = LocalHapticFeedback.current
    val on = LocalHapticsOn.current
    return remember(system, on) {
        object : androidx.compose.ui.hapticfeedback.HapticFeedback {
            override fun performHapticFeedback(hapticFeedbackType: HapticFeedbackType) { if (on) system.performHapticFeedback(hapticFeedbackType) }
        }
    }
}

val LocalHapticsOn = androidx.compose.runtime.staticCompositionLocalOf { true }

/** App shortcuts: two columns of brand-coloured buttons with the logo, as on the iPhone (Settings › Remote shortcuts). */
@Composable
private fun Apps(enabled: Boolean, apps: List<com.guilhermeramalho.puriotv.core.RemoteApp>, model: RemoteModel) {
    val haptics = rememberHaptics()
    Column(Modifier.fillMaxWidth().padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        apps.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                pair.forEach { app ->
                    val open = stringResource(R.string.open_app, app.name)
                    Surface(
                        onClick = { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); model.open(app) }, enabled = enabled,
                        shape = RoundedCornerShape(17.dp), color = Brand.color(app.id), border = androidx.compose.foundation.BorderStroke(1.dp, Quiet.edge),
                        modifier = Modifier.weight(1f).height(58.dp).alpha(if (enabled) 1f else 0.45f).semantics { contentDescription = open },
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            val logo = Brand.logo(app.id)
                            if (logo != null) {
                                Image(painterResource(logo), null, colorFilter = ColorFilter.tint(Color.White),
                                    modifier = Modifier.height(Brand.logoHeight(app.id).dp).widthIn(max = 108.dp))
                            } else Text(app.name, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                        }
                    }
                }
                if (pair.size == 1) Box(Modifier.weight(1f))
            }
        }
    }
}

/**
 * Play and pause side by side (the iPhone's playpause.fill, Google's TV remote): one toggle key, because the remote
 * protocol doesn't tell the phone whether something is playing.
 */
private val PlayPauseIcon: ImageVector by lazy {
    ImageVector.Builder("PlayPause", 24.dp, 24.dp, 24f, 24f).apply {
        path(fill = SolidColor(Color.White)) {
            moveTo(2.5f, 6.2f); curveTo(2.5f, 5.4f, 3.4f, 4.9f, 4.1f, 5.4f); lineTo(11.4f, 11.2f)
            curveTo(11.9f, 11.6f, 11.9f, 12.4f, 11.4f, 12.8f); lineTo(4.1f, 18.6f); curveTo(3.4f, 19.1f, 2.5f, 18.6f, 2.5f, 17.8f); close()
        }
        path(fill = SolidColor(Color.White)) {
            moveTo(14f, 6f); curveTo(14f, 5.4f, 14.4f, 5f, 15f, 5f); lineTo(16f, 5f); curveTo(16.6f, 5f, 17f, 5.4f, 17f, 6f)
            lineTo(17f, 18f); curveTo(17f, 18.6f, 16.6f, 19f, 16f, 19f); lineTo(15f, 19f); curveTo(14.4f, 19f, 14f, 18.6f, 14f, 18f); close()
            moveTo(19.5f, 6f); curveTo(19.5f, 5.4f, 19.9f, 5f, 20.5f, 5f); lineTo(21.5f, 5f); curveTo(22.1f, 5f, 22.5f, 5.4f, 22.5f, 6f)
            lineTo(22.5f, 18f); curveTo(22.5f, 18.6f, 22.1f, 19f, 21.5f, 19f); lineTo(20.5f, 19f); curveTo(19.9f, 19f, 19.5f, 18.6f, 19.5f, 18f); close()
        }
    }.build()
}
