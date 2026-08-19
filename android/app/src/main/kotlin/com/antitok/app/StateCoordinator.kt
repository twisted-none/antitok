package com.antitok.app

import android.content.Context

object StateCoordinator {
    fun changed(context: Context) {
        AntiTokWidgetProvider.updateAll(context.applicationContext)
        AntiTokAccessibilityService.handleSettingsChanged()
    }
}
