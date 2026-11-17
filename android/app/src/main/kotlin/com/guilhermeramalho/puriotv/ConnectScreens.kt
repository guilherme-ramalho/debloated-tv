package com.guilhermeramalho.puriotv

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Backspace
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.guilhermeramalho.puriotv.core.DiscoveredTv
import com.guilhermeramalho.puriotv.core.PortKnock
import com.guilhermeramalho.puriotv.core.TvKind
import com.guilhermeramalho.puriotv.core.TvPorts
import com.guilhermeramalho.puriotv.core.TvSupport

/** The Remote tab before any TV is paired (ConnectTVView): TVs found on the Wi-Fi, or type the address. */
@Composable
fun ConnectScreen(model: RemoteModel) {
    val tvs by model.discovery.tvs.collectAsStateWithLifecycle()
    var typing by rememberSaveable { mutableStateOf(false) }
    var search by remember { mutableIntStateOf(0) }
    var waitedLong by remember { mutableStateOf(false) }
    // Search only while this screen is visible and the app is in front.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, search) {
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
    LaunchedEffect(search) { waitedLong = false; delay(8_000); waitedLong = true }

    Page {
        if (tvs.isEmpty() && waitedLong) {
            PageTitle(stringResource(R.string.connect_none_title))
            Text(stringResource(R.string.connect_none_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
            RowCard {
                Column(Modifier.padding(vertical = 6.dp)) {
                    Tip(1, R.string.tip_on, R.string.tip_on_detail)
                    Tip(2, R.string.tip_network, R.string.tip_network_detail)
                    Tip(3, R.string.tip_system, R.string.tip_system_detail)
                }
            }
            Button(onClick = { search++ }, modifier = Modifier.fillMaxWidth().height(48.dp)) { Text(stringResource(R.string.search_again)) }
            TextButton(onClick = { typing = true }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.enter_address_instead)) }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PageTitle(stringResource(R.string.connect_title))
                Text(stringResource(R.string.connect_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionTitle(stringResource(R.string.tvs_on_network))
                Spacer(Modifier.weight(1f))
                CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = Quiet.muted)
                Spacer(Modifier.size(6.dp))
                Caption(stringResource(R.string.still_looking))
            }
            if (tvs.isNotEmpty()) RowCard {
                tvs.forEachIndexed { i, tv ->
                    val pairable = tv.host != null && tv.support?.canPair != false
                    ListItem(
                        headlineContent = { Text(tv.name) },
                        supportingContent = { Text(tvDetail(tv)) },
                        leadingContent = { Icon(Icons.Outlined.Tv, null) },
                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                        modifier = Modifier.alpha(if (tv.support?.canPair == false) 0.55f else 1f)
                            .clickable(enabled = pairable) { tv.host?.let { model.choose(it, tv.name) } },
                    )
                    if (i < tvs.lastIndex) RowDivider()
                }
            }
            TextButton(onClick = { typing = true }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.not_listed)) }
            Surface(color = Color.White.copy(alpha = 0.045f), shape = RoundedCornerShape(14.dp)) {
                Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(Icons.Outlined.Info, null, tint = Quiet.muted, modifier = Modifier.size(18.dp))
                    Caption(stringResource(R.string.connect_footer))
                }
            }
        }
    }
    if (typing) AddressSheet(onDismiss = { typing = false }) { address -> typing = false; model.choose(address, address) }
}

/** The row's second line: the kind of TV and what Purio can do on it (DiscoveredTV.detail). */
@Composable
private fun tvDetail(tv: DiscoveredTv): String {
    val host = tv.host ?: return stringResource(R.string.finding_address)
    val support = tv.support ?: return if (tv.kind == TvKind.ANDROID_TV) "${tv.kind.label} · $host" else stringResource(R.string.checking)
    val can = when (support) {
        is TvSupport.Full -> stringResource(if (support.showOnTv) R.string.tv_can_full else R.string.tv_can_basic)
        TvSupport.RemoteComing -> stringResource(R.string.tv_remote_coming)
        TvSupport.NotYet -> stringResource(R.string.tv_not_yet)
    }
    return "${tv.kind.label} · $can"
}

@Composable
private fun Tip(n: Int, title: Int, detail: Int) {
    Row(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(24.dp).background(Quiet.cyan.copy(alpha = 0.18f), CircleShape), contentAlignment = Alignment.Center) {
            Text("$n", color = Quiet.cyan, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        }
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.titleSmall)
            Caption(stringResource(detail))
        }
    }
}

