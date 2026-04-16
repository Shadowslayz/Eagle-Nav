package com.example.eaglenav.arcore

/**
 * A single item to be drawn on top of the camera feed.
 *
 * [rect] is in VIEW pixel coordinates (same coordinate space as the GLSurfaceView).
 * [filled] when true, draws a semi-transparent filled rectangle (segmentation style).
 */
data class OverlayItem(
  val rect: RectF,
  val label: String,
  val colorArgb: Int,
  val filled: Boolean = false,
)