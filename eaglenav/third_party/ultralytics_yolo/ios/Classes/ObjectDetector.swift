// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//
//  Patched ObjectDetector.swift
//  Supports both Vision-native detection outputs (VNRecognizedObjectObservation)
//  and raw Core ML multi-array outputs such as YOLO26 exports created with nms=False.
//

import CoreML
import Foundation
import UIKit
import Vision

class ObjectDetector: BasePredictor {
  override func setConfidenceThreshold(confidence: Double) {
    confidenceThreshold = confidence
    detector.featureProvider = ThresholdProvider(
      iouThreshold: iouThreshold, confidenceThreshold: confidenceThreshold)
  }

  override func setIouThreshold(iou: Double) {
    iouThreshold = iou
    detector.featureProvider = ThresholdProvider(
      iouThreshold: iouThreshold, confidenceThreshold: confidenceThreshold)
  }

  override func processObservations(for request: VNRequest, error: Error?) {
    if let results = request.results as? [VNRecognizedObjectObservation] {
      deliverResult(boxes: makeBoxes(from: results))
      return
    }

    if let multiArray = firstSupportedMultiArray(from: request.results) {
      deliverResult(boxes: decodeRawDetections(from: multiArray))
      return
    }

    if let error {
      print("ObjectDetector: Vision request failed: \(error.localizedDescription)")
    } else {
      let resultTypes = request.results?.map { String(describing: type(of: $0)) } ?? []
      print("ObjectDetector: Unsupported request result types: \(resultTypes)")
    }
  }

  override func predictOnImage(image: CIImage) -> YOLOResult {
    let requestHandler = VNImageRequestHandler(ciImage: image, options: [:])
    guard let request = visionRequest else {
      return YOLOResult(orig_shape: inputSize ?? .zero, boxes: [], speed: 0, names: labels)
    }

    let imageWidth = image.extent.width
    let imageHeight = image.extent.height
    self.inputSize = CGSize(width: imageWidth, height: imageHeight)
    let start = Date()

    var boxes = [Box]()

    do {
      try requestHandler.perform([request])
      if let results = request.results as? [VNRecognizedObjectObservation] {
        boxes = makeBoxes(from: results)
      } else if let multiArray = firstSupportedMultiArray(from: request.results) {
        boxes = decodeRawDetections(from: multiArray)
      }
    } catch {
      print("ObjectDetector: predictOnImage failed: \(error.localizedDescription)")
    }

    let end = Date().timeIntervalSince(start)
    var result = YOLOResult(orig_shape: inputSize ?? .zero, boxes: boxes, speed: end, names: labels)
    if let originalImageData = self.originalImageData {
      result.originalImage = UIImage(data: originalImageData)
    }
    return result
  }

  private func makeBoxes(from results: [VNRecognizedObjectObservation]) -> [Box] {
    guard let inputSize else { return [] }

    var boxes = [Box]()
    let maxDetections = min(results.count, self.numItemsThreshold)

    for i in 0..<maxDetections {
      let prediction = results[i]
      guard let topLabel = prediction.labels.first else { continue }

      let invertedBox = CGRect(
        x: prediction.boundingBox.minX,
        y: 1 - prediction.boundingBox.maxY,
        width: prediction.boundingBox.width,
        height: prediction.boundingBox.height)
      let imageRect = VNImageRectForNormalizedRect(
        invertedBox,
        Int(inputSize.width),
        Int(inputSize.height))

      let label = topLabel.identifier
      let index = self.labels.firstIndex(of: label) ?? 0
      let confidence = topLabel.confidence
      let box = Box(index: index, cls: label, conf: confidence, xywh: imageRect, xywhn: invertedBox)
      boxes.append(box)
    }

    return boxes
  }