/** Type the TV's address (AddressEntrySheet): commas become dots for keyboards that have no dot key. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddressSheet(onDismiss: () -> Unit, onConnect: (String) -> Unit) {
    var address by rememberSaveable { mutableStateOf("") }
    var checking by remember { mutableStateOf(false) }
    /** What answered at that address when it isn't an Android TV. */
    var other by remember { mutableStateOf<TvKind?>(null) }
    val scope = rememberCoroutineScope()
    // Knock first: an Android TV (or nothing answering, which pairing then explains) goes on to pairing; any other
    // TV is named here instead of a pairing that could never work.
    val connect = {
        checking = true
        scope.launch {
            val kind = TvPorts.kind(PortKnock.openPorts(address))
            checking = false
            if (kind != null && kind != TvKind.ANDROID_TV) other = kind else onConnect(address)
        }
        Unit
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Quiet.panel) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(stringResource(R.string.address_title), style = MaterialTheme.typography.titleLarge)
            Caption(stringResource(R.string.address_hint))
            OutlinedTextField(
                value = address, onValueChange = { address = it.replace(',', '.').filterNot(Char::isWhitespace).take(15); other = null },
                label = { Text(stringResource(R.string.address_label)) }, placeholder = { Text("192.168.0.13") }, singleLine = true,
                isError = address.isNotEmpty() && !isIPv4(address) && address.count { it == '.' } == 3 && address.last() != '.',
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { if (isIPv4(address) && !checking) connect() }),
                modifier = Modifier.fillMaxWidth(),
            )
            other?.let { kind ->
                Surface(color = Color.White.copy(alpha = 0.045f), shape = RoundedCornerShape(14.dp)) {
                    Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.Outlined.Info, null, tint = Quiet.muted, modifier = Modifier.size(18.dp))
                        Caption(if (kind == TvKind.CHROMECAST) stringResource(R.string.tv_is_chromecast) else stringResource(R.string.tv_is_other, kind.label))
                    }
                }
            }
            Button(onClick = connect, enabled = isIPv4(address) && !checking, modifier = Modifier.fillMaxWidth().height(48.dp)) {
                if (checking) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.size(8.dp))
                    Text(stringResource(R.string.checking))
                } else Text(stringResource(R.string.address_connect))
            }
        }
    }
}

fun isIPv4(text: String): Boolean {
    val parts = text.split('.')
    return parts.size == 4 && parts.all { p -> p.isNotEmpty() && p.length <= 3 && p.all(Char::isDigit) && p.toInt() in 0..255 }
}

/** Pairing (TVPairingView): the TV is asked for a code, then six boxes and a keypad with only 0–9 and A–F. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairingSheet(state: RemoteModel.State, model: RemoteModel) {
    val pairing = state.pairing ?: return
    var code by rememberSaveable { mutableStateOf("") }
    LaunchedEffect(pairing) { if (pairing is RemoteModel.Pairing.Code && pairing.notice != null || pairing == RemoteModel.Pairing.Asking) code = "" }
    ModalBottomSheet(
        onDismissRequest = { model.cancelPairing() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { true }),
        containerColor = Quiet.panel,
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 20.dp).navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            when (pairing) {
                RemoteModel.Pairing.Asking -> {
                    Icon(Icons.Outlined.Tv, null, tint = Quiet.muted, modifier = Modifier.size(44.dp))
                    Text(stringResource(R.string.pair_title), style = MaterialTheme.typography.titleLarge)
                    CircularProgressIndicator()
                    Text(stringResource(R.string.pair_asking, state.tvName), textAlign = TextAlign.Center, color = Quiet.muted)
                    Caption(stringResource(R.string.pair_keep_on), Modifier)
                }
                is RemoteModel.Pairing.Failed -> {
                    Icon(Icons.Outlined.Tv, null, tint = Quiet.muted, modifier = Modifier.size(44.dp))
                    Text(stringResource(R.string.pair_no_answer, state.tvName), textAlign = TextAlign.Center)
                    Text(stringResource(pairing.problem.message()), color = Quiet.amber, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall)
                    Button(onClick = { code = ""; model.pairAgain() }, modifier = Modifier.fillMaxWidth().height(48.dp)) { Text(stringResource(R.string.retry)) }
                }
                is RemoteModel.Pairing.Code -> {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(stringResource(R.string.pair_enter_code), style = MaterialTheme.typography.titleLarge)
                        Text(stringResource(R.string.pair_showing_code, state.tvName), color = Quiet.muted, textAlign = TextAlign.Center)
                    }
                    CodeField(code) { value ->
                        code = value
                        if (value.length == 6) model.submit(value)
                    }
                    pairing.notice?.let { Text(stringResource(it.message()), color = Quiet.amber, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall) }
                    TextButton(onClick = { code = ""; model.pairAgain() }) { Text(stringResource(R.string.pair_no_code)) }
                }
            }
            TextButton(onClick = { code = ""; model.cancelPairing() }) { Text(stringResource(R.string.cancel), color = Quiet.muted) }
        }
    }
}

@Composable
private fun CodeField(code: String, onChange: (String) -> Unit) {
    val haptics = LocalHapticFeedback.current
    val label = stringResource(R.string.pair_code_label)
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(Modifier.semantics { contentDescription = "$label ${code.toList().joinToString(" ")}" }, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            repeat(6) { i ->
                Box(
                    Modifier.weight(1f).height(58.dp)
                        .background(Quiet.background, RoundedCornerShape(12.dp))
                        .border(1.dp, if (i == code.length) Quiet.cyan else Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(code.getOrNull(i)?.toString() ?: "", fontSize = 26.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("123A", "456B", "789C", "0DEF").forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { c ->
                        FilledTonalButton(
                            onClick = { if (code.length < 6) { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); onChange(code + c) } },
                            shape = RoundedCornerShape(12.dp), modifier = Modifier.weight(1f).height(50.dp),
                        ) { Text("$c", fontSize = 22.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace) }
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Spacer(Modifier.weight(3f).padding(horizontal = 8.dp))
                val delete = stringResource(R.string.delete)
                TextButton(onClick = { onChange(code.dropLast(1)) }, enabled = code.isNotEmpty(),
                    modifier = Modifier.weight(1f).height(50.dp).semantics { contentDescription = delete }) {
                    Icon(Icons.AutoMirrored.Outlined.Backspace, null, tint = Color.White)
                }
            }
        }
    }
}

