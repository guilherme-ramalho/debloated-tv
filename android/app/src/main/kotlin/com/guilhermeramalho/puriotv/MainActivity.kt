package com.guilhermeramalho.puriotv

import android.os.Bundle
import android.view.HapticFeedbackConstants
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.automirrored.filled.Input
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.automirrored.filled.VolumeDown
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.guilhermeramalho.puriotv.core.TVKey
import com.guilhermeramalho.puriotv.core.TVSession

class MainActivity : ComponentActivity() {
    private val model: RemoteModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(background = Color(0xFF0E0F13), surface = Color(0xFF0E0F13))) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    App(model)
                }
            }
        }
    }

    override fun onStart() { super.onStart(); model.foreground(true) }
    override fun onStop() { model.foreground(false); super.onStop() }
}

@Composable
private fun App(model: RemoteModel) {
    val state by model.state.collectAsStateWithLifecycle()
    Box(Modifier.safeDrawingPadding().padding(16.dp)) {
        when (val screen = state.screen) {
            RemoteModel.Screen.Find -> FindScreen(model)
            is RemoteModel.Screen.Pairing -> PairScreen(state, screen.waitingForCode, model)
            RemoteModel.Screen.Connecting -> Waiting(stringResource(R.string.connecting, state.tvName)) { model.forget() }
            RemoteModel.Screen.Remote -> RemoteScreen(state, model)
            is RemoteModel.Screen.Failed -> Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(stringResource(screen.problem.message()), style = MaterialTheme.typography.bodyLarge)
                Button(onClick = { model.connect() }) { Text(stringResource(R.string.retry)) }
                TextButton(onClick = { model.forget() }) { Text(stringResource(R.string.forget_tv)) }
            }
        }
    }
}

@Composable
private fun Waiting(text: String, onCancel: () -> Unit) {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        CircularProgressIndicator()
        Spacer(Modifier.height(16.dp))
        Text(text)
        TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) }
    }
}

@Composable
private fun FindScreen(model: RemoteModel) {
    val tvs by model.discovery.tvs.collectAsStateWithLifecycle()
    var address by rememberSaveable { mutableStateOf("") }
    // Search only while this screen is visible and the app is in front.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> model.discovery.start()
                Lifecycle.Event.ON_STOP -> model.discovery.stop()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) model.discovery.start()
        onDispose { lifecycle.removeObserver(observer); model.discovery.stop() }
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.find_title), style = MaterialTheme.typography.headlineSmall)
        Text(stringResource(if (tvs.isEmpty()) R.string.find_none else R.string.find_searching),
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        LazyColumn(Modifier.weight(1f, fill = false)) {
            items(tvs, key = { it.name }) { tv ->
                ListItem(
                    headlineContent = { Text(tv.name) },
                    supportingContent = { Text(tv.host ?: stringResource(R.string.find_resolving)) },
                    leadingContent = { Icon(Icons.Filled.Tv, null) },
                    modifier = Modifier.pointerInput(tv) { detectTapGestures { tv.host?.let { model.choose(it, tv.name) } } },
                )
            }
        }
        OutlinedTextField(
            value = address, onValueChange = { address = it.replace(',', '.').filterNot(Char::isWhitespace) },
            label = { Text(stringResource(R.string.address_label)) }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { if (isIPv4(address)) model.choose(address, address) }),
            modifier = Modifier.fillMaxWidth(),
        )
        Button(onClick = { model.choose(address, address) }, enabled = isIPv4(address)) { Text(stringResource(R.string.address_use)) }
    }
}

fun isIPv4(text: String): Boolean {
    val parts = text.split('.')
    return parts.size == 4 && parts.all { p -> p.isNotEmpty() && p.length <= 3 && p.all(Char::isDigit) && p.toInt() in 0..255 }
}

@Composable
private fun PairScreen(state: RemoteModel.State, waitingForCode: Boolean, model: RemoteModel) {
    if (!waitingForCode) return Waiting(stringResource(R.string.pair_starting)) { model.forget() }
    var code by rememberSaveable { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.pair_title, state.tvName), style = MaterialTheme.typography.headlineSmall)
        Text(stringResource(R.string.pair_hint))
        OutlinedTextField(
            value = code, onValueChange = { code = it.uppercase().filter { c -> c.isLetterOrDigit() }.take(6) },
            label = { Text(stringResource(R.string.pair_code)) }, singleLine = true,
            isError = state.notice != null,
            supportingText = { state.notice?.let { Text(stringResource(it.message())) } },
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false,
                keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { if (code.length == 6) model.submit(code) }),
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { model.submit(code) }, enabled = code.length == 6) { Text(stringResource(R.string.pair_submit)) }
            TextButton(onClick = { model.forget() }) { Text(stringResource(R.string.cancel)) }
        }
    }
}

