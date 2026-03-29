package com.example.eaglenav.arcore

/**
 * A single item to be drawn on top of the camera feed.
 *
 * [rect] is in VIEW pixel coordinates (same coordinate space as the GLSurfaceView).
 */
data class OverlayItem(
  val rect: RectF,
  val label: String,
  val colorArgb: Int,
)