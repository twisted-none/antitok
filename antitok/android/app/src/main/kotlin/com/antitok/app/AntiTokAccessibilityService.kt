package com.antitok.app

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityWindowInfo
import android.view.inputmethod.InputMethodManager

class AntiTokAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private val inputMethodManager by lazy {
        getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
    }
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
            if (isInputMethodVisible()) {
                deferTimeoutAction()
            } else {
                executeTimeoutAction()
            }
        }
    }
    private val delayedTimeoutRunnable = Runnable {
        delayedTimeoutScheduled = false
        if (
            pendingTimeoutAction &&
            sessionActive &&
            !promptShowing &&
            !isInputMethodVisible() &&
            rootInActiveWindow?.packageName?.toString() in tikTokPackages &&
            AntiTokSettings.getMode(this) != ReminderMode.DISABLED &&
            AntiTokSettings.isWithinActiveWindow(this)
        ) {
            executeTimeoutAction()
        }
    }
    private var sessionActive = false
    private var promptShowing = false
    private var reminderIndex = 0
    private var remindersFinished = false
    private var pendingTimeoutAction = false
    private var delayedTimeoutScheduled = false
    private var ignoreOwnPackageUntil = 0L
    private var missingForegroundChecks = 0
    private var pendingPrompt = PromptType.ENTRY

    override fun onServiceConnected() {
        activeService = this
        startForegroundWatchdog()
    }

    override fun onDestroy() {
        if (activeService === this) activeService = null
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val packageName = event?.packageName?.toString()
            ?: rootInActiveWindow?.packageName?.toString()
            ?: return
        if (promptShowing) return

        if (packageName in tikTokPackages) {
            if (
                AntiTokSettings.getMode(this) == ReminderMode.DISABLED ||
                !AntiTokSettings.isWithinActiveWindow(this)
            ) {
                endTikTokSession()
                return
            }
            if (!sessionActive) startTikTokSession()
            refreshDeferredTimeout()
            return
        }

        if (sessionActive) {
            handleNonTikTokPackage(packageName)
        }
    }

    override fun onInterrupt() = Unit

    private fun startTikTokSession() {
        if (
            AntiTokSettings.getMode(this) == ReminderMode.DISABLED ||
            !AntiTokSettings.isWithinActiveWindow(this)
        ) {
            return
        }
        sessionActive = true
        reminderIndex = 0
        remindersFinished = false
        pendingTimeoutAction = false
        cancelDelayedTimeout()
        ignoreOwnPackageUntil = 0L
        missingForegroundChecks = 0
        showPrompt(PromptType.ENTRY)
    }

    private fun endTikTokSession() {
        sessionActive = false
        promptShowing = false
        reminderIndex = 0
        remindersFinished = false
        pendingTimeoutAction = false
        cancelDelayedTimeout()
        ignoreOwnPackageUntil = 0L
        missingForegroundChecks = 0
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
            if (isInputMethodVisible()) {
                missingForegroundChecks = 0
                cancelDelayedTimeout()
                return
            }
            missingForegroundChecks += 1
            if (missingForegroundChecks >= MAX_MISSING_FOREGROUND_CHECKS) {
                endTikTokSession()
            }
            return
        }

        missingForegroundChecks = 0
        if (packageName in tikTokPackages && !sessionActive) {
            startTikTokSession()
            return
        }
        if (!sessionActive) return
        if (!AntiTokSettings.isWithinActiveWindow(this)) {
            endTikTokSession()
            return
        }
        if (packageName in tikTokPackages) {
            refreshDeferredTimeout()
            return
        }
        handleNonTikTokPackage(packageName)
    }

    private fun handleNonTikTokPackage(packageName: String) {
        if (packageName == ownPackageName() && SystemClock.uptimeMillis() <= ignoreOwnPackageUntil) {
            return
        }
        if (isInputMethodPackage(packageName)) {
            cancelDelayedTimeout()
            return
        }
        if (packageName in transientPackages) return
        endTikTokSession()
    }

    private fun isInputMethodVisible(): Boolean =
        windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }

    private fun isInputMethodPackage(packageName: String): Boolean {
        if (!isInputMethodVisible()) return false
        val windowPackages = windows
            .filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .mapNotNull { it.root?.packageName?.toString() }
        return packageName in windowPackages ||
            inputMethodManager.enabledInputMethodList.any { it.packageName == packageName }
    }

    private fun deferTimeoutAction() {
        pendingTimeoutAction = true
        cancelDelayedTimeout()
    }

    private fun refreshDeferredTimeout() {
        if (!pendingTimeoutAction) return
        if (isInputMethodVisible()) {
            cancelDelayedTimeout()
            return
        }
        if (delayedTimeoutScheduled) return
        delayedTimeoutScheduled = true
        handler.postDelayed(delayedTimeoutRunnable, KEYBOARD_DISMISS_GRACE_MS)
    }

    private fun cancelDelayedTimeout() {
        delayedTimeoutScheduled = false
        handler.removeCallbacks(delayedTimeoutRunnable)
    }

    private fun executeTimeoutAction() {
        pendingTimeoutAction = false
        cancelDelayedTimeout()
        if (AntiTokSettings.getTimeoutAction(this) == TimeoutAction.CLOSE) {
            performGlobalAction(GLOBAL_ACTION_HOME)
            endTikTokSession()
        } else {
            showPrompt(PromptType.REMINDER)
        }
    }

    private fun onPromptResult(continueWatching: Boolean) {
        val prompt = pendingPrompt
        if (!promptShowing) return
        promptShowing = false
        if (!sessionActive) return

        if (!continueWatching) {
            performGlobalAction(GLOBAL_ACTION_HOME)
            endTikTokSession()
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

    private fun showPrompt(type: PromptType) {
        val elapsedMinutes = if (type == PromptType.REMINDER) {
            AntiTokSettings.getIntervals(this).take(reminderIndex + 1).sum()
        } else {
            0L
        }
        pendingPrompt = type
        promptShowing = true
        if (type == PromptType.REMINDER) reminderIndex += 1

        val intent = Intent(this, PromptActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(PromptActivity.EXTRA_PROMPT_TYPE, type.name)
            .putExtra(PromptActivity.EXTRA_ELAPSED_MINUTES, elapsedMinutes)
        startActivity(intent)
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
        private const val FOREGROUND_CHECK_MS = 1_000L
        private const val KEYBOARD_DISMISS_GRACE_MS = 10_000L
        private const val MAX_MISSING_FOREGROUND_CHECKS = 3

        @Volatile
        private var activeService: AntiTokAccessibilityService? = null

        fun handlePromptResult(continueWatching: Boolean) {
            activeService?.onPromptResult(continueWatching)
        }
    }
}
