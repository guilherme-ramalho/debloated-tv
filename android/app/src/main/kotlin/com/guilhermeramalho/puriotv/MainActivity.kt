package com.guilhermeramalho.puriotv

import android.graphics.Color as AndroidColor
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.SettingsRemote
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle

class MainActivity : ComponentActivity() {
    private val model: RemoteModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
        )
        AppShortcuts.publish(this)
        setContent { PurioTheme { App(model) } }
    }

    override fun onStart() { super.onStart(); model.foreground(true) }
    override fun onStop() { model.foreground(false); super.onStop() }
}

private enum class Tab(@StringRes val label: Int, val icon: ImageVector) {
    REMOTE(R.string.tab_remote, Icons.Outlined.SettingsRemote),
    TV(R.string.tab_tv, Icons.Outlined.Tv),
    ACTIONS(R.string.tab_actions, Icons.Outlined.Bolt),
    SETTINGS(R.string.tab_settings, Icons.Outlined.Tune),
}

/**
 * Four tabs as on the iPhone (Remote, TV, Actions, Settings), as a Material navigation bar. Each tab keeps its own
 * stack of pushed screens (the iPhone's NavigationStack per tab); Back pops it.
 */
@Composable
private fun App(model: RemoteModel) {
    val state by model.state.collectAsStateWithLifecycle()
    val prefs by model.settings.value.collectAsStateWithLifecycle()
    val notice by model.settings.notice.collectAsState()
    val editorState by model.editor.state.collectAsState()
    val layoutChange by model.settings.layoutChange.collectAsState()
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val tvStack = remember { mutableStateListOf<TVRoute>() }
    val actionsStack = remember { mutableStateListOf<ActionsRoute>() }
    val settingsStack = remember { mutableStateListOf<SettingsRoute>() }

    // The TV tab's editor: it connects when the tab shows, follows a new TV, and applies draft changes.
    LaunchedEffect(tab, state.ready) { if (tab == Tab.TV.ordinal) model.editor.autoConnect() }
    LaunchedEffect(state.host) { model.editor.close() }
    LaunchedEffect(editorState.ready) { if (editorState.ready) { model.setup.sawHome(state.host); model.editor.connectedApplyPending() } }
    LaunchedEffect(layoutChange) { if (layoutChange.count > 0) model.editor.layoutChanged(layoutChange) }
    LaunchedEffect(state.foreground) { state.foreground?.let { model.setup.sawForeground(state.host, it) } }
    LaunchedEffect(state.pairings) { if (state.pairings > 0) model.setup.offerAfterPairing(state.host, state.foreground.orEmpty()) }

    CompositionLocalProvider(LocalHapticsOn provides prefs.haptics) {
        Scaffold(
            bottomBar = {
                NavigationBar(containerColor = Quiet.panel) {
                    Tab.entries.forEachIndexed { i, t ->
                        NavigationBarItem(
                            selected = tab == i,
                            onClick = {
                                // Tapping the current tab again goes back to its first screen.
                                if (tab == i) when (t) { Tab.TV -> tvStack.clear(); Tab.ACTIONS -> actionsStack.clear(); Tab.SETTINGS -> settingsStack.clear(); else -> Unit }
                                tab = i
                            },
                            icon = { Icon(t.icon, contentDescription = null) },
                            label = { Text(stringResource(t.label)) },
                            colors = NavigationBarItemDefaults.colors(indicatorColor = Quiet.panelHigh),
                        )
                    }
                }
            },
        ) { padding ->
            Box(Modifier.fillMaxSize().padding(padding)) {
                when (Tab.entries[tab]) {
                    Tab.REMOTE -> if (state.paired) RemoteScreen(state, model) else ConnectScreen(model)
                    Tab.TV -> when (val r = tvStack.lastOrNull()) {
                        null -> TVTab(model, { tvStack.add(it) })
                        TVRoute.Wallpaper -> WallpaperScreen(model) { tvStack.removeLastOrNull() }
                        TVRoute.Look -> LookScreen(model) { tvStack.removeLastOrNull() }
                        TVRoute.Apps -> HomeAppsScreen(model) { tvStack.removeLastOrNull() }
                        TVRoute.Profiles -> ProfilesScreen(model.settings) { tvStack.removeLastOrNull() }
                        else -> SetupRoute(r, model, { tvStack.add(it) }) { tvStack.removeLastOrNull() }
                    }
                    Tab.ACTIONS -> when (actionsStack.lastOrNull()) {
                        null -> ActionsScreen(model) { actionsStack.add(it) }
                        ActionsRoute.Widgets -> WidgetsScreen { actionsStack.removeLastOrNull() }
                        ActionsRoute.SleepTimer -> SleepTimerScreen(model) { actionsStack.removeLastOrNull() }
                    }
                    Tab.SETTINGS -> when (settingsStack.lastOrNull()) {
                        null -> SettingsScreen(state, model) { settingsStack.add(it) }
                        SettingsRoute.Connection -> ConnectionScreen(model) { settingsStack.removeLastOrNull() }
                        SettingsRoute.Shortcuts -> ShortcutsScreen(model.settings) { settingsStack.removeLastOrNull() }
                        SettingsRoute.Inputs -> InputsScreen(model) { settingsStack.removeLastOrNull() }
                        SettingsRoute.Backups -> BackupsScreen(model.settings) { settingsStack.removeLastOrNull() }
                        SettingsRoute.Credits -> CreditsScreen { settingsStack.removeLastOrNull() }
                        SettingsRoute.Setup -> SetupRoute(TVRoute.Setup, model, { tvStack.add(it); tab = Tab.TV.ordinal }) { settingsStack.removeLastOrNull() }
                        SettingsRoute.Undo -> SetupRoute(TVRoute.Undo, model, { tvStack.add(it); tab = Tab.TV.ordinal }) { settingsStack.removeLastOrNull() }
                    }
                }
            }
        }
        if (state.pairing != null) PairingSheet(state, model)
        SetupOffer(model) { tvStack.clear(); tvStack.add(TVRoute.Setup); tab = Tab.TV.ordinal }
        if (notice.isNotEmpty()) AlertDialog(
            onDismissRequest = { model.settings.notice.value = "" },
            title = { Text(stringResource(R.string.app_name)) }, text = { Text(notice) },
            confirmButton = { TextButton(onClick = { model.settings.notice.value = "" }) { Text(stringResource(R.string.ok)) } },
        )
    }
}
