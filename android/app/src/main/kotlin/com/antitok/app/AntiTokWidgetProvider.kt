package com.antitok.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class AntiTokWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { manager.updateAppWidget(it, views(context)) }
    }

    companion object {
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, AntiTokWidgetProvider::class.java)
            manager.getAppWidgetIds(component).forEach {
                manager.updateAppWidget(it, views(context))
            }
        }

        private fun views(context: Context): RemoteViews {
            val enabled = AntiTokSettings.getMode(context) != ReminderMode.DISABLED
            val intent = Intent(context, WidgetToggleReceiver::class.java)
                .setAction("${context.packageName}.WIDGET_TOGGLE")
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return RemoteViews(context.packageName, R.layout.antitok_widget).apply {
                setInt(
                    R.id.widget_root,
                    "setBackgroundResource",
                    if (enabled) R.drawable.widget_background_on
                    else R.drawable.widget_background_off,
                )
                setImageViewResource(
                    R.id.widget_power,
                    if (enabled) R.drawable.ic_power_on else R.drawable.ic_power_off,
                )
                setContentDescription(
                    R.id.widget_power,
                    if (enabled) "Защита AntiTok включена" else "Защита AntiTok выключена",
                )
                setOnClickPendingIntent(R.id.widget_root, pendingIntent)
            }
        }
    }
}
