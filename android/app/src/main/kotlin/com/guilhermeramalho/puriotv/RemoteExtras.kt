package com.guilhermeramalho.puriotv

import androidx.compose.foundation.background
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AddCircleOutline
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.outlined.Input
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.guilhermeramalho.puriotv.core.FavoriteInput
import com.guilhermeramalho.puriotv.core.TVKey
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Type on TV (KeyboardView): what you type fills the focused field on the TV as you go. Only the change since the
 * last send goes, once typing pauses for 400 ms, so the TV gets one update per pause; the keyboard's Go sends at once.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KeyboardSheet(model: RemoteModel, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    var secure by rememberSaveable { mutableStateOf(false) }
    var message by remember { mutableStateOf("") }
    // What the TV's field holds, as far as this sheet knows.
    var sent by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var stamp by remember { mutableStateOf(0) }
    val focus = remember { FocusRequester() }

    suspend fun push() {
        while (!sending && text != sent) {
            if (!model.state.value.ready) { message = context.getString(R.string.connect_before_text); return }
            if (text.length > 4096) { message = context.getString(R.string.problem_text_length); return }
            sending = true
            val value = text
            try {
                // Only the change goes: the TV inserts at its cursor, so the whole text again would repeat it.
                val (deletes, insert) = com.guilhermeramalho.puriotv.core.TVSession.typingEdit(sent, value)
                repeat(minOf(deletes, 256)) { model.tap(TVKey.DELETE) }
                if (insert.isNotEmpty()) model.sendText(insert)
                sent = value; message = ""
            } catch (e: Exception) {
                message = errorText(context, e); sending = false; return
            }
            sending = false
        }
    }
    LaunchedEffect(text) { val mine = ++stamp; delay(400); if (mine == stamp) push() }

    ModalBottomSheet(onDismissRequest = { stamp++; scope.launch { push() }; onDismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Quiet.panel) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 16.dp).navigationBarsPadding().imePadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Text(stringResource(R.string.type_on_tv), style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                TextButton(onClick = { stamp++; scope.launch { push(); onDismiss() } }) { Text(stringResource(R.string.done)) }
            }
            OutlinedTextField(
                value = text, onValueChange = { text = it }, singleLine = true,
                label = { Text(stringResource(R.string.search_or_enter_text)) },
                visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { stamp++; scope.launch { push() } }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
            )
            // Focus the field and raise the keyboard as soon as the sheet is up, so typing can start at once.
            val ime = LocalSoftwareKeyboardController.current
            LaunchedEffect(Unit) { delay(100); runCatching { focus.requestFocus() }; ime?.show() }
            SwitchRow(stringResource(R.string.hide_text), checked = secure) { secure = it }
            Caption(stringResource(R.string.type_on_tv_footer))
            if (message.isNotEmpty()) Text(message, style = MaterialTheme.typography.bodySmall, color = Quiet.amber)
        }
    }
}

/** Favorite inputs (InputSettingsView): named devices, each tied to one of the TV's inputs; tap to switch to it. */
@Composable
fun InputsContent(model: RemoteModel, onOpenMenu: (() -> Unit)?) {
    val settings = model.settings
    val prefs by settings.value.collectAsState()
    val state by model.state.collectAsState()
    var editing by remember { mutableStateOf<FavoriteInput?>(null) }
    var message by remember { mutableStateOf("") }
    val context = LocalContext.current
    RowCard {
        prefs.inputs.forEachIndexed { i, input ->
            if (i > 0) RowDivider()
            val assigned = prefs.tvInputs.firstOrNull { it.id == input.inputID }
            ListItem(
                headlineContent = { Text(input.name) },
                supportingContent = { Text(assigned?.name ?: stringResource(R.string.not_assigned), color = Quiet.muted, style = MaterialTheme.typography.bodySmall) },
                leadingContent = { Icon(Icons.Outlined.SportsEsports, null) },
                trailingContent = {
                    Row {
                        IconButton(onClick = { editing = input }) { Icon(Icons.Outlined.Edit, stringResource(R.string.edit_named, input.name)) }
                        IconButton(onClick = { settings.update { p -> p.copy(inputs = p.inputs.filterNot { it.id == input.id }) } }) {
                            Icon(Icons.Rounded.Close, stringResource(R.string.delete), tint = Quiet.muted)
                        }
                    }
                },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                modifier = Modifier.clickableIf(state.ready) {
                    val found = if (prefs.editorHost == state.host) prefs.tvInputs.firstOrNull { it.id == input.inputID } else null
                    if (found == null) message = context.getString(R.string.sync_assign_input) else model.launch(found.launchURL)
                },
            )
        }
        if (prefs.inputs.isNotEmpty()) RowDivider()
        NavRow(Icons.Rounded.Add, stringResource(R.string.add_favorite), chevron = false, enabled = prefs.inputs.size < 20, tint = Quiet.cyan) {
            editing = FavoriteInput(name = context.getString(R.string.new_device))
        }
    }
    Caption(stringResource(R.string.inputs_footer))
    if (onOpenMenu != null) RowCard {
        NavRow(Icons.Outlined.Input, stringResource(R.string.open_input_menu), chevron = false, enabled = state.ready) { model.tap(TVKey.INPUTS); onOpenMenu() }
    }
    editing?.let { InputForm(it, model) { editing = null } }
    if (message.isNotEmpty()) AlertDialog(onDismissRequest = { message = "" }, title = { Text(stringResource(R.string.inputs)) }, text = { Text(message) },
        confirmButton = { TextButton(onClick = { message = "" }) { Text(stringResource(R.string.ok)) } })
}

