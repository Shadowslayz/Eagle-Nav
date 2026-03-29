package com.example.eaglenav.arcore

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Flutter PlatformView factory that creates an ARCore-powered camera view.
 *
 * The view exposes a MethodChannel per-view-instance: `arcore_measure_view_<id>`.
 */
class ArCoreMeasureViewFactory(
  private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    return ArCoreMeasurePlatformView(
      context = context,
      messenger = messenger,
      viewId = viewId,
    )
  }
}