  private func deliverResult(boxes: [Box]) {
    if self.t1 < 10.0 {
      self.t2 = self.t1 * 0.05 + self.t2 * 0.95
    }
    self.t4 = (CACurrentMediaTime() - self.t3) * 0.05 + self.t4 * 0.95
    self.t3 = CACurrentMediaTime()

    self.currentOnInferenceTimeListener?.on(inferenceTime: self.t2 * 1000, fpsRate: 1 / self.t4)

    var result = YOLOResult(
      orig_shape: inputSize ?? .zero,
      boxes: boxes,
      speed: self.t2,
      fps: 1 / self.t4,
      names: labels)

    if let originalImageData = self.originalImageData {
      result.originalImage = UIImage(data: originalImageData)
    }

    self.currentOnResultsListener?.on(result: result)
  }

  private func firstSupportedMultiArray(from results: [Any]?) -> MLMultiArray? {
    guard let observations = results as? [VNCoreMLFeatureValueObservation] else {
      return nil
    }

    for observation in observations {
      if let multiArray = observation.featureValue.multiArrayValue {
        return multiArray
      }
    }
    return nil
  }

  private func decodeRawDetections(from multiArray: MLMultiArray) -> [Box] {
    let shape = multiArray.shape.map { $0.intValue }
    guard !shape.isEmpty else {
      print("ObjectDetector: Empty multi-array output")
      return []
    }

    let channelCandidates = [labels.count + 4, labels.count + 5]
    let channelDimensionIndex = shape.firstIndex(where: { channelCandidates.contains($0) })
    guard let channelDim = channelDimensionIndex else {
      print("ObjectDetector: Unsupported raw output shape \(shape) for \(labels.count) labels")
      return []
    }

    let channelCount = shape[channelDim]
    let hasObjectness = (channelCount == labels.count + 5)
    let classStartIndex = hasObjectness ? 5 : 4

    let boxDimensionIndex = shape.enumerated().first { index, value in
      index != channelDim && value > 1
    }?.offset

    guard let boxDim = boxDimensionIndex else {
      print("ObjectDetector: Could not infer box dimension from raw output shape \(shape)")
      return []
    }

    let boxCount = shape[boxDim]
    let modelWidth = max(Float(modelInputSize.width), 1)
    let modelHeight = max(Float(modelInputSize.height), 1)
    let originalWidth = max(Float(inputSize?.width ?? CGFloat(modelInputSize.width)), 1)
    let originalHeight = max(Float(inputSize?.height ?? CGFloat(modelInputSize.height)), 1)
    let scaleX = originalWidth / modelWidth
    let scaleY = originalHeight / modelHeight

    struct Candidate {
      let classIndex: Int
      let className: String
      let confidence: Float
      let pixelRect: CGRect
      let normalizedRect: CGRect
    }

    var candidates = [Candidate]()
    candidates.reserveCapacity(min(boxCount, self.numItemsThreshold * 4))

    for boxIndex in 0..<boxCount {
      guard
        let rawCx = value(from: multiArray, shape: shape, channelDim: channelDim, boxDim: boxDim, channel: 0, box: boxIndex),
        let rawCy = value(from: multiArray, shape: shape, channelDim: channelDim, boxDim: boxDim, channel: 1, box: boxIndex),
        let rawW = value(from: multiArray, shape: shape, channelDim: channelDim, boxDim: boxDim, channel: 2, box: boxIndex),
        let rawH = value(from: multiArray, shape: shape, channelDim: channelDim, boxDim: boxDim, channel: 3, box: boxIndex)
      else {
        continue
      }

      let coordMagnitude = max(abs(rawCx), abs(rawCy), abs(rawW), abs(rawH))
      let coordinatesAreNormalized = coordMagnitude <= 2.5

      let cx = coordinatesAreNormalized ? rawCx * modelWidth : rawCx
      let cy = coordinatesAreNormalized ? rawCy * modelHeight : rawCy
      let w = coordinatesAreNormalized ? rawW * modelWidth : rawW
      let h = coordinatesAreNormalized ? rawH * modelHeight : rawH

      let objectness: Float
      if hasObjectness {
        objectness = value(
          from: multiArray,
          shape: shape,
          channelDim: channelDim,
          boxDim: boxDim,
          channel: 4,
          box: boxIndex) ?? 0
      } else {
        objectness = 1
      }

      var bestClassIndex = -1
      var bestConfidence: Float = 0
      for labelIndex in 0..<labels.count {
        guard let classScore = value(
          from: multiArray,
          shape: shape,
          channelDim: channelDim,
          boxDim: boxDim,
          channel: classStartIndex + labelIndex,
          box: boxIndex)
        else {
          continue
        }

        let combinedConfidence = classScore * objectness
        if combinedConfidence > bestConfidence {
          bestConfidence = combinedConfidence
          bestClassIndex = labelIndex
        }
      }

      if bestClassIndex < 0 || bestConfidence < Float(confidenceThreshold) {
        continue
      }

      let x1 = max(0, min(cx - (w / 2), modelWidth))
      let y1 = max(0, min(cy - (h / 2), modelHeight))
      let clippedW = max(0, min(w, modelWidth - x1))
      let clippedH = max(0, min(h, modelHeight - y1))

      if clippedW <= 0 || clippedH <= 0 {
        continue
      }

      let normalizedRect = CGRect(
        x: CGFloat(x1 / modelWidth),
        y: CGFloat(y1 / modelHeight),
        width: CGFloat(clippedW / modelWidth),
        height: CGFloat(clippedH / modelHeight))

      let pixelRect = CGRect(
        x: CGFloat(x1 * scaleX),
        y: CGFloat(y1 * scaleY),
        width: CGFloat(clippedW * scaleX),
        height: CGFloat(clippedH * scaleY))

      candidates.append(
        Candidate(
          classIndex: bestClassIndex,
          className: labels[bestClassIndex],
          confidence: bestConfidence,
          pixelRect: pixelRect,
          normalizedRect: normalizedRect))
    }

    if candidates.isEmpty {
      return []
    }

    candidates.sort { lhs, rhs in
      if lhs.confidence == rhs.confidence {
        return lhs.classIndex < rhs.classIndex
      }
      return lhs.confidence > rhs.confidence
    }

    var selected = [Candidate]()
    selected.reserveCapacity(min(candidates.count, self.numItemsThreshold))

    for candidate in candidates {
      var shouldKeep = true
      for kept in selected where kept.classIndex == candidate.classIndex {
        if iou(candidate.normalizedRect, kept.normalizedRect) > CGFloat(iouThreshold) {
          shouldKeep = false
          break
        }
      }

      if shouldKeep {
        selected.append(candidate)
        if selected.count >= self.numItemsThreshold {
          break
        }
      }
    }

    return selected.enumerated().map { offset, detection in
      Box(
        index: detection.classIndex,
        cls: detection.className,
        conf: detection.confidence,
        xywh: detection.pixelRect,
        xywhn: detection.normalizedRect)
    }
  }

