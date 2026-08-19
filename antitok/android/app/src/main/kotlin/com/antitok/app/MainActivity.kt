package com.antitok.app

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
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
                    "getSettings" -> result.success(AntiTokSettings.asMap(this))
                    "saveSettings" -> {
                        val mode = call.argument<String>("mode") ?: "schedule"
                        val intervals = call.argument<String>("intervals") ?: "5,10,15"
                        val timeoutAction = call.argument<String>("timeoutAction") ?: "prompt"
                        val windows = call.argument<String>("windows") ?: ""
                        AntiTokSettings.save(this, mode, intervals, timeoutAction, windows)
                        result.success(null)
                    }
                    "isServiceEnabled" -> result.success(isAccessibilityServiceEnabled())
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
