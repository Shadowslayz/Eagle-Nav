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
        // Explicit resume hook from Flutter (optional). Safe to call multiple times.
        try {
          glSurfaceView.onResume()
        } catch (_: Throwable) {
          // ignore
        }
        ensureSessionIfPossible()
        result.success(true)
      }

      "pause" -> {
        // Explicit pause hook from Flutter (optional). Safe to call multiple times.
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

        // Run depth + math on the GL thread (ARCore session is updated there).
        glSurfaceView.queueEvent {
          val measurement = renderer.computeMeasurements(
            rect = RectF(left, top, right, bottom),
          )

          // Return to platform thread.
          root.post {
            if (measurement == null) {
              result.success(null)
            } else {
              result.success(measurement.toMap())
            }
          }
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

    // Check support first.
    if (!isArCoreSupported(context)) {
      Log.w(TAG, "ARCore not supported on this device")
      return null
    }

    // Ensure ARCore is installed.
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

      // Select highest-resolution camera config for better depth accuracy.
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
      // Set renderer session on the GL thread to avoid threading issues.
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