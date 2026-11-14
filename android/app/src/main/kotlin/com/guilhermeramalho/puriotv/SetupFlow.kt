package com.guilhermeramalho.puriotv

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.GppGood
import androidx.compose.material.icons.outlined.GppMaybe
import androidx.compose.material.icons.automirrored.outlined.Help
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.RemoveCircleOutline
import androidx.compose.material.icons.outlined.Restore
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.FileUpload
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.guilhermeramalho.puriotv.core.DebloatList
import com.guilhermeramalho.puriotv.core.DebloatProfile
import com.guilhermeramalho.puriotv.core.HomeScreenBlock
import com.guilhermeramalho.puriotv.core.ProfileMatch
import com.guilhermeramalho.puriotv.core.TVAddress
import com.guilhermeramalho.puriotv.core.TVSession
import com.guilhermeramalho.puriotv.core.WifiNetwork
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/*
 * TV setup screens (DebloatViews.swift, HomeUpdateView in TVSetupViews.swift). The flows live in SetupController.kt;
 * these only show them. A flow survives a tab switch (its connection doesn't: leaving the screen cancels the work and
 * closes the connection), and is dropped when the person leaves it with Back or Done.
 */
private object SetupHolder {
    var debloat: DebloatController? = null
    var update: HomeUpdateController? = null
}

// MARK: - Shared pieces

/** SubPage with a Back that the flow decides: null hides it, and system Back then does nothing (a step must finish). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SetupPage(title: String, onBack: (() -> Unit)?, content: @Composable ColumnScope.() -> Unit) {
    BackHandler { onBack?.invoke() }
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(title) },
            navigationIcon = {
                if (onBack != null) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back)) }
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Quiet.background),
        )
        Page(content)
    }
}

@Composable
private fun Heading(text: String) = Text(text, fontSize = 24.sp, fontWeight = FontWeight.Bold)

@Composable
private fun Numbered(n: Int, text: String) = Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
    Box(Modifier.size(24.dp).background(Quiet.cyan.copy(alpha = 0.2f), CircleShape), contentAlignment = Alignment.Center) {
        Text("$n", fontSize = 13.sp, fontWeight = FontWeight.Bold)
    }
    Text(text, fontSize = 14.sp, modifier = Modifier.weight(1f))
}

@Composable
private fun Steps(vararg lines: String) = RowCard {
    Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        lines.forEachIndexed { i, line -> Numbered(i + 1, line) }
    }
}

@Composable
private fun Warning(text: String) = RowCard {
    Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(Icons.Outlined.WarningAmber, null, tint = Quiet.amber, modifier = Modifier.size(20.dp))
        Text(text, fontSize = 13.sp, color = Quiet.amber, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun StatusLine(text: String, good: Boolean) = Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
    Icon(if (good) Icons.Outlined.GppGood else Icons.Outlined.GppMaybe, null, tint = if (good) Quiet.green else Quiet.amber, modifier = Modifier.size(18.dp))
    Text(text, fontSize = 13.sp, color = if (good) Quiet.green else Quiet.amber)
}

@Composable
private fun Working(message: String) = Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
    Text(message, fontSize = 13.sp, color = Quiet.muted)
}

@Composable
private fun AddressField(value: String, onChange: (String) -> Unit, label: String? = stringResource(R.string.su_tv_address)) =
    OutlinedTextField(
        value = value, onValueChange = { onChange(TVAddress.typed(it)) },
        label = label?.let { { Text(it) } }, placeholder = { Text("192.168.1.20") }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
        modifier = Modifier.fillMaxWidth(),
    )

/** A tap-to-open section (the iPhone's DisclosureGroup). */
@Composable
private fun Disclosure(title: String, content: @Composable ColumnScope.() -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column {
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable { open = !open }, verticalAlignment = Alignment.CenterVertically) {
            Text(title, fontSize = 14.sp, modifier = Modifier.weight(1f))
            Icon(if (open) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore, null, tint = Quiet.muted)
        }
        if (open) Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp), content = content)
    }
}

