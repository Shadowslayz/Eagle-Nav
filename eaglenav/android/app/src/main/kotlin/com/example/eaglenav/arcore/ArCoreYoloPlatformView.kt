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
import com.google.ar.core.Config
import com.google.ar.core.Session
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.util.concurrent.atomic.AtomicBoolean

class ArCoreYoloPlatformView(
    private val context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "arcore_yolo_view_$viewId")
    private val root = FrameLayout(context)
    private val glSurfaceView: GLSurfaceView = GLSurfaceView(context)
    private val overlayView: DetectionOverlayView = DetectionOverlayView(context)

    private var session: Session? = null
    private val renderer: ArCoreYoloRenderer
    private val didRequestInstall = AtomicBoolean(false)

    init {
        channel.setMethodCallHandler(this)

        glSurfaceView.preserveEGLContextOnPause = true
        glSurfaceView.setEGLContextClientVersion(2)

        renderer = ArCoreYoloRenderer(
            context = context,
            onDetections = { items, payload ->
                root.post {
                    overlayView.setItems(items)
                    try {
                        channel.invokeMethod("onDetections", payload)
                    } catch (_: Throwable) {
                    }
                }
            },
        )

        glSurfaceView.setRenderer(renderer)
        glSurfaceView.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY

        try {
            glSurfaceView.onResume()
        } catch (_: Throwable) {
        }

        root.addView(
            glSurfaceView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        root.addView(
            overlayView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        root.post {
            val s = ensureSessionIfPossible()
            if (s != null) {
                Log.i(TAG, "ARCore session started successfully in init")
            } else {
                Log.w(TAG, "ARCore session not available yet in init, will retry on resume")
            }
        }
    }

    override fun getView(): View = root

    override fun dispose() {
        try {
            channel.setMethodCallHandler(null)
        } catch (_: Throwable) {
        }
        try {
            glSurfaceView.onPause()
        } catch (_: Throwable) {
        }

        glSurfaceView.queueEvent {
            renderer.setSession(null)
            renderer.dispose()
            try {
                session?.close()
            } catch (_: Throwable) {
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
                }
                val s = ensureSessionIfPossible()
                Log.i(TAG, "resume called, session=${if (s != null) "active" else "null"}")
                result.success(s != null)
            }
            "pause" -> {
                try {
                    glSurfaceView.onPause()
                } catch (_: Throwable) {
                }
                pauseSession()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureSessionIfPossible(): Session? {
        if (session != null) {
            try {
                session!!.resume()
            } catch (t: Throwable) {
                Log.w(TAG, "Session resume failed, recreating", t)
                try {
                    session?.close()
                } catch (_: Throwable) {
                }
                session = null
            }
            if (session != null) return session
        }

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
                !didRequestInstall.getAndSet(true),
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

            val config = Config(newSession).apply {
                updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE

                if (newSession.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                    depthMode = Config.DepthMode.AUTOMATIC
                    Log.i(TAG, "Depth mode AUTOMATIC enabled")
                } else {
                    Log.w(TAG, "Depth mode AUTOMATIC not supported")
                }
            }

            // Intentionally keep the default camera config here.
            // Forcing the max CPU resolution made the ARCore path heavier and less stable.
            newSession.configure(config)
            newSession.resume()
            session = newSession

            glSurfaceView.queueEvent { renderer.setSession(newSession) }
            Log.i(TAG, "ARCore Session created and resumed successfully")

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
        private const val TAG = "ArCoreYoloView"
    }
}
