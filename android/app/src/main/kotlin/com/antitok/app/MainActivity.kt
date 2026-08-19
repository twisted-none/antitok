package com.antitok.app

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "antitok/settings")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSettings" -> result.success(
                        AntiTokSettings.asMap(this) + mapOf(
                            "serviceConnected" to AntiTokAccessibilityService.isConnected(),
                        ),
                    )
                    "saveSettings" -> {
                        val mode = call.argument<String>("mode") ?: "schedule"
                        val intervals = call.argument<String>("intervals") ?: "5,10,15"
                        val current = AntiTokSettings.asMap(this)
                        val windows = call.argument<String>("windows")
                            ?: current["windows"] as String
                        val lockDuration = call.argument<Int>("lockDuration")
                            ?: current["lockDuration"] as Int
                        val autoLock = call.argument<Boolean>("autoLockAfterForcedExit")
                            ?: current["autoLockAfterForcedExit"] as Boolean
                        val timeoutAction = call.argument<String>("timeoutAction")
                            ?: current["timeoutAction"] as String
                        if (AntiTokSettings.save(
                                this,
                                mode,
                                intervals,
                                windows,
                                lockDuration,
                                autoLock,
                                timeoutAction,
                            )
                        ) {
                            result.success(null)
                        } else {
                            result.error("storage_error", "Не удалось сохранить настройки", null)
                        }
                    }
                    "isServiceEnabled" -> result.success(isAccessibilityServiceEnabled())
                    "isServiceConnected" ->
                        result.success(AntiTokAccessibilityService.isConnected())
                    "startLock" -> {
                        if (!AntiTokAccessibilityService.isConnected()) {
                            result.error(
                                "service_disconnected",
                                "Сервис специальных возможностей не подключен",
                                null,
                            )
                        } else {
                            val minutes = call.argument<Int>("minutes") ?: 5
                            if (minutes !in 1..180) {
                                result.error("invalid_duration", "Допустимо от 1 до 180 минут", null)
                            } else {
                                runCatching { AntiTokSettings.startLock(this, minutes) }
                                    .onSuccess {
                                        result.success(
                                        mapOf(
                                            "lockEndMs" to it.wallEndMs,
                                            "lockRemainingMs" to it.remainingMs,
                                        ),
                                    )
                                }.onFailure {
                                    result.error("storage_error", it.message, null)
                                }
                            }
                        }
                    }
                    "requestPinWidget" -> result.success(requestPinWidget())
                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(null)
                    }
                    "openAppSettings" -> {
                        val intent = Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName"),
                        )
                        startActivity(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestPinWidget(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = getSystemService(AppWidgetManager::class.java)
        if (!manager.isRequestPinAppWidgetSupported) return false
        return manager.requestPinAppWidget(
            ComponentName(this, AntiTokWidgetProvider::class.java),
            null,
            null,
        )
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val expected = ComponentName(this, AntiTokAccessibilityService::class.java).flattenToString()
        val enabled = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        )
        return enabled?.split(':').orEmpty().any {
            it.equals(expected, ignoreCase = true)
        }
    }
}
