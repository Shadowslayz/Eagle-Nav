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
import java.nio.FloatBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.Future
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Maximum-throughput YOLO TFLite detector for Snapdragon 8 Gen 2.
 *
 * - GPU delegate with FP16 forced (Adreno 740)
 * - NNAPI sustained-speed fallback (Hexagon DSP)
 * - All available CPU cores for XNNPACK fallback
 * - Parallel YUV→RGB across all big cores
 * - Bulk float array → ByteBuffer copy (no per-pixel puts)
 * - Pre-allocated everything to zero GC pressure
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
    val scale: Float, val padX: Float, val padY: Float,
    val origW: Int, val origH: Int, val resizedW: Int, val resizedH: Int,
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

    // GPU first — force FP16 for max Adreno 740 throughput.
    try {
      val compatList = CompatibilityList()
      if (compatList.isDelegateSupportedOnThisDevice) {
        val gpuOptions = GpuDelegate.Options()
          .setPrecisionLossAllowed(true)   // FP16 — 2× throughput on Adreno 740
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

    // NNAPI fallback — Hexagon DSP.
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

  var confidenceThreshold: Float = 0.22f
  var iouThreshold: Float = 0.5f
  var maxDetections: Int = 25

  // Use all big cores for preprocessing.
  private val preprocWorkerCount = Runtime.getRuntime().availableProcessors().coerceIn(4, 8)
  private val preprocPool = Executors.newFixedThreadPool(preprocWorkerCount)

  // Pre-allocated bulk float array for NHWC input — avoids per-pixel putFloat().
  // For float32 NHWC: size = H * W * 3
  private val bulkFloatArray: FloatArray?

  // Pre-allocated RGB cache per row for parallel fill.
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

    // Bulk float array for fast packing (float32 only, NHWC).
    bulkFloatArray = if (inputType == DataType.FLOAT32 && !isNchw) {
      FloatArray(inputHeight * inputWidth * 3)
    } else null

    rgbRowCache = Array(inputHeight) { IntArray(inputWidth * 3) }
  }

  fun detect(image: Image): List<Detection> {
    val origW = image.width
    val origH = image.height
    if (origW <= 0 || origH <= 0) return emptyList()

    val lb = makeLetterbox(origW, origH, inputWidth, inputHeight)

    try {
      fillInputParallel(image, lb)
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

    val raw = decodeDetections(outputFloats, outputShape, lb)
    if (raw.isEmpty()) return emptyList()
    return nonMaxSuppression(raw, iouThreshold, maxDetections)
  }

  // ── Parallel preprocessing with bulk copy ─────────────────────────────

  private fun fillInputParallel(image: Image, lb: Letterbox) {
    val yPlane = image.planes[0]
    val uPlane = image.planes[1]
    val vPlane = image.planes[2]

    val yBuf = yPlane.buffer
    val uBuf = uPlane.buffer
    val vBuf = vPlane.buffer

    val yRowStride = yPlane.rowStride
    val uvRowStride = uPlane.rowStride
    val uvPixelStride = uPlane.pixelStride

    val xMap = IntArray(inputWidth) { -1 }
    val yMap = IntArray(inputHeight) { -1 }

    for (ix in 0 until inputWidth) {
      val xIn = ix.toFloat() - lb.padX
      if (xIn >= 0f && xIn < lb.resizedW.toFloat()) {
        xMap[ix] = (xIn / lb.scale).toInt().coerceIn(0, lb.origW - 1)
      }
    }
    for (iy in 0 until inputHeight) {
      val yIn = iy.toFloat() - lb.padY
      if (yIn >= 0f && yIn < lb.resizedH.toFloat()) {
        yMap[iy] = (yIn / lb.scale).toInt().coerceIn(0, lb.origH - 1)
      }
    }

    // Phase 1: Parallel YUV→RGB into rgbRowCache across all cores.
    val rowsPerWorker = (inputHeight + preprocWorkerCount - 1) / preprocWorkerCount
    val futures = ArrayList<Future<*>>(preprocWorkerCount)

    for (w in 0 until preprocWorkerCount) {
      val startRow = w * rowsPerWorker
      val endRow = min((w + 1) * rowsPerWorker, inputHeight)
      if (startRow >= endRow) continue
      futures.add(preprocPool.submit(Callable {
        for (iy in startRow until endRow) {
          val oy = yMap[iy]
          val row = rgbRowCache[iy]
          for (ix in 0 until inputWidth) {
            val ox = xMap[ix]
            val base = ix * 3
            if (ox == -1 || oy == -1) {
              row[base] = 0; row[base + 1] = 0; row[base + 2] = 0
            } else {
              val yIdx = oy * yRowStride + ox
              val yVal = yBuf.get(yIdx).toInt() and 0xFF
              val uvX = ox shr 1; val uvY = oy shr 1
              val uvIdx = uvY * uvRowStride + uvX * uvPixelStride
              val u = (uBuf.get(uvIdx).toInt() and 0xFF) - 128
              val v = (vBuf.get(uvIdx).toInt() and 0xFF) - 128
              val yf = yVal.toFloat()
              var r = yf + 1.370705f * v
              var g = yf - 0.337633f * u - 0.698001f * v
              var b = yf + 1.732446f * u
              if (r < 0f) r = 0f else if (r > 255f) r = 255f
              if (g < 0f) g = 0f else if (g > 255f) g = 255f
              if (b < 0f) b = 0f else if (b > 255f) b = 255f
              row[base] = r.toInt(); row[base + 1] = g.toInt(); row[base + 2] = b.toInt()
            }
          }
        }
      }))
    }
    for (f in futures) f.get()

    // Phase 2: Pack into input buffer.
    // For float32 NHWC: bulk-fill a float array then copy with one put() call.
    // This is ~3× faster than per-pixel putFloat() due to JNI overhead.
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
      // Non-float32 NHWC.
      inputBuffer.rewind()
      val qScale = inputQuant.scale; val qZero = inputQuant.zeroPoint
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
      // NCHW layout — planar write.
      inputBuffer.rewind()
      val planeSize = inputWidth * inputHeight
      val bytesPerElement = if (inputType == DataType.FLOAT32) 4 else 1
      val qScale = inputQuant.scale; val qZero = inputQuant.zeroPoint
      for (iy in 0 until inputHeight) {
        val row = rgbRowCache[iy]
        for (ix in 0 until inputWidth) {
          val base = ix * 3
          val pixelIdx = iy * inputWidth + ix
          putPixelAt((0 * planeSize + pixelIdx) * bytesPerElement, row[base], qScale, qZero)
          putPixelAt((1 * planeSize + pixelIdx) * bytesPerElement, row[base + 1], qScale, qZero)
          putPixelAt((2 * planeSize + pixelIdx) * bytesPerElement, row[base + 2], qScale, qZero)
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

  // ── Output parsing ──────────────────────────────────────────────────────

  private fun readOutputToFloatArray() {
    outputBuffer.rewind()
    when (outputType) {
      DataType.FLOAT32 -> outputBuffer.asFloatBuffer().get(outputFloats)
      DataType.UINT8 -> {
        val bytes = ByteArray(outputBuffer.capacity())
        outputBuffer.get(bytes)
        val s = outputQuant.scale; val z = outputQuant.zeroPoint
        for (i in bytes.indices) outputFloats[i] = ((bytes[i].toInt() and 0xFF) - z) * s
      }
      DataType.INT8 -> {
        val bytes = ByteArray(outputBuffer.capacity())
        outputBuffer.get(bytes)
        val s = outputQuant.scale; val z = outputQuant.zeroPoint
        for (i in bytes.indices) outputFloats[i] = (bytes[i].toInt() - z) * s
      }
      else -> outputBuffer.asFloatBuffer().get(outputFloats)
    }
  }

  private fun decodeDetections(out: FloatArray, shape: IntArray, lb: Letterbox): List<Detection> {
    if (shape.size != 3) return emptyList()
    val d1 = shape[1]; val d2 = shape[2]

    val fieldsMaybe = min(d1, d2); val boxesMaybe = max(d1, d2)
    if (fieldsMaybe in 6..7) {
      val fields = fieldsMaybe; val numBoxes = boxesMaybe; val fieldsFirst = (d1 == fields)
      fun getField(box: Int, field: Int): Float {
        val idx = if (fieldsFirst) field * numBoxes + box else box * fields + field
        return out[idx]
      }
      val dets = ArrayList<Detection>(numBoxes)
      for (i in 0 until numBoxes) {
        val score = getField(i, 4)
        if (!score.isFinite() || score < confidenceThreshold) continue
        val x1 = getField(i, 0); val y1 = getField(i, 1)
        val x2 = getField(i, 2); val y2 = getField(i, 3)
        val cls = getField(i, 5).roundToInt()
        val norm = (max(max(x1, y1), max(x2, y2)) <= 1.5f)
        val sx1 = if (norm) x1 * inputWidth else x1; val sy1 = if (norm) y1 * inputHeight else y1
        val sx2 = if (norm) x2 * inputWidth else x2; val sy2 = if (norm) y2 * inputHeight else y2
        val mapped = mapFromLetterbox(sx1, sy1, sx2, sy2, lb) ?: continue
        dets.add(Detection(cls, labelForClassId(cls), score, mapped[0], mapped[1], mapped[2], mapped[3]))
      }
      return dets
    }

    val boxes = max(d1, d2); val features = min(d1, d2); val featuresFirst = (d1 == features)
    if (features < 6) return emptyList()
    val numClasses = features - 4
    val dets = ArrayList<Detection>(512)
    fun getFeat(box: Int, feat: Int): Float {
      val idx = if (featuresFirst) feat * boxes + box else box * features + feat
      return out[idx]
    }
    for (b in 0 until boxes) {
      var bestScore = 0f; var bestClass = -1
      for (c in 0 until numClasses) {
        val s = getFeat(b, 4 + c)
        if (s > bestScore) { bestScore = s; bestClass = c }
      }
      if (bestClass < 0 || !bestScore.isFinite() || bestScore < confidenceThreshold) continue
      var cx = getFeat(b, 0); var cy = getFeat(b, 1); var w = getFeat(b, 2); var h = getFeat(b, 3)
      val normalized = (max(max(cx, cy), max(w, h)) <= 1.5f)
      if (normalized) { cx *= inputWidth.toFloat(); w *= inputWidth.toFloat(); cy *= inputHeight.toFloat(); h *= inputHeight.toFloat() }
      val mapped = mapFromLetterbox(cx - w / 2f, cy - h / 2f, cx + w / 2f, cy + h / 2f, lb) ?: continue
      dets.add(Detection(bestClass, labelForClassId(bestClass), bestScore, mapped[0], mapped[1], mapped[2], mapped[3]))
    }
    return dets
  }

  private fun mapFromLetterbox(x1: Float, y1: Float, x2: Float, y2: Float, lb: Letterbox): FloatArray? {
    val left = ((x1 - lb.padX) / lb.scale).coerceIn(0f, (lb.origW - 1).toFloat())
    val top = ((y1 - lb.padY) / lb.scale).coerceIn(0f, (lb.origH - 1).toFloat())
    val right = ((x2 - lb.padX) / lb.scale).coerceIn(0f, (lb.origW - 1).toFloat())
    val bottom = ((y2 - lb.padY) / lb.scale).coerceIn(0f, (lb.origH - 1).toFloat())
    if (right <= left || bottom <= top) return null
    return floatArrayOf(left, top, right, bottom)
  }

  private fun nonMaxSuppression(dets: List<Detection>, iouThresh: Float, limit: Int): List<Detection> {
    if (dets.isEmpty()) return emptyList()
    val byClass = dets.groupBy { it.classId }
    val all = ArrayList<Detection>(min(limit, dets.size))
    for ((_, classDets) in byClass) {
      val sorted = classDets.sortedByDescending { it.score }
      for (d in sorted) {
        var keep = true
        for (s in all) { if (s.classId == d.classId && iou(d, s) > iouThresh) { keep = false; break } }
        if (keep) { all.add(d); if (all.size >= limit) break }
      }
      if (all.size >= limit) break
    }
    return all.sortedByDescending { it.score }
  }

  private fun iou(a: Detection, b: Detection): Float {
    val iL = max(a.left, b.left); val iT = max(a.top, b.top)
    val iR = min(a.right, b.right); val iB = min(a.bottom, b.bottom)
    val iW = max(0f, iR - iL); val iH = max(0f, iB - iT); val iA = iW * iH
    val aA = max(0f, a.right - a.left) * max(0f, a.bottom - a.top)
    val bA = max(0f, b.right - b.left) * max(0f, b.bottom - b.top)
    val u = aA + bA - iA; return if (u <= 0f) 0f else iA / u
  }

  private fun makeLetterbox(origW: Int, origH: Int, inW: Int, inH: Int): Letterbox {
    val s = min(inW.toFloat() / origW, inH.toFloat() / origH)
    val rW = floor(origW * s).toInt().coerceAtLeast(1); val rH = floor(origH * s).toInt().coerceAtLeast(1)
    return Letterbox(s, (inW - rW) / 2f, (inH - rH) / 2f, origW, origH, rW, rH)
  }

  override fun close() {
    try { interpreter.close() } catch (_: Throwable) {}
    try { gpuDelegate?.close() } catch (_: Throwable) {}
    try { (nnapiDelegate as? AutoCloseable)?.close() } catch (_: Throwable) {}
    preprocPool.shutdownNow()
  }

  private fun loadModelFile(am: AssetManager, path: String): ByteBuffer {
    val afd = am.openFd(path)
    FileInputStream(afd.fileDescriptor).use { return it.channel.map(FileChannel.MapMode.READ_ONLY, afd.startOffset, afd.declaredLength) }
  }

  private fun numElements(shape: IntArray): Int { var n = 1; for (v in shape) n *= v; return n }
  private fun labelForClassId(id: Int) = if (id in labels.indices) labels[id] else "cls_$id"

  companion object { private const val TAG = "YoloTfliteDetector" }
}