// MARK: - The guided setup

@Composable
fun DebloatSetupScreen(model: RemoteModel, onBack: () -> Unit) {
    val context = LocalContext.current.applicationContext
    val flow = remember {
        SetupHolder.debloat ?: DebloatController(context, model.setup, model.state.value.host).also { SetupHolder.debloat = it }
    }
    // Leaving the screen (or the tab) holds no connection and stops any work.
    DisposableEffect(flow) { onDispose { flow.cancel() } }
    val leave = { flow.cancel(); SetupHolder.debloat = null; onBack() }
    var confirmRestore by remember { mutableStateOf(false) }
    val step = flow.step
    val back: (() -> Unit)? = when {
        step == DebloatController.Step.OVERVIEW -> leave
        flow.busy && (step == DebloatController.Step.CONNECT || step == DebloatController.Step.INSPECT) -> ({ flow.abandonConnecting() })
        step.ordinal < DebloatController.Step.APPLY.ordinal && !flow.busy -> ({ flow.back() })
        else -> null
    }
    SetupPage(stringResource(R.string.su_title), back) {
        LinearProgressIndicator(progress = { (step.ordinal + 1f) / DebloatController.Step.entries.size }, modifier = Modifier.fillMaxWidth(), color = Quiet.cyan)
        when (step) {
            DebloatController.Step.OVERVIEW -> Overview(flow)
            DebloatController.Step.DEVELOPER -> Developer(flow)
            DebloatController.Step.CONNECT, DebloatController.Step.INSPECT -> Connecting(flow, leave)
            DebloatController.Step.CHOOSE -> Choose(flow)
            DebloatController.Step.REVIEW -> Review(flow)
            DebloatController.Step.HOME -> ChooseHome(flow)
            DebloatController.Step.APPLY -> Applying(flow) { confirmRestore = true }
            DebloatController.Step.TEST -> TestStep(flow) { confirmRestore = true }
            DebloatController.Step.FINISH -> Finish(flow, leave)
        }
        flow.error?.let { Warning(it) }
        if (flow.lostConnection && !flow.busy && step.ordinal in DebloatController.Step.CHOOSE.ordinal until DebloatController.Step.APPLY.ordinal) {
            PrimaryButton(stringResource(R.string.su_connect_again)) { flow.reconnect() }
        }
    }
    if (confirmRestore) Confirm(
        stringResource(R.string.su_restore_confirm_title), stringResource(R.string.su_restore_confirm_message),
        stringResource(R.string.su_restore_tv), destructive = true, onDismiss = { confirmRestore = false },
    ) { flow.restore() }
}

