package com.guilhermeramalho.puriotv

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.AutoFixHigh
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.automirrored.rounded.Undo
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.guilhermeramalho.puriotv.core.CommandRunner
import com.guilhermeramalho.puriotv.core.HomeBackup
import com.guilhermeramalho.puriotv.core.TVSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date
import java.util.Locale

@Composable
fun statusText(state: RemoteModel.State): String = when {
    !state.paired -> stringResource(R.string.status_not_paired)
    state.link == RemoteModel.Link.READY && state.power == false -> stringResource(R.string.status_standby)
    state.link == RemoteModel.Link.READY -> stringResource(R.string.status_connected)
    state.link == RemoteModel.Link.OFFLINE -> stringResource(R.string.status_offline)
    else -> stringResource(R.string.status_connecting)
}

sealed interface SettingsRoute {
    data object Connection : SettingsRoute
    data object Shortcuts : SettingsRoute
    data object Inputs : SettingsRoute
    data object Backups : SettingsRoute
    data object Setup : SettingsRoute
    data object Undo : SettingsRoute
    data object Credits : SettingsRoute
}

/** Settings (SettingsView). */
@Composable
fun SettingsScreen(state: RemoteModel.State, model: RemoteModel, open: (SettingsRoute) -> Unit) {
    val settings = model.settings
    val prefs by settings.value.collectAsState()
    val context = LocalContext.current
    Page {
        PageTitle(stringResource(R.string.tab_settings))
        RowCard {
            NavRow(Icons.Outlined.Wifi, stringResource(R.string.connection), stringResource(R.string.connection_detail), value = statusText(state)) { open(SettingsRoute.Connection) }
            RowDivider()
            NavRow(Icons.Outlined.GridView, stringResource(R.string.remote_shortcuts), stringResource(R.string.remote_shortcuts_detail)) { open(SettingsRoute.Shortcuts) }
            RowDivider()
            NavRow(Icons.Outlined.SportsEsports, stringResource(R.string.favorite_inputs), stringResource(R.string.favorite_inputs_detail)) { open(SettingsRoute.Inputs) }
            RowDivider()
            NavRow(Icons.Outlined.Archive, stringResource(R.string.backup_restore), stringResource(R.string.backup_restore_detail)) { open(SettingsRoute.Backups) }
        }
        SectionTitle(stringResource(R.string.tv_setup))
        RowCard {
            NavRow(Icons.Outlined.AutoFixHigh, stringResource(R.string.debloat_new_home), stringResource(R.string.debloat_new_home_detail)) { open(SettingsRoute.Setup) }
            RowDivider()
            NavRow(Icons.AutoMirrored.Rounded.Undo, stringResource(R.string.undo_setup), stringResource(R.string.undo_setup_detail)) { open(SettingsRoute.Undo) }
        }
        RowCard {
            NavRow(Icons.Outlined.Language, stringResource(R.string.language), stringResource(R.string.language_detail),
                value = Locale.getDefault().let { it.getDisplayName(it).replaceFirstChar { c -> c.titlecase(it) } }) {
                // Android 13+: this app's own language page; before that, the phone's language settings.
                val intent = if (Build.VERSION.SDK_INT >= 33) Intent(Settings.ACTION_APP_LOCALE_SETTINGS, Uri.parse("package:" + context.packageName))
                else Intent(Settings.ACTION_LOCALE_SETTINGS)
                runCatching { context.startActivity(intent) }
            }
        }
        SectionTitle(stringResource(R.string.remote_preferences))
        RowCard {
            SwitchRow(stringResource(R.string.touch_feedback), stringResource(R.string.touch_feedback_detail), prefs.haptics) { v -> settings.update { it.copy(haptics = v) } }
            RowDivider()
            SwitchRow(stringResource(R.string.reverse_swipe), stringResource(R.string.reverse_swipe_detail), prefs.reverseSwipe) { v -> settings.update { it.copy(reverseSwipe = v) } }
            RowDivider()
            SwitchRow(stringResource(R.string.reconnect_automatically), stringResource(R.string.reconnect_automatically_detail), prefs.autoReconnect) { v -> settings.update { it.copy(autoReconnect = v) } }
        }
        TextButton(onClick = { open(SettingsRoute.Credits) }) { Text(stringResource(R.string.credits), color = Quiet.muted, fontSize = 13.sp) }
        Caption(stringResource(R.string.about_detail, BuildInfo.versionName(context.applicationContext as android.app.Application)))
    }
}