/** The inputs list as a sheet from the remote's header. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InputsSheet(model: RemoteModel, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Quiet.background) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(stringResource(R.string.favorite_inputs), style = MaterialTheme.typography.titleLarge)
            InputsContent(model, onOpenMenu = onDismiss)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InputForm(input: FavoriteInput, model: RemoteModel, onDismiss: () -> Unit) {
    val settings = model.settings
    val prefs by settings.value.collectAsState()
    var name by rememberSaveable { mutableStateOf(input.name) }
    var inputID by rememberSaveable { mutableStateOf(input.inputID) }
    var open by remember { mutableStateOf(false) }
    val valid = name.trim().isNotEmpty() && name.length <= 60
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.edit_input)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.device_name)) }, singleLine = true)
                ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
                    OutlinedTextField(
                        value = prefs.tvInputs.firstOrNull { it.id == inputID }?.name ?: stringResource(R.string.not_assigned),
                        onValueChange = {}, readOnly = true, label = { Text(stringResource(R.string.tv_input)) },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(open) },
                        modifier = Modifier.menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                        DropdownMenuItem(text = { Text(stringResource(R.string.not_assigned)) }, onClick = { inputID = null; open = false })
                        prefs.tvInputs.forEach { tv -> DropdownMenuItem(text = { Text(tv.name) }, onClick = { inputID = tv.id; open = false }) }
                    }
                }
                if (prefs.tvInputs.isEmpty()) Caption(stringResource(R.string.connect_editor_inputs))
            }
        },
        confirmButton = {
            TextButton(enabled = valid, onClick = {
                val saved = input.copy(name = name.trim(), inputID = inputID)
                settings.update { p ->
                    p.copy(inputs = if (p.inputs.any { it.id == saved.id }) p.inputs.map { if (it.id == saved.id) saved else it } else p.inputs + saved)
                }
                onDismiss()
            }) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** Remote shortcuts (ShortcutSettingsView): how many app buttons the remote shows, and in which order. */