  private func value(
    from multiArray: MLMultiArray,
    shape: [Int],
    channelDim: Int,
    boxDim: Int,
    channel: Int,
    box: Int
  ) -> Float? {
    guard channelDim < shape.count, boxDim < shape.count else { return nil }

    var indices = Array(repeating: 0, count: shape.count)
    indices[channelDim] = channel
    indices[boxDim] = box

    let strides = multiArray.strides.map { $0.intValue }
    let linearIndex = zip(indices, strides).reduce(0) { partial, element in
      partial + (element.0 * element.1)
    }

    switch multiArray.dataType {
    case .float32:
      let pointer = multiArray.dataPointer.assumingMemoryBound(to: Float32.self)
      return pointer[linearIndex]
    case .double:
      let pointer = multiArray.dataPointer.assumingMemoryBound(to: Double.self)
      return Float(pointer[linearIndex])
    case .float16:
      let pointer = multiArray.dataPointer.assumingMemoryBound(to: UInt16.self)
      return Float(Float16(bitPattern: pointer[linearIndex]))
    default:
      return nil
    }
  }

  private func iou(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    if intersection.isNull || intersection.isEmpty {
      return 0
    }

    let intersectionArea = intersection.width * intersection.height
    let lhsArea = lhs.width * lhs.height
    let rhsArea = rhs.width * rhs.height
    let unionArea = lhsArea + rhsArea - intersectionArea
    if unionArea <= 0 {
      return 0
    }
    return intersectionArea / unionArea
  }
}
