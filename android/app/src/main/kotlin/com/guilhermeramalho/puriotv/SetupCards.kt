package com.guilhermeramalho.puriotv

import android.content.Intent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.Undo
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Downloading
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.OfflineBolt
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.guilhermeramalho.puriotv.core.LauncherVersion
import com.guilhermeramalho.puriotv.core.ModelRequest
import com.guilhermeramalho.puriotv.core.TVSetupInfo
import kotlinx.coroutines.launch

/** The version of TV Home this app carries (assets/tvhome.json), or null when the build has none. */
fun bundledHomeVersion(context: android.content.Context): Int? =
    LauncherVersion.bundled(runCatching { context.assets.open("Launcher/tvhome.json").use { it.readBytes() } }.getOrNull())

/** The TV tab (TVHomeView): setup until the new Home is on the TV, then the Home editor. */
@Composable
fun TVTab(model: RemoteModel, open: (TVRoute) -> Unit) {
    val state by model.state.collectAsState()
    val all by model.setup.all.collectAsState()
    val ed by model.editor.state.collectAsState()
    val prefs by model.settings.value.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var checkMessage by remember { mutableStateOf("") }
    val info = all[state.host] ?: TVSetupInfo()
    Page {
        PageTitle(stringResource(R.string.tab_tv))
        when {
            // TV setup and Purio's Home are Android TV features; say so plainly for Roku, LG and Samsung.
            state.kind != com.guilhermeramalho.puriotv.core.TvKind.ANDROID_TV && state.paired -> RowCard {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("${state.tvName} · ${state.kind.label}", fontWeight = FontWeight.SemiBold)
                    Caption(stringResource(R.string.brand_tv_notice))
                    // Roku, LG and Samsung remotes are new in 1.3 and not yet tried on every model: ask for reports.
                    Caption(stringResource(R.string.brand_tv_beta))
                    val uri = LocalUriHandler.current
                    TextButton(onClick = { uri.openUri("https://github.com/guilherme-ramalho/debloated-tv/issues/new?title=Remote%20for%20my%20TV") }) {
                        Text(stringResource(R.string.brand_tv_report), color = Quiet.cyan)
                    }
                }
            }
            info.homeInstalled -> {
                SetupStrip(info) { open(TVRoute.Manage) }
                val update = ed.snapshot?.let { LauncherVersion.updateAvailable(LauncherVersion.onTV(it), bundledHomeVersion(context)) } == true
                if (update) HomeUpdateCard { open(TVRoute.HomeUpdate) }
                HomeEditorContent(model, open)
            }
            info.supported == false -> UnsupportedCard(info) { open(TVRoute.Setup) }
            else -> {
                HeroCard(info, start = { open(TVRoute.Setup) }, checkMessage = checkMessage, check = if (state.ready) ({
                    scope.launch {
                        checkTV(model, { model.setup.info(state.host).homeInstalled }, { checkMessage = it ?: "" }, { context.getString(it) })
                    }
                }) else null)
                SectionTitle(stringResource(R.string.after_setup_edit_here))
                Box(Modifier.alpha(0.5f)) { HomePreview(prefs.profile.layout, model.settings, prefs.profile.name) }
                Caption(stringResource(R.string.editor_unlocks_after_setup))
                if (ed.busy) Caption(ed.message)
            }
        }
    }
}

@Composable
private fun Benefit(text: String) = Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    Icon(Icons.Rounded.Check, null, tint = Quiet.cyan, modifier = Modifier.size(16.dp)); Text(text, fontSize = 13.sp)
}

@Composable
private fun IconTile(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, fill: Color) =
    Box(Modifier.size(52.dp).background(fill, RoundedCornerShape(15.dp)), contentAlignment = Alignment.Center) { Icon(icon, null, tint = tint, modifier = Modifier.size(26.dp)) }

