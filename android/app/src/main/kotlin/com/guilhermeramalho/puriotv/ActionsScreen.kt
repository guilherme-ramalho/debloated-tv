package com.guilhermeramalho.puriotv

import android.content.Context
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Bedtime
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material.icons.outlined.Widgets
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material.icons.outlined.ViewQuilt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.guilhermeramalho.puriotv.core.ActionStep
import com.guilhermeramalho.puriotv.core.CommandRunner
import com.guilhermeramalho.puriotv.core.QuickAction
import com.guilhermeramalho.puriotv.core.RemotePreferences
import com.guilhermeramalho.puriotv.core.TVKey
import com.guilhermeramalho.puriotv.core.TVSession
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** Runs one quick action at a time from the Actions tab (ActionController). Cancelled when the app leaves the screen. */
class ActionController(private val context: Context, private val scope: CoroutineScope, private val remote: RemoteModel) {
    data class State(val running: String? = null, val progress: Int = 0, val message: String = "")
    val state = MutableStateFlow(State())
    private var job: Job? = null
    private var runner: CommandRunner? = null

    fun cancel() { job?.cancel(); job = null; runner?.cancel(); runner = null; state.value = state.value.copy(running = null) }

    fun run(action: QuickAction) {
        if (state.value.running != null) return
        try { action.validate() } catch (e: Exception) { state.value = State(message = errorText(context, e)); return }
        val pin = remote.pin ?: run { state.value = State(message = context.getString(R.string.pair_first)); return }
        state.value = State(running = action.id)
        val prefs = remote.settings.current
        val host = remote.state.value.host
        job = scope.launch {
            val identity = try { remote.clientIdentity() } catch (e: Exception) { state.value = State(message = errorText(context, e)); return@launch }
            val kind = remote.state.value.kind
            val r = CommandRunner({ TVSession(host, identity, remote.clientName, remote.clientInfo(), scope) },
                newBrand = { com.guilhermeramalho.puriotv.core.BrandRemotes.make(kind, host, scope) }).also { runner = it }
            val message = try {
                r.run(action.steps, pin, prefs.apps, if (prefs.editorHost == host) prefs.tvInputs else emptyList()) { n -> state.value = state.value.copy(progress = n) }
                context.getString(R.string.commands_sent)
            } catch (e: CancellationException) { context.getString(R.string.action_cancelled) }
            catch (e: Exception) { errorText(context, e) }
            state.value = State(message = message)
            runner = null; job = null
        }
    }
}

fun keyName(context: Context, key: TVKey): String = context.getString(when (key) {
    TVKey.UP -> R.string.key_up; TVKey.DOWN -> R.string.key_down; TVKey.LEFT -> R.string.key_left; TVKey.RIGHT -> R.string.key_right
    TVKey.SELECT -> R.string.key_select; TVKey.BACK -> R.string.key_back; TVKey.POWER -> R.string.key_power
    TVKey.REWIND -> R.string.key_rewind; TVKey.FAST_FORWARD -> R.string.key_fast_forward; TVKey.CAPTIONS -> R.string.key_captions
    TVKey.SETTINGS -> R.string.key_settings; else -> R.string.remote_key
})

/** A step as people read it ("Open Netflix", "Select PlayStation 5"). */
fun stepName(context: Context, step: ActionStep, prefs: RemotePreferences): String = when (step.kind) {
    ActionStep.Kind.WAKE -> context.getString(R.string.key_wake)
    ActionStep.Kind.SLEEP -> context.getString(R.string.turn_off_tv)
    ActionStep.Kind.HOME -> context.getString(R.string.tv_home)
    ActionStep.Kind.MUTE -> context.getString(R.string.mute_tv)
    ActionStep.Kind.PAUSE -> context.getString(R.string.pause)
    ActionStep.Kind.PLAY_PAUSE -> context.getString(R.string.play_pause)
    ActionStep.Kind.VOLUME_UP -> context.getString(R.string.key_volume_up)
    ActionStep.Kind.VOLUME_DOWN -> context.getString(R.string.key_volume_down)
    ActionStep.Kind.KEY -> step.key?.let { keyName(context, it) } ?: context.getString(R.string.remote_key)
    ActionStep.Kind.OPEN_APP -> context.getString(R.string.open_app, prefs.app(step.argument)?.name ?: context.getString(R.string.app))
    ActionStep.Kind.INPUT -> context.getString(R.string.select_named, prefs.tvInputs.firstOrNull { it.id == step.argument }?.name ?: context.getString(R.string.input))
}

