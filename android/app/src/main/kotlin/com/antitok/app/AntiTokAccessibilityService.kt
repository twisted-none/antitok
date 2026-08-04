package com.antitok.app

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent

class AntiTokAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private val foregroundWatchdogRunnable = object : Runnable {
        override fun run() {
            checkForegroundPackage()
            handler.postDelayed(this, FOREGROUND_CHECK_MS)
        }
    }
    private val reminderRunnable = Runnable {
        if (
            sessionActive &&
            !promptShowing &&
            !remindersFinished &&
            AntiTokSettings.getMode(this) != ReminderMode.DISABLED &&
            AntiTokSettings.isWithinActiveWindow(this)
        ) {
            if (rootInActiveWindow?.packageName?.toString() !in tikTokPackages) {
                timeoutPending = true
            } else {
                executeTimeoutAction()
            }
        }
    }
    private val connectedRecheckRunnable = object : Runnable {
        override fun run() {
            val packageName = rootInActiveWindow?.packageName?.toString()
            if (packageName != null) {
                if (packageName in tikTokPackages) onAccessibilityEvent(null)
                return
            }
            if (connectedRecheckAttempts++ < MAX_CONNECTED_RECHECKS) {
                handler.postDelayed(this, FOREGROUND_CHECK_MS)
            }
        }
    }
    private var sessionActive = false
    private var promptShowing = false
    private var reminderIndex = 0
    private var remindersFinished = false
    private var ignoreOwnPackageUntil = 0L
    private var missingForegroundChecks = 0
    private var pendingPrompt = PromptType.ENTRY
    private var promptToken = SystemClock.elapsedRealtimeNanos()
    private var connectedRecheckAttempts = 0
    private var timeoutPending = false
    private var lastTikTokSeenAt = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        activeService = this
        startForegroundWatchdog()
        recheckForeground()
    }

    override fun onDestroy() {
        if (activeService === this) activeService = null
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        if (activeService === this) activeService = null
        handler.removeCallbacksAndMessages(null)
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val packageName = event?.packageName?.toString()
            ?: rootInActiveWindow?.packageName?.toString()
            ?: return
        if (packageName in tikTokPackages) {
            markTikTokSeen()
            if (AntiTokSettings.getLock(this) != null) {
                endTikTokSession()
                showBlocker()
                return
            }
            if (promptShowing) return
            if (AntiTokSettings.getMode(this) == ReminderMode.DISABLED) {
                endTikTokSession()
                return
            }
            if (!AntiTokSettings.isWithinActiveWindow(this)) {
                endTikTokSession()
                return
            }
            if (!sessionActive) startTikTokSession()
            if (timeoutPending && sessionActive && !promptShowing) {
                executeTimeoutAction()
            }
            return
        }

        if (promptShowing) return
        if (sessionActive) {
            handleNonTikTokPackage(packageName)
        }
    }

    override fun onInterrupt() = Unit

    private fun startTikTokSession() {
        if (
            AntiTokSettings.getMode(this) == ReminderMode.DISABLED ||
            !AntiTokSettings.isWithinActiveWindow(this)
        ) return
        sessionActive = true
        reminderIndex = 0
        remindersFinished = false
        timeoutPending = false
        ignoreOwnPackageUntil = 0L
        missingForegroundChecks = 0
        lastTikTokSeenAt = SystemClock.uptimeMillis()
        startForegroundWatchdog()
        showPrompt(PromptType.ENTRY)
    }

    private fun endTikTokSession() {
        sessionActive = false
        promptShowing = false
        reminderIndex = 0
        remindersFinished = false
        timeoutPending = false
        ignoreOwnPackageUntil = 0L
        missingForegroundChecks = 0
        lastTikTokSeenAt = 0L
        handler.removeCallbacks(reminderRunnable)
    }

    private fun startForegroundWatchdog() {
        handler.removeCallbacks(foregroundWatchdogRunnable)
        handler.postDelayed(foregroundWatchdogRunnable, FOREGROUND_CHECK_MS)
    }

    private fun checkForegroundPackage() {
        if (promptShowing) return

        val packageName = rootInActiveWindow?.packageName?.toString()
        if (packageName == null) {
            if (!sessionActive) return
            if (isTikTokSessionRecentlyVisible()) {
                missingForegroundChecks = 0
                return
            }
            missingForegroundChecks += 1
            if (missingForegroundChecks >= MAX_MISSING_FOREGROUND_CHECKS) {
                endTikTokSession()
            }
            return
        }

        missingForegroundChecks = 0
        if (packageName in tikTokPackages) markTikTokSeen()
        if (packageName in tikTokPackages && !sessionActive) {
            if (
                AntiTokSettings.getLock(this) != null ||
                AntiTokSettings.getMode(this) != ReminderMode.DISABLED &&
                AntiTokSettings.isWithinActiveWindow(this)
            ) {
                onAccessibilityEvent(null)
            }
            return
        }
        if (!sessionActive) return
        if (!AntiTokSettings.isWithinActiveWindow(this)) {
            endTikTokSession()
            return
        }
        if (packageName in tikTokPackages) {
            if (timeoutPending) executeTimeoutAction()
            return
        }
        handleNonTikTokPackage(packageName)
    }

    private fun handleNonTikTokPackage(packageName: String) {
        if (packageName == ownPackageName() && SystemClock.uptimeMillis() <= ignoreOwnPackageUntil) {
            return
        }
        if (packageName in transientPackages) return
        if (isTikTokSessionRecentlyVisible()) return
        endTikTokSession()
    }

    private fun markTikTokSeen() {
        lastTikTokSeenAt = SystemClock.uptimeMillis()
    }

    private fun isTikTokSessionRecentlyVisible(): Boolean {
        if (lastTikTokSeenAt == 0L) return false
        return SystemClock.uptimeMillis() - lastTikTokSeenAt <= TIKTOK_FOREGROUND_GRACE_MS
    }

    private fun onPromptResult(token: Long, continueWatching: Boolean) {
        if (token != promptToken || AntiTokSettings.getLock(this) != null) return
        val prompt = pendingPrompt
        if (!promptShowing) return
        promptShowing = false
        if (!sessionActive) return

        if (!continueWatching) {
            forceExitTikTok(requireTikTokForeground = false)
            return
        }

        ignoreOwnPackageUntil = SystemClock.uptimeMillis() + OWN_PACKAGE_GRACE_MS
        val mode = AntiTokSettings.getMode(this)
        if (mode == ReminderMode.DISABLED || !AntiTokSettings.isWithinActiveWindow(this)) {
            endTikTokSession()
            return
        }
        if (prompt != PromptType.ENTRY && mode == ReminderMode.ONCE) {
            remindersFinished = true
            handler.removeCallbacks(reminderRunnable)
            return
        }
        if (prompt == PromptType.ENTRY || mode == ReminderMode.SCHEDULE) {
            scheduleNextReminder()
        }
    }

    private fun scheduleNextReminder() {
        handler.removeCallbacks(reminderRunnable)
        if (remindersFinished) return
        val intervals = AntiTokSettings.getIntervals(this)
        val mode = AntiTokSettings.getMode(this)
        if (
            mode == ReminderMode.DISABLED ||
            !AntiTokSettings.isWithinActiveWindow(this) ||
            reminderIndex >= intervals.size ||
            mode == ReminderMode.ONCE && reminderIndex > 0
        ) {
            remindersFinished = true
            return
        }

        val delayMillis = intervals[reminderIndex] * 60_000L
        handler.postDelayed(reminderRunnable, delayMillis)
    }

    private fun executeTimeoutAction() {
        timeoutPending = false
        if (rootInActiveWindow?.packageName?.toString() !in tikTokPackages) {
            timeoutPending = true
            return
        }
        if (AntiTokSettings.shouldCloseOnTimeout(this)) {
            forceExitTikTok(requireTikTokForeground = true)
        } else {
            showPrompt(PromptType.REMINDER)
        }
    }

    private fun showPrompt(type: PromptType) {
        val elapsedMinutes = if (type == PromptType.REMINDER) {
            AntiTokSettings.getIntervals(this).take(reminderIndex + 1).sum()
        } else {
            0L
        }
        pendingPrompt = type
        promptShowing = true
        promptToken += 1L
        if (type == PromptType.REMINDER) reminderIndex += 1

        val intent = Intent(this, PromptActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(PromptActivity.EXTRA_PROMPT_TYPE, type.name)
            .putExtra(PromptActivity.EXTRA_ELAPSED_MINUTES, elapsedMinutes)
            .putExtra(PromptActivity.EXTRA_PROMPT_TOKEN, promptToken)
        startActivity(intent)
    }

    private fun forceExitTikTok(requireTikTokForeground: Boolean) {
        if (!sessionActive || AntiTokSettings.getMode(this) == ReminderMode.DISABLED) {
            endTikTokSession()
            return
        }
        val packageName = rootInActiveWindow?.packageName?.toString()
        if (requireTikTokForeground && packageName !in tikTokPackages) {
            timeoutPending = true
            return
        }
        val startAutoLock = AntiTokSettings.isAutoLockEnabled(this)
        performGlobalAction(GLOBAL_ACTION_HOME)
        endTikTokSession()
        if (startAutoLock) {
            runCatching { AntiTokSettings.startConfiguredLock(this) }
        }
    }

    private fun showBlocker() {
        startActivity(
            Intent(this, BlockerActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(BlockerActivity.EXTRA_GENERATION, AntiTokSettings.getGeneration(this)),
        )
    }

    private fun recheckForeground() {
        connectedRecheckAttempts = 0
        handler.removeCallbacks(connectedRecheckRunnable)
        handler.post(connectedRecheckRunnable)
    }

    private fun onSettingsChanged() {
        promptToken += 1L
        endTikTokSession()
        startForegroundWatchdog()
        recheckForeground()
    }

    private fun ownPackageName(): String = applicationContext.packageName

    private enum class PromptType { ENTRY, REMINDER }

    companion object {
        private val tikTokPackages = setOf(
            "com.zhiliaoapp.musically",
            "com.ss.android.ugc.trill",
            "com.zhiliaoapp.musically.go",
        )
        private val transientPackages = setOf(
            "android",
            "com.android.systemui",
            "com.miui.systemui",
        )
        private const val OWN_PACKAGE_GRACE_MS = 2_500L
        private const val TIKTOK_FOREGROUND_GRACE_MS = 5_000L
        private const val FOREGROUND_CHECK_MS = 1_000L
        private const val MAX_MISSING_FOREGROUND_CHECKS = 3
        private const val MAX_CONNECTED_RECHECKS = 5

        @Volatile
        private var activeService: AntiTokAccessibilityService? = null

        fun handlePromptResult(token: Long, continueWatching: Boolean) {
            activeService?.onPromptResult(token, continueWatching)
        }

        fun isConnected(): Boolean = activeService != null

        fun handleSettingsChanged() {
            activeService?.onSettingsChanged()
        }

        fun leaveToHome() {
            activeService?.performGlobalAction(GLOBAL_ACTION_HOME)
        }
    }
}
