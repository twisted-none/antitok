package com.antitok.app

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.ceil

class BlockerActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var countdown: TextView
    private val ticker = object : Runnable {
        override fun run() {
            renderOrFinish()
            handler.postDelayed(this, 1_000L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.BLACK
        window.navigationBarColor = Color.BLACK
        setContentView(buildContent())
    }

    override fun onResume() {
        super.onResume()
        handler.removeCallbacks(ticker)
        ticker.run()
    }

    override fun onPause() {
        handler.removeCallbacks(ticker)
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        renderOrFinish()
    }

    @Deprecated("Back exits TikTok while the lock remains active.")
    override fun onBackPressed() = leave()

    private fun renderOrFinish() {
        val lock = AntiTokSettings.getLock(this)
        val expected = intent.getLongExtra(EXTRA_GENERATION, -1L)
        if (lock == null || lock.generation != expected) {
            finish()
            return
        }
        val seconds = ceil(lock.remainingMs / 1_000.0).toLong().coerceAtLeast(0L)
        countdown.text = String.format("%02d:%02d", seconds / 60L, seconds % 60L)
    }

    private fun buildContent(): LinearLayout {
        val density = resources.displayMetrics.density
        fun Int.dp() = (this * density).toInt()
        countdown = TextView(this).apply {
            textSize = 48f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(28.dp(), 40.dp(), 28.dp(), 40.dp())
            setBackgroundColor(Color.BLACK)
            addView(TextView(this@BlockerActivity).apply {
                text = "TikTok временно заблокирован"
                textSize = 26f
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
                setTextColor(Color.WHITE)
            }, wrap())
            addView(TextView(this@BlockerActivity).apply {
                text = "Оставшееся время"
                textSize = 16f
                gravity = Gravity.CENTER
                setTextColor(0xFF9B9B9B.toInt())
                setPadding(0, 20.dp(), 0, 8.dp())
            }, wrap())
            addView(countdown, wrap())
            addView(TextView(this@BlockerActivity).apply {
                text = "Выйти на главный экран"
                textSize = 17f
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
                setTextColor(Color.BLACK)
                setBackgroundColor(Color.WHITE)
                setPadding(20.dp(), 16.dp(), 20.dp(), 16.dp())
                setOnClickListener { leave() }
            }, wrap().apply { topMargin = 36.dp() })
        }
    }

    private fun wrap() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )

    private fun leave() {
        AntiTokAccessibilityService.leaveToHome()
        startActivity(
            Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_HOME)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        finish()
    }

    companion object {
        const val EXTRA_GENERATION = "generation"
    }
}