sealed interface ActionsRoute {
    data object Widgets : ActionsRoute
    data object SleepTimer : ActionsRoute
}

/** The Actions tab (ActionsView): saved quick actions, then hands-free and quick access. */
@Composable
fun ActionsScreen(model: RemoteModel, open: (ActionsRoute) -> Unit) {
    val settings = model.settings
    val prefs by settings.value.collectAsState()
    val run by model.actions.state.collectAsState()
    val context = LocalContext.current
    var editing by remember { mutableStateOf<QuickAction?>(null) }
    Page {
        PageTitle(stringResource(R.string.tab_actions)) {
            IconButton(onClick = { editing = QuickAction(name = context.getString(R.string.new_action), steps = listOf(ActionStep.of(ActionStep.Kind.WAKE))) },
                enabled = prefs.actions.size < 30) { Icon(Icons.Rounded.Add, stringResource(R.string.create_quick_action), tint = Quiet.cyan) }
        }
        prefs.actions.forEach { action ->
            RowCard {
                Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(11.dp)) {
                        Icon(if (action.steps.any { it.kind == ActionStep.Kind.INPUT }) Icons.Outlined.SportsEsports else Icons.Outlined.Movie, null)
                        Text(action.name, fontSize = 17.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                        IconButton(onClick = { editing = action }) { Icon(Icons.Outlined.MoreHoriz, stringResource(R.string.edit_named, action.name)) }
                    }
                    Text(action.steps.joinToString(" → ") { stepName(context, it, prefs) }, fontSize = 12.sp, color = Quiet.muted, lineHeight = 17.sp)
                    if (run.running == action.id) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.heightIn(min = 44.dp)) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            Text(stringResource(R.string.n_of_m, run.progress, action.steps.size), fontSize = 13.sp, modifier = Modifier.weight(1f))
                            TextButton(onClick = { model.actions.cancel() }) { Text(stringResource(R.string.cancel)) }
                        }
                    } else {
                        OutlinedButton(onClick = { model.actions.run(action) }, enabled = run.running == null, shape = RoundedCornerShape(11.dp),
                            border = BorderStroke(1.dp, Quiet.edge)) {
                            Icon(Icons.Rounded.PlayArrow, null, Modifier.size(18.dp)); Text(" " + stringResource(R.string.run), fontSize = 13.sp)
                        }
                    }
                }
            }
        }
        if (prefs.actions.isEmpty()) Caption(stringResource(R.string.create_action_hint))
        if (run.message.isNotEmpty()) Caption(run.message)
        SectionTitle(stringResource(R.string.quick_access))
        RowCard {
            NavRow(Icons.Outlined.Widgets, stringResource(R.string.widgets_and_tile), stringResource(R.string.widgets_and_tile_detail)) { open(ActionsRoute.Widgets) }
            RowDivider()
            NavRow(Icons.Outlined.Bedtime, stringResource(R.string.sleep_timer), stringResource(R.string.sleep_timer_detail)) { open(ActionsRoute.SleepTimer) }
        }
        Caption(stringResource(R.string.widgets_hint))
    }
    editing?.let { QuickActionForm(it, settings) { editing = null } }
}

