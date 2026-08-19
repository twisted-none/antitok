package com.antitok.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock

class WidgetToggleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "${context.packageName}.WIDGET_TOGGLE") return
        synchronized(lock) {
            val now = SystemClock.elapsedRealtime()
            if (now - lastToggleMs < 500L) return
            lastToggleMs = now
            AntiTokSettings.toggleProtection(context.applicationContext)
        }
    }

    companion object {
        private val lock = Any()
        private var lastToggleMs = 0L
    }
}
