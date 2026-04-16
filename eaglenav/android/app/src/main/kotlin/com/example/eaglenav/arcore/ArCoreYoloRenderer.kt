package com.example.eaglenav.arcore

import android.content.Context
import android.graphics.Color
import android.media.Image
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.util.Log
import android.view.Surface
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
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Detection-first AR renderer.
 *
 * Detection always runs whenever a camera image is available.
 * Depth/measurement is opportunistic and never allowed to suppress boxes.
 */
class ArCoreYoloRenderer(
    private val context: Context,
    private val modelAssetPath: String = "yolo11n.tflite",
    private val labels: List<String> = CocoLabels.LABELS,
    private val numClasses: Int = -1,
    private val filledOverlay: Boolean = false,
    private val confidenceOverride: Float = -1f,
    private val onDetections: (items: List<OverlayItem>, payload: List<Map<String, Any>>) -> Unit,
) : GLSurfaceView.Renderer {

    private val backgroundRenderer = BackgroundRenderer()
    private var session: Session? = null

    private val detector: YoloTfliteDetector = YoloTfliteDetector(
        assetManager = context.assets,
        modelAssetPath = modelAssetPath,
        labels = labels,
        numClasses = numClasses,
    ).apply {
        confidenceThreshold = if (confidenceOverride > 0f) confidenceOverride else DETECTION_CONF
        iouThreshold = DETECTION_IOU
        maxDetections = MAX_DETECTIONS
    }

    // Inference still stays single-flight so we never overlap TFLite runs.
    private val inferenceRunning = AtomicBoolean(false)

    // Depth is throttled and single-flight as well.
    private val depthExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "depth-proc").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY
        }
    }
    private val depthWorkInFlight = AtomicBoolean(false)
    private val activeDepthCtx = AtomicReference<DepthContext?>(null)
    @Volatile private var depthTimestampMs: Long = 0L
    @Volatile private var lastDepthSubmitNs: Long = 0L

    // Measurement work is intentionally capped; measuring everything every frame is too expensive.
    private val measurePool = Executors.newFixedThreadPool(2)
    private val smoother = MeasurementSmoother()

    private var depthSuccessCount = 0
    private var depthFailCount = 0

    private val tracks = LinkedHashMap<String, Track>()
    private var nextTrackId = 1L

    private val measurementCache = HashMap<String, MeasurementEntry>()

    fun setSession(session: Session?) {
        this.session = session
        if (session != null && backgroundRenderer.textureId != 0) {
            try {
                session.setCameraTextureName(backgroundRenderer.textureId)
            } catch (_: Throwable) {
            }
        }
    }

    fun dispose() {
        try {
            detector.close()
        } catch (_: Throwable) {
        }
        depthExecutor.shutdownNow()
        measurePool.shutdownNow()
    }

    override fun onSurfaceCreated(
        gl: javax.microedition.khronos.opengles.GL10?,
        config: javax.microedition.khronos.egl.EGLConfig?,
    ) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        backgroundRenderer.createOnGlThread()
        session?.setCameraTextureName(backgroundRenderer.textureId)
    }

    override fun onSurfaceChanged(
        gl: javax.microedition.khronos.opengles.GL10?,
        width: Int,
        height: Int,
    ) {
        GLES20.glViewport(0, 0, width, height)
        try {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            @Suppress("DEPRECATION")
            val rotation = wm?.defaultDisplay?.rotation ?: 0
            session?.setDisplayGeometry(rotation, width, height)
        } catch (_: Throwable) {
        }
    }

    override fun onDrawFrame(gl: javax.microedition.khronos.opengles.GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val s = session ?: return

        try {
            val frame = s.update()
            backgroundRenderer.draw(frame)

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

    private fun runPipeline(frame: Frame) {
        val tracking = frame.camera.trackingState == TrackingState.TRACKING
        if (tracking) {
            submitDepthWork(frame)
        }

        val rawDetections = acquireDetections(frame)
        val trackedDetections = updateTracks(rawDetections)

        val depthCtx = if (tracking) currentDepthContext() else null
        scheduleMeasurements(depthCtx, trackedDetections)
        emitOverlay(frame, trackedDetections)
    }

    private fun acquireDetections(frame: Frame): List<YoloTfliteDetector.Detection> {
        val cameraImage: Image = try {
            frame.acquireCameraImage()
        } catch (_: NotYetAvailableException) {
            return emptyList()
        } catch (t: Throwable) {
            Log.e(TAG, "acquireCameraImage failed", t)
            return emptyList()
        }

        return try {
            detector.detect(cameraImage, rotationDegrees = currentModelRotationDegrees())
        } catch (t: Throwable) {
            Log.e(TAG, "detect failed", t)
            emptyList()
        } finally {
            try {
                cameraImage.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun currentDepthContext(): DepthContext? {
        val nowMs = System.currentTimeMillis()
        return if (nowMs - depthTimestampMs <= MAX_DEPTH_AGE_MS) activeDepthCtx.get() else null
    }

    // ── Detection persistence ────────────────────────────────────────────

    private data class Track(
        val id: String,
        var classId: Int,
        var className: String,
        var score: Float,
        var left: Float,
        var top: Float,
        var right: Float,
        var bottom: Float,
        var hits: Int,
        var lastSeenMs: Long,
        var lastMeasuredNs: Long = 0L,
    ) {
        fun areaPx(): Float = max(0f, right - left) * max(0f, bottom - top)
    }

    private fun updateTracks(rawDetections: List<YoloTfliteDetector.Detection>): List<Track> {
        val nowMs = System.currentTimeMillis()
        val detections = rawDetections
            .asSequence()
            .filter { it.score >= DETECTION_CONF }
            .sortedByDescending { it.score }
            .toList()

        val matchedDetection = BooleanArray(detections.size)
        val matchedTrackIds = HashSet<String>()

        for ((index, det) in detections.withIndex()) {
            var bestTrack: Track? = null
            var bestIou = 0f

            for (track in tracks.values) {
                if (track.id in matchedTrackIds) continue
                if (track.classId != det.classId) continue
                if (nowMs - track.lastSeenMs > TRACK_PERSIST_MS) continue

                val overlap = iou(
                    track.left,
                    track.top,
                    track.right,
                    track.bottom,
                    det.left,
                    det.top,
                    det.right,
                    det.bottom,
                )
                if (overlap >= TRACK_MATCH_IOU && overlap > bestIou) {
                    bestIou = overlap
                    bestTrack = track
                }
            }

            if (bestTrack != null) {
                updateTrack(bestTrack, det, nowMs)
                matchedTrackIds.add(bestTrack.id)
                matchedDetection[index] = true
            }
        }

        for ((index, det) in detections.withIndex()) {
            if (matchedDetection[index]) continue

            val id = "track_${nextTrackId++}"
            tracks[id] = Track(
                id = id,
                classId = det.classId,
                className = det.className,
                score = det.score,
                left = det.left,
                top = det.top,
                right = det.right,
                bottom = det.bottom,
                hits = 1,
                lastSeenMs = nowMs,
            )
            matchedTrackIds.add(id)
        }

        val iterator = tracks.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            val track = entry.value
            val ageMs = nowMs - track.lastSeenMs

            if (ageMs > TRACK_PERSIST_MS) {
                iterator.remove()
                synchronized(measurementCache) {
                    measurementCache.remove(track.id)
                }
                smoother.forget(track.id)
                continue
            }

            if (track.id !in matchedTrackIds) {
                track.score *= TRACK_SCORE_DECAY
            }
        }

        return tracks.values
            .filter { track ->
                val stable = track.hits >= MIN_STABLE_HITS || track.score >= FAST_PATH_CONF
                stable && (nowMs - track.lastSeenMs <= TRACK_PERSIST_MS)
            }
            .sortedWith(
                compareByDescending<Track> { it.score }
                    .thenByDescending { it.areaPx() }
            )
    }

    private fun updateTrack(
        track: Track,
        detection: YoloTfliteDetector.Detection,
        nowMs: Long,
    ) {
        track.classId = detection.classId
        track.className = detection.className
        track.left = lerp(track.left, detection.left, BOX_EMA_ALPHA)
        track.top = lerp(track.top, detection.top, BOX_EMA_ALPHA)
        track.right = lerp(track.right, detection.right, BOX_EMA_ALPHA)
        track.bottom = lerp(track.bottom, detection.bottom, BOX_EMA_ALPHA)
        track.score = lerp(track.score, detection.score, SCORE_EMA_ALPHA)
        track.lastSeenMs = nowMs
        track.hits = (track.hits + 1).coerceAtMost(1000)
    }

    private fun lerp(a: Float, b: Float, alpha: Float): Float {
        return a * (1f - alpha) + b * alpha
    }

    private fun iou(
        aLeft: Float,
        aTop: Float,
        aRight: Float,
        aBottom: Float,
        bLeft: Float,
        bTop: Float,
        bRight: Float,
        bBottom: Float,
    ): Float {
        val interLeft = max(aLeft, bLeft)
        val interTop = max(aTop, bTop)
        val interRight = min(aRight, bRight)
        val interBottom = min(aBottom, bBottom)
        val interWidth = max(0f, interRight - interLeft)
        val interHeight = max(0f, interBottom - interTop)
        val interArea = interWidth * interHeight

        val areaA = max(0f, aRight - aLeft) * max(0f, aBottom - aTop)
        val areaB = max(0f, bRight - bLeft) * max(0f, bBottom - bTop)
        val union = areaA + areaB - interArea
        return if (union <= 0f) 0f else interArea / union
    }

    // ── Overlay emission ─────────────────────────────────────────────────

    private data class MeasurementEntry(
        val value: Measurement,
        val updatedMs: Long,
    )

    private fun emitOverlay(frame: Frame, tracksToDraw: List<Track>) {
        if (tracksToDraw.isEmpty()) {
            onDetections(emptyList(), emptyList())
            return
        }

        val nowMs = System.currentTimeMillis()
        val overlayItems = ArrayList<OverlayItem>(tracksToDraw.size)
        val payload = ArrayList<Map<String, Any>>(tracksToDraw.size)

        for (track in tracksToDraw) {
            val rectView = imageRectToViewRect(frame, track.left, track.top, track.right, track.bottom)
                ?: continue

            val measurement = synchronized(measurementCache) {
                measurementCache[track.id]
            }?.takeIf { nowMs - it.updatedMs <= MAX_MEASUREMENT_CACHE_AGE_MS }?.value

            val color = colorForClassId(track.classId)
            val confStr = String.format(Locale.US, "%.0f%%", track.score * 100f)

            val label = if (measurement != null) {
                val widthInches = measurement.widthInches.roundToInt()
                val heightInches = measurement.heightInches.roundToInt()
                "${track.className} $confStr ${measurement.distanceFeet}ft ${measurement.distanceInches}in ${widthInches}x${heightInches}in"
            } else {
                "${track.className} $confStr processing"
            }

            overlayItems.add(
                OverlayItem(
                    rect = rectView,
                    label = label,
                    colorArgb = color,
                    filled = filledOverlay,
                )
            )

            val itemPayload = HashMap<String, Any>(10)
            itemPayload["class"] = track.className
            itemPayload["confidence"] = track.score.toDouble()
            if (measurement != null) {
                itemPayload["distance_m"] = measurement.distanceMeters.toDouble()
                itemPayload["distance_ft"] = measurement.distanceFeet
                itemPayload["distance_in"] = measurement.distanceInches
                itemPayload["width_in"] = measurement.widthInches.toDouble()
                itemPayload["height_in"] = measurement.heightInches.toDouble()
                itemPayload["distance_text"] = "${measurement.distanceFeet}ft ${measurement.distanceInches}in"
                itemPayload["size_text"] = "${measurement.widthInches.roundToInt()}in x ${measurement.heightInches.roundToInt()}in"
            } else {
                itemPayload["processing"] = "processing"
            }
            payload.add(itemPayload)
        }

        onDetections(overlayItems, payload)
    }

    // ── Measurement scheduling ───────────────────────────────────────────

    private fun scheduleMeasurements(depthCtx: DepthContext?, tracksToMeasure: List<Track>) {
        if (depthCtx == null || tracksToMeasure.isEmpty()) return

        val nowNs = System.nanoTime()
        val candidates = tracksToMeasure
            .asSequence()
            .filter { it.hits >= MIN_STABLE_HITS }
            .sortedWith(
                compareByDescending<Track> { it.score }
                    .thenByDescending { it.areaPx() }
            )
            .take(MAX_MEASUREMENTS_PER_CYCLE)
            .toList()

        for (track in candidates) {
            if (nowNs - track.lastMeasuredNs < MEASURE_INTERVAL_NS) continue
            track.lastMeasuredNs = nowNs

            val trackId = track.id
            val classId = track.classId
            val left = track.left
            val top = track.top
            val right = track.right
            val bottom = track.bottom

            try {
                measurePool.execute measureTask@{
                    val measurement = computeMeasurement(depthCtx, classId, left, top, right, bottom)
                        ?: return@measureTask
                    val smoothed = smoother.smooth(trackId, measurement)
                    synchronized(measurementCache) {
                        measurementCache[trackId] = MeasurementEntry(
                            value = smoothed,
                            updatedMs = System.currentTimeMillis(),
                        )
                    }
                }
            } catch (_: Throwable) {
            }
        }
    }

    // ── Depth acquisition ────────────────────────────────────────────────

    private fun submitDepthWork(frame: Frame) {
        val nowNs = System.nanoTime()
        if (nowNs - lastDepthSubmitNs < DEPTH_INTERVAL_NS) return
        if (!depthWorkInFlight.compareAndSet(false, true)) return
        lastDepthSubmitNs = nowNs

        val camera = frame.camera
        val intr = camera.imageIntrinsics
        val focal = intr.focalLength.clone()
        val principal = intr.principalPoint.clone()
        val dims = intr.imageDimensions.clone()

        try {
            val depthImage: Image? = try {
                frame.acquireRawDepthImage16Bits()
            } catch (_: NotYetAvailableException) {
                try {
                    frame.acquireDepthImage16Bits()
                } catch (_: Throwable) {
                    null
                }
            } catch (_: Throwable) {
                null
            }

            if (depthImage == null) {
                depthFailCount++
                if (depthFailCount <= 3 || depthFailCount % 100 == 0) {
                    Log.d(TAG, "Depth not available (#$depthFailCount)")
                }
                depthWorkInFlight.set(false)
                return
            }

            val confidenceImage: Image? = try {
                frame.acquireRawDepthConfidenceImage()
            } catch (_: Throwable) {
                null
            }

            depthSuccessCount++
            if (depthSuccessCount == 1) {
                Log.i(TAG, "First depth: ${depthImage.width}x${depthImage.height}")
            }

            val depthWidth = depthImage.width
            val depthHeight = depthImage.height
            val depthPlane = depthImage.planes[0]
            val depthCopy = deepCopy(depthPlane.buffer)
            val depthRowStride = depthPlane.rowStride
            val depthPixelStride = depthPlane.pixelStride

            var confCopy: ByteBuffer? = null
            var confRowStride = 0
            var confPixelStride = 0
            if (confidenceImage != null && confidenceImage.planes.isNotEmpty()) {
                try {
                    val confPlane = confidenceImage.planes[0]
                    confCopy = deepCopy(confPlane.buffer)
                    confRowStride = confPlane.rowStride
                    confPixelStride = confPlane.pixelStride
                } catch (_: Throwable) {
                }
            }

            try {
                depthImage.close()
            } catch (_: Throwable) {
            }
            try {
                confidenceImage?.close()
            } catch (_: Throwable) {
            }

            depthExecutor.execute depthTask@{
                try {
                    val imageWidth = dims[0]
                    val imageHeight = dims[1]
                    if (imageWidth <= 0 || imageHeight <= 0 || depthWidth <= 0 || depthHeight <= 0) return@depthTask

                    val scaleX = depthWidth.toFloat() / imageWidth.toFloat()
                    val scaleY = depthHeight.toFloat() / imageHeight.toFloat()
                    activeDepthCtx.set(
                        DepthContext(
                            dw = depthWidth,
                            dh = depthHeight,
                            buf = depthCopy,
                            confBuf = confCopy,
                            rs = depthRowStride,
                            ps = depthPixelStride,
                            crs = confRowStride,
                            cps = confPixelStride,
                            sx = scaleX,
                            sy = scaleY,
                            fx = focal[0] * scaleX,
                            fy = focal[1] * scaleY,
                            cx = principal[0] * scaleX,
                            cy = principal[1] * scaleY,
                        )
                    )
                    depthTimestampMs = System.currentTimeMillis()
                } finally {
                    depthWorkInFlight.set(false)
                }
            }
        } catch (t: Throwable) {
            depthWorkInFlight.set(false)
            Log.w(TAG, "submitDepthWork failed", t)
        }
    }

    private fun deepCopy(src: ByteBuffer): ByteBuffer {
        val copy = ByteBuffer.allocateDirect(src.capacity()).order(ByteOrder.LITTLE_ENDIAN)
        src.rewind()
        copy.put(src)
        copy.rewind()
        return copy
    }

    // ── Coordinate transform ─────────────────────────────────────────────

    private fun imageRectToViewRect(
        frame: Frame,
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
    ): RectF? {
        if (!left.isFinite() || !top.isFinite() || !right.isFinite() || !bottom.isFinite()) {
            return null
        }

        val inCoords = floatArrayOf(left, top, right, top, left, bottom, right, bottom)
        val outCoords = FloatArray(8)

        return try {
            frame.transformCoordinates2d(
                Coordinates2d.IMAGE_PIXELS,
                inCoords,
                Coordinates2d.VIEW,
                outCoords,
            )
            val xs = floatArrayOf(outCoords[0], outCoords[2], outCoords[4], outCoords[6])
            val ys = floatArrayOf(outCoords[1], outCoords[3], outCoords[5], outCoords[7])
            val minX = xs.minOrNull() ?: return null
            val minY = ys.minOrNull() ?: return null
            val maxX = xs.maxOrNull() ?: return null
            val maxY = ys.maxOrNull() ?: return null
            if (maxX <= minX || maxY <= minY) {
                null
            } else {
                RectF(minX, minY, maxX, maxY)
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun currentModelRotationDegrees(): Int {
        return try {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            @Suppress("DEPRECATION")
            when (wm?.defaultDisplay?.rotation) {
                Surface.ROTATION_0 -> 90
                Surface.ROTATION_90 -> 0
                Surface.ROTATION_180 -> 270
                Surface.ROTATION_270 -> 180
                else -> 0
            }
        } catch (_: Throwable) {
            0
        }
    }

    // ── Depth data ───────────────────────────────────────────────────────

    private data class DepthContext(
        val dw: Int,
        val dh: Int,
        val buf: ByteBuffer,
        val confBuf: ByteBuffer?,
        val rs: Int,
        val ps: Int,
        val crs: Int,
        val cps: Int,
        val sx: Float,
        val sy: Float,
        val fx: Float,
        val fy: Float,
        val cx: Float,
        val cy: Float,
    )

    data class Measurement(
        val distanceMeters: Float,
        val distanceFeet: Int,
        val distanceInches: Int,
        val widthMeters: Float,
        val heightMeters: Float,
        val widthInches: Float,
        val heightInches: Float,
    )

    /**
     * YOLO boxes are loose, so we shrink the box inward before measuring.
     */
    private fun bboxKeepFactor(classId: Int, bboxPixelArea: Int): Float {
        val sizeFactor = when {
            bboxPixelArea < 2_000 -> 0.65f
            bboxPixelArea < 8_000 -> 0.72f
            bboxPixelArea < 30_000 -> 0.80f
            bboxPixelArea < 80_000 -> 0.88f
            else -> 0.92f
        }

        val classOverride = when (classId) {
            67 -> 0.55f // cell phone
            65 -> 0.58f // remote
            64 -> 0.58f // mouse
            73 -> 0.65f // book
            39 -> 0.65f // bottle
            41 -> 0.65f // cup
            43 -> 0.60f // knife
            42 -> 0.60f // fork
            44 -> 0.60f // spoon
            76 -> 0.60f // scissors
            27 -> 0.62f // tie
            66 -> 0.65f // keyboard
            63 -> 0.72f // laptop
            62 -> 0.75f // tv
            24 -> 0.72f // backpack
            26 -> 0.65f // handbag
            0 -> 0.90f  // person
            56 -> 0.85f // chair
            57 -> 0.88f // couch
            60 -> 0.85f // dining table
            else -> -1f
        }

        return if (classOverride > 0f) classOverride else sizeFactor
    }

    private fun computeMeasurement(
        ctx: DepthContext,
        classId: Int,
        leftImg: Float,
        topImg: Float,
        rightImg: Float,
        bottomImg: Float,
    ): Measurement? {
        fun imageToDepth(x: Float, y: Float): Pair<Int, Int> {
            return Pair(
                (x * ctx.sx).roundToInt().coerceIn(0, ctx.dw - 1),
                (y * ctx.sy).roundToInt().coerceIn(0, ctx.dh - 1),
            )
        }

        fun sampleDepth(x: Int, y: Int, radius: Int): Float? {
            val samples = ArrayList<Float>((2 * radius + 1) * (2 * radius + 1))
            for (dy in -radius..radius) {
                for (dx in -radius..radius) {
                    val px = (x + dx).coerceIn(0, ctx.dw - 1)
                    val py = (y + dy).coerceIn(0, ctx.dh - 1)
                    val bufferIndex = py * ctx.rs + px * ctx.ps
                    if (bufferIndex + 1 >= ctx.buf.capacity()) continue

                    if (ctx.confBuf != null) {
                        val confIndex = py * ctx.crs + px * ctx.cps
                        if (confIndex < ctx.confBuf.capacity()) {
                            val conf = ctx.confBuf.get(confIndex).toInt() and 0xFF
                            if (conf < CONF_THRESH) continue
                        }
                    }

                    val depthMm = ctx.buf.getShort(bufferIndex).toInt() and 0xFFFF
                    if (depthMm in 1..MAX_DEPTH_MM) {
                        samples.add(depthMm / 1000f)
                    }
                }
            }

            if (samples.isEmpty()) return null
            samples.sort()
            return samples[samples.size / 2]
        }

        fun iqrMedian(values: ArrayList<Float>): Float? {
            if (values.isEmpty()) return null
            if (values.size < 4) {
                values.sort()
                return values[values.size / 2]
            }
            values.sort()
            val q1 = values[values.size / 4]
            val q3 = values[3 * values.size / 4]
            val iqr = q3 - q1
            val filtered = values.filter { it in (q1 - 1.5f * iqr)..(q3 + 1.5f * iqr) }
            return if (filtered.isEmpty()) values[values.size / 2] else filtered[filtered.size / 2]
        }

        fun depthToCamera(u: Int, v: Int, z: Float): FloatArray {
            return floatArrayOf(
                (u.toFloat() - ctx.cx) / ctx.fx * z,
                (v.toFloat() - ctx.cy) / ctx.fy * z,
                z,
            )
        }

        fun dist(a: FloatArray, b: FloatArray): Float {
            val dx = a[0] - b[0]
            val dy = a[1] - b[1]
            val dz = a[2] - b[2]
            return sqrt(dx * dx + dy * dy + dz * dz)
        }

        val bboxWidth = rightImg - leftImg
        val bboxHeight = bottomImg - topImg
        val bboxWidthDepth = (bboxWidth * ctx.sx).roundToInt().coerceAtLeast(1)
        val bboxHeightDepth = (bboxHeight * ctx.sy).roundToInt().coerceAtLeast(1)
        val bboxPixelArea = bboxWidthDepth * bboxHeightDepth

        val grid: Int
        val radius: Int
        when {
            bboxPixelArea < 200 -> {
                grid = 11
                radius = 5
            }
            bboxPixelArea < 800 -> {
                grid = 9
                radius = 4
            }
            bboxPixelArea < 2_500 -> {
                grid = 8
                radius = 3
            }
            else -> {
                grid = 7
                radius = 2
            }
        }

        val centerX = (leftImg + rightImg) / 2f
        val centerY = (topImg + bottomImg) / 2f
        val (centerDepthX, centerDepthY) = imageToDepth(centerX, centerY)
        val halfWidthDepth = (bboxWidthDepth / 2).coerceAtLeast(1)
        val halfHeightDepth = (bboxHeightDepth / 2).coerceAtLeast(1)
        val sampleWidth = (halfWidthDepth * 0.55f).toInt().coerceAtLeast(1)
        val sampleHeight = (halfHeightDepth * 0.55f).toInt().coerceAtLeast(1)

        val distanceSamples = ArrayList<Float>(grid * grid)
        for (gy in 0 until grid) {
            for (gx in 0 until grid) {
                val denom = (grid - 1).coerceAtLeast(1)
                val px = (centerDepthX - sampleWidth + (2 * sampleWidth * gx) / denom)
                    .coerceIn(0, ctx.dw - 1)
                val py = (centerDepthY - sampleHeight + (2 * sampleHeight * gy) / denom)
                    .coerceIn(0, ctx.dh - 1)
                val depth = sampleDepth(px, py, radius)
                if (depth != null) {
                    distanceSamples.add(depth)
                }
            }
        }

        val rawDistanceMeters = iqrMedian(distanceSamples) ?: return null
        if (rawDistanceMeters < 0.05f || rawDistanceMeters > 10f) return null

        val distanceMeters = applyDistanceSuppression(rawDistanceMeters)

        val keepFactor = bboxKeepFactor(classId, (bboxWidth * bboxHeight).toInt())
        val insetX = bboxWidth * (1f - keepFactor) / 2f
        val insetY = bboxHeight * (1f - keepFactor) / 2f
        val measureLeft = leftImg + insetX
        val measureTop = topImg + insetY
        val measureRight = rightImg - insetX
        val measureBottom = bottomImg - insetY
        val measureWidth = measureRight - measureLeft
        val measureHeight = measureBottom - measureTop

        if (measureWidth <= 0f || measureHeight <= 0f) return null

        val edgeSteps = grid.coerceIn(5, 11)

        val topPoints = ArrayList<FloatArray>(edgeSteps)
        for (i in 0 until edgeSteps) {
            val t = i.toFloat() / (edgeSteps - 1).coerceAtLeast(1)
            val (dx, dy) = imageToDepth(measureLeft + t * measureWidth, measureTop)
            topPoints.add(depthToCamera(dx, dy, rawDistanceMeters))
        }
        var widthTopMeters = 0f
        for (i in 1 until topPoints.size) {
            widthTopMeters += dist(topPoints[i - 1], topPoints[i])
        }

        val bottomPoints = ArrayList<FloatArray>(edgeSteps)
        for (i in 0 until edgeSteps) {
            val t = i.toFloat() / (edgeSteps - 1).coerceAtLeast(1)
            val (dx, dy) = imageToDepth(measureLeft + t * measureWidth, measureBottom)
            bottomPoints.add(depthToCamera(dx, dy, rawDistanceMeters))
        }
        var widthBottomMeters = 0f
        for (i in 1 until bottomPoints.size) {
            widthBottomMeters += dist(bottomPoints[i - 1], bottomPoints[i])
        }
        val widthMeters = (widthTopMeters + widthBottomMeters) / 2f

        val leftPoints = ArrayList<FloatArray>(edgeSteps)
        for (i in 0 until edgeSteps) {
            val t = i.toFloat() / (edgeSteps - 1).coerceAtLeast(1)
            val (dx, dy) = imageToDepth(measureLeft, measureTop + t * measureHeight)
            leftPoints.add(depthToCamera(dx, dy, rawDistanceMeters))
        }
        var heightLeftMeters = 0f
        for (i in 1 until leftPoints.size) {
            heightLeftMeters += dist(leftPoints[i - 1], leftPoints[i])
        }

        val rightPoints = ArrayList<FloatArray>(edgeSteps)
        for (i in 0 until edgeSteps) {
            val t = i.toFloat() / (edgeSteps - 1).coerceAtLeast(1)
            val (dx, dy) = imageToDepth(measureRight, measureTop + t * measureHeight)
            rightPoints.add(depthToCamera(dx, dy, rawDistanceMeters))
        }
        var heightRightMeters = 0f
        for (i in 1 until rightPoints.size) {
            heightRightMeters += dist(rightPoints[i - 1], rightPoints[i])
        }
        val heightMeters = (heightLeftMeters + heightRightMeters) / 2f

        val totalInches = distanceMeters * M2IN
        val (feet, inches) = feetAndInches(totalInches)

        return Measurement(
            distanceMeters = distanceMeters,
            distanceFeet = feet,
            distanceInches = inches,
            widthMeters = widthMeters,
            heightMeters = heightMeters,
            widthInches = widthMeters * M2IN,
            heightInches = heightMeters * M2IN,
        )
    }

    private fun feetAndInches(totalInches: Float): Pair<Int, Int> {
        if (!totalInches.isFinite() || totalInches < 0f) return Pair(0, 0)
        var feet = floor(totalInches / 12f).toInt()
        var inches = (totalInches - feet * 12f).roundToInt()
        if (inches >= 12) {
            feet++
            inches -= 12
        }
        return Pair(feet, inches)
    }


    private fun applyDistanceSuppression(rawDistanceMeters: Float): Float {
        val rawDistanceFeet = rawDistanceMeters * M2FT
        val multiplier = when {
            rawDistanceFeet < 3f -> DISTANCE_SCALE_0_TO_3_FT
            rawDistanceFeet < 6f -> DISTANCE_SCALE_3_TO_6_FT
            else -> DISTANCE_SCALE_6_PLUS_FT
        }
        return rawDistanceMeters * multiplier * DISTANCE_SCALE_FINAL
    }

    private fun colorForClassId(classId: Int): Int {
        return Color.HSVToColor(
            floatArrayOf(((classId * 37) % 360).toFloat(), 0.85f, 0.95f)
        )
    }

    // ── Measurement smoother ─────────────────────────────────────────────

    private class MeasurementSmoother {
        private val history = HashMap<String, Entry>()
        private val maxAgeMs = 1_200L
        private val baseAlpha = 0.35f

        private data class Entry(
            var distanceMeters: Float,
            var widthMeters: Float,
            var heightMeters: Float,
            var timestampMs: Long,
            var lastDelta: Float,
            var consecutiveSameDirection: Int,
        )

        @Synchronized
        fun forget(key: String) {
            history.remove(key)
        }

        @Synchronized
        fun smooth(key: String, raw: Measurement): Measurement {
            val nowMs = System.currentTimeMillis()
            if (history.size > 120) {
                val iterator = history.entries.iterator()
                while (iterator.hasNext()) {
                    val entry = iterator.next().value
                    if (nowMs - entry.timestampMs > maxAgeMs) {
                        iterator.remove()
                    }
                }
            }

            val existing = history[key]
            if (existing == null || nowMs - existing.timestampMs > maxAgeMs) {
                history[key] = Entry(
                    distanceMeters = raw.distanceMeters,
                    widthMeters = raw.widthMeters,
                    heightMeters = raw.heightMeters,
                    timestampMs = nowMs,
                    lastDelta = 0f,
                    consecutiveSameDirection = 0,
                )
                return raw
            }

            val delta = raw.distanceMeters - existing.distanceMeters
            val sameDirection = (delta > 0f && existing.lastDelta > 0f) ||
                (delta < 0f && existing.lastDelta < 0f)

            existing.consecutiveSameDirection = if (sameDirection) {
                (existing.consecutiveSameDirection + 1).coerceAtMost(6)
            } else {
                0
            }
            existing.lastDelta = delta

            val alpha = when {
                existing.consecutiveSameDirection >= 3 -> 0.70f
                existing.consecutiveSameDirection >= 2 -> 0.55f
                existing.consecutiveSameDirection >= 1 -> 0.40f
                else -> baseAlpha
            }

            existing.distanceMeters = lerp(existing.distanceMeters, raw.distanceMeters, alpha)
            existing.widthMeters = lerp(existing.widthMeters, raw.widthMeters, alpha)
            existing.heightMeters = lerp(existing.heightMeters, raw.heightMeters, alpha)
            existing.timestampMs = nowMs

            val totalInches = existing.distanceMeters * M2IN
            val (feet, inches) = feetAndInchesStatic(totalInches)
            return Measurement(
                distanceMeters = existing.distanceMeters,
                distanceFeet = feet,
                distanceInches = inches,
                widthMeters = existing.widthMeters,
                heightMeters = existing.heightMeters,
                widthInches = existing.widthMeters * M2IN,
                heightInches = existing.heightMeters * M2IN,
            )
        }

        companion object {
            private fun lerp(a: Float, b: Float, alpha: Float): Float {
                return a * (1f - alpha) + b * alpha
            }

            private fun feetAndInchesStatic(totalInches: Float): Pair<Int, Int> {
                if (!totalInches.isFinite() || totalInches < 0f) return Pair(0, 0)
                var feet = floor(totalInches / 12f).toInt()
                var inches = (totalInches - feet * 12f).roundToInt()
                if (inches >= 12) {
                    feet++
                    inches -= 12
                }
                return Pair(feet, inches)
            }
        }
    }

    companion object {
        private const val TAG = "ArCoreYoloRenderer"

        private const val DETECTION_CONF = 0.25f
        private const val DETECTION_IOU = 0.40f
        private const val MAX_DETECTIONS = 20

        private const val TRACK_MATCH_IOU = 0.30f
        private const val TRACK_PERSIST_MS = 350L
        private const val MIN_STABLE_HITS = 2
        private const val FAST_PATH_CONF = 0.60f
        private const val BOX_EMA_ALPHA = 0.60f
        private const val SCORE_EMA_ALPHA = 0.50f
        private const val TRACK_SCORE_DECAY = 0.94f

        private const val DEPTH_INTERVAL_NS = 120_000_000L
        private const val MAX_DEPTH_AGE_MS = 450L
        private const val MEASURE_INTERVAL_NS = 250_000_000L
        private const val MAX_MEASUREMENTS_PER_CYCLE = 4
        private const val MAX_MEASUREMENT_CACHE_AGE_MS = 1_000L

        private const val M2IN = 39.3701f
        private const val M2FT = 3.28084f
        private const val MAX_DEPTH_MM = 8_000
        private const val CONF_THRESH = 40

        private const val DISTANCE_SCALE_0_TO_3_FT = 0.819f
        private const val DISTANCE_SCALE_3_TO_6_FT = 0.765f
        private const val DISTANCE_SCALE_6_PLUS_FT = 0.684f
        private const val DISTANCE_SCALE_FINAL = 0.76f
    }
}