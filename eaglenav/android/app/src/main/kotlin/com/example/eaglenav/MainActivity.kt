package com.example.eaglenav

import androidx.annotation.NonNull
import com.example.eaglenav.arcore.ArCoreMeasureViewFactory
import com.example.eaglenav.arcore.ArCoreYoloViewFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.platform.PlatformViewRegistry

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val registry = flutterEngine.platformViewsController.registry
        val yoloFactory = ArCoreYoloViewFactory(messenger)
        val measureFactory = ArCoreMeasureViewFactory(messenger)
        registerViewFactorySafely(registry, "arcore_yolo_view", yoloFactory)
        registerViewFactorySafely(registry, "com.example.eaglenav/arcore_yolo_view", yoloFactory)
        registerViewFactorySafely(registry, "arcore_measure_view", measureFactory)
        registerViewFactorySafely(registry, "com.example.eaglenav/arcore_measure_view", measureFactory)
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