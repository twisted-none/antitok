package com.antitok.app

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import java.util.Calendar

enum class ReminderMode { SCHEDULE, ONCE, DISABLED }

data class LockState(
    val wallEndMs: Long,
    val remainingMs: Long,
    val durationMinutes: Int,
    val generation: Long,
)

object AntiTokSettings {
    private const val PREFS = "antitok_settings"
    private const val KEY_MODE = "mode"
    private const val KEY_LAST_MODE = "last_enabled_mode"
    private const val KEY_INTERVALS = "intervals"
    private const val KEY_WINDOWS = "windows"
    private const val KEY_AUTO_LOCK = "auto_lock_after_forced_exit"
    private const val KEY_TIMEOUT_ACTION = "timeout_action"
    private const val KEY_LOCK_DURATION = "lock_duration"
    private const val KEY_LOCK_WALL_END = "lock_wall_end"
    private const val KEY_LOCK_ELAPSED_END = "lock_elapsed_end"
    private const val KEY_LOCK_BOOT_COUNT = "lock_boot_count"
    private const val KEY_LOCK_BOOT_BASE = "lock_boot_base"
    private const val KEY_GENERATION = "generation"
    private const val DEFAULT_INTERVALS = "5,10,15"

    fun getMode(context: Context): ReminderMode = when (modeName(context)) {
        "once" -> ReminderMode.ONCE
        "disabled" -> ReminderMode.DISABLED
        else -> ReminderMode.SCHEDULE
    }

    fun getIntervals(context: Context): List<Long> {
        val raw = prefs(context).getString(KEY_INTERVALS, DEFAULT_INTERVALS) ?: DEFAULT_INTERVALS
        return raw.split(",").mapNotNull { it.trim().toLongOrNull() }
            .filter { it > 0L }.ifEmpty { listOf(5L, 10L, 15L) }
    }

    fun getGeneration(context: Context): Long = prefs(context).getLong(KEY_GENERATION, 0L)

    fun getWindowsRaw(context: Context): String =
        prefs(context).getString(KEY_WINDOWS, "") ?: ""

    fun getLockDuration(context: Context): Int =
        prefs(context).getInt(KEY_LOCK_DURATION, 5).coerceIn(1, 180)