@Composable
private fun Overview(flow: DebloatController) {
    Text(stringResource(R.string.su_reclaimed).uppercase(), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Quiet.muted)
    Text(stringResource(R.string.su_hero), fontSize = 30.sp, fontWeight = FontWeight.Bold, lineHeight = 36.sp)
    Text(stringResource(R.string.su_overview_detail), color = Quiet.muted)
    RowCard {
        NavRow(Icons.Outlined.Checklist, stringResource(R.string.su_choose_stays), stringResource(R.string.su_choose_stays_detail), chevron = false)
        RowDivider()
        NavRow(Icons.Outlined.Restore, stringResource(R.string.su_save_record), stringResource(R.string.su_save_record_detail), chevron = false)
    }
    RowCard {
        Column(Modifier.padding(top = 14.dp)) {
            Text(stringResource(R.string.su_risk_title), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Quiet.amber, modifier = Modifier.padding(horizontal = 16.dp))
            Text(stringResource(R.string.su_risk_detail), fontSize = 13.sp, color = Quiet.muted, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            SwitchRow(stringResource(R.string.su_understand_risks), checked = flow.acknowledged) { flow.acknowledged = it }
        }
    }
    Caption(stringResource(R.string.su_remote_ready))
    PrimaryButton(stringResource(R.string.su_continue), enabled = flow.acknowledged) { flow.step = DebloatController.Step.DEVELOPER }
}

@Composable
private fun Developer(flow: DebloatController) {
    Heading(stringResource(R.string.su_debugging_title))
    Steps(stringResource(R.string.su_dev_step1), stringResource(R.string.su_dev_step2), stringResource(R.string.su_dev_step3), stringResource(R.string.su_dev_step4))
    AddressField(flow.address, { flow.address = it })
    Caption(stringResource(R.string.su_wireless_unsupported))
    PrimaryButton(stringResource(R.string.su_connect), enabled = TVAddress.parse(flow.address) != null) {
        flow.step = DebloatController.Step.CONNECT; flow.connect()
    }
}

@Composable
private fun Connecting(flow: DebloatController, close: () -> Unit) {
    val inventory = flow.inventory
    when {
        flow.waitingForApproval -> {
            Icon(Icons.Outlined.Tv, null, tint = Quiet.cyan, modifier = Modifier.size(44.dp))
            Heading(stringResource(R.string.su_allow_title))
            Text(stringResource(R.string.su_allow_detail), color = Quiet.muted)
        }
        !flow.busy && inventory != null && (flow.profile == null ||
            (flow.step == DebloatController.Step.INSPECT && flow.match?.kind != ProfileMatch.Kind.TESTED)) ->
            if (flow.candidates.isEmpty()) Unsupported(flow, close) else ListPicker(flow, close)
        else -> Heading(stringResource(if (flow.step == DebloatController.Step.CONNECT) R.string.su_connecting else R.string.su_checking_tv))
    }
    if (flow.busy) Working(flow.message)
    if (!flow.busy && flow.error != null) PrimaryButton(stringResource(R.string.su_try_again)) { flow.retry() }
}

@Composable
private fun Unsupported(flow: DebloatController, close: () -> Unit) {
    val p = flow.inventory?.properties ?: emptyMap()
    Heading(stringResource(R.string.su_unsupported_title))
    RowCard {
        NavRow(Icons.Outlined.Tv, p["ro.product.model"] ?: stringResource(R.string.unknown_model),
            "${p["ro.product.manufacturer"] ?: ""} · ${p["ro.product.device"] ?: ""} · Android ${p["ro.build.version.release"] ?: "?"}", chevron = false)
    }
    Caption(stringResource(R.string.su_unsupported_detail))
    if (BuildConfig.DEBUG) Caption(stringResource(R.string.su_dev_profiles,
        if (flow.profiles.isEmpty()) stringResource(R.string.su_dev_profiles_none) else flow.profiles.joinToString(", ") { it.id }))
    SecondaryButton(stringResource(R.string.su_close), onClick = close)
}

/** The lists ProfileMatcher found for this TV, best first; the person picks the one for their TV. */
@Composable
private fun ListPicker(flow: DebloatController, close: () -> Unit) {
    var showAll by remember { mutableStateOf(false) }
    var closestPending by remember { mutableStateOf<ProfileMatch?>(null) }
    val p = flow.inventory?.properties ?: emptyMap()
    Heading(stringResource(R.string.su_choose_list))
    Caption(stringResource(R.string.su_choose_list_detail, p["ro.product.model"] ?: "?", p["ro.product.device"] ?: "?"))
    val shown = if (showAll) flow.candidates else flow.candidates.take(3)
    RowCard {
        shown.forEachIndexed { i, candidate ->
            NavRow(if (candidate.kind == ProfileMatch.Kind.CLOSEST) Icons.AutoMirrored.Outlined.Help else Icons.Outlined.CheckCircle,
                candidate.profile.manifest.name, matchDetail(candidate)) {
                if (candidate.kind == ProfileMatch.Kind.CLOSEST) closestPending = candidate else flow.choose(candidate)
            }
            if (i < shown.size - 1) RowDivider()
        }
    }
    if (flow.candidates.size > 3 && !showAll) SecondaryButton(stringResource(R.string.su_show_more, flow.candidates.size - 3)) { showAll = true }
    Caption(stringResource(R.string.su_nothing_until_apply))
    SecondaryButton(stringResource(R.string.su_close), onClick = close)
    closestPending?.let { candidate ->
        Confirm(stringResource(R.string.su_closest_title), stringResource(R.string.su_closest_message), stringResource(R.string.su_use_list),
            onDismiss = { closestPending = null }) { flow.choose(candidate) }
    }
}

/** One app gets its own sentence: the translations have no plural variants for these. */
@Composable
private fun matchDetail(match: ProfileMatch): String {
    val one = match.present == 1
    val names = match.named.joinToString(", ")
    return when (match.kind) {
        ProfileMatch.Kind.TESTED -> if (one) stringResource(R.string.su_match_tested_one) else stringResource(R.string.su_match_tested, match.present)
        ProfileMatch.Kind.MODEL -> if (one) stringResource(R.string.su_match_model_one, names) else stringResource(R.string.su_match_model, names, match.present)
        ProfileMatch.Kind.CLOSEST -> if (one) stringResource(R.string.su_match_closest_one) else stringResource(R.string.su_match_closest, match.present)
    }
}

private fun entryTitle(entry: DebloatList.Entry): String =
    if (entry.note.isEmpty()) entry.packageName else entry.note.replaceFirstChar { it.uppercase() }

@Composable
private fun Choose(flow: DebloatController) {
    Heading(stringResource(R.string.su_choose_stays))
    val profile = flow.profile ?: return
    val detail = when (flow.match?.kind) {
        ProfileMatch.Kind.CLOSEST -> stringResource(R.string.su_choose_closest)
        ProfileMatch.Kind.MODEL -> stringResource(R.string.su_choose_model)
        else -> stringResource(R.string.su_choose_tested)
    }
    RowCard {
        NavRow(if (flow.match?.kind == ProfileMatch.Kind.CLOSEST) Icons.Outlined.WarningAmber else Icons.Outlined.Verified,
            profile.manifest.name, detail, chevron = false)
    }
    if (profile.isCommunity) ListNotes(profile)
    val choices = flow.choices
    for (group in profile.list.groups) {
        val entries = choices.filter { it.group == group }
        if (entries.isEmpty()) continue
        SectionTitle(group)
        RowCard {
            entries.forEachIndexed { i, entry ->
                SwitchRow(entryTitle(entry), if (entry.note.isNotEmpty()) entry.packageName else null, checked = entry.packageName in flow.keep) { on ->
                    flow.keep = if (on) flow.keep + entry.packageName else flow.keep - entry.packageName
                }
                if (i < entries.size - 1) RowDivider()
            }
        }
    }
    // One app gets its own sentence (chooseFooter in DebloatViews.swift).
    Caption(when {
        flow.protectedCount == 1 && flow.alreadyHandled == 1 -> stringResource(R.string.su_choose_footer_p1l1)
        flow.protectedCount == 1 -> stringResource(R.string.su_choose_footer_p1, flow.alreadyHandled)
        flow.alreadyHandled == 1 -> stringResource(R.string.su_choose_footer_l1, flow.protectedCount)
        else -> stringResource(R.string.su_choose_footer, flow.protectedCount, flow.alreadyHandled)
    })
    PrimaryButton(stringResource(if (flow.busy) R.string.su_checking else R.string.su_review_changes), enabled = !flow.busy) { flow.review() }
}

/** What the list's testers wrote: the importer's warnings and the list's summary (tv.json notes). */
@Composable
private fun ListNotes(profile: DebloatProfile) {
    val warnings = profile.manifest.warnings ?: emptyList()
    if (warnings.isNotEmpty()) {
        SectionTitle(stringResource(R.string.su_testers))
        RowCard {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                warnings.forEach { w ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(Icons.Outlined.ErrorOutline, null, tint = Quiet.amber, modifier = Modifier.size(16.dp))
                        Text(w, fontSize = 12.sp, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    }
    if (profile.notes.isNotEmpty()) Disclosure(stringResource(R.string.su_about_list)) {
        Text(profile.notes, fontSize = 12.sp, color = Quiet.muted)
    }
}

@Composable
private fun Review(flow: DebloatController) {
    Heading(stringResource(R.string.su_review))
    val plan = flow.plan ?: return
    RowCard {
        NavRow(Icons.Outlined.RemoveCircleOutline, stringResource(R.string.su_will_disable, plan.disable.size), stringResource(R.string.su_will_disable_detail), chevron = false)
    }
    if (plan.skipped.isNotEmpty()) {
        SectionTitle(stringResource(R.string.su_kept_by_checks))
        RowCard {
            plan.skipped.forEachIndexed { i, skip ->
                Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(skip.packageName, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    Text(stringResource(skip.reason.text()), fontSize = 12.sp, color = Quiet.muted)
                }
                if (i < plan.skipped.size - 1) RowDivider()
            }
        }
    }
    plan.notes.forEach { Caption(stringResource(it.text())) }
    if (plan.wifiToResave.isNotEmpty()) WifiResave(flow, plan.wifiToResave)
    Disclosure(stringResource(R.string.su_show_apps, plan.disable.size)) {
        plan.disable.forEach { Text(it, fontSize = 12.sp, fontFamily = FontFamily.Monospace) }
    }
    RowCard { SwitchRow(stringResource(R.string.su_reviewed), checked = flow.understood) { flow.understood = it } }
    PrimaryButton(stringResource(R.string.su_continue), enabled = flow.understood && flow.wifiReady) { flow.step = DebloatController.Step.HOME }
}

/** The setup wizard owns these networks and deletes them when it's disabled, so they're saved again first. */
@Composable
private fun WifiResave(flow: DebloatController, networks: List<WifiNetwork>) {
    SectionTitle(stringResource(R.string.su_keep_wifi))
    Caption(stringResource(R.string.su_wifi_detail))
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Outlined.WarningAmber, null, tint = Quiet.amber, modifier = Modifier.size(16.dp))
        Text(stringResource(R.string.su_wifi_warning), fontSize = 12.sp, color = Quiet.amber, modifier = Modifier.weight(1f))
    }
    RowCard {
        networks.forEachIndexed { i, network ->
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(network.ssid, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                if (network.needsPassword) {
                    val typed = flow.wifiPasswords[network.ssid] ?: ""
                    val again = flow.wifiConfirm[network.ssid] ?: ""
                    PasswordField(typed, stringResource(R.string.su_wifi_password)) { flow.wifiPasswords = flow.wifiPasswords + (network.ssid to it) }
                    PasswordField(again, stringResource(R.string.su_wifi_password_again)) { flow.wifiConfirm = flow.wifiConfirm + (network.ssid to it) }
                    if (again.isNotEmpty() && typed != again) Text(stringResource(R.string.su_wifi_mismatch), fontSize = 12.sp, color = Quiet.amber)
                } else {
                    Text(stringResource(R.string.su_wifi_open), fontSize = 12.sp, color = Quiet.muted)
                }
            }
            if (i < networks.size - 1) RowDivider()
        }
    }
    Caption(stringResource(R.string.su_wifi_once))
    SectionTitle(stringResource(R.string.su_wifi_safer))
    Caption(stringResource(R.string.su_wifi_safer_detail))
    SecondaryButton(stringResource(R.string.su_review_again), enabled = !flow.busy) { flow.review() }
}

@Composable
private fun PasswordField(value: String, label: String, onChange: (String) -> Unit) = OutlinedTextField(
    value = value, onValueChange = onChange, label = { Text(label) }, singleLine = true,
    visualTransformation = PasswordVisualTransformation(),
    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
    modifier = Modifier.fillMaxWidth(),
)

@Composable
private fun homeBlockText(block: HomeScreenBlock): String = stringResource(when (block) {
    HomeScreenBlock.FIRE_OS -> R.string.su_block_fire
    HomeScreenBlock.CVTE -> R.string.su_block_cvte
    HomeScreenBlock.DEBLOAT_ONLY -> R.string.su_block_debloat_only
    HomeScreenBlock.CUSTOM_BUILD -> R.string.su_block_custom
    HomeScreenBlock.NO_CONFIG -> R.string.su_block_no_config
})

@Composable
private fun ChooseHome(flow: DebloatController) {
    Heading(stringResource(R.string.su_choose_home))
    val block = flow.homeScreenBlock
    if (block != null) {
        RowCard { NavRow(Icons.Outlined.Home, stringResource(R.string.su_keeps_home), homeBlockText(block), chevron = false) }
    } else {
        RowCard { SwitchRow(stringResource(R.string.su_install_home), stringResource(R.string.su_install_home_detail), checked = flow.installLauncher) { flow.installLauncher = it } }
        val profile = flow.profile
        val inventory = flow.inventory
        if (flow.installLauncher && profile != null && inventory != null) {
            SectionTitle(stringResource(R.string.su_dock_title))
            val apps = profile.manifest.dockCandidates.filter { it in inventory.installed }
            RowCard {
                apps.forEachIndexed { i, id ->
                    val at = flow.dock.indexOf(id)
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable {
                        flow.dock = if (at >= 0) flow.dock - id else if (flow.dock.size < 7) flow.dock + id else flow.dock
                    }.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(TVSession.appName(id) ?: id, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        if (at >= 0) Box(Modifier.size(22.dp).background(Quiet.cyan.copy(alpha = 0.25f), CircleShape), contentAlignment = Alignment.Center) {
                            Text("${at + 1}", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    if (i < apps.size - 1) RowDivider()
                }
            }
            Caption(stringResource(R.string.su_rearrange_later))
        }
    }
    if (flow.homeBlocked) Warning(stringResource(R.string.su_wizard_keeps_home))
    Caption(stringResource(R.string.su_restart_once))
    PrimaryButton(stringResource(R.string.su_apply), enabled = !flow.busy && !flow.homeBlocked) { flow.apply() }
}

@Composable
private fun Applying(flow: DebloatController, restore: () -> Unit) {
    // A successful apply moves on to the test step, so standing here idle means it stopped (failed or interrupted).
    Heading(stringResource(if (flow.busy) R.string.su_applying else R.string.su_stopped))
    LinearProgressIndicator(progress = { flow.progress }, modifier = Modifier.fillMaxWidth(), color = Quiet.cyan)
    if (flow.waitingForApproval) Caption(stringResource(R.string.su_undo_allow))
    Text(flow.message, fontSize = 13.sp, color = Quiet.muted)
    if (flow.log.isNotEmpty()) RowCard {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) { flow.log.forEach { Text(it, fontSize = 12.sp) } }
    }
    if (!flow.busy) {
        Caption(stringResource(R.string.su_apply_failed))
        if (flow.recordFile != null) SecondaryButton(stringResource(R.string.su_restore_tv), onClick = restore)
        SecondaryButton(stringResource(R.string.su_back_to_review)) { flow.error = null; flow.step = DebloatController.Step.REVIEW }
    }
    flow.restoreResult?.let { StatusLine(it, flow.restoredOK) }
}

@Composable
private fun TestStep(flow: DebloatController, restore: () -> Unit) {
    var checks by remember { mutableStateOf(setOf<Int>()) }
    val checklist = listOf(
        stringResource(if (flow.homeComponent == null) R.string.su_check_home_tv else R.string.su_check_home_new),
        stringResource(R.string.su_check_buttons), stringResource(R.string.su_check_hdmi),
        stringResource(R.string.su_check_settings), stringResource(R.string.su_check_online),
    )
    Heading(stringResource(R.string.su_test_title))
    flow.restartProblem?.let { Warning(it) }
    if (flow.restartChecked) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.CheckCircle, null, tint = Quiet.green, modifier = Modifier.size(18.dp))
        Text(stringResource(R.string.su_restart_ok), fontSize = 13.sp, color = Quiet.green)
    }
    flow.restartNote?.let { Caption(it) }
    flow.result?.takeIf { it.stillEnabled.isNotEmpty() }?.let {
        Caption(stringResource(R.string.su_still_enabled, it.stillEnabled.size, it.stillEnabled.joinToString(", ")))
    }
    RowCard {
        checklist.forEachIndexed { i, line ->
            SwitchRow(line, checked = i in checks) { on -> checks = if (on) checks + i else checks - i }
            if (i < checklist.size - 1) RowDivider()
        }
    }
    PrimaryButton(stringResource(R.string.su_everything_works), enabled = checks.size == checklist.size && !flow.busy) { flow.step = DebloatController.Step.FINISH }
    SecondaryButton(stringResource(R.string.su_something_wrong), enabled = !flow.busy, onClick = restore)
    if (flow.busy) Working(flow.message)
    flow.restoreResult?.let { StatusLine(it, flow.restoredOK) }
}

@Composable
private fun Finish(flow: DebloatController, done: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var exported by remember { mutableStateOf<Boolean?>(null) }
    val file = flow.recordFile
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri != null && file != null) scope.launch {
            exported = withContext(Dispatchers.IO) {
                runCatching { context.contentResolver.openOutputStream(uri)?.use { it.write(file.readBytes()) } != null }.getOrDefault(false)
            }
        }
    }
    Heading(stringResource(R.string.su_secure_title))
    if (file != null) {
        SecondaryButton(stringResource(R.string.su_export_record), Icons.Rounded.FileUpload) { exporter.launch(file.name) }
        Caption(stringResource(R.string.su_export_detail))
        exported?.let { StatusLine(stringResource(if (it) R.string.su_exported else R.string.su_export_failed), it) }
    }
    PrimaryButton(stringResource(R.string.su_turn_off_debugging), enabled = !flow.busy) { flow.turnOffDebugging() }
    Caption(stringResource(R.string.su_turn_off_detail))
    Steps(stringResource(R.string.su_secure_step1), stringResource(R.string.su_secure_step2), stringResource(R.string.su_secure_step3))
    Caption(stringResource(R.string.su_no_debugging_needed))
    SecondaryButton(stringResource(R.string.su_check_debugging_off), enabled = !flow.busy) { flow.checkDebuggingClosed() }
    if (flow.busy) Working(flow.message)
    flow.debuggingClosed?.let { StatusLine(stringResource(if (it) R.string.su_debugging_off else R.string.su_debugging_open), it) }
    SecondaryButton(stringResource(R.string.done), onClick = done)
}