/** Connection (ConnectionView): the TV's address, reconnect, pair again, a test that sends nothing, forget. */
@Composable
fun ConnectionScreen(model: RemoteModel, onBack: () -> Unit) {
    val state by model.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var address by rememberSaveable { mutableStateOf(state.host) }
    var result by remember { mutableStateOf("") }
    var testing by remember { mutableStateOf(false) }
    var confirmRepair by remember { mutableStateOf(false) }
    var confirmForget by remember { mutableStateOf(false) }
    SubPage(stringResource(R.string.connection), onBack) {
        SectionTitle(stringResource(R.string.address_title))
        OutlinedTextField(address, { address = it.trim() }, label = { Text(stringResource(R.string.address_label)) }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done), modifier = Modifier.fillMaxWidth())
        SecondaryButton(stringResource(R.string.save_and_connect), enabled = state.paired && isIPv4(address) && address != state.host) { model.saveHost(address) }
        SectionTitle(stringResource(R.string.connection))
        RowCard {
            ListItem(
                headlineContent = { Text(state.tvName.ifEmpty { stringResource(R.string.no_tv) }) },
                supportingContent = { Text(statusText(state), color = Quiet.muted) },
                leadingContent = { Icon(if (state.ready) Icons.Outlined.CheckCircle else Icons.Outlined.WifiOff, null, tint = if (state.ready) Quiet.green else Quiet.amber) },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
            if (state.paired) {
                RowDivider()
                NavRow(Icons.Outlined.VerifiedUser, stringResource(R.string.pairing_saved), chevron = false)
                RowDivider()
                NavRow(Icons.Rounded.Refresh, stringResource(R.string.reconnect), chevron = false, tint = Quiet.cyan, enabled = state.link != RemoteModel.Link.CONNECTING) { model.connect() }
            }
        }
        Caption(stringResource(if (state.paired) R.string.reconnect_hint else R.string.pair_once_hint))
        if (state.paired) {
            SecondaryButton(stringResource(R.string.pair_again)) { confirmRepair = true }
            Caption(stringResource(R.string.pair_again_hint))
        }
        SectionTitle(stringResource(R.string.diagnostics))
        SecondaryButton(stringResource(if (testing) R.string.checking else R.string.test_connection), enabled = !testing && state.paired) {
            testing = true; result = ""
            scope.launch {
                result = try {
                    val pin = model.pin ?: throw UserMessage(context.getString(R.string.pair_first))
                    val identity = model.clientIdentity()
                    CommandRunner({ TVSession(state.host, identity, model.clientName, model.clientInfo(), scope) }).diagnose(pin)
                    context.getString(R.string.test_ok)
                } catch (e: Exception) { errorText(context, e) }
                testing = false
            }
        }
        if (result.isNotEmpty()) Text(result, style = MaterialTheme.typography.bodySmall)
        Caption(stringResource(R.string.diagnostics_footer))
        state.problem?.let { Text(stringResource(it.message()), color = Quiet.amber, style = MaterialTheme.typography.bodySmall) }
        if (state.paired) TextButton(onClick = { confirmForget = true }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.forget_tv), color = Quiet.amber) }
    }
    if (confirmRepair) Confirm(stringResource(R.string.pair_again_title), stringResource(R.string.pair_again_message), stringResource(R.string.show_code), onDismiss = { confirmRepair = false }) {
        model.choose(state.host, state.tvName)
    }
    if (confirmForget) Confirm(stringResource(R.string.forget_title, state.tvName), stringResource(R.string.forget_message), stringResource(R.string.forget_confirm), destructive = true,
        onDismiss = { confirmForget = false }) { model.forget(); onBack() }
}

/** The connection details from the remote's header: the same page, as a sheet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionSheet(state: RemoteModel.State, model: RemoteModel, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Quiet.background) {
        Column(Modifier.navigationBarsPadding().padding(bottom = 8.dp)) { ConnectionScreen(model, onDismiss) }
    }
}

/** Favorite inputs, from Settings. */
@Composable
fun InputsScreen(model: RemoteModel, onBack: () -> Unit) =
    SubPage(stringResource(R.string.favorite_inputs), onBack) { InputsContent(model, onOpenMenu = {}) }

