package com.antitok.app

import android.content.Context
import java.util.Calendar

enum class ReminderMode {
    SCHEDULE,
    ONCE,
    DISABLED,
}

enum class TimeoutAction {
    PROMPT,
    CLOSE,
}

object AntiTokSettings {
    private const val PREFS = "antitok_settings"
    private const val KEY_MODE = "mode"
    private const val KEY_INTERVALS = "intervals"
    private const val KEY_TIMEOUT_ACTION = "timeout_action"
    private const val KEY_WINDOWS = "windows"
    private const val DEFAULT_INTERVALS = "5,10,15"

    fun getMode(context: Context): ReminderMode {
        val value = prefs(context).getString(KEY_MODE, "schedule")
        return when (value) {
            "once" -> ReminderMode.ONCE
            "disabled" -> ReminderMode.DISABLED
            else -> ReminderMode.SCHEDULE
        }
    }

    fun getIntervals(context: Context): List<Long> {
        val raw = prefs(context).getString(KEY_INTERVALS, DEFAULT_INTERVALS) ?: DEFAULT_INTERVALS
        val values = raw.split(",").mapNotNull { it.trim().toLongOrNull() }.filter { it > 0L }
        return values.ifEmpty { listOf(5L, 10L, 15L) }
    }

    fun getTimeoutAction(context: Context): TimeoutAction {
        val value = prefs(context).getString(KEY_TIMEOUT_ACTION, "prompt")
        return if (value == "close") TimeoutAction.CLOSE else TimeoutAction.PROMPT
    }

    fun getWindowsRaw(context: Context): String {
        return prefs(context).getString(KEY_WINDOWS, "") ?: ""
    }

    fun isWithinActiveWindow(context: Context): Boolean {
        val windows = getWindowsRaw(context).split(";").mapNotNull { TimeWindow.parse(it) }
        if (windows.isEmpty()) return true

        val calendar = Calendar.getInstance()
        val dayBit = when (calendar.get(Calendar.DAY_OF_WEEK)) {
            Calendar.MONDAY -> 1
            Calendar.TUESDAY -> 2
            Calendar.WEDNESDAY -> 4
            Calendar.THURSDAY -> 8
            Calendar.FRIDAY -> 16
            Calendar.SATURDAY -> 32
            else -> 64
        }
        val previousDayBit = if (dayBit == 1) 64 else dayBit shr 1
        val minute = calendar.get(Calendar.HOUR_OF_DAY) * 60 + calendar.get(Calendar.MINUTE)
        return windows.any { it.contains(dayBit, previousDayBit, minute) }
    }

    fun asMap(context: Context): Map<String, Any> {
        val mode = when (getMode(context)) {
            ReminderMode.ONCE -> "once"
            ReminderMode.DISABLED -> "disabled"
            ReminderMode.SCHEDULE -> "schedule"
        }
        val action = if (getTimeoutAction(context) == TimeoutAction.CLOSE) "close" else "prompt"
        return mapOf(
            "mode" to mode,
            "intervals" to getIntervals(context).joinToString(","),
            "timeoutAction" to action,
            "windows" to getWindowsRaw(context),
        )
    }

    fun save(context: Context, mode: String, intervals: String, timeoutAction: String, windows: String) {
        val normalizedMode = when (mode) {
            "once" -> "once"
            "disabled" -> "disabled"
            else -> "schedule"
        }
        val normalizedAction = if (timeoutAction == "close") "close" else "prompt"
        val normalizedIntervals = intervals.split(",")
            .mapNotNull { it.trim().toLongOrNull() }
            .filter { it > 0L }
            .ifEmpty { listOf(5L, 10L, 15L) }
            .joinToString(",")

        prefs(context).edit()
            .putString(KEY_MODE, normalizedMode)
            .putString(KEY_INTERVALS, normalizedIntervals)
            .putString(KEY_TIMEOUT_ACTION, normalizedAction)
            .putString(KEY_WINDOWS, normalizeWindows(windows))
            .apply()
    }

    private fun normalizeWindows(raw: String): String {
        return raw.split(";").mapNotNull { TimeWindow.parse(it) }.joinToString(";") {
            "${it.start}-${it.end}-${it.daysMask}"
        }
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private data class TimeWindow(val start: Int, val end: Int, val daysMask: Int) {
        fun contains(dayBit: Int, previousDayBit: Int, minute: Int): Boolean {
            return if (start < end) {
                daysMask and dayBit != 0 && minute in start until end
            } else {
                (daysMask and dayBit != 0 && minute >= start) ||
                    (daysMask and previousDayBit != 0 && minute < end)
            }
        }

        companion object {
            fun parse(raw: String): TimeWindow? {
                val parts = raw.split("-")
                if (parts.size != 3) return null
                val start = parts[0].toIntOrNull() ?: return null
                val end = parts[1].toIntOrNull() ?: return null
                val days = parts[2].toIntOrNull() ?: return null
                if (
                    start !in 0..1439 ||
                    end !in 0..1439 ||
                    start == end ||
                    (days and 127) == 0
                ) {
                    return null
                }
                return TimeWindow(start, end, days and 127)
            }
        }
    }
}
