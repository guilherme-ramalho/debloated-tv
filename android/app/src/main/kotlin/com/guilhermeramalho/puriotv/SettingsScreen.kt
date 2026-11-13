package com.guilhermeramalho.puriotv

import androidx.annotation.StringRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
fun statusText(state: RemoteModel.State): String = when {
    !state.paired -> stringResource(R.string.status_not_paired)
    state.link == RemoteModel.Link.READY && state.power == false -> stringResource(R.string.status_standby)
    state.link == RemoteModel.Link.READY -> stringResource(R.string.status_connected)
    state.link == RemoteModel.Link.OFFLINE -> stringResource(R.string.status_offline)
    else -> stringResource(R.string.status_connecting)
}

/** Settings (SettingsView): what exists on Android so far; the rest arrives with the features. */
@Composable
fun SettingsScreen(state: RemoteModel.State, model: RemoteModel) {
    var details by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    Page {
        PageTitle(stringResource(R.string.tab_settings))
        RowCard {
            ListItem(
                headlineContent = { Text(stringResource(R.string.connection)) },
                supportingContent = { Text(stringResource(R.string.connection_detail)) },
                leadingContent = { Icon(Icons.Outlined.Wifi, null) },
                trailingContent = { Text(statusText(state), style = MaterialTheme.typography.bodySmall, color = Quiet.muted) },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                modifier = Modifier.clickable { details = true },
            )
        }
        RowCard {
            ListItem(
                headlineContent = { Text(stringResource(R.string.about)) },
                supportingContent = { Text(stringResource(R.string.about_detail, BuildInfo.versionName(context.applicationContext as android.app.Application))) },
                leadingContent = { Icon(Icons.Outlined.Info, null) },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
        }
    }
    if (details) ConnectionSheet(state, model) { details = false }
}

/** Connection details (ConnectionView): status, reconnect, pair again, connect another TV. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionSheet(state: RemoteModel.State, model: RemoteModel, onDismiss: () -> Unit) {
    var confirmRepair by rememberSaveable { mutableStateOf(false) }
    var confirmForget by rememberSaveable { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Quiet.panel) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.connection), style = MaterialTheme.typography.titleLarge)
            RowCard {
                ListItem(
                    headlineContent = { Text(state.tvName.ifEmpty { stringResource(R.string.no_tv) }) },
                    supportingContent = { Text(state.host) },
                    leadingContent = { Icon(if (state.ready) Icons.Outlined.CheckCircle else Icons.Outlined.WifiOff, null, tint = if (state.ready) Quiet.green else Quiet.amber) },
                    trailingContent = { Text(statusText(state), style = MaterialTheme.typography.bodySmall, color = Quiet.muted) },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
            }
            state.problem?.let { Text(stringResource(it.message()), color = Quiet.amber, style = MaterialTheme.typography.bodySmall) }
            if (state.paired) {
                Caption(stringResource(R.string.reconnect_hint))
                Button(onClick = { model.connect() }, enabled = state.link != RemoteModel.Link.CONNECTING, modifier = Modifier.fillMaxWidth().height(48.dp)) {
                    Text(stringResource(R.string.reconnect))
                }
                OutlinedButton(onClick = { confirmRepair = true }, modifier = Modifier.fillMaxWidth().height(48.dp)) { Text(stringResource(R.string.pair_again)) }
                Caption(stringResource(R.string.pair_again_hint))
                TextButton(onClick = { confirmForget = true }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.forget_tv), color = Quiet.amber) }
            }
        }
    }
    if (confirmRepair) AlertDialog(
        onDismissRequest = { confirmRepair = false },
        title = { Text(stringResource(R.string.pair_again_title)) },
        text = { Text(stringResource(R.string.pair_again_message)) },
        confirmButton = { TextButton(onClick = { confirmRepair = false; onDismiss(); model.choose(state.host, state.tvName) }) { Text(stringResource(R.string.show_code)) } },
        dismissButton = { TextButton(onClick = { confirmRepair = false }) { Text(stringResource(R.string.cancel)) } },
    )
    if (confirmForget) AlertDialog(
        onDismissRequest = { confirmForget = false },
        title = { Text(stringResource(R.string.forget_title, state.tvName)) },
        text = { Text(stringResource(R.string.forget_message)) },
        confirmButton = { TextButton(onClick = { confirmForget = false; onDismiss(); model.forget() }) { Text(stringResource(R.string.forget_confirm)) } },
        dismissButton = { TextButton(onClick = { confirmForget = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

/** TV and Actions tabs until those features are ported. */
@Composable
fun ComingSoon(@StringRes title: Int, @StringRes detail: Int) {
    Page {
        PageTitle(stringResource(title))
        RowCard { Text(stringResource(detail), color = Quiet.muted, modifier = Modifier.padding(16.dp)) }
    }
}
