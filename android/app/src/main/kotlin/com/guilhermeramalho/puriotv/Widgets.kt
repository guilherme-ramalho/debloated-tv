package com.guilhermeramalho.puriotv

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.view.View
import android.widget.RemoteViews

/**
 * Home-screen widgets and the Quick Settings tile (the iPhone's widgets and Control Center button). They hold no
 * connection and never refresh on a timer: a tap opens [CommandActivity], which sends and closes.
 */
object Widgets {
    /** The quick actions changed: redraw the quick actions widget (only when one is on the home screen). */
    fun actionsChanged(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, ActionsWidget::class.java))
        if (ids.isNotEmpty()) ActionsWidget.draw(context, manager, ids)
    }
}

class RemoteWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = RemoteViews(context.packageName, R.layout.widget_remote)
        listOf(R.id.w_power to TVCommand.POWER, R.id.w_up to TVCommand.UP, R.id.w_home to TVCommand.HOME, R.id.w_left to TVCommand.LEFT,
            R.id.w_ok to TVCommand.SELECT, R.id.w_right to TVCommand.RIGHT, R.id.w_back to TVCommand.BACK, R.id.w_down to TVCommand.DOWN,
        ).forEach { (id, command) -> views.setOnClickPendingIntent(id, TVCommand.pending(context, TVCommand.intent(context, command))) }
        manager.updateAppWidget(ids, views)
    }
}

class ActionsWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = draw(context, manager, ids)

    companion object {
        private val slots = listOf(R.id.w_a0, R.id.w_a1, R.id.w_a2, R.id.w_a3)
        fun draw(context: Context, manager: AppWidgetManager, ids: IntArray) {
            val actions = context.purio.settings.current.actions.take(slots.size)
            val views = RemoteViews(context.packageName, R.layout.widget_actions)
            views.setViewVisibility(R.id.w_empty, if (actions.isEmpty()) View.VISIBLE else View.GONE)
            slots.forEachIndexed { i, slot ->
                val action = actions.getOrNull(i)
                views.setViewVisibility(slot, if (action == null) View.GONE else View.VISIBLE)
                if (action != null) {
                    views.setTextViewText(slot, action.name)
                    views.setOnClickPendingIntent(slot, TVCommand.pending(context, TVCommand.actionIntent(context, action.id)))
                }
            }
            if (actions.isEmpty()) views.setOnClickPendingIntent(R.id.w_empty, PendingIntent.getActivity(context, 0,
                context.packageManager.getLaunchIntentForPackage(context.packageName), PendingIntent.FLAG_IMMUTABLE))
            manager.updateAppWidget(ids, views)
        }
    }
}

/** TV power in Quick Settings: wakes a TV in standby, otherwise presses Power (TVQuickCommand.power). */
class PowerTileService : TileService() {
    override fun onStartListening() {
        qsTile?.apply { state = Tile.STATE_INACTIVE; updateTile() }
    }

    override fun onClick() {
        val intent = TVCommand.intent(this, TVCommand.POWER)
        if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(TVCommand.pending(this, intent))
        else @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated") startActivityAndCollapse(intent)
    }
}