@Composable
fun ShortcutsScreen(settings: AppSettings, onBack: () -> Unit) {
    val prefs by settings.value.collectAsState()
    SubPage(stringResource(R.string.remote_shortcuts), onBack) {
        RowCard {
            ListItem(
                headlineContent = { Text(stringResource(R.string.visible_shortcuts, prefs.remoteCount)) },
                trailingContent = {
                    Counter(prefs.remoteCount, 1..12, stringResource(R.string.fewer), stringResource(R.string.more)) { v -> settings.update { it.copy(remoteCount = v) } }
                },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
        }
        SectionTitle(stringResource(R.string.order))
        RowCard {
            prefs.remoteOrder.forEachIndexed { i, id ->
                if (i > 0) RowDivider()
                val app = prefs.app(id)
                ReorderRow(
                    leading = { AppBadge(app) }, title = app?.name ?: id,
                    canUp = i > 0, canDown = i < prefs.remoteOrder.size - 1,
                    onMove = { d -> settings.update { it.copy(remoteOrder = it.remoteOrder.moved(i, i + d)) } },
                    onRemove = { settings.update { p -> p.copy(remoteOrder = p.remoteOrder.filterNot { it == id }) } },
                )
            }
        }
        val more = prefs.apps.filter { it.id !in prefs.remoteOrder }
        if (more.isNotEmpty()) {
            SectionTitle(stringResource(R.string.more_apps))
            RowCard {
                more.forEachIndexed { i, app ->
                    if (i > 0) RowDivider()
                    NavRow(Icons.Rounded.AddCircleOutline, app.name, chevron = false) { settings.update { it.copy(remoteOrder = it.remoteOrder + app.id) } }
                }
            }
        }
        Caption(stringResource(R.string.removing_shortcut_keeps))
    }
}

/** A list row with move up / move down and an optional remove (the iPhone's Edit mode, as buttons). */
@Composable
fun ReorderRow(
    leading: @Composable () -> Unit, title: String, detail: String? = null, canUp: Boolean, canDown: Boolean,
    onMove: (Int) -> Unit, onRemove: (() -> Unit)? = null, onClick: (() -> Unit)? = null,
) = ListItem(
    headlineContent = { Text(title) },
    supportingContent = detail?.let { { Text(it, color = Quiet.muted, style = MaterialTheme.typography.bodySmall) } },
    leadingContent = leading,
    trailingContent = {
        Row {
            IconButton(onClick = { onMove(-1) }, enabled = canUp, modifier = Modifier.size(40.dp)) { Icon(Icons.Rounded.ArrowUpward, stringResource(R.string.move_up)) }
            IconButton(onClick = { onMove(1) }, enabled = canDown, modifier = Modifier.size(40.dp)) { Icon(Icons.Rounded.ArrowDownward, stringResource(R.string.move_down)) }
            if (onRemove != null) IconButton(onClick = onRemove, modifier = Modifier.size(40.dp)) { Icon(Icons.Rounded.Close, stringResource(R.string.remove), tint = Quiet.muted) }
        }
    },
    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    modifier = if (onClick != null) Modifier.clickableIf(true, onClick) else Modifier,
)

fun <T> List<T>.moved(from: Int, to: Int): List<T> {
    if (from !in indices || to !in indices) return this
    return toMutableList().apply { add(to, removeAt(from)) }
}

fun Modifier.clickableIf(enabled: Boolean, onClick: () -> Unit): Modifier = this.clickable(enabled = enabled, onClick = onClick)


/**
 * Every app on the TV, A to Z; tap one to open it there (AllAppsSheet on the iPhone). Android TV: the apps Purio's
 * Home reports (or the remote's known apps until it connects). Roku, LG, Samsung: the TV's own list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AllAppsSheet(state: RemoteModel.State, model: RemoteModel, onDismiss: () -> Unit) {
    val editor by model.editor.state.collectAsState()
    val prefs by model.settings.value.collectAsState()
    var brandApps by remember { mutableStateOf<List<com.guilhermeramalho.puriotv.core.BrandApp>?>(null) }
    var problem by remember { mutableStateOf("") }
    LaunchedEffect(Unit) {
        if (state.kind == com.guilhermeramalho.puriotv.core.TvKind.ANDROID_TV) { if (editor.snapshot == null) model.editor.autoConnect() }
        else try { brandApps = model.brandApps() ?: emptyList() } catch (e: Exception) { problem = e.message ?: "" }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Quiet.background) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 16.dp).navigationBarsPadding().verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.all_apps), style = MaterialTheme.typography.titleLarge)
            if (state.kind == com.guilhermeramalho.puriotv.core.TvKind.ANDROID_TV) {
                if (editor.snapshot == null) Text(stringResource(R.string.all_apps_partial), fontSize = 13.sp, color = Quiet.muted)
                (editor.snapshot?.apps ?: prefs.apps).sortedBy { it.name.lowercase() }.forEach { app ->
                    AllAppsRow(app.id, app.name, state.ready) { model.open(app); onDismiss() }
                }
            } else {
                val list = brandApps
                if (list == null && problem.isEmpty()) CircularProgressIndicator(Modifier.size(24.dp), color = Quiet.muted)
                list?.sortedBy { it.name.lowercase() }?.forEach { app -> AllAppsRow(app.id, app.name, state.ready) { model.launch(app); onDismiss() } }
            }
            if (problem.isNotEmpty()) Text(problem, fontSize = 13.sp, color = Quiet.amber)
        }
    }
}

@Composable
private fun AllAppsRow(id: String, name: String, enabled: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Quiet.panel).clickable(enabled = enabled, onClick = onClick).padding(10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        AppTile(id, name, 36.dp)
        Text(name, color = Color.White, fontSize = 15.sp)
    }
}
