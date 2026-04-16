package com.example.eaglenav.arcore

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.opengl.GLSurfaceView
import android.util.Log
import android.view.View
import android.widget.FrameLayout
import androidx.core.content.ContextCompat
import com.google.ar.core.ArCoreApk
import com.google.ar.core.CameraConfig
import com.google.ar.core.CameraConfigFilter
import com.google.ar.core.Config
import com.google.ar.core.Session
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A PlatformView that renders the ARCore camera background and can compute
 * distance + bounding-box dimensions using ARCore Depth.
 */
class ArCoreMeasurePlatformView(
  private val context: Context,
  messenger: BinaryMessenger,
  viewId: Int,
) : PlatformView, MethodChannel.MethodCallHandler {

  private val channel = MethodChannel(messenger, "arcore_measure_view_$viewId")
  private val root = FrameLayout(context)
  private val glSurfaceView: GLSurfaceView = GLSurfaceView(context)

  // ARCore
  private var session: Session? = null
  private val renderer: ArCoreMeasureRenderer

  // Avoid spamming install requests.
  private val didRequestInstall = AtomicBoolean(false)

  init {
    channel.setMethodCallHandler(this)

    glSurfaceView.preserveEGLContextOnPause = true
    glSurfaceView.setEGLContextClientVersion(2)
    renderer = ArCoreMeasureRenderer(context = context)
    glSurfaceView.setRenderer(renderer)
    glSurfaceView.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY

    // Start GL rendering loop.
    try {
      glSurfaceView.onResume()
    } catch (_: Throwable) {
      // ignore
    }

    root.addView(
      glSurfaceView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
  }

  override fun getView(): View = root

  override fun dispose() {
    try {
      channel.setMethodCallHandler(null)
    } catch (_: Throwable) {
      // ignore
    }

    try {
      glSurfaceView.onPause()
    } catch (_: Throwable) {
      // ignore
    }

    glSurfaceView.queueEvent {
      renderer.setSession(null)
      try {
        session?.close()
      } catch (_: Throwable) {
        // ignore
      } finally {
        session = null
      }
    }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "isSupported" -> {
        result.success(isArCoreSupported(context))
      }

      "resume" -> {
        try {
          glSurfaceView.onResume()
        } catch (_: Throwable) {
          // ignore
        }
        ensureSessionIfPossible()
        result.success(true)
      }

      "pause" -> {
        try {
          glSurfaceView.onPause()
        } catch (_: Throwable) {
          // ignore
        }
        pauseSession()
        result.success(true)
      }

      "getMeasurements" -> {
        val args = call.arguments as? Map<*, *>
        if (args == null) {
          result.error("bad_args", "Expected map arguments", null)
          return
        }

        val left = (args["left"] as? Number)?.toFloat()
        val top = (args["top"] as? Number)?.toFloat()
        val right = (args["right"] as? Number)?.toFloat()
        val bottom = (args["bottom"] as? Number)?.toFloat()

        if (left == null || top == null || right == null || bottom == null) {
          result.error("bad_args", "Missing rect fields", null)
          return
        }

        if (ensureSessionIfPossible() == null) {
          result.error(
            "arcore_unavailable",
            "ARCore is unavailable or not installed (or camera permission missing)",
            null,
          )
          return
        }

        glSurfaceView.queueEvent {
          val measurement = renderer.computeMeasurements(
            rect = RectF(left, top, right, bottom),
          )

          root.post {
            if (measurement == null) {
              result.success(null)
            } else {
              result.success(measurement.toMap())
            }
          }
        }
      }

      // ── NEW: batch measurements for segmentation / multiple detections ──
      "getMeasurementsForBoxes" -> {
        val args = call.arguments as? Map<*, *>
        if (args == null) {
          result.error("bad_args", "Expected map arguments", null)
          return
        }

        @Suppress("UNCHECKED_CAST")
        val boxes = args["boxes"] as? List<Map<String, Any?>>
        if (boxes == null) {
          result.error("bad_args", "Expected 'boxes' to be a list of rect maps", null)
          return
        }

        if (ensureSessionIfPossible() == null) {
          result.error(
            "arcore_unavailable",
            "ARCore is unavailable or not installed (or camera permission missing)",
            null,
          )
          return
        }

        // Parse each rect with an optional id for Flutter-side matching.
        data class Request(
          val id: String?,
          val rect: RectF,
        )

        val requests = ArrayList<Request>(boxes.size)
        for ((index, box) in boxes.withIndex()) {
          val left = (box["left"] as? Number)?.toFloat()
          val top = (box["top"] as? Number)?.toFloat()
          val right = (box["right"] as? Number)?.toFloat()
          val bottom = (box["bottom"] as? Number)?.toFloat()
          if (left == null || top == null || right == null || bottom == null) continue

          val id = box["id"]?.toString() ?: index.toString()
          requests.add(Request(id = id, rect = RectF(left, top, right, bottom)))
        }

        if (requests.isEmpty()) {
          result.success(emptyList<Map<String, Any>>())
          return
        }

        glSurfaceView.queueEvent {
          val out = ArrayList<Map<String, Any?>>(requests.size)
          for (req in requests) {
            val measurement = try {
              renderer.computeMeasurements(req.rect)
            } catch (t: Throwable) {
              Log.w(TAG, "computeMeasurements failed for id=${req.id}", t)
              null
            }

            val entry = HashMap<String, Any?>(8)
            entry["id"] = req.id
            if (measurement != null) {
              entry.putAll(measurement.toMap())
            } else {
              entry["processing"] = "processing"
            }
            out.add(entry)
          }

          root.post { result.success(out) }
        }
      }

      else -> result.notImplemented()
    }
  }

  private fun ensureSessionIfPossible(): Session? {
    if (session != null) return session

    val activity = findActivity(context)
    if (activity == null) {
      Log.e(TAG, "Context is not an Activity; cannot create ARCore Session")
      return null
    }

    if (!hasCameraPermission(context)) {
      Log.w(TAG, "Camera permission missing")
      return null
    }

    if (!isArCoreSupported(context)) {
      Log.w(TAG, "ARCore not supported on this device")
      return null
    }

    try {
      val installStatus = ArCoreApk.getInstance().requestInstall(
        activity,
        /* userRequestedInstall = */ !didRequestInstall.getAndSet(true),
      )
      if (installStatus == ArCoreApk.InstallStatus.INSTALL_REQUESTED) {
        Log.i(TAG, "ARCore installation requested")
        return null
      }
    } catch (t: Throwable) {
      Log.e(TAG, "ARCore install request failed", t)
      return null
    }

    return try {
      val newSession = Session(activity)

      try {
        val filter = CameraConfigFilter(newSession)
        val configs = newSession.getSupportedCameraConfigs(filter)
        if (configs.isNotEmpty()) {
          val best = configs.maxByOrNull {
            it.imageSize.width.toLong() * it.imageSize.height.toLong()
          }
          if (best != null) {
            newSession.cameraConfig = best
            Log.i(TAG, "Camera config: ${best.imageSize.width}x${best.imageSize.height}")
          }
        }
      } catch (t: Throwable) {
        Log.w(TAG, "Failed to select high-res camera config", t)
      }

      val config = Config(newSession)
      if (newSession.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
        config.depthMode = Config.DepthMode.AUTOMATIC
      }
      newSession.configure(config)
      newSession.resume()
      session = newSession
      glSurfaceView.queueEvent { renderer.setSession(newSession) }
      newSession
    } catch (t: Throwable) {
      Log.e(TAG, "Failed to create ARCore Session", t)
      null
    }
  }

  private fun pauseSession() {
    glSurfaceView.queueEvent {
      try {
        session?.pause()
      } catch (_: Throwable) {
        // ignore
      }
    }
  }

  private fun findActivity(context: Context): Activity? {
    var current: Context? = context
    while (current is ContextWrapper) {
      if (current is Activity) return current
      val base = current.baseContext
      if (base === current) break
      current = base
    }
    return if (current is Activity) current else null
  }

  private fun hasCameraPermission(context: Context): Boolean {
    return ContextCompat.checkSelfPermission(
      context,
      Manifest.permission.CAMERA,
    ) == PackageManager.PERMISSION_GRANTED
  }

  private fun isArCoreSupported(context: Context): Boolean {
    return try {
      val availability = ArCoreApk.getInstance().checkAvailability(context)
      availability.isSupported
    } catch (_: Throwable) {
      false
    }
  }

  companion object {
    private const val TAG = "ArCoreMeasureView"
  }
}

/** Lightweight immutable rect used across threads. */
data class RectF(
  val left: Float,
  val top: Float,
  val right: Float,
  val bottom: Float,
) {
  val width: Float get() = right - left
  val height: Float get() = bottom - top
  val centerX: Float get() = (left + right) / 2f
  val centerY: Float get() = (top + bottom) / 2f
}