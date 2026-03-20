package com.example.eaglenav.arcore

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class ArCoreYoloViewFactory(
  private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    return ArCoreYoloPlatformView(
      context = context,
      messenger = messenger,
      viewId = viewId,
    )
  }
}