// MARK: - Undo

@Composable
fun UndoSetupScreen(model: RemoteModel, onBack: () -> Unit) {
    val context = LocalContext.current.applicationContext
    val flow = remember { UndoController(context, model.setup, model.state.value.host).also { it.reload() } }
    DisposableEffect(flow) { onDispose { flow.cancel() } }
    SetupPage(stringResource(R.string.su_undo_title), onBack) {
        Heading(stringResource(R.string.su_undo_title))
        if (flow.records.isEmpty()) {
            Caption(stringResource(R.string.su_undo_none))
            return@SetupPage
        }
        RowCard {
            flow.records.forEachIndexed { i, item ->
                val record = item.record
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) {
                        NavRow(Icons.Outlined.Tv, (record.lists ?: listOf(record.list)).joinToString(" + "),
                            stringResource(R.string.su_undo_record_detail, record.host, record.created.take(10), record.packages.values.count { it == "enabled" }),
                            chevron = false, enabled = !flow.busy) { flow.select(item) }
                    }
                    if (flow.selected == item.file) Icon(Icons.Rounded.CheckCircle, null, tint = Quiet.cyan, modifier = Modifier.padding(end = 16.dp))
                }
                if (i < flow.records.size - 1) RowDivider()
            }
        }
        AddressField(flow.address, { flow.address = it })
        Caption(stringResource(R.string.su_undo_debugging))
        PrimaryButton(stringResource(if (flow.busy) R.string.su_restoring_button else R.string.su_restore_this_tv),
            enabled = !flow.busy && flow.selected != null && TVAddress.parse(flow.address) != null) { flow.restore() }
        if (flow.waitingForApproval) Caption(stringResource(R.string.su_undo_allow))
        if (flow.message.isNotEmpty()) Text(flow.message, fontSize = 13.sp, color = if (flow.done) Quiet.green else Quiet.amber)
        flow.error?.let { Warning(it) }
    }
}

