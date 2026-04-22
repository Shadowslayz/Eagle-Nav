package com.example.eaglenav.arcore

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import android.util.AttributeSet
import android.view.View
import kotlin.math.max

/**
 * Simple Canvas-based overlay that draws detection bounding boxes + labels.
 * When [OverlayItem.filled] is true, draws a semi-transparent filled rectangle
 * (segmentation style) instead of just the outline.
 */
class DetectionOverlayView @JvmOverloads constructor(
  context: Context,
  attrs: AttributeSet? = null,
) : View(context, attrs) {

  private val lock = Any()
  private val items: MutableList<OverlayItem> = ArrayList()
  private val drawItems: MutableList<OverlayItem> = ArrayList()

  private val boxPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeJoin = Paint.Join.ROUND
    strokeCap = Paint.Cap.ROUND
  }

  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
  }

  private val labelBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
  }

  private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
  }

  private val textBounds = Rect()
  private val tmpRoundRect = android.graphics.RectF()

  private val density = resources.displayMetrics.density
  private val boxStrokePx = max(2f, 2.5f * density)
  private val textSizePx = 14f * resources.displayMetrics.scaledDensity
  private val padPx = 6f * density
  private val radiusPx = 8f * density

  init {
    // Allow taps to pass through.
    isClickable = false
    isFocusable = false
    isFocusableInTouchMode = false

    boxPaint.strokeWidth = boxStrokePx
    textPaint.textSize = textSizePx
  }

  fun setItems(newItems: List<OverlayItem>) {
    synchronized(lock) {
      items.clear()
      items.addAll(newItems)
    }
    postInvalidateOnAnimation()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)

    // Copy under lock to avoid allocations inside draw loop.
    drawItems.clear()
    synchronized(lock) {
      drawItems.addAll(items)
    }

    for (item in drawItems) {
      val left = item.rect.left
      val top = item.rect.top
      val right = item.rect.right
      val bottom = item.rect.bottom

      if (item.filled) {
        // Segmentation style: semi-transparent filled rectangle + border
        val rgb = item.colorArgb and 0x00FFFFFF
        fillPaint.color = (0x55 shl 24) or rgb  // ~33% opacity fill
        canvas.drawRect(left, top, right, bottom, fillPaint)

        // Solid border on top of the fill
        boxPaint.color = item.colorArgb
        canvas.drawRect(left, top, right, bottom, boxPaint)
      } else {
        // Detection style: just the outline
        boxPaint.color = item.colorArgb
        canvas.drawRect(left, top, right, bottom, boxPaint)
      }

      // Label background + text
      val label = item.label
      if (label.isBlank()) continue

      textPaint.getTextBounds(label, 0, label.length, textBounds)
      val textW = textBounds.width().toFloat()
      val textH = textBounds.height().toFloat()

      val bgLeft = left
      var bgTop = top - (textH + 2f * padPx)
      if (bgTop < 0f) bgTop = top + boxStrokePx // if too close to top, place inside

      val bgRight = bgLeft + textW + 2f * padPx
      val bgBottom = bgTop + textH + 2f * padPx

      val alphaBg = 0xB0 shl 24
      val rgb = item.colorArgb and 0x00FFFFFF
      labelBgPaint.color = alphaBg or rgb

      tmpRoundRect.set(bgLeft, bgTop, bgRight, bgBottom)
      canvas.drawRoundRect(tmpRoundRect, radiusPx, radiusPx, labelBgPaint)

      val textX = bgLeft + padPx
      val textY = bgBottom - padPx - textBounds.bottom
      canvas.drawText(label, textX, textY, textPaint)
    }
  }
}