/** Create or edit a quick action (QuickActionForm): name, steps in order, delete. */
@Composable
private fun QuickActionForm(initial: QuickAction, settings: AppSettings, onDismiss: () -> Unit) {
    val prefs by settings.value.collectAsState()
    val context = LocalContext.current
    var name by remember { mutableStateOf(initial.name) }
    var steps by remember { mutableStateOf(initial.steps) }
    var menu by remember { mutableStateOf<String?>(null) }
    fun add(step: ActionStep) { steps = steps + step; menu = null }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.quick_action)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.action_name)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                SectionTitle(stringResource(R.string.steps))
                steps.forEachIndexed { i, step ->
                    ReorderRow(leading = { Text("${i + 1}", color = Quiet.muted) }, title = stepName(context, step, prefs),
                        canUp = i > 0, canDown = i < steps.size - 1, onMove = { d -> steps = steps.moved(i, i + d) },
                        onRemove = { steps = steps.filterIndexed { j, _ -> j != i } })
                }
                Box {
                    TextButton(onClick = { menu = "main" }, enabled = steps.size < 12) { Icon(Icons.Rounded.Add, null); Text(" " + stringResource(R.string.add_step)) }
                    DropdownMenu(menu == "main", { menu = null }) {
                        DropdownMenuItem({ Text(stringResource(R.string.key_wake)) }, { add(ActionStep.of(ActionStep.Kind.WAKE)) })
                        DropdownMenuItem({ Text(stringResource(R.string.turn_off_tv)) }, { add(ActionStep.of(ActionStep.Kind.SLEEP)) })
                        DropdownMenuItem({ Text(stringResource(R.string.open_app_menu)) }, { menu = "apps" })
                        DropdownMenuItem({ Text(stringResource(R.string.select_input)) }, { menu = "inputs" }, enabled = prefs.tvInputs.isNotEmpty())
                        DropdownMenuItem({ Text(stringResource(R.string.tv_home)) }, { add(ActionStep.of(ActionStep.Kind.HOME)) })
                        DropdownMenuItem({ Text(stringResource(R.string.mute_tv)) }, { add(ActionStep.of(ActionStep.Kind.MUTE)) })
                        DropdownMenuItem({ Text(stringResource(R.string.pause)) }, { add(ActionStep.of(ActionStep.Kind.PAUSE)) })
                        DropdownMenuItem({ Text(stringResource(R.string.play_pause)) }, { add(ActionStep.of(ActionStep.Kind.PLAY_PAUSE)) })
                    }
                    DropdownMenu(menu == "apps", { menu = null }) {
                        prefs.apps.forEach { app -> DropdownMenuItem({ Text(app.name) }, { add(ActionStep.of(ActionStep.Kind.OPEN_APP, app.id)) }) }
                    }
                    DropdownMenu(menu == "inputs", { menu = null }) {
                        prefs.tvInputs.forEach { input -> DropdownMenuItem({ Text(input.name) }, { add(ActionStep.of(ActionStep.Kind.INPUT, input.id)) }) }
                    }
                }
                if (prefs.actions.any { it.id == initial.id }) TextButton(onClick = {
                    settings.update { p -> p.copy(actions = p.actions.filterNot { it.id == initial.id }) }; onDismiss()
                }) { Text(stringResource(R.string.delete_action), color = Quiet.amber) }
                Caption(stringResource(R.string.action_footer))
            }
        },
        confirmButton = {
            TextButton(enabled = name.isNotBlank() && steps.isNotEmpty(), onClick = {
                val action = initial.copy(name = name.trim(), steps = steps)
                try {
                    action.validate()
                    settings.update { p -> p.copy(actions = if (p.actions.any { it.id == action.id }) p.actions.map { if (it.id == action.id) action else it } else p.actions + action) }
                    onDismiss()
                } catch (e: Exception) { settings.notice.value = errorText(context, e) }
            }) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/**
 * Android's quick access, in place of the iPhone's Siri & Shortcuts: home-screen widgets, a Quick Settings tile and
 * the app icon's shortcuts. Each runs in the background over one short connection; nothing stays running.
 */
@Composable
fun WidgetsScreen(onBack: () -> Unit) {
    SubPage(stringResource(R.string.widgets_and_tile), onBack) {
        RowCard {
            NavRow(Icons.Outlined.ViewQuilt, stringResource(R.string.widget_remote), stringResource(R.string.widget_remote_detail), chevron = false)
            RowDivider()
            NavRow(Icons.Outlined.TouchApp, stringResource(R.string.widget_actions), stringResource(R.string.widget_actions_detail), chevron = false)
            RowDivider()
            NavRow(Icons.Outlined.PowerSettingsNew, stringResource(R.string.tile_power), stringResource(R.string.tile_power_detail), chevron = false)
            RowDivider()
            NavRow(Icons.Outlined.Apps, stringResource(R.string.app_shortcuts), stringResource(R.string.app_shortcuts_detail), chevron = false)
        }
        Caption(stringResource(R.string.quick_access_footer))
    }
}

/** Sleep timer (SleepTimerView): runs on the TV, shown as active only once the TV confirms it. */
@Composable
fun SleepTimerScreen(model: RemoteModel, onBack: () -> Unit) {
    val ed by model.editor.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf<Int?>(null) }
    var custom by remember { mutableStateOf(false) }
    val deadline = ed.snapshot?.sleepDeadline?.takeIf { it > System.currentTimeMillis() / 1000.0 }
    fun schedule(minutes: Int) {
        working = true
        scope.launch {
            try { model.editor.sleepTimer(minutes); selected = if (minutes == 0) null else minutes } catch (e: Exception) { model.settings.notice.value = errorText(context, e) }
            working = false
        }
    }
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { model.editor.close() } }
    SubPage(stringResource(R.string.sleep_timer), onBack) {
        RowCard {
            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(Icons.Outlined.Bedtime, null)
                    Text(deadline?.let { stringResource(R.string.turn_off_at, DateFormat.getTimeInstance(DateFormat.SHORT).format(Date((it * 1000).toLong()))) }
                        ?: stringResource(R.string.no_confirmed_timer), fontSize = 17.sp, fontWeight = FontWeight.Medium)
                }
                Caption(stringResource(R.string.timer_runs_on_tv))
            }
        }
        listOf(15, 30, 45, 60, 90, 120).chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                row.forEach { value ->
                    val on = selected == value && deadline != null
                    Surface(onClick = { schedule(value) }, enabled = ed.ready && !working, shape = RoundedCornerShape(13.dp),
                        color = if (on) androidx.compose.ui.graphics.Color(0xFF32435E) else Quiet.panel, border = BorderStroke(1.dp, if (on) Quiet.cyan else Quiet.edge),
                        modifier = Modifier.weight(1f).heightIn(min = 52.dp)) {
                        Box(contentAlignment = Alignment.Center) { Text(stringResource(R.string.n_min, value), fontSize = 14.sp) }
                    }
                }
            }
        }
        SecondaryButton(stringResource(R.string.custom_duration)) { custom = true }
        if (deadline != null) SecondaryButton(stringResource(R.string.cancel_timer), enabled = ed.ready && !working) { schedule(0) }
        if (working) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp); Caption(stringResource(R.string.confirming_on_tv))
        }
        RowCard { EditorConnection(model) }
        Caption(stringResource(R.string.timer_footer))
    }
    if (custom) {
        var text by remember { mutableStateOf("30") }
        val minutes = text.toIntOrNull()
        AlertDialog(
            onDismissRequest = { custom = false }, title = { Text(stringResource(R.string.custom_timer)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(text, { text = it.filter(Char::isDigit).take(3) }, label = { Text(stringResource(R.string.minutes)) }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                    Caption(stringResource(R.string.minutes_range))
                }
            },
            confirmButton = { TextButton(enabled = ed.ready && !working && minutes != null && minutes in 1..240, onClick = { custom = false; schedule(minutes!!) }) { Text(stringResource(R.string.set_timer)) } },
            dismissButton = { TextButton(onClick = { custom = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}
