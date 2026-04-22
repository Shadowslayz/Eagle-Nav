package com.example.eaglenav

import android.os.Bundle
import android.util.Log
import androidx.annotation.NonNull
import com.example.eaglenav.arcore.ArCoreMeasureViewFactory
import com.example.eaglenav.arcore.ArCoreSegViewFactory
import com.example.eaglenav.arcore.ArCoreYoloViewFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.platform.PlatformViewRegistry

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        installArCoreCrashGuard()
    }

    /**
     * ARCore's internal coroutine workers sometimes throw
     * IllegalStateException("Session has been closed; further changes are illegal.")
     * when a platform view is disposed mid-frame and the new view creates a new
     * camera capture session. The exception is thrown on a background
     * DefaultDispatcher-worker thread and has no recovery path — it just crashes
     * the app. We install a default uncaught exception handler that swallows
     * this specific, benign race condition while letting other crashes through.
     */
    private fun installArCoreCrashGuard() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            val msg = throwable.message ?: ""
            val threadName = thread.name ?: ""
            val isArCoreCameraRace = throwable is IllegalStateException &&
                msg.contains("Session has been closed") &&
                (threadName.startsWith("DefaultDispatcher-worker") ||
                 threadName.startsWith("arcore_") ||
                 throwable.stackTrace.any {
                     it.className.contains("CameraCaptureSession", ignoreCase = true)
                 })

            if (isArCoreCameraRace) {
                Log.w("MainActivity",
                    "Swallowed ARCore camera session race on $threadName: $msg")
                return@setDefaultUncaughtExceptionHandler
            }
            // Any other exception — delegate to the previous handler (which
            // will crash the app as normal). This preserves crash reporting.
            previous?.uncaughtException(thread, throwable)
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val registry = flutterEngine.platformViewsController.registry
        val yoloFactory = ArCoreYoloViewFactory(messenger)
        val measureFactory = ArCoreMeasureViewFactory(messenger)
        val segFactory = ArCoreSegViewFactory(messenger)
        registerViewFactorySafely(registry, "arcore_yolo_view", yoloFactory)
        registerViewFactorySafely(registry, "com.example.eaglenav/arcore_yolo_view", yoloFactory)
        registerViewFactorySafely(registry, "arcore_measure_view", measureFactory)
        registerViewFactorySafely(registry, "com.example.eaglenav/arcore_measure_view", measureFactory)
        registerViewFactorySafely(registry, "arcore_seg_view", segFactory)
        registerViewFactorySafely(registry, "com.example.eaglenav/arcore_seg_view", segFactory)
    }

    private fun registerViewFactorySafely(
        registry: PlatformViewRegistry,
        viewTypeId: String,
        factory: PlatformViewFactory,
    ) {
        try {
            registry.registerViewFactory(viewTypeId, factory)
        } catch (_: IllegalStateException) {
            // Already registered on this engine instance.
        }
    }
}