    fun isAutoLockEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_AUTO_LOCK, false)

    fun shouldCloseOnTimeout(context: Context): Boolean =
        prefs(context).getString(KEY_TIMEOUT_ACTION, "prompt") == "close"

    fun isWithinActiveWindow(context: Context, calendar: Calendar = Calendar.getInstance()): Boolean {
        val windows = getWindowsRaw(context).split(";").mapNotNull(TimeWindow::parse)
        if (windows.isEmpty()) return true
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

    fun getLock(context: Context): LockState? {
        if (getMode(context) == ReminderMode.DISABLED) return null
        val storage = prefs(context)
        val wallEnd = storage.getLong(KEY_LOCK_WALL_END, 0L)
        if (wallEnd <= 0L) return null
        val savedBootCount = storage.getInt(KEY_LOCK_BOOT_COUNT, -1)
        val currentBootCount = bootCount(context)
        val savedBootBase = storage.getLong(KEY_LOCK_BOOT_BASE, Long.MIN_VALUE)
        val currentBootBase = System.currentTimeMillis() - SystemClock.elapsedRealtime()
        val sameBoot = if (savedBootCount >= 0 && currentBootCount >= 0) {
            savedBootCount == currentBootCount
        } else {
            kotlin.math.abs(savedBootBase - currentBootBase) < 5 * 60_000L
        }
        val remaining = if (sameBoot) {
            storage.getLong(KEY_LOCK_ELAPSED_END, 0L) - SystemClock.elapsedRealtime()
        } else {
            wallEnd - System.currentTimeMillis()
        }
        if (remaining <= 0L) return null
        return LockState(
            wallEnd,
            remaining,
            storage.getInt(KEY_LOCK_DURATION, 5),
            storage.getLong(KEY_GENERATION, 0L),
        )
    }

    fun asMap(context: Context): Map<String, Any> {
        val lock = getLock(context)
        return mapOf(
            "mode" to modeName(context),
            "intervals" to getIntervals(context).joinToString(","),
            "windows" to getWindowsRaw(context),
            "lockDuration" to getLockDuration(context),
            "autoLockAfterForcedExit" to isAutoLockEnabled(context),
            "timeoutAction" to if (shouldCloseOnTimeout(context)) "close" else "prompt",
            "lockActive" to (lock != null),
            "lockEndMs" to (lock?.wallEndMs ?: 0L),
            "lockRemainingMs" to (lock?.remainingMs ?: 0L),
        )
    }

    @Synchronized
    fun save(
        context: Context,
        mode: String,
        intervals: String,
        windows: String = getWindowsRaw(context),
        lockDuration: Int = getLockDuration(context),
        autoLockAfterForcedExit: Boolean = isAutoLockEnabled(context),
        timeoutAction: String = if (shouldCloseOnTimeout(context)) "close" else "prompt",
    ): Boolean {
        val normalizedMode = normalizeMode(mode)
        val normalizedIntervals = normalizeIntervals(intervals)
        val editor = prefs(context).edit()
            .putString(KEY_MODE, normalizedMode)
            .putString(KEY_INTERVALS, normalizedIntervals)
            .putString(KEY_WINDOWS, normalizeWindows(windows))
            .putInt(KEY_LOCK_DURATION, lockDuration.coerceIn(1, 180))
            .putBoolean(KEY_AUTO_LOCK, autoLockAfterForcedExit)
            .putString(KEY_TIMEOUT_ACTION, if (timeoutAction == "close") "close" else "prompt")
        if (normalizedMode == "disabled") {
            clearLock(editor)
            editor.putLong(KEY_GENERATION, getGeneration(context) + 1L)
        } else {
            editor.putString(KEY_LAST_MODE, normalizedMode)
        }
        val saved = editor.commit()
        if (saved) StateCoordinator.changed(context)
        return saved
    }

    @Synchronized
    fun toggleProtection(context: Context): Boolean {
        val current = modeName(context)
        val next = if (current == "disabled") {
            prefs(context).getString(KEY_LAST_MODE, "schedule")
                ?.takeIf { it == "schedule" || it == "once" } ?: "schedule"
        } else {
            "disabled"
        }
        return save(context, next, getIntervals(context).joinToString(","))
    }

    @Synchronized
    fun startLock(context: Context, minutes: Int): LockState {
        require(minutes in 1..180)
        val storage = prefs(context)
        val mode = modeName(context)
        val enabledMode = if (mode == "disabled") {
            storage.getString(KEY_LAST_MODE, "schedule")
                ?.takeIf { it == "schedule" || it == "once" } ?: "schedule"
        } else {
            mode
        }
        val nowWall = System.currentTimeMillis()
        val nowElapsed = SystemClock.elapsedRealtime()
        val generation = storage.getLong(KEY_GENERATION, 0L) + 1L
        storage.edit()
            .putString(KEY_MODE, enabledMode)
            .putString(KEY_LAST_MODE, enabledMode)
            .putInt(KEY_LOCK_DURATION, minutes)
            .putLong(KEY_LOCK_WALL_END, nowWall + minutes * 60_000L)
            .putLong(KEY_LOCK_ELAPSED_END, nowElapsed + minutes * 60_000L)
            .putInt(KEY_LOCK_BOOT_COUNT, bootCount(context))
            .putLong(KEY_LOCK_BOOT_BASE, nowWall - nowElapsed)
            .putLong(KEY_GENERATION, generation)
            .commit()
            .also { check(it) { "Не удалось сохранить блокировку" } }
        StateCoordinator.changed(context)
        return requireNotNull(getLock(context))
    }

    fun startConfiguredLock(context: Context): LockState =
        startLock(context, getLockDuration(context))

    private fun modeName(context: Context): String =
        normalizeMode(prefs(context).getString(KEY_MODE, "schedule") ?: "schedule")

    private fun normalizeMode(mode: String): String =
        if (mode == "once" || mode == "disabled") mode else "schedule"

    private fun normalizeIntervals(intervals: String): String =
        intervals.split(",").mapNotNull { it.trim().toLongOrNull() }
            .filter { it > 0L }.ifEmpty { listOf(5L, 10L, 15L) }.joinToString(",")

    private fun normalizeWindows(raw: String): String =
        raw.split(";").mapNotNull(TimeWindow::parse).joinToString(";") {
            "${it.start}-${it.end}-${it.daysMask}"
        }

    private fun clearLock(editor: android.content.SharedPreferences.Editor) {
        editor.remove(KEY_LOCK_WALL_END)
            .remove(KEY_LOCK_ELAPSED_END)
            .remove(KEY_LOCK_BOOT_COUNT)
            .remove(KEY_LOCK_BOOT_BASE)
    }

    private fun bootCount(context: Context): Int =
        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private data class TimeWindow(val start: Int, val end: Int, val daysMask: Int) {
        fun contains(dayBit: Int, previousDayBit: Int, minute: Int): Boolean =
            if (start < end) {
                daysMask and dayBit != 0 && minute in start until end
            } else {
                (daysMask and dayBit != 0 && minute >= start) ||
                    (daysMask and previousDayBit != 0 && minute < end)
            }

        companion object {
            fun parse(raw: String): TimeWindow? {
                val parts = raw.split("-")
                if (parts.size != 3) return null
                val start = parts[0].toIntOrNull() ?: return null
                val end = parts[1].toIntOrNull() ?: return null
                val days = parts[2].toIntOrNull() ?: return null
                if (start !in 0..1439 || end !in 0..1439 || start == end) return null
                if (days and 127 == 0) return null
                return TimeWindow(start, end, days and 127)
            }
        }
    }
}
