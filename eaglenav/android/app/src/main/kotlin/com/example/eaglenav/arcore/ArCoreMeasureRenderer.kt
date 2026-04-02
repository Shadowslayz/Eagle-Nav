package com.example.eaglenav.arcore

import android.content.Context
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
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlin.math.sqrt

class ArCoreMeasureRenderer(
    private val context: Context,
) : GLSurfaceView.Renderer {

    private val backgroundRenderer = BackgroundRenderer()
    private var session: Session? = null
    private var latestFrame: Frame? = null

    fun setSession(session: Session?) {
        this.session = session
        if (session != null && backgroundRenderer.textureId != 0) {
            try {
                session.setCameraTextureName(backgroundRenderer.textureId)
            } catch (_: Throwable) {}
        }
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
            latestFrame = frame
            backgroundRenderer.draw(frame)
        } catch (t: Throwable) {
            Log.e(TAG, "onDrawFrame error", t)
        }
    }

    fun computeMeasurements(rect: RectF): MeasurementResult? {
        val frame = latestFrame ?: return null
        val camera = frame.camera
        if (camera.trackingState != TrackingState.TRACKING) return null

        // Try raw depth first, fall back to smoothed depth.
        val depthImage: Image = try {
            frame.acquireRawDepthImage16Bits()
        } catch (_: NotYetAvailableException) {
            try {
                frame.acquireDepthImage16Bits()
            } catch (_: NotYetAvailableException) {
                return null
            } catch (t: Throwable) {
                Log.e(TAG, "Smoothed depth acquisition failed", t)
                return null
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Raw depth acquisition failed", t)
            return null
        }

        // Also try confidence image.
        val confidenceImage: Image? = try {
            frame.acquireRawDepthConfidenceImage()
        } catch (_: Throwable) { null }

        try {
            val depthWidth = depthImage.width
            val depthHeight = depthImage.height
            val depthPlane = depthImage.planes[0]
            val depthBuffer = depthPlane.buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            val rowStride = depthPlane.rowStride
            val pixelStride = depthPlane.pixelStride

            var confBuffer: ByteBuffer? = null
            var confRowStride = 0
            var confPixelStride = 0
            if (confidenceImage != null && confidenceImage.planes.isNotEmpty()) {
                try {
                    val confPlane = confidenceImage.planes[0]
                    confBuffer = confPlane.buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
                    confRowStride = confPlane.rowStride
                    confPixelStride = confPlane.pixelStride
                } catch (_: Throwable) {}
            }

            val intr = camera.imageIntrinsics
            val focal = intr.focalLength
            val principal = intr.principalPoint
            val dims = intr.imageDimensions
            val imageWidth = dims[0]
            val imageHeight = dims[1]

            if (imageWidth <= 0 || imageHeight <= 0 || depthWidth <= 0 || depthHeight <= 0) return null

            val scaleX = depthWidth.toFloat() / imageWidth.toFloat()
            val scaleY = depthHeight.toFloat() / imageHeight.toFloat()

            val fx = focal[0] * scaleX
            val fy = focal[1] * scaleY
            val cx = principal[0] * scaleX
            val cy = principal[1] * scaleY

            fun viewToDepth(vx: Float, vy: Float): Pair<Int, Int> {
                val inCoords = floatArrayOf(vx, vy)
                val outCoords = FloatArray(2)
                frame.transformCoordinates2d(
                    Coordinates2d.VIEW,
                    inCoords,
                    Coordinates2d.IMAGE_PIXELS,
                    outCoords,
                )
                val uDepth = (outCoords[0] * scaleX).roundToInt().coerceIn(0, depthWidth - 1)
                val vDepth = (outCoords[1] * scaleY).roundToInt().coerceIn(0, depthHeight - 1)
                return Pair(uDepth, vDepth)
            }

            fun sampleDepthMeters(x: Int, y: Int, radius: Int = 3): Float? {
                val samples = ArrayList<Float>((2 * radius + 1) * (2 * radius + 1))
                for (dy in -radius..radius) {
                    for (dx in -radius..radius) {
                        val px = (x + dx).coerceIn(0, depthWidth - 1)
                        val py = (y + dy).coerceIn(0, depthHeight - 1)
                        val index = py * rowStride + px * pixelStride
                        if (index + 1 >= depthBuffer.capacity()) continue

                        // Check confidence if available.
                        if (confBuffer != null) {
                            val confIdx = py * confRowStride + px * confPixelStride
                            if (confIdx < confBuffer.capacity()) {
                                val conf = confBuffer.get(confIdx).toInt() and 0xFF
                                if (conf < DEPTH_CONFIDENCE_THRESHOLD) continue
                            }
                        }

                        val depthMm = depthBuffer.getShort(index).toInt() and 0xFFFF
                        if (depthMm in 1..MAX_DEPTH_MM) {
                            samples.add(depthMm / 1000f)
                        }
                    }
                }
                if (samples.isEmpty()) return null
                samples.sort()
                return samples[samples.size / 2]
            }

            fun sampleDepthGrid(
                xCenter: Int, yCenter: Int,
                halfW: Int, halfH: Int,
                gridSteps: Int = 7,
            ): Float? {
                val samples = ArrayList<Float>(gridSteps * gridSteps)
                val shrinkW = (halfW * 0.6f).toInt().coerceAtLeast(1)
                val shrinkH = (halfH * 0.6f).toInt().coerceAtLeast(1)

                for (gy in 0 until gridSteps) {
                    for (gx in 0 until gridSteps) {
                        val stepDenom = (gridSteps - 1).coerceAtLeast(1)
                        val fxP = xCenter - shrinkW + (2 * shrinkW * gx) / stepDenom
                        val fyP = yCenter - shrinkH + (2 * shrinkH * gy) / stepDenom
                        val px = fxP.coerceIn(0, depthWidth - 1)
                        val py = fyP.coerceIn(0, depthHeight - 1)
                        val d = sampleDepthMeters(px, py, radius = 2)
                        if (d != null) samples.add(d)
                    }
                }

                if (samples.isEmpty()) return null
                if (samples.size < 3) {
                    samples.sort()
                    return samples[samples.size / 2]
                }

                // IQR outlier rejection.
                samples.sort()
                val q1 = samples[samples.size / 4]
                val q3 = samples[3 * samples.size / 4]
                val iqr = q3 - q1
                val lowerBound = q1 - 1.5f * iqr
                val upperBound = q3 + 1.5f * iqr

                val filtered = samples.filter { it in lowerBound..upperBound }
                if (filtered.isEmpty()) return samples[samples.size / 2]
                return filtered[filtered.size / 2]
            }

            fun depthToCameraPoint(u: Int, v: Int, z: Float): FloatArray {
                val x = (u.toFloat() - cx) / fx * z
                val y = (v.toFloat() - cy) / fy * z
                return floatArrayOf(x, y, z)
            }

            fun dist(a: FloatArray, b: FloatArray): Float {
                val dx = a[0] - b[0]
                val dy = a[1] - b[1]
                val dz = a[2] - b[2]
                return sqrt(dx * dx + dy * dy + dz * dz)
            }

            val (cxD, cyD) = viewToDepth(rect.centerX, rect.centerY)
            val (tlx, tly) = viewToDepth(rect.left, rect.top)
            val (trx, try_) = viewToDepth(rect.right, rect.top)
            val (blx, bly) = viewToDepth(rect.left, rect.bottom)

            // Compute half-dimensions in depth space for grid sampling.
            val halfWDepth = ((trx - tlx).toFloat() / 2f).toInt().coerceAtLeast(1)
            val halfHDepth = ((bly - tly).toFloat() / 2f).toInt().coerceAtLeast(1)

            // Use grid sampling for accurate center distance.
            val distanceM = sampleDepthGrid(cxD, cyD, halfWDepth, halfHDepth) ?: return null

            // Sanity check.
            if (distanceM < 0.05f || distanceM > 10f) return null

            val zTL = sampleDepthMeters(tlx, tly) ?: distanceM
            val zTR = sampleDepthMeters(trx, try_) ?: distanceM
            val zBL = sampleDepthMeters(blx, bly) ?: distanceM

            val pTL = depthToCameraPoint(tlx, tly, zTL)
            val pTR = depthToCameraPoint(trx, try_, zTR)
            val pBL = depthToCameraPoint(blx, bly, zBL)

            val widthM = dist(pTL, pTR)
            val heightM = dist(pTL, pBL)

            val distanceInches = distanceM * METERS_TO_INCHES
            val widthInches = widthM * METERS_TO_INCHES
            val heightInches = heightM * METERS_TO_INCHES

            val (feet, inchesRemainder) = inchesToFeetInches(distanceInches)

            return MeasurementResult(
                distanceMeters = distanceM,
                distanceFeet = feet,
                distanceInches = inchesRemainder,
                widthInches = widthInches,
                heightInches = heightInches,
            )
        } finally {
            try { depthImage.close() } catch (_: Throwable) {}
            try { confidenceImage?.close() } catch (_: Throwable) {}
        }
    }

    private fun inchesToFeetInches(totalInches: Float): Pair<Int, Int> {
        if (!totalInches.isFinite() || totalInches < 0f) return Pair(0, 0)
        var feet = floor(totalInches / 12f).toInt()
        var inches = (totalInches - (feet * 12f)).roundToInt()
        if (inches >= 12) {
            feet += 1
            inches -= 12
        }
        return Pair(feet, inches)
    }

    companion object {
        private const val TAG = "ArCoreMeasureRenderer"
        private const val METERS_TO_INCHES = 39.3701f
        private const val MAX_DEPTH_MM = 8000
        private const val DEPTH_CONFIDENCE_THRESHOLD = 40
    }
}

data class MeasurementResult(
    val distanceMeters: Float,
    val distanceFeet: Int,
    val distanceInches: Int,
    val widthInches: Float,
    val heightInches: Float,
) {
    fun toMap(): Map<String, Any> {
        return mapOf(
            "distance_m" to distanceMeters,
            "distance_ft" to distanceFeet,
            "distance_in" to distanceInches,
            "width_in" to widthInches,
            "height_in" to heightInches,
            "distance_text" to "${distanceFeet}ft ${distanceInches}in",
            "size_text" to "${widthInches.roundToInt()}in x ${heightInches.roundToInt()}in",
        )
    }
}