package com.example.eaglenav

import android.os.Bundle
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        installArCoreCrashGuard()
    }

    /**
     * Keeps the old guard in case any camera/session race still happens.
     * It does not register any custom ARCore platform views.
     */
    private fun installArCoreCrashGuard() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()

        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            val msg = throwable.message ?: ""
            val threadName = thread.name ?: ""

            val isArCoreCameraRace =
                throwable is IllegalStateException &&
                msg.contains("Session has been closed") &&
                (
                    threadName.startsWith("DefaultDispatcher-worker") ||
                    threadName.startsWith("arcore_") ||
                    throwable.stackTrace.any {
                        it.className.contains("CameraCaptureSession", ignoreCase = true)
                    }
                )

            if (isArCoreCameraRace) {
                Log.w(
                    "MainActivity",
                    "Swallowed ARCore camera session race on $threadName: $msg"
                )
                return@setDefaultUncaughtExceptionHandler
            }

            previous?.uncaughtException(thread, throwable)
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // No custom platform views registered here.
        // Android is using the working YOLOView plugin path instead.
    }
}