@Composable
private fun ModelRow(title: String, detail: String, badge: String?, badgeOn: Boolean) =
    Row(Modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.045f), RoundedCornerShape(13.dp)).border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(13.dp))
        .padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(Icons.Outlined.Tv, null, modifier = Modifier.size(18.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            if (detail.isNotEmpty()) Text(detail, fontSize = 11.sp, color = Quiet.muted)
        }
        badge?.let {
            Text(it, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = if (badgeOn) Quiet.background else Color.White,
                modifier = Modifier.background(if (badgeOn) Quiet.cyan else Color.White.copy(alpha = 0.1f), RoundedCornerShape(8.dp)).padding(horizontal = 8.dp, vertical = 4.dp))
        }
    }

/** Before the new Home is installed: what setup does, and the way in (TVSetupHeroCard). */
@Composable
private fun HeroCard(info: TVSetupInfo, start: () -> Unit, check: (() -> Unit)?, checkMessage: String) = RowCard {
    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        IconTile(Icons.Outlined.OfflineBolt, Quiet.cyan, Quiet.cyan.copy(alpha = 0.14f))
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(stringResource(R.string.make_tv_faster), fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            Text(stringResource(R.string.make_tv_faster_detail), fontSize = 14.sp, color = Quiet.muted)
        }
        Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
            Benefit(stringResource(R.string.benefit_tested_list)); Benefit(stringResource(R.string.benefit_undo)); Benefit(stringResource(R.string.benefit_no_computer))
        }
        if (info.supported == true) ModelRow(info.model.ifEmpty { stringResource(R.string.unknown_model) }, info.detail, stringResource(R.string.supported), true)
        else ModelRow(stringResource(R.string.check_supported), stringResource(R.string.setup_reads_model), null, false)
        PrimaryButton(stringResource(R.string.start_setup), onClick = start)
        if (check != null) Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
            TextButton(onClick = check) { Text(stringResource(R.string.already_set_up), color = Quiet.cyan, fontSize = 13.sp) }
            Text(checkMessage.ifEmpty { stringResource(R.string.check_goes_home) }, fontSize = 11.sp, color = Quiet.muted, textAlign = TextAlign.Center)
        }
    }
}

/** Setup found no tested list for this model (TVSetupUnsupportedCard). */
@Composable
private fun UnsupportedCard(info: TVSetupInfo, retry: () -> Unit) = RowCard {
    val context = LocalContext.current
    val uri = LocalUriHandler.current
    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        IconTile(Icons.Outlined.ErrorOutline, Quiet.muted, Color.White.copy(alpha = 0.07f))
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(stringResource(R.string.not_supported_yet), fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
            Text(stringResource(R.string.not_supported_detail), fontSize = 14.sp, color = Quiet.muted)
        }
        ModelRow(info.model.ifEmpty { stringResource(R.string.unknown_model) }, info.detail, stringResource(R.string.not_yet), false)
        val url = ModelRequest.url(info)
        val chooser = stringResource(R.string.model_request_subject)
        if (url != null) SecondaryButton(stringResource(R.string.ask_for_model)) { uri.openUri(url) }
        else SecondaryButton(stringResource(R.string.share_model)) {
            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, chooser)
                .putExtra(Intent.EXTRA_TEXT, context.getString(R.string.model_request_text, info.model, info.detail))
            context.startActivity(Intent.createChooser(send, chooser))
        }
        Caption(stringResource(R.string.model_request_footer))
        TextButton(onClick = { uri.openUri(ModelRequest.ADD_TV_GUIDE) }) { Text(stringResource(R.string.how_to_add_model), color = Quiet.cyan, fontSize = 12.sp) }
        TextButton(onClick = retry) { Text(stringResource(R.string.check_again), color = Quiet.muted, fontSize = 12.sp) }
    }
}

@Composable
private fun Strip(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, accent: Color, title: String, detail: String, action: String, onClick: () -> Unit) =
    Surface(onClick = onClick, shape = RoundedCornerShape(16.dp), color = accent.copy(alpha = 0.14f), border = BorderStroke(1.dp, accent.copy(alpha = 0.35f)),
        modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp)) {
        Row(Modifier.padding(horizontal = 13.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(11.dp)) {
            Icon(icon, null, tint = tint)
            Column(Modifier.weight(1f)) {
                Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                Text(detail, fontSize = 12.sp, color = Quiet.muted)
            }
            Text(action, fontSize = 13.sp, color = Quiet.cyan)
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Quiet.muted, modifier = Modifier.size(18.dp))
        }
    }