// MARK: - Home screen update

@Composable
fun HomeUpdateScreen(model: RemoteModel, onBack: () -> Unit) {
    val context = LocalContext.current.applicationContext
    val flow = remember {
        SetupHolder.update ?: HomeUpdateController(context, model.state.value.host).also { SetupHolder.update = it }
    }
    DisposableEffect(flow) { onDispose { flow.cancel() } }
    val leave = { flow.cancel(); SetupHolder.update = null; onBack() }
    // Once the TV has the new Home: reconnect the editor so the TV tab reads the new version.
    LaunchedEffect(flow.step) {
        if (flow.step == HomeUpdateController.Step.DONE) model.editor.connect(force = true)
    }
    SetupPage(stringResource(R.string.su_update_title), if (flow.busy) null else leave) {
        when (flow.step) {
            HomeUpdateController.Step.START -> {
                Heading(stringResource(R.string.su_update_heading))
                Text(stringResource(R.string.su_update_detail), fontSize = 14.sp, color = Quiet.muted)
                RowCard {
                    Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(stringResource(R.string.su_update_debugging), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                        Numbered(1, stringResource(R.string.su_update_step1))
                        Numbered(2, stringResource(R.string.su_update_step2))
                        Numbered(3, stringResource(R.string.su_update_step3))
                    }
                }
                AddressField(flow.address, { flow.address = it })
                PrimaryButton(stringResource(R.string.su_update_title), enabled = TVAddress.parse(flow.address) != null && !flow.busy) { flow.update() }
                Caption(stringResource(R.string.su_update_footer))
            }
            HomeUpdateController.Step.CONNECTING, HomeUpdateController.Step.UPDATING -> {
                if (flow.waitingForApproval) {
                    Icon(Icons.Outlined.Tv, null, tint = Quiet.cyan, modifier = Modifier.size(44.dp))
                    Heading(stringResource(R.string.su_allow_title))
                    Text(stringResource(R.string.su_allow_detail), color = Quiet.muted)
                } else {
                    Heading(stringResource(if (flow.step == HomeUpdateController.Step.CONNECTING) R.string.su_connecting else R.string.su_updating))
                    if (flow.step == HomeUpdateController.Step.UPDATING) LinearProgressIndicator(progress = { flow.progress }, modifier = Modifier.fillMaxWidth(), color = Quiet.cyan)
                }
                if (flow.busy) Working(flow.message)
            }
            HomeUpdateController.Step.DONE -> {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.CheckCircle, null, tint = Quiet.cyan)
                    Text(stringResource(if (flow.alreadyCurrent) R.string.su_update_current else R.string.su_update_done),
                        fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Quiet.cyan)
                }
                if (!flow.alreadyCurrent) Caption(stringResource(R.string.su_update_done_detail))
                PrimaryButton(stringResource(R.string.su_turn_off_debugging), enabled = !flow.busy) { flow.turnOffDebugging() }
                if (flow.busy) Working(flow.message)
                flow.debuggingClosed?.let { StatusLine(stringResource(if (it) R.string.su_debugging_off else R.string.su_debugging_open), it) }
                SecondaryButton(stringResource(R.string.done), onClick = leave)
            }
        }
        flow.error?.let {
            Warning(it)
            if (!flow.busy && flow.step != HomeUpdateController.Step.DONE) PrimaryButton(stringResource(R.string.su_try_again)) { flow.update() }
        }
    }
}

