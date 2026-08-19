package com.antitok.app

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

class PromptActivity : Activity() {
    private var answered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setFinishOnTouchOutside(false)
        configureWindow()

        val isEntryPrompt = intent.getStringExtra(EXTRA_PROMPT_TYPE) == "ENTRY"
        val elapsedMinutes = intent.getLongExtra(EXTRA_ELAPSED_MINUTES, 0L)
        val title = if (isEntryPrompt) "Открыть TikTok?" else "Продолжить TikTok?"
        val message = if (isEntryPrompt) {
            "Точно хочешь сейчас туда зайти?"
        } else {
            "Вы сидите уже ${formatMinutes(elapsedMinutes)}, может, передохнете?"
        }
        setContentView(buildContent(title, message, isEntryPrompt))
        resizeWindow()
    }

    @Deprecated("Back should decline the prompt.")
    override fun onBackPressed() = answer(false)

    private fun configureWindow() {
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.attributes = window.attributes.apply { dimAmount = 0.38f }
    }

    private fun resizeWindow() {
        val width = (resources.displayMetrics.widthPixels * 0.86f).toInt()
        window.setLayout(width, WindowManager.LayoutParams.WRAP_CONTENT)
    }

    private fun buildContent(title: String, message: String, isEntryPrompt: Boolean): FrameLayout {
        val density = resources.displayMetrics.density
        fun Int.dp(): Int = (this * density).toInt()

        val root = FrameLayout(this).apply {
            setPadding(0, 0, 0, 0)
            setBackgroundColor(Color.TRANSPARENT)
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(22.dp(), 24.dp(), 22.dp(), 22.dp())
            background = rounded(0xFF080808.toInt(), 24.dp(), 0xFF242424.toInt(), 1.dp())
        }

        card.addView(TextView(this).apply {
            text = title
            textSize = 24f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
        }, matchWrap())
        card.addView(TextView(this).apply {
            text = message
            textSize = 16f
            gravity = Gravity.CENTER
            setTextColor(0xFFB8B8B8.toInt())
            setPadding(0, 10.dp(), 0, 18.dp())
        }, matchWrap())
        if (isEntryPrompt) {
            card.addView(
                actionButton("Да, остаться в приложении", true, true, 18.dp(), 52.dp()),
                matchWrap(),
            )
            card.addView(
                actionButton("Выйти из приложения", false, false, 18.dp(), 52.dp()),
                matchWrap(),
            )
        } else {
            card.addView(
                actionButton("Да, выйти и отдохнуть", false, true, 18.dp(), 52.dp()),
                matchWrap(),
            )
            card.addView(
                actionButton("Нет, остаться в приложении", true, false, 18.dp(), 52.dp()),
                matchWrap(),
            )
        }

        root.addView(card, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER,
        ))
        return root
    }

    private fun actionButton(
        label: String,
        continueWatching: Boolean,
        primary: Boolean,
        radius: Int,
        height: Int,
    ): TextView {
        return TextView(this).apply {
            text = label
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            minHeight = height
            setTextColor(if (primary) Color.BLACK else Color.WHITE)
            background = if (primary) {
                rounded(Color.WHITE, radius, Color.WHITE, 0)
            } else {
                rounded(0xFF111111.toInt(), radius, 0xFF2A2A2A.toInt(), 1)
            }
            setPadding(16, 0, 16, 0)
            setOnClickListener { answer(continueWatching) }
        }
    }

    private fun rounded(color: Int, radius: Int, strokeColor: Int, strokeWidth: Int): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = radius.toFloat()
            setColor(color)
            if (strokeWidth > 0) setStroke(strokeWidth, strokeColor)
        }
    }

    private fun matchWrap(): LinearLayout.LayoutParams {
        return LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = 10 }
    }

    private fun answer(continueWatching: Boolean) {
        if (answered) return
        answered = true
        AntiTokAccessibilityService.handlePromptResult(continueWatching)
        finish()
    }

    private fun formatMinutes(value: Long): String {
        val mod100 = value % 100
        val mod10 = value % 10
        val word = when {
            mod100 in 11..14 -> "минут"
            mod10 == 1L -> "минуту"
            mod10 in 2..4 -> "минуты"
            else -> "минут"
        }
        return "$value $word"
    }

    companion object {
        const val EXTRA_PROMPT_TYPE = "prompt_type"
        const val EXTRA_ELAPSED_MINUTES = "elapsed_minutes"
    }
}