/** After setup: the status line that leads to managing it (TVSetupStrip). */
@Composable
private fun SetupStrip(info: TVSetupInfo, onClick: () -> Unit) = Strip(
    Icons.Outlined.VerifiedUser, Color(0xFF7FD3C4), Quiet.toggle, stringResource(R.string.app_name),
    info.disabledCount?.let { stringResource(R.string.n_apps_off_new_home, it) } ?: stringResource(R.string.new_home_installed),
    stringResource(R.string.manage), onClick,
)

/** A newer TV Home comes with this app (HomeUpdateCard). */
@Composable
private fun HomeUpdateCard(onClick: () -> Unit) = Strip(
    Icons.Outlined.Downloading, Quiet.cyan, Quiet.cyan, stringResource(R.string.home_update), stringResource(R.string.home_update_detail),
    stringResource(R.string.update), onClick,
)

/** What setup did, and the ways to redo or undo it (TVSetupManageView). */
@Composable
fun SetupManageScreen(model: RemoteModel, open: (TVRoute) -> Unit, onBack: () -> Unit) {
    val state by model.state.collectAsState()
    val all by model.setup.all.collectAsState()
    val info = all[state.host] ?: TVSetupInfo()
    SubPage(stringResource(R.string.tv_setup), onBack) {
        RowCard {
            NavRow(Icons.Outlined.VerifiedUser, info.profile.ifEmpty { stringResource(R.string.new_home_installed) },
                info.disabledCount?.let { stringResource(R.string.n_apps_switched_off, it) } ?: stringResource(R.string.set_up_on_this_tv), chevron = false)
        }
        RowCard {
            NavRow(Icons.Rounded.Sync, stringResource(R.string.run_setup_again), stringResource(R.string.run_setup_again_detail)) { open(TVRoute.Setup) }
            RowDivider()
            NavRow(Icons.AutoMirrored.Rounded.Undo, stringResource(R.string.undo_setup), stringResource(R.string.undo_setup_manage_detail)) { open(TVRoute.Undo) }
        }
        Caption(stringResource(R.string.both_need_debugging))
    }
}

/** The one-time sheet after a new pairing (TVSetupOfferSheet). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SetupOffer(model: RemoteModel, start: () -> Unit) {
    val offerFor by model.setup.offerFor.collectAsState()
    if (offerFor == null) return
    val close = { model.setup.offerFor.value = null }
    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Quiet.panel) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 16.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.CheckCircle, null, tint = Quiet.cyan, modifier = Modifier.size(16.dp))
                Text(stringResource(R.string.paired_with_tv), fontSize = 13.sp, color = Quiet.cyan)
            }
            Text(stringResource(R.string.offer_title), fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
            Text(stringResource(R.string.offer_detail), fontSize = 14.sp, color = Quiet.muted)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("0" to R.string.apps_deleted, stringResource(R.string.undo) to R.string.anytime, "~10 min" to R.string.no_computer).forEach { (v, l) ->
                    Column(Modifier.weight(1f).background(Color.White.copy(alpha = 0.045f), RoundedCornerShape(14.dp)).padding(12.dp)) {
                        Text(v, fontSize = 18.sp, fontWeight = FontWeight.SemiBold); Text(stringResource(l), fontSize = 11.sp, color = Quiet.muted)
                    }
                }
            }
            PrimaryButton(stringResource(R.string.set_up_my_tv)) { close(); start() }
            TextButton(onClick = close, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.not_now)) }
            Text(stringResource(R.string.find_in_tv_tab), fontSize = 12.sp, color = Quiet.muted, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        }
    }
}

/** The setup screens, reachable from the TV tab and Settings. */
@Composable
fun SetupRoute(route: TVRoute, model: RemoteModel, open: (TVRoute) -> Unit, onBack: () -> Unit) {
    when (route) {
        TVRoute.Manage -> SetupManageScreen(model, open, onBack)
        TVRoute.Setup -> DebloatSetupScreen(model, onBack)
        TVRoute.Undo -> UndoSetupScreen(model, onBack)
        TVRoute.HomeUpdate -> HomeUpdateScreen(model, onBack)
        else -> onBack()
    }
}
