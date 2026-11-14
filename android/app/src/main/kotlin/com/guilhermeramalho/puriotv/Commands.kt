package com.guilhermeramalho.puriotv

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.guilhermeramalho.puriotv.core.ActionStep
import com.guilhermeramalho.puriotv.core.ClientInfo
import com.guilhermeramalho.puriotv.core.CommandRunner
import com.guilhermeramalho.puriotv.core.Problem
import com.guilhermeramalho.puriotv.core.RemoteFailure
import com.guilhermeramalho.puriotv.core.TVKey
import com.guilhermeramalho.puriotv.core.TVSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One-tap commands for widgets, the tile and app shortcuts (TVQuickCommand in TVIntents.swift). */
enum class TVCommand(val steps: List<ActionStep>, val quiet: Boolean = false) {
    WAKE(listOf(ActionStep.of(ActionStep.Kind.WAKE))),
    SLEEP(listOf(ActionStep.of(ActionStep.Kind.SLEEP))),
    HOME(listOf(ActionStep.of(ActionStep.Kind.HOME)), quiet = true),
    PAUSE(listOf(ActionStep.of(ActionStep.Kind.PAUSE))),
    MUTE(listOf(ActionStep.of(ActionStep.Kind.MUTE))),
    NETFLIX(listOf(ActionStep.of(ActionStep.Kind.WAKE), ActionStep.of(ActionStep.Kind.OPEN_APP, "com.netflix.ninja"))),
    YOUTUBE(listOf(ActionStep.of(ActionStep.Kind.WAKE), ActionStep.of(ActionStep.Kind.OPEN_APP, "com.google.android.youtube.tv"))),
    // Single keys, for the remote widget and the power tile: no "sent" message after each press.
    POWER(listOf(ActionStep.key(TVKey.POWER)), quiet = true),
    UP(listOf(ActionStep.key(TVKey.UP)), quiet = true),
    DOWN(listOf(ActionStep.key(TVKey.DOWN)), quiet = true),
    LEFT(listOf(ActionStep.key(TVKey.LEFT)), quiet = true),
    RIGHT(listOf(ActionStep.key(TVKey.RIGHT)), quiet = true),
    SELECT(listOf(ActionStep.key(TVKey.SELECT)), quiet = true),
    BACK(listOf(ActionStep.key(TVKey.BACK)), quiet = true);

    companion object {
        const val EXTRA_COMMAND = "command"
        const val EXTRA_ACTION = "action"

        fun intent(context: Context, command: TVCommand): Intent = Intent(context, CommandActivity::class.java)
            .setAction("com.guilhermeramalho.puriotv.COMMAND").setData(Uri.parse("purio://command/" + command.name))
            .putExtra(EXTRA_COMMAND, command.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        fun actionIntent(context: Context, id: String): Intent = Intent(context, CommandActivity::class.java)
            .setAction("com.guilhermeramalho.puriotv.ACTION").setData(Uri.parse("purio://action/$id"))
            .putExtra(EXTRA_ACTION, id).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        fun pending(context: Context, intent: Intent): PendingIntent =
            PendingIntent.getActivity(context, intent.data.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
}

/**
 * Runs one command or saved quick action and closes, with no screen of its own (the iPhone runs these in the
 * background). An activity rather than a broadcast: it may take a few seconds to reach a TV in standby, and the
 * system lets a visible activity use the network for as long as that takes. Nothing stays running afterwards.
 */
class CommandActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) { finish(); return }
        val app = purio
        val command = intent.getStringExtra(TVCommand.EXTRA_COMMAND)?.let { name -> TVCommand.entries.firstOrNull { it.name == name } }
        val actionId = intent.getStringExtra(TVCommand.EXTRA_ACTION)
        lifecycleScope.launch {
            val message = try {
                val tv = app.store.tv
                val pin = tv?.pin ?: throw RemoteFailure(Problem.NOT_PAIRED)
                val prefs = app.settings.current
                val (steps, name) = when {
                    command != null -> command.steps to null
                    actionId != null -> prefs.actions.firstOrNull { it.id == actionId }?.also { it.validate() }?.let { it.steps to it.name }
                        ?: throw UserMessage(getString(R.string.action_gone))
                    else -> throw RemoteFailure(Problem.INVALID_ACTION)
                }
                val identity = withContext(Dispatchers.IO) { KeystoreIdentity.loadOrCreate(app.store.clientName) }
                val info = ClientInfo(Build.MODEL ?: "Android", packageName, BuildInfo.versionName(application))
                CommandRunner({ TVSession(tv.host, identity, app.store.clientName, info, lifecycleScope) })
                    .run(steps, pin, prefs.apps, if (prefs.editorHost == tv.host) prefs.tvInputs else emptyList())
                when {
                    name != null -> getString(R.string.sent_named, name)
                    command?.quiet == true -> null
                    else -> getString(R.string.sent_to_tv)
                }
            } catch (e: Exception) { errorText(this@CommandActivity, e) }
            message?.let { Toast.makeText(applicationContext, it, Toast.LENGTH_SHORT).show() }
            finish()
        }
    }

    override fun finish() { super.finish(); if (Build.VERSION.SDK_INT >= 34) overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0) else @Suppress("DEPRECATION") overridePendingTransition(0, 0) }
}

/** The app icon's long-press menu (the iPhone's App Shortcuts): Wake, Turn off, Netflix, YouTube, Pause. */
object AppShortcuts {
    fun publish(context: Context) {
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return
        val list = listOf(
            Triple(TVCommand.WAKE, context.getString(R.string.key_wake), R.drawable.ic_w_power),
            Triple(TVCommand.SLEEP, context.getString(R.string.turn_off_tv), R.drawable.ic_w_moon),
            Triple(TVCommand.NETFLIX, context.getString(R.string.open_app, "Netflix"), R.drawable.ic_w_play),
            Triple(TVCommand.YOUTUBE, context.getString(R.string.open_app, "YouTube"), R.drawable.ic_w_play),
            Triple(TVCommand.PAUSE, context.getString(R.string.pause_tv), R.drawable.ic_w_pause),
        ).take(manager.maxShortcutCountPerActivity.coerceAtMost(5)).mapIndexed { i, (command, label, icon) ->
            ShortcutInfo.Builder(context, command.name.lowercase()).setShortLabel(label).setRank(i)
                .setIcon(Icon.createWithResource(context, icon)).setIntent(TVCommand.intent(context, command)).build()
        }
        runCatching { manager.dynamicShortcuts = list }
    }
}