@Composable
private fun RemoteScreen(state: RemoteModel.State, model: RemoteModel) {
    val view = LocalView.current
    val press: (TVKey) -> Unit = { key ->
        view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        model.key(key)
    }
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(state.tvName, style = MaterialTheme.typography.titleLarge)
                val status = when {
                    state.power == false -> stringResource(R.string.tv_off)
                    state.foreground != null && TVSession.appName(state.foreground) != null ->
                        stringResource(R.string.now_on, TVSession.appName(state.foreground)!!)
                    else -> stringResource(R.string.connected)
                }
                Text(status, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            KeyButton(Icons.Filled.PowerSettingsNew, R.string.key_power) { press(TVKey.POWER) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            KeyButton(Icons.AutoMirrored.Filled.Input, R.string.key_inputs) { press(TVKey.INPUTS) }
            KeyButton(Icons.Filled.Settings, R.string.key_settings) { press(TVKey.SETTINGS) }
        }
        DPad(press)
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            KeyButton(Icons.AutoMirrored.Filled.ArrowBack, R.string.key_back) { press(TVKey.BACK) }
            KeyButton(Icons.Filled.Home, R.string.key_home) { press(TVKey.HOME) }
            KeyButton(Icons.Filled.PlayArrow, R.string.key_play_pause) { press(TVKey.PLAY_PAUSE) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            KeyButton(Icons.AutoMirrored.Filled.VolumeDown, R.string.key_volume_down) { press(TVKey.VOLUME_DOWN) }
            KeyButton(Icons.AutoMirrored.Filled.VolumeOff, R.string.key_mute) { press(TVKey.MUTE) }
            KeyButton(Icons.AutoMirrored.Filled.VolumeUp, R.string.key_volume_up) { press(TVKey.VOLUME_UP) }
        }
        state.volume?.let { v ->
            Text(if (v.muted) stringResource(R.string.muted) else stringResource(R.string.volume, v.level, v.maximum),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun KeyButton(icon: ImageVector, label: Int, onClick: () -> Unit) {
    val text = stringResource(label)
    FilledTonalIconButton(onClick = onClick, modifier = Modifier.size(56.dp).semantics { contentDescription = text }) {
        Icon(icon, contentDescription = null)
    }
}

/** Arrows around OK. A first version: taps only (swipe and hold come with PadInteraction next). */
@Composable
private fun DPad(press: (TVKey) -> Unit) {
    Box(Modifier.size(240.dp).aspectRatio(1f).background(MaterialTheme.colorScheme.surfaceVariant, CircleShape)) {
        DPadKey(Icons.Filled.KeyboardArrowUp, R.string.key_up, Alignment.TopCenter) { press(TVKey.UP) }
        DPadKey(Icons.Filled.KeyboardArrowDown, R.string.key_down, Alignment.BottomCenter) { press(TVKey.DOWN) }
        DPadKey(Icons.AutoMirrored.Filled.KeyboardArrowLeft, R.string.key_left, Alignment.CenterStart) { press(TVKey.LEFT) }
        DPadKey(Icons.AutoMirrored.Filled.KeyboardArrowRight, R.string.key_right, Alignment.CenterEnd) { press(TVKey.RIGHT) }
        val ok = stringResource(R.string.key_select)
        Button(onClick = { press(TVKey.SELECT) }, shape = CircleShape,
            modifier = Modifier.align(Alignment.Center).size(96.dp).semantics { contentDescription = ok }) { Text(ok) }
    }
}

@Composable
private fun androidx.compose.foundation.layout.BoxScope.DPadKey(icon: ImageVector, label: Int, alignment: Alignment, onClick: () -> Unit) {
    val text = stringResource(label)
    androidx.compose.material3.IconButton(onClick = onClick,
        modifier = Modifier.align(alignment).padding(8.dp).size(64.dp).semantics { contentDescription = text }) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(40.dp))
    }
}
