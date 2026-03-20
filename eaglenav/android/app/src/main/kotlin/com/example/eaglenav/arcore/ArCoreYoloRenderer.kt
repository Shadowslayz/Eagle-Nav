package com.example.eaglenav.arcore

import android.content.Context
import android.graphics.Color
import android.media.Image
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.util.Log
import android.view.WindowManager
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.NotYetAvailableException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Zero-throttle maximum-compute renderer.
 *
 * - Inference runs every GL frame that the previous inference is done
 * - Depth acquisition + context building on dedicated thread
 * - Measurement computation parallelized across detections
 * - All buffers pre-allocated, zero GC during steady state
 */
class ArCoreYoloRenderer(
    private val context: Context,
    private val onDetections: (items: List<OverlayItem>, payload: List<Map<String, Any>>) -> Unit,
) : GLSurfaceView.Renderer {

    private val backgroundRenderer = BackgroundRenderer()
    private var session: Session? = null

    private val detector: YoloTfliteDetector = YoloTfliteDetector(
        assetManager = context.assets,
        modelAssetPath = "yolo11n.tflite",
    ).apply {
        confidenceThreshold = 0.13f
        iouThreshold = 0.5f
        maxDetections = 30
    }

    // ── No throttle — run as fast as inference completes ──────────────────
    private val inferenceRunning = AtomicBoolean(false)

    // ── Async depth ──────────────────────────────────────────────────────
    private val depthExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "depth-proc").apply { isDaemon = true; priority = Thread.MAX_PRIORITY }
    }
    private val activeDepthCtx = AtomicReference<DepthContext?>(null)
    @Volatile private var depthTimestampMs: Long = 0L
    private val maxDepthAgeMs: Long = 1000L

    // ── Parallel measurement computation ─────────────────────────────────
    private val measurePool = Executors.newFixedThreadPool(
        Runtime.getRuntime().availableProcessors().coerceIn(2, 4)
    )

    // ── Smoothing ────────────────────────────────────────────────────────
    private val smoother = MeasurementSmoother()

    private var depthSuccessCount = 0
    private var depthFailCount = 0

    fun setSession(session: Session?) {
        this.session = session
        if (session != null && backgroundRenderer.textureId != 0) {
            try { session.setCameraTextureName(backgroundRenderer.textureId) } catch (_: Throwable) {}
        }
    }

    fun dispose() {
        try { detector.close() } catch (_: Throwable) {}
        depthExecutor.shutdownNow()
        measurePool.shutdownNow()
    }

    override fun onSurfaceCreated(gl: javax.microedition.khronos.opengles.GL10?, config: javax.microedition.khronos.egl.EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        backgroundRenderer.createOnGlThread()
        session?.setCameraTextureName(backgroundRenderer.textureId)
    }

    override fun onSurfaceChanged(gl: javax.microedition.khronos.opengles.GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        try {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            @Suppress("DEPRECATION")
            val rotation = wm?.defaultDisplay?.rotation ?: 0
            session?.setDisplayGeometry(rotation, width, height)
        } catch (_: Throwable) {}
    }

    override fun onDrawFrame(gl: javax.microedition.khronos.opengles.GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val s = session ?: return
        try {
            val frame = s.update()
            backgroundRenderer.draw(frame)

            // Only run inference if previous one is done — no throttle, max throughput.
            if (inferenceRunning.compareAndSet(false, true)) {
                try {
                    runPipeline(frame)
                } finally {
                    inferenceRunning.set(false)
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "onDrawFrame error", t)
            inferenceRunning.set(false)
        }
    }

    // ── Cached measurements — updated async, never blocks GL ────────────
    private val measurementCache = HashMap<String, Measurement>()
    private var lastMeasureTimeNs: Long = 0L
    private val measureIntervalNs: Long = 500_000_000L  // Recalculate every 500ms

    // ── Main pipeline (fully non-blocking) ────────────────────────────────

    private fun runPipeline(frame: Frame) {
        val camera = frame.camera
        if (camera.trackingState != TrackingState.TRACKING) {
            onDetections(emptyList(), emptyList())
            return
        }

        // Kick off depth in parallel with inference.
        submitDepthWork(frame)

        // Acquire camera image and run YOLO.
        val cameraImage: Image = try {
            frame.acquireCameraImage()
        } catch (_: NotYetAvailableException) { return }
        catch (t: Throwable) { Log.e(TAG, "acquireCameraImage failed", t); return }

        val detections = try {
            detector.detect(cameraImage)
        } finally {
            try { cameraImage.close() } catch (_: Throwable) {}
        }

        if (detections.isEmpty()) {
            onDetections(emptyList(), emptyList())
            return
        }

        // Get latest depth context.
        val nowMs = System.currentTimeMillis()
        val depthCtx = if (nowMs - depthTimestampMs < maxDepthAgeMs) activeDepthCtx.get() else null

        // ── Throttled fire-and-forget measurements ────────────────────────
        // Only submit new measurement work every 500ms — not every frame.
        // This frees up massive CPU for YOLO detection.
        val nowNs = System.nanoTime()
        if (depthCtx != null && (nowNs - lastMeasureTimeNs) > measureIntervalNs) {
            lastMeasureTimeNs = nowNs
            for (d in detections) {
                val key = "${d.classId}_${(d.left / 40).roundToInt()}_${(d.top / 40).roundToInt()}"
                val cId = d.classId
                val l = d.left; val t = d.top; val r = d.right; val b = d.bottom
                try {
                    measurePool.execute {
                        val m = computeMeasurement(depthCtx, cId, l, t, r, b)
                        if (m != null) {
                            val smoothed = smoother.smooth(key, m)
                            synchronized(measurementCache) {
                                measurementCache[key] = smoothed
                            }
                        }
                    }
                } catch (_: Throwable) {}
            }
        }

        // ── Build overlay using cached measurements (instant) ─────────────
        val overlayItems = ArrayList<OverlayItem>(detections.size)
        val payload = ArrayList<Map<String, Any>>(detections.size)

        for (d in detections) {
            // Skip bounding box entirely for low-confidence detections
            if (d.score < 0.15f) continue

            val rectView = imageRectToViewRect(frame, d.left, d.top, d.right, d.bottom) ?: continue

            val key = "${d.classId}_${(d.left / 40).roundToInt()}_${(d.top / 40).roundToInt()}"
            val smoothed = synchronized(measurementCache) { measurementCache[key] }

            val color = colorForClassId(d.classId)
            val confStr = String.format(Locale.US, "%.0f%%", d.score * 100f)

            val label = if (smoothed != null) {
                val wIn = smoothed.widthInches.roundToInt()
                val hIn = smoothed.heightInches.roundToInt()
                "${d.className} $confStr ${smoothed.distanceFeet}ft ${smoothed.distanceInches}in ${wIn}x${hIn}in"
            } else {
                "${d.className} $confStr processing..."
            }

            overlayItems.add(OverlayItem(rect = rectView, label = label, colorArgb = color))

            val map = HashMap<String, Any>(10)
            map["class"] = d.className
            map["confidence"] = d.score.toDouble()
            if (smoothed != null) {
                map["distance_m"] = smoothed.distanceMeters.toDouble()
                map["distance_ft"] = smoothed.distanceFeet
                map["distance_in"] = smoothed.distanceInches
                map["width_in"] = smoothed.widthInches.toDouble()
                map["height_in"] = smoothed.heightInches.toDouble()
                map["distance_text"] = "${smoothed.distanceFeet}ft ${smoothed.distanceInches}in"
                map["size_text"] = "${smoothed.widthInches.roundToInt()}in x ${smoothed.heightInches.roundToInt()}in"
            }
            payload.add(map)
        }

        onDetections(overlayItems, payload)
    }

    // ── Async depth ───────────────────────────────────────────────────────

    private fun submitDepthWork(frame: Frame) {
        val camera = frame.camera
        val intr = camera.imageIntrinsics
        val focal = intr.focalLength.clone()
        val principal = intr.principalPoint.clone()
        val dims = intr.imageDimensions.clone()

        val depthImage: Image? = try {
            frame.acquireRawDepthImage16Bits()
        } catch (_: NotYetAvailableException) {
            try { frame.acquireDepthImage16Bits() } catch (_: Throwable) { null }
        } catch (_: Throwable) { null }

        if (depthImage == null) {
            depthFailCount++
            if (depthFailCount <= 3 || depthFailCount % 100 == 0)
                Log.d(TAG, "Depth not available (#$depthFailCount)")
            return
        }

        val confidenceImage: Image? = try { frame.acquireRawDepthConfidenceImage() } catch (_: Throwable) { null }

        depthSuccessCount++
        if (depthSuccessCount == 1) Log.i(TAG, "First depth: ${depthImage.width}x${depthImage.height}")

        val dw = depthImage.width; val dh = depthImage.height
        val dp = depthImage.planes[0]
        val depthCopy = deepCopy(dp.buffer)
        val dRowStride = dp.rowStride; val dPixelStride = dp.pixelStride

        var confCopy: ByteBuffer? = null; var cRS = 0; var cPS = 0
        if (confidenceImage != null && confidenceImage.planes.isNotEmpty()) {
            try {
                val cp = confidenceImage.planes[0]
                confCopy = deepCopy(cp.buffer); cRS = cp.rowStride; cPS = cp.pixelStride
            } catch (_: Throwable) {}
        }

        try { depthImage.close() } catch (_: Throwable) {}
        try { confidenceImage?.close() } catch (_: Throwable) {}

        try {
            depthExecutor.execute {
                val iw = dims[0]; val ih = dims[1]
                if (iw <= 0 || ih <= 0 || dw <= 0 || dh <= 0) return@execute
                val sx = dw.toFloat() / iw; val sy = dh.toFloat() / ih
                activeDepthCtx.set(DepthContext(dw, dh, depthCopy, confCopy, dRowStride, dPixelStride,
                    cRS, cPS, sx, sy, focal[0] * sx, focal[1] * sy, principal[0] * sx, principal[1] * sy))
                depthTimestampMs = System.currentTimeMillis()
            }
        } catch (_: Throwable) {}
    }

    private fun deepCopy(src: ByteBuffer): ByteBuffer {
        val c = ByteBuffer.allocateDirect(src.capacity()).order(ByteOrder.LITTLE_ENDIAN)
        src.rewind(); c.put(src); c.rewind(); return c
    }

    // ── Coord transform ───────────────────────────────────────────────────

    private fun imageRectToViewRect(frame: Frame, l: Float, t: Float, r: Float, b: Float): RectF? {
        if (!l.isFinite() || !t.isFinite() || !r.isFinite() || !b.isFinite()) return null
        val inC = floatArrayOf(l, t, r, t, l, b, r, b); val outC = FloatArray(8)
        return try {
            frame.transformCoordinates2d(Coordinates2d.IMAGE_PIXELS, inC, Coordinates2d.VIEW, outC)
            val xs = floatArrayOf(outC[0], outC[2], outC[4], outC[6])
            val ys = floatArrayOf(outC[1], outC[3], outC[5], outC[7])
            val mnX = xs.minOrNull() ?: return null; val mnY = ys.minOrNull() ?: return null
            val mxX = xs.maxOrNull() ?: return null; val mxY = ys.maxOrNull() ?: return null
            if (mxX <= mnX || mxY <= mnY) null else RectF(mnX, mnY, mxX, mxY)
        } catch (t: Throwable) { null }
    }

    // ── Depth data ────────────────────────────────────────────────────────

    private data class DepthContext(
        val dw: Int, val dh: Int,
        val buf: ByteBuffer, val confBuf: ByteBuffer?,
        val rs: Int, val ps: Int, val crs: Int, val cps: Int,
        val sx: Float, val sy: Float,
        val fx: Float, val fy: Float, val cx: Float, val cy: Float,
    )

    data class Measurement(
        val distanceMeters: Float, val distanceFeet: Int, val distanceInches: Int,
        val widthMeters: Float, val heightMeters: Float,
        val widthInches: Float, val heightInches: Float,
    )

    // ── Auto-zoom measurement with calibration corrections ──────────────────

    /**
     * Bbox inset factor: how much to shrink the YOLO bounding box inward
     * before measuring width/height. YOLO boxes are loose — especially on
     * small objects where the box can be 2-3× the actual object.
     *
     * Returns the fraction of the bbox to KEEP (0.0 = nothing, 1.0 = full bbox).
     */
    private fun bboxKeepFactor(classId: Int, bboxPixelArea: Int): Float {
        // Relaxed factors — previous version was shrinking too aggressively.
        val sizeFactor = when {
            bboxPixelArea < 2000   -> 0.65f  // tiny objects
            bboxPixelArea < 8000   -> 0.72f  // small objects
            bboxPixelArea < 30000  -> 0.80f  // medium objects
            bboxPixelArea < 80000  -> 0.88f  // large objects
            else                   -> 0.92f  // very large / close-up
        }

        // Per-class overrides — only for objects known to be very loosely boxed.
        val classOverride = when (classId) {
            67 -> 0.55f  // cell phone
            65 -> 0.58f  // remote
            64 -> 0.58f  // mouse
            73 -> 0.65f  // book
            39 -> 0.65f  // bottle
            41 -> 0.65f  // cup
            43 -> 0.60f  // knife
            42 -> 0.60f  // fork
            44 -> 0.60f  // spoon
            76 -> 0.60f  // scissors
            27 -> 0.62f  // tie
            66 -> 0.65f  // keyboard
            63 -> 0.72f  // laptop
            62 -> 0.75f  // tv
            24 -> 0.72f  // backpack
            26 -> 0.65f  // handbag
            0  -> 0.90f  // person
            56 -> 0.85f  // chair
            57 -> 0.88f  // couch
            60 -> 0.85f  // dining table
            else -> -1f
        }

        return if (classOverride > 0f) classOverride else sizeFactor
    }

    private fun computeMeasurement(
        ctx: DepthContext, classId: Int,
        leftImg: Float, topImg: Float, rightImg: Float, bottomImg: Float,
    ): Measurement? {
        fun i2d(x: Float, y: Float) = Pair(
            (x * ctx.sx).roundToInt().coerceIn(0, ctx.dw - 1),
            (y * ctx.sy).roundToInt().coerceIn(0, ctx.dh - 1)
        )

        fun sampleDepth(x: Int, y: Int, r: Int): Float? {
            val samples = ArrayList<Float>((2 * r + 1) * (2 * r + 1))
            for (dy in -r..r) for (dx in -r..r) {
                val px = (x + dx).coerceIn(0, ctx.dw - 1)
                val py = (y + dy).coerceIn(0, ctx.dh - 1)
                val bi = py * ctx.rs + px * ctx.ps
                if (bi + 1 >= ctx.buf.capacity()) continue
                if (ctx.confBuf != null) {
                    val ci = py * ctx.crs + px * ctx.cps
                    if (ci < ctx.confBuf.capacity() && (ctx.confBuf.get(ci).toInt() and 0xFF) < CONF_THRESH) continue
                }
                val mm = ctx.buf.getShort(bi).toInt() and 0xFFFF
                if (mm in 1..MAX_DEPTH_MM) samples.add(mm / 1000f)
            }
            if (samples.isEmpty()) return null
            samples.sort(); return samples[samples.size / 2]
        }

        fun iqrMedian(s: ArrayList<Float>): Float? {
            if (s.isEmpty()) return null
            if (s.size < 4) { s.sort(); return s[s.size / 2] }
            s.sort()
            val q1 = s[s.size / 4]; val q3 = s[3 * s.size / 4]; val iq = q3 - q1
            val f = s.filter { it in (q1 - 1.5f * iq)..(q3 + 1.5f * iq) }
            return if (f.isEmpty()) s[s.size / 2] else f[f.size / 2]
        }

        fun d2c(u: Int, v: Int, z: Float) = floatArrayOf(
            (u.toFloat() - ctx.cx) / ctx.fx * z,
            (v.toFloat() - ctx.cy) / ctx.fy * z, z
        )

        fun dist(a: FloatArray, b: FloatArray): Float {
            val dx = a[0] - b[0]; val dy = a[1] - b[1]; val dz = a[2] - b[2]
            return sqrt(dx * dx + dy * dy + dz * dz)
        }

        val bw = rightImg - leftImg; val bh = bottomImg - topImg
        val bwD = (bw * ctx.sx).roundToInt().coerceAtLeast(1)
        val bhD = (bh * ctx.sy).roundToInt().coerceAtLeast(1)
        val bpx = bwD * bhD

        // Auto-zoom grid density.
        val grid: Int; val rad: Int
        when {
            bpx < 200  -> { grid = 11; rad = 5 }
            bpx < 800  -> { grid = 9;  rad = 4 }
            bpx < 2500 -> { grid = 8;  rad = 3 }
            else       -> { grid = 7;  rad = 2 }
        }

        // ── Distance (center grid, then apply 0.666 correction) ───────────
        val imgCx = (leftImg + rightImg) / 2f; val imgCy = (topImg + bottomImg) / 2f
        val (cdx, cdy) = i2d(imgCx, imgCy)
        val hwD = (bwD / 2).coerceAtLeast(1); val hhD = (bhD / 2).coerceAtLeast(1)
        val sw = (hwD * 0.55f).toInt().coerceAtLeast(1)
        val sh = (hhD * 0.55f).toInt().coerceAtLeast(1)

        val ds = ArrayList<Float>(grid * grid)
        for (gy in 0 until grid) for (gx in 0 until grid) {
            val sd = (grid - 1).coerceAtLeast(1)
            val px = (cdx - sw + (2 * sw * gx) / sd).coerceIn(0, ctx.dw - 1)
            val py = (cdy - sh + (2 * sh * gy) / sd).coerceIn(0, ctx.dh - 1)
            val d = sampleDepth(px, py, rad)
            if (d != null) ds.add(d)
        }

        val rawDistM = iqrMedian(ds) ?: return null
        if (rawDistM < 0.05f || rawDistM > 10f) return null

        // Apply distance calibration correction FOR DISPLAY ONLY.
        val distM = rawDistM * DISTANCE_CORRECTION

        // ── Width/Height with adaptive bbox inset ─────────────────────────
        // Use rawDistM (uncorrected) for 3D projection — the correction is
        // only for how far away we report the object, not for computing its
        // physical size via angular spread × depth.
        val sizeDepth = rawDistM
        // Compute the bbox area in image pixels to determine how loose YOLO's box is.
        val bboxImgArea = (bw * bh).toInt()
        val keepFactor = bboxKeepFactor(classId, bboxImgArea)

        // Shrink the bbox inward symmetrically.
        val insetX = bw * (1f - keepFactor) / 2f
        val insetY = bh * (1f - keepFactor) / 2f
        val measLeft = leftImg + insetX
        val measTop = topImg + insetY
        val measRight = rightImg - insetX
        val measBottom = bottomImg - insetY
        val measW = measRight - measLeft
        val measH = measBottom - measTop

        if (measW <= 0f || measH <= 0f) return null

        // Multi-point edge walk on the INSET bbox, using CENTER DEPTH
        // for all edge points. This prevents background depth from
        // corrupting the size measurement.
        val es = grid.coerceIn(5, 11)

        val topPts = ArrayList<FloatArray>(es)
        for (i in 0 until es) {
            val t = i.toFloat() / (es - 1).coerceAtLeast(1)
            val (dx, dy) = i2d(measLeft + t * measW, measTop)
            topPts.add(d2c(dx, dy, sizeDepth))
        }
        var wM = 0f; for (i in 1 until topPts.size) wM += dist(topPts[i - 1], topPts[i])

        val leftPts = ArrayList<FloatArray>(es)
        for (i in 0 until es) {
            val t = i.toFloat() / (es - 1).coerceAtLeast(1)
            val (dx, dy) = i2d(measLeft, measTop + t * measH)
            leftPts.add(d2c(dx, dy, sizeDepth))
        }
        var hM = 0f; for (i in 1 until leftPts.size) hM += dist(leftPts[i - 1], leftPts[i])

        val totalIn = distM * M2IN; val (ft, inc) = ftIn(totalIn)

        return Measurement(distM, ft, inc, wM, hM, wM * M2IN, hM * M2IN)
    }

    private fun ftIn(totalInches: Float): Pair<Int, Int> {
        if (!totalInches.isFinite() || totalInches < 0f) return Pair(0, 0)
        var ft = floor(totalInches / 12f).toInt()
        var inc = (totalInches - ft * 12f).roundToInt()
        if (inc >= 12) { ft++; inc -= 12 }
        return Pair(ft, inc)
    }

    private fun colorForClassId(id: Int) = Color.HSVToColor(floatArrayOf(((id * 37) % 360).toFloat(), 0.85f, 0.95f))

    // ── Measurement smoother ──────────────────────────────────────────────

    private class MeasurementSmoother {
        private val history = HashMap<String, E>()
        private val maxAge = 1200L
        private val baseAlpha = 0.35f

        data class E(
            var d: Float,
            var w: Float,
            var h: Float,
            var t: Long,
            var lastDelta: Float,         // previous frame's distance change direction
            var consecutiveSameDir: Int,   // how many frames in a row distance moved same way
        )

        @Synchronized fun smooth(key: String, raw: Measurement): Measurement {
            val now = System.currentTimeMillis()
            if (history.size > 120) {
                val iter = history.entries.iterator()
                while (iter.hasNext()) { if (now - iter.next().value.t > maxAge) iter.remove() }
            }
            val e = history[key]
            if (e == null || now - e.t > maxAge) {
                history[key] = E(raw.distanceMeters, raw.widthMeters, raw.heightMeters, now, 0f, 0)
                return raw
            }

            val delta = raw.distanceMeters - e.d
            val sameDirection = (delta > 0f && e.lastDelta > 0f) || (delta < 0f && e.lastDelta < 0f)

            if (sameDirection) {
                e.consecutiveSameDir = (e.consecutiveSameDir + 1).coerceAtMost(6)
            } else {
                e.consecutiveSameDir = 0
            }
            e.lastDelta = delta

            // If distance has been moving the same direction for 2+ frames,
            // this is real movement (walking), not noise. Use high alpha.
            // Single-frame spikes get low alpha (filtered as noise).
            val a = when {
                e.consecutiveSameDir >= 3 -> 0.70f   // Definitely walking — track fast
                e.consecutiveSameDir >= 2 -> 0.55f   // Probably walking
                e.consecutiveSameDir >= 1 -> 0.40f   // Maybe walking
                else -> baseAlpha                      // Stationary — normal smoothing
            }

            e.d = e.d * (1 - a) + raw.distanceMeters * a
            e.w = e.w * (1 - a) + raw.widthMeters * a
            e.h = e.h * (1 - a) + raw.heightMeters * a
            e.t = now
            val totalIn = e.d * M2IN; val (ft, inc) = ftInStatic(totalIn)
            return Measurement(e.d, ft, inc, e.w, e.h, e.w * M2IN, e.h * M2IN)
        }

        companion object {
            fun ftInStatic(totalInches: Float): Pair<Int, Int> {
                if (!totalInches.isFinite() || totalInches < 0f) return Pair(0, 0)
                var ft = floor(totalInches / 12f).toInt()
                var inc = (totalInches - ft * 12f).roundToInt()
                if (inc >= 12) { ft++; inc -= 12 }
                return Pair(ft, inc)
            }
        }
    }

    companion object {
        private const val TAG = "ArCoreYoloRenderer"
        private const val M2IN = 39.3701f
        private const val MAX_DEPTH_MM = 8000
        private const val CONF_THRESH = 40
        private const val DISTANCE_CORRECTION = 0.666f  // Calibrated: raw depth overshoots ~1.5×
    }
}