/** Backup & restore (BackupsView): Home layouts and wallpaper, saved on this phone, exported or imported as JSON. */
@Composable
fun BackupsScreen(settings: AppSettings, onBack: () -> Unit) {
    val backups by settings.backups.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var restoring by remember { mutableStateOf<HomeBackup?>(null) }
    var exporting by remember { mutableStateOf<HomeBackup?>(null) }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            try {
                val data = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { it.readNBytesCompat(2_000_001) } ?: throw UserMessage(context.getString(R.string.backup_empty))
                }
                if (data.size > 2_000_000) throw UserMessage(context.getString(R.string.backup_too_big))
                restoring = HomeBackup.decode(data)
            } catch (e: Exception) { settings.notice.value = errorText(context, e) }
        }
    }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        val backup = exporting ?: return@rememberLauncherForActivityResult
        exporting = null
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            try { withContext(Dispatchers.IO) { context.contentResolver.openOutputStream(uri)?.use { it.write(settings.encode(backup)) } } }
            catch (e: Exception) { settings.notice.value = errorText(context, e) }
        }
    }
    SubPage(stringResource(R.string.backup_restore), onBack) {
        RowCard {
            NavRow(Icons.Rounded.Add, stringResource(R.string.create_backup), chevron = false, tint = Quiet.cyan) {
                try { settings.backup() } catch (e: Exception) { settings.notice.value = errorText(context, e) }
            }
            RowDivider()
            NavRow(Icons.Outlined.FileDownload, stringResource(R.string.import_backup), chevron = false, tint = Quiet.cyan) { importer.launch(arrayOf("application/json", "text/plain", "*/*")) }
        }
        SectionTitle(stringResource(R.string.saved_backups))
        RowCard {
            if (backups.isEmpty()) Text(stringResource(R.string.no_backups), color = Quiet.muted, modifier = Modifier.padding(16.dp))
            backups.forEachIndexed { i, b ->
                if (i > 0) RowDivider()
                ListItem(
                    headlineContent = { Text(b.name) },
                    supportingContent = { Text(DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(b.date)), color = Quiet.muted) },
                    trailingContent = {
                        IconButton(onClick = { exporting = b; exporter.launch("TV-Home-backup.json") }) { Icon(Icons.Outlined.Share, stringResource(R.string.export_named, b.name)) }
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                    modifier = Modifier.clickableIf(true) { restoring = b },
                )
            }
        }
    }
    restoring?.let { b ->
        Confirm(stringResource(R.string.restore_title), stringResource(R.string.restore_message), stringResource(R.string.restore_draft), onDismiss = { restoring = null }) {
            try { settings.backup(context.getString(R.string.backup_before_restoring)); settings.restore(b) } catch (e: Exception) { settings.notice.value = errorText(context, e) }
        }
    }
}

private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buf = ByteArray(65536)
    while (out.size() < limit) { val n = read(buf); if (n < 0) break; out.write(buf, 0, n) }
    return out.toByteArray()
}

/** Credits & licenses. */
@Composable
fun CreditsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val uri = LocalUriHandler.current
    val license = remember { runCatching { context.assets.open("Launcher/LICENSE-cleanyourtv.txt").bufferedReader().readText() }.getOrNull() }
    SubPage(stringResource(R.string.credits), onBack) {
        Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleLarge)
        Text(stringResource(R.string.app_subtitle), color = Quiet.muted)
        SectionTitle(stringResource(R.string.android_robot))
        Text(stringResource(R.string.android_robot_credit), style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = { uri.openUri("https://creativecommons.org/licenses/by/3.0/") }) { Text("Creative Commons Attribution 3.0", color = Quiet.cyan) }
        Caption(stringResource(R.string.android_trademark))
        TextButton(onClick = { uri.openUri("https://github.com/guilherme-ramalho/debloated-tv#references-and-assets") }) { Text(stringResource(R.string.logo_sources), color = Quiet.cyan) }
        SectionTitle("cleanyourtv")
        Text(stringResource(R.string.cleanyourtv_credit), style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = { uri.openUri("https://github.com/Gathin23/cleanyourtv") }) { Text("github.com/Gathin23/cleanyourtv", color = Quiet.cyan) }
        license?.let { Text(it, fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = Quiet.muted) }
    }
}
