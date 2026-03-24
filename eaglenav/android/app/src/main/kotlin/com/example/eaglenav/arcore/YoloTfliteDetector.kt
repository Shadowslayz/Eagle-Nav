package com.example.eaglenav.arcore

import android.content.res.AssetManager
import android.media.Image
import android.os.Build
import android.util.Log
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.Future
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * ARCore camera YOLO TFLite detector.
 *
 * Key change from the old version: this detector can rotate the CPU camera image
 * before inference and then map detections back into the original IMAGE_PIXELS
 * coordinate space that ARCore expects.
 */
class YoloTfliteDetector(
    assetManager: AssetManager,
    modelAssetPath: String = "yolo11n.tflite",
    private val labels: List<String> = CocoLabels.LABELS,
) : AutoCloseable {

    data class Detection(
        val classId: Int,
        val className: String,
        val score: Float,
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
    )

    private data class Letterbox(
        val scale: Float,
        val padX: Float,
        val padY: Float,
        val origW: Int,
        val origH: Int,
        val resizedW: Int,
        val resizedH: Int,
    )

    private var gpuDelegate: GpuDelegate? = null
    private var nnapiDelegate: Any? = null

    private val interpreter: Interpreter = run {
        val mapped = loadModelFile(assetManager, modelAssetPath)
        val options = Interpreter.Options()

        val cpuCores = Runtime.getRuntime().availableProcessors()
        options.setNumThreads(cpuCores.coerceIn(4, 8))
        options.setUseXNNPACK(true)

        var delegateUsed = "CPU/XNNPACK(${cpuCores.coerceIn(4, 8)}t)"

        try {
            val compatList = CompatibilityList()
            if (compatList.isDelegateSupportedOnThisDevice) {
                val gpuOptions = GpuDelegate.Options()
                    .setPrecisionLossAllowed(true)
                    .setInferencePreference(GpuDelegate.Options.INFERENCE_PREFERENCE_SUSTAINED_SPEED)
                val gpu = GpuDelegate(gpuOptions)
                options.addDelegate(gpu)
                gpuDelegate = gpu
                delegateUsed = "GPU/FP16"
            }
        } catch (t: Throwable) {
            Log.w(TAG, "GPU delegate failed", t)
            gpuDelegate = null
        }

        if (gpuDelegate == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val nnapi = org.tensorflow.lite.nnapi.NnApiDelegate(
                    org.tensorflow.lite.nnapi.NnApiDelegate.Options()
                        .setAllowFp16(true)
                        .setExecutionPreference(
                            org.tensorflow.lite.nnapi.NnApiDelegate.Options.EXECUTION_PREFERENCE_SUSTAINED_SPEED
                        )
                )
                options.addDelegate(nnapi)
                nnapiDelegate = nnapi
                delegateUsed = "NNAPI/FP16"
            } catch (t: Throwable) {
                Log.w(TAG, "NNAPI failed: ${t.javaClass.simpleName}", t)
                nnapiDelegate = null
            }
        }

        Log.i(TAG, "Interpreter: $delegateUsed")
        Interpreter(mapped, options)
    }

    private val inputShape: IntArray = interpreter.getInputTensor(0).shape()
    private val inputType: DataType = interpreter.getInputTensor(0).dataType()
    private val inputQuant = interpreter.getInputTensor(0).quantizationParams()

    private val isNchw: Boolean
    private val inputWidth: Int
    private val inputHeight: Int

    private val outputShape: IntArray = interpreter.getOutputTensor(0).shape()
    private val outputType: DataType = interpreter.getOutputTensor(0).dataType()
    private val outputQuant = interpreter.getOutputTensor(0).quantizationParams()

    private val inputBuffer: ByteBuffer
    private val outputBuffer: ByteBuffer
    private val outputFloats: FloatArray

    var confidenceThreshold: Float = 0.25f
    var iouThreshold: Float = 0.5f
    var maxDetections: Int = 25

    private val preprocWorkerCount = Runtime.getRuntime().availableProcessors().coerceIn(4, 8)
    private val preprocPool = Executors.newFixedThreadPool(preprocWorkerCount)

    private val bulkFloatArray: FloatArray?
    private val rgbRowCache: Array<IntArray>

    init {
        if (inputShape.size != 4) {
            throw IllegalStateException("Unexpected input: ${inputShape.contentToString()}")
        }

        isNchw = (inputShape[1] == 3 && inputShape[3] != 3)
        inputHeight = if (isNchw) inputShape[2] else inputShape[1]
        inputWidth = if (isNchw) inputShape[3] else inputShape[2]

        val inputBytes = interpreter.getInputTensor(0).numBytes()
        inputBuffer = ByteBuffer.allocateDirect(inputBytes).order(ByteOrder.nativeOrder())

        val outputBytes = interpreter.getOutputTensor(0).numBytes()
        outputBuffer = ByteBuffer.allocateDirect(outputBytes).order(ByteOrder.nativeOrder())

        outputFloats = FloatArray(numElements(outputShape))

        bulkFloatArray = if (inputType == DataType.FLOAT32 && !isNchw) {
            FloatArray(inputHeight * inputWidth * 3)
        } else {
            null
        }

        rgbRowCache = Array(inputHeight) { IntArray(inputWidth * 3) }
    }

    fun detect(image: Image, rotationDegrees: Int = 0): List<Detection> {
        val srcWidth = image.width
        val srcHeight = image.height
        if (srcWidth <= 0 || srcHeight <= 0) return emptyList()

        val normalizedRotation = normalizeRotationDegrees(rotationDegrees)
        val rotatedWidth = if (normalizedRotation == 90 || normalizedRotation == 270) srcHeight else srcWidth
        val rotatedHeight = if (normalizedRotation == 90 || normalizedRotation == 270) srcWidth else srcHeight
        val letterbox = makeLetterbox(rotatedWidth, rotatedHeight, inputWidth, inputHeight)

        try {
            fillInputParallel(
                image = image,
                lb = letterbox,
                rotationDegrees = normalizedRotation,
                srcWidth = srcWidth,
                srcHeight = srcHeight,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "Preprocess failed", t)
            return emptyList()
        }

        try {
            inputBuffer.rewind()
            outputBuffer.rewind()
            interpreter.run(inputBuffer, outputBuffer)
        } catch (t: Throwable) {
            Log.e(TAG, "TFLite run failed", t)
            return emptyList()
        }

        try {
            readOutputToFloatArray()
        } catch (t: Throwable) {
            Log.e(TAG, "Output read failed", t)
            return emptyList()
        }

        val raw = decodeDetections(outputFloats, outputShape, letterbox)
        if (raw.isEmpty()) return emptyList()

        val mapped = if (normalizedRotation == 0) {
            raw
        } else {
            mapDetectionsBackToSource(raw, srcWidth, srcHeight, normalizedRotation)
        }

        if (mapped.isEmpty()) return emptyList()
        return nonMaxSuppression(mapped, iouThreshold, maxDetections)
    }

    // ── Preprocessing ────────────────────────────────────────────────────

    private fun fillInputParallel(
        image: Image,
        lb: Letterbox,
        rotationDegrees: Int,
        srcWidth: Int,
        srcHeight: Int,
    ) {
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]

        val yBuf = yPlane.buffer
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer

        val yRowStride = yPlane.rowStride
        val uvRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride

        val rotatedXMap = IntArray(inputWidth) { -1 }
        val rotatedYMap = IntArray(inputHeight) { -1 }

        for (ix in 0 until inputWidth) {
            val xIn = ix.toFloat() - lb.padX
            if (xIn >= 0f && xIn < lb.resizedW.toFloat()) {
                rotatedXMap[ix] = (xIn / lb.scale).toInt().coerceIn(0, lb.origW - 1)
            }
        }
        for (iy in 0 until inputHeight) {
            val yIn = iy.toFloat() - lb.padY
            if (yIn >= 0f && yIn < lb.resizedH.toFloat()) {
                rotatedYMap[iy] = (yIn / lb.scale).toInt().coerceIn(0, lb.origH - 1)
            }
        }

        val rowsPerWorker = (inputHeight + preprocWorkerCount - 1) / preprocWorkerCount
        val futures = ArrayList<Future<*>>(preprocWorkerCount)

        for (worker in 0 until preprocWorkerCount) {
            val startRow = worker * rowsPerWorker
            val endRow = min((worker + 1) * rowsPerWorker, inputHeight)
            if (startRow >= endRow) continue

            futures.add(preprocPool.submit(Callable {
                for (iy in startRow until endRow) {
                    val rotatedY = rotatedYMap[iy]
                    val row = rgbRowCache[iy]
                    for (ix in 0 until inputWidth) {
                        val rotatedX = rotatedXMap[ix]
                        val base = ix * 3

                        if (rotatedX == -1 || rotatedY == -1) {
                            row[base] = 0
                            row[base + 1] = 0
                            row[base + 2] = 0
                            continue
                        }

                        val sourceX: Int
                        val sourceY: Int
                        when (rotationDegrees) {
                            90 -> {
                                sourceX = rotatedY
                                sourceY = srcHeight - 1 - rotatedX
                            }
                            180 -> {
                                sourceX = srcWidth - 1 - rotatedX
                                sourceY = srcHeight - 1 - rotatedY
                            }
                            270 -> {
                                sourceX = srcWidth - 1 - rotatedY
                                sourceY = rotatedX
                            }
                            else -> {
                                sourceX = rotatedX
                                sourceY = rotatedY
                            }
                        }

                        val yIndex = sourceY * yRowStride + sourceX
                        val yVal = yBuf.get(yIndex).toInt() and 0xFF

                        val uvX = sourceX shr 1
                        val uvY = sourceY shr 1
                        val uvIndex = uvY * uvRowStride + uvX * uvPixelStride
                        val u = (uBuf.get(uvIndex).toInt() and 0xFF) - 128
                        val v = (vBuf.get(uvIndex).toInt() and 0xFF) - 128

                        val yf = yVal.toFloat()
                        var r = yf + 1.5748f * v
                        var g = yf - 0.1873f * u - 0.4681f * v
                        var b = yf + 1.8556f * u

                        if (r < 0f) r = 0f else if (r > 255f) r = 255f
                        if (g < 0f) g = 0f else if (g > 255f) g = 255f
                        if (b < 0f) b = 0f else if (b > 255f) b = 255f

                        row[base] = r.toInt()
                        row[base + 1] = g.toInt()
                        row[base + 2] = b.toInt()
                    }
                }
            }))
        }

        for (future in futures) {
            future.get()
        }

        if (bulkFloatArray != null && inputType == DataType.FLOAT32 && !isNchw) {
            var idx = 0
            for (iy in 0 until inputHeight) {
                val row = rgbRowCache[iy]
                for (ix in 0 until inputWidth) {
                    val base = ix * 3
                    bulkFloatArray[idx++] = row[base] / 255f
                    bulkFloatArray[idx++] = row[base + 1] / 255f
                    bulkFloatArray[idx++] = row[base + 2] / 255f
                }
            }
            inputBuffer.rewind()
            inputBuffer.asFloatBuffer().put(bulkFloatArray)
        } else if (!isNchw) {
            inputBuffer.rewind()
            val qScale = inputQuant.scale
            val qZero = inputQuant.zeroPoint
            for (iy in 0 until inputHeight) {
                val row = rgbRowCache[iy]
                for (ix in 0 until inputWidth) {
                    val base = ix * 3
                    putPixel(row[base], qScale, qZero)
                    putPixel(row[base + 1], qScale, qZero)
                    putPixel(row[base + 2], qScale, qZero)
                }
            }
        } else {
            inputBuffer.rewind()
            val planeSize = inputWidth * inputHeight
            val bytesPerElement = if (inputType == DataType.FLOAT32) 4 else 1
            val qScale = inputQuant.scale
            val qZero = inputQuant.zeroPoint
            for (iy in 0 until inputHeight) {
                val row = rgbRowCache[iy]
                for (ix in 0 until inputWidth) {
                    val base = ix * 3
                    val pixelIndex = iy * inputWidth + ix
                    putPixelAt((0 * planeSize + pixelIndex) * bytesPerElement, row[base], qScale, qZero)
                    putPixelAt((1 * planeSize + pixelIndex) * bytesPerElement, row[base + 1], qScale, qZero)
                    putPixelAt((2 * planeSize + pixelIndex) * bytesPerElement, row[base + 2], qScale, qZero)
                }
            }
        }
    }

    private fun putPixel(v: Int, qScale: Float, qZero: Int) {
        when (inputType) {
            DataType.FLOAT32 -> inputBuffer.putFloat(v / 255f)
            DataType.UINT8 -> inputBuffer.put(v.toByte())
            DataType.INT8 -> inputBuffer.put((v / 255f / qScale + qZero).roundToInt().coerceIn(-128, 127).toByte())
            else -> inputBuffer.putFloat(v / 255f)
        }
    }

    private fun putPixelAt(byteIndex: Int, v: Int, qScale: Float, qZero: Int) {
        when (inputType) {
            DataType.FLOAT32 -> inputBuffer.putFloat(byteIndex, v / 255f)
            DataType.UINT8 -> inputBuffer.put(byteIndex, v.toByte())
            DataType.INT8 -> inputBuffer.put(byteIndex, (v / 255f / qScale + qZero).roundToInt().coerceIn(-128, 127).toByte())
            else -> inputBuffer.putFloat(byteIndex, v / 255f)
        }
    }

    // ── Output parsing ───────────────────────────────────────────────────

    private fun readOutputToFloatArray() {
        outputBuffer.rewind()
        when (outputType) {
            DataType.FLOAT32 -> outputBuffer.asFloatBuffer().get(outputFloats)
            DataType.UINT8 -> {
                val bytes = ByteArray(outputBuffer.capacity())
                outputBuffer.get(bytes)
                val scale = outputQuant.scale
                val zero = outputQuant.zeroPoint
                for (i in bytes.indices) {
                    outputFloats[i] = ((bytes[i].toInt() and 0xFF) - zero) * scale
                }
            }
            DataType.INT8 -> {
                val bytes = ByteArray(outputBuffer.capacity())
                outputBuffer.get(bytes)
                val scale = outputQuant.scale
                val zero = outputQuant.zeroPoint
                for (i in bytes.indices) {
                    outputFloats[i] = (bytes[i].toInt() - zero) * scale
                }
            }
            else -> outputBuffer.asFloatBuffer().get(outputFloats)
        }
    }

    private fun decodeDetections(out: FloatArray, shape: IntArray, lb: Letterbox): List<Detection> {
        if (shape.size != 3) return emptyList()
        val d1 = shape[1]
        val d2 = shape[2]

        val fieldsMaybe = min(d1, d2)
        val boxesMaybe = max(d1, d2)
        if (fieldsMaybe in 6..7) {
            val fields = fieldsMaybe
            val numBoxes = boxesMaybe
            val fieldsFirst = (d1 == fields)

            fun getField(box: Int, field: Int): Float {
                val idx = if (fieldsFirst) field * numBoxes + box else box * fields + field
                return out[idx]
            }

            val detections = ArrayList<Detection>(numBoxes)
            for (i in 0 until numBoxes) {
                val score = getField(i, 4)
                if (!score.isFinite() || score < confidenceThreshold) continue

                val x1 = getField(i, 0)
                val y1 = getField(i, 1)
                val x2 = getField(i, 2)
                val y2 = getField(i, 3)
                val cls = getField(i, 5).roundToInt()

                val normalized = (max(max(x1, y1), max(x2, y2)) <= 1.5f)
                val sx1 = if (normalized) x1 * inputWidth else x1
                val sy1 = if (normalized) y1 * inputHeight else y1
                val sx2 = if (normalized) x2 * inputWidth else x2
                val sy2 = if (normalized) y2 * inputHeight else y2

                val mapped = mapFromLetterbox(sx1, sy1, sx2, sy2, lb) ?: continue
                detections.add(
                    Detection(
                        classId = cls,
                        className = labelForClassId(cls),
                        score = score,
                        left = mapped[0],
                        top = mapped[1],
                        right = mapped[2],
                        bottom = mapped[3],
                    )
                )
            }
            return detections
        }

        val boxes = max(d1, d2)
        val features = min(d1, d2)
        val featuresFirst = (d1 == features)
        if (features < 6) return emptyList()

        val numClasses = features - 4
        val detections = ArrayList<Detection>(512)

        fun getFeat(box: Int, feat: Int): Float {
            val idx = if (featuresFirst) feat * boxes + box else box * features + feat
            return out[idx]
        }

        for (b in 0 until boxes) {
            var bestScore = 0f
            var bestClass = -1
            for (c in 0 until numClasses) {
                val s = getFeat(b, 4 + c)
                if (s > bestScore) {
                    bestScore = s
                    bestClass = c
                }
            }
            if (bestClass < 0 || !bestScore.isFinite() || bestScore < confidenceThreshold) continue

            var cx = getFeat(b, 0)
            var cy = getFeat(b, 1)
            var w = getFeat(b, 2)
            var h = getFeat(b, 3)
            val normalized = (max(max(cx, cy), max(w, h)) <= 1.5f)
            if (normalized) {
                cx *= inputWidth.toFloat()
                w *= inputWidth.toFloat()
                cy *= inputHeight.toFloat()
                h *= inputHeight.toFloat()
            }

            val mapped = mapFromLetterbox(cx - w / 2f, cy - h / 2f, cx + w / 2f, cy + h / 2f, lb)
                ?: continue
            detections.add(
                Detection(
                    classId = bestClass,
                    className = labelForClassId(bestClass),
                    score = bestScore,
                    left = mapped[0],
                    top = mapped[1],
                    right = mapped[2],
                    bottom = mapped[3],
                )
            )
        }
        return detections
    }

    private fun mapFromLetterbox(
        x1: Float,
        y1: Float,
        x2: Float,
        y2: Float,
        lb: Letterbox,
    ): FloatArray? {
        val left = ((x1 - lb.padX) / lb.scale).coerceIn(0f, (lb.origW - 1).toFloat())
        val top = ((y1 - lb.padY) / lb.scale).coerceIn(0f, (lb.origH - 1).toFloat())
        val right = ((x2 - lb.padX) / lb.scale).coerceIn(0f, (lb.origW - 1).toFloat())
        val bottom = ((y2 - lb.padY) / lb.scale).coerceIn(0f, (lb.origH - 1).toFloat())
        if (right <= left || bottom <= top) return null
        return floatArrayOf(left, top, right, bottom)
    }

    private fun mapDetectionsBackToSource(
        detections: List<Detection>,
        srcWidth: Int,
        srcHeight: Int,
        rotationDegrees: Int,
    ): List<Detection> {
        val mapped = ArrayList<Detection>(detections.size)
        for (d in detections) {
            val box = when (rotationDegrees) {
                90 -> floatArrayOf(
                    d.top,
                    srcHeight.toFloat() - d.right,
                    d.bottom,
                    srcHeight.toFloat() - d.left,
                )
                180 -> floatArrayOf(
                    srcWidth.toFloat() - d.right,
                    srcHeight.toFloat() - d.bottom,
                    srcWidth.toFloat() - d.left,
                    srcHeight.toFloat() - d.top,
                )
                270 -> floatArrayOf(
                    srcWidth.toFloat() - d.bottom,
                    d.left,
                    srcWidth.toFloat() - d.top,
                    d.right,
                )
                else -> floatArrayOf(d.left, d.top, d.right, d.bottom)
            }

            val left = box[0].coerceIn(0f, (srcWidth - 1).toFloat())
            val top = box[1].coerceIn(0f, (srcHeight - 1).toFloat())
            val right = box[2].coerceIn(0f, (srcWidth - 1).toFloat())
            val bottom = box[3].coerceIn(0f, (srcHeight - 1).toFloat())
            if (right <= left || bottom <= top) continue

            mapped.add(
                d.copy(
                    left = left,
                    top = top,
                    right = right,
                    bottom = bottom,
                )
            )
        }
        return mapped
    }

    private fun normalizeRotationDegrees(rotationDegrees: Int): Int {
        return when (((rotationDegrees % 360) + 360) % 360) {
            90 -> 90
            180 -> 180
            270 -> 270
            else -> 0
        }
    }

    private fun nonMaxSuppression(
        detections: List<Detection>,
        iouThresh: Float,
        limit: Int,
    ): List<Detection> {
        if (detections.isEmpty()) return emptyList()

        val byClass = detections.groupBy { it.classId }
        val all = ArrayList<Detection>(min(limit, detections.size))
        for ((_, classDetections) in byClass) {
            val sorted = classDetections.sortedByDescending { it.score }
            for (d in sorted) {
                var keep = true
                for (kept in all) {
                    if (kept.classId == d.classId && iou(d, kept) > iouThresh) {
                        keep = false
                        break
                    }
                }
                if (keep) {
                    all.add(d)
                    if (all.size >= limit) break
                }
            }
            if (all.size >= limit) break
        }
        return all.sortedByDescending { it.score }
    }

    private fun iou(a: Detection, b: Detection): Float {
        val interLeft = max(a.left, b.left)
        val interTop = max(a.top, b.top)
        val interRight = min(a.right, b.right)
        val interBottom = min(a.bottom, b.bottom)
        val interWidth = max(0f, interRight - interLeft)
        val interHeight = max(0f, interBottom - interTop)
        val interArea = interWidth * interHeight

        val areaA = max(0f, a.right - a.left) * max(0f, a.bottom - a.top)
        val areaB = max(0f, b.right - b.left) * max(0f, b.bottom - b.top)
        val union = areaA + areaB - interArea
        return if (union <= 0f) 0f else interArea / union
    }

    private fun makeLetterbox(origW: Int, origH: Int, inW: Int, inH: Int): Letterbox {
        val scale = min(inW.toFloat() / origW, inH.toFloat() / origH)
        val resizedW = floor(origW * scale).toInt().coerceAtLeast(1)
        val resizedH = floor(origH * scale).toInt().coerceAtLeast(1)
        return Letterbox(
            scale = scale,
            padX = (inW - resizedW) / 2f,
            padY = (inH - resizedH) / 2f,
            origW = origW,
            origH = origH,
            resizedW = resizedW,
            resizedH = resizedH,
        )
    }

    override fun close() {
        try {
            interpreter.close()
        } catch (_: Throwable) {
        }
        try {
            gpuDelegate?.close()
        } catch (_: Throwable) {
        }
        try {
            (nnapiDelegate as? AutoCloseable)?.close()
        } catch (_: Throwable) {
        }
        preprocPool.shutdownNow()
    }

    private fun loadModelFile(am: AssetManager, path: String): ByteBuffer {
        val afd = am.openFd(path)
        FileInputStream(afd.fileDescriptor).use {
            return it.channel.map(
                FileChannel.MapMode.READ_ONLY,
                afd.startOffset,
                afd.declaredLength,
            )
        }
    }

    private fun numElements(shape: IntArray): Int {
        var n = 1
        for (v in shape) {
            n *= v
        }
        return n
    }

    private fun labelForClassId(id: Int): String {
        return if (id in labels.indices) labels[id] else "cls_$id"
    }

    companion object {
        private const val TAG = "YoloTfliteDetector"
    }
}