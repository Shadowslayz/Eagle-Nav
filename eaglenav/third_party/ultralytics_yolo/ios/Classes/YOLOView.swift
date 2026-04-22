// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import AVFoundation
import UIKit
import Vision
import simd

@MainActor
public class YOLOView: UIView, VideoCaptureDelegate {
  func onInferenceTime(speed: Double, fps: Double) {
    self.currentFps = fps
    self.currentProcessingTime = speed

    if showUIControls {
      DispatchQueue.main.async {
        self.labelFPS.text = String(format: "%.1f FPS - %.1f ms", fps, speed)
      }
    }
  }

  func onPredict(result: YOLOResult) {
    if !shouldRunInference() {
      return
    }

    showBoxes(predictions: result)
    onDetection?(result)

    if let streamCallback = onStream {
      if shouldProcessFrame() {
        updateLastInferenceTime()

        let streamData = convertResultToStreamData(result)
        var enhancedStreamData = streamData
        enhancedStreamData["timestamp"] = Int64(Date().timeIntervalSince1970 * 1000)
        enhancedStreamData["frameNumber"] = frameNumberCounter
        frameNumberCounter += 1

        streamCallback(enhancedStreamData)
      }
    }

    if task == .segment {
      DispatchQueue.main.async {
        if let maskImage = result.masks?.combinedMask {
          guard let maskLayer = self.maskLayer else { return }

          maskLayer.isHidden = false
          maskLayer.frame = self.overlayLayer.bounds
          maskLayer.contents = maskImage

          self.videoCapture.predictor.isUpdating = false
        } else {
          self.videoCapture.predictor.isUpdating = false
        }
      }
    } else if task == .classify {
      self.overlayYOLOClassificationsCALayer(on: self, result: result)
    } else if task == .pose {
      self.removeAllSubLayers(parentLayer: poseLayer)
      var keypointList = [[(x: Float, y: Float)]]()
      var confsList = [[Float]]()

      for keypoint in result.keypointsList {
        keypointList.append(keypoint.xyn)
        confsList.append(keypoint.conf)
      }
      guard let poseLayer = poseLayer else { return }
      drawKeypoints(
        keypointsList: keypointList,
        confsList: confsList,
        boundingBoxes: result.boxes,
        on: poseLayer,
        imageViewSize: overlayLayer.frame.size,
        originalImageSize: result.orig_shape
      )
    } else if task == .obb {
      guard let obbLayer = obbLayer else { return }
      let obbDetections = result.obb
      self.obbRenderer.drawObbDetectionsWithReuse(
        obbDetections: obbDetections,
        on: obbLayer,
        imageViewSize: self.overlayLayer.frame.size,
        originalImageSize: result.orig_shape,
        lineWidth: 3
      )
    }
  }

  var onDetection: ((YOLOResult) -> Void)?

  private var streamConfig: YOLOStreamConfig?
  var onStream: (([String: Any]) -> Void)?

  // Cache of LiDAR distance text per box index, populated in showBoxes()
  // and read by convertResultToStreamData() to expose to Flutter.
  var lastDistanceByBoxIndex: [Int: String] = [:]

  private var frameNumberCounter: Int64 = 0
  private var lastInferenceTime: TimeInterval = 0
  private var targetFrameInterval: TimeInterval? = nil
  private var throttleInterval: TimeInterval? = nil
  private var inferenceFrameInterval: TimeInterval? = nil
  private var frameSkipCount: Int = 0
  private var targetSkipFrames: Int = 0

  private var currentFps: Double = 0.0
  private var currentProcessingTime: Double = 0.0

  private var videoCapture: VideoCapture
  private var busy = false
  private var currentBuffer: CVPixelBuffer?
  var framesDone = 0
  var t0 = 0.0
  var t1 = 0.0
  var t2 = 0.0
  var t3 = CACurrentMediaTime()
  var t4 = 0.0
  var task = YOLOTask.detect
  var colors: [String: UIColor] = [:]
  var modelName: String = ""
  var classes: [String] = []
  let maxBoundingBoxViews = 100
  var boundingBoxViews = [BoundingBoxView]()
  public var sliderNumItems = UISlider()
  public var labelSliderNumItems = UILabel()
  public var sliderConf = UISlider()
  public var labelSliderConf = UILabel()
  public var sliderIoU = UISlider()
  public var labelSliderIoU = UILabel()
  public var labelName = UILabel()
  public var labelFPS = UILabel()
  public var labelZoom = UILabel()
  public var activityIndicator = UIActivityIndicatorView()
  public var playButton = UIButton()
  public var pauseButton = UIButton()
  public var switchCameraButton = UIButton()
  public var toolbar = UIView()
  let selection = UISelectionFeedbackGenerator()
  private var overlayLayer = CALayer()
  private var maskLayer: CALayer?
  private var poseLayer: CALayer?
  private var obbLayer: CALayer?

  private var _showUIControls: Bool = false

  public var showUIControls: Bool {
    get { return _showUIControls }
    set {
      _showUIControls = newValue
      updateUIControlsVisibility()
    }
  }

  private var _showOverlays: Bool = true

  public var showOverlays: Bool {
    get { return _showOverlays }
    set {
      _showOverlays = newValue
    }
  }

  let obbRenderer = OBBRenderer()

  private let minimumZoom: CGFloat = 1.0
  private let maximumZoom: CGFloat = 10.0
  private var lastZoomFactor: CGFloat = 1.0

  public var onZoomChanged: ((CGFloat) -> Void)?

  public var capturedImage: UIImage?
  private var photoCaptureCompletion: ((UIImage?) -> Void)?

  public init(
    frame: CGRect,
    modelPathOrName: String,
    task: YOLOTask
  ) {
    self.videoCapture = VideoCapture()
    super.init(frame: frame)
    setModel(modelPathOrName: modelPathOrName, task: task)
    setUpOrientationChangeNotification()
    self.setUpBoundingBoxViews()
    self.setupUI()
    self.videoCapture.delegate = self
    self.showUIControls = false
    start(position: .back)
    setupOverlayLayer()
  }

  required init?(coder: NSCoder) {
    self.videoCapture = VideoCapture()
    super.init(coder: coder)
  }

  public override func awakeFromNib() {
    super.awakeFromNib()
    Task { @MainActor in
      setUpOrientationChangeNotification()
      setUpBoundingBoxViews()
      setupUI()
      videoCapture.delegate = self
      self.showUIControls = false
      start(position: .back)
      setupOverlayLayer()
    }
  }

  public func setModel(
    modelPathOrName: String,
    task: YOLOTask,
    completion: ((Result<Void, Error>) -> Void)? = nil
  ) {
    activityIndicator.startAnimating()
    boundingBoxViews.forEach { box in
      box.hide()
    }
    removeClassificationLayers()

    self.task = task
    setupSublayers()

    var modelURL: URL?
    let lowercasedPath = modelPathOrName.lowercased()
    let fileManager = FileManager.default

    if lowercasedPath.hasSuffix(".mlmodel") || lowercasedPath.hasSuffix(".mlpackage")
      || lowercasedPath.hasSuffix(".mlmodelc")
    {
      let possibleURL = URL(fileURLWithPath: modelPathOrName)
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: possibleURL.path, isDirectory: &isDirectory) {
        modelURL = possibleURL
        print("YOLOView: Found model at: \(possibleURL.path) (isDirectory: \(isDirectory.boolValue))")
      }
    } else {
      if let compiledURL = Bundle.main.url(forResource: modelPathOrName, withExtension: "mlmodelc") {
        modelURL = compiledURL
      } else if let packageURL = Bundle.main.url(forResource: modelPathOrName, withExtension: "mlpackage") {
        modelURL = packageURL
      }
    }

    guard let unwrappedModelURL = modelURL else {
      let error = NSError(
        domain: "YOLOView",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "Model file not found: \(modelPathOrName)"]
      )
      print("YOLOView Error: \(error.localizedDescription)")
      self.videoCapture.predictor = nil
      self.activityIndicator.stopAnimating()
      self.labelName.text = "Model Missing"
      completion?(.failure(error))
      return
    }

    modelName = unwrappedModelURL.deletingPathExtension().lastPathComponent

    func handleSuccess(predictor: Predictor) {
      if self.videoCapture.predictor != nil {
        self.videoCapture.predictor = nil
      }

      self.videoCapture.predictor = predictor

      if let basePredictor = predictor as? BasePredictor {
        basePredictor.streamConfig = self.streamConfig
      }

      self.activityIndicator.stopAnimating()
      self.labelName.text = modelName
      completion?(.success(()))
    }

    func handleFailure(_ error: Error) {
      print("Failed to load model with error: \(error)")
      self.activityIndicator.stopAnimating()
      completion?(.failure(error))
    }

    switch task {
    case .classify:
      Classifier.create(unwrappedModelURL: unwrappedModelURL, isRealTime: true) { result in
        switch result {
        case .success(let predictor):
          handleSuccess(predictor: predictor)
        case .failure(let error):
          handleFailure(error)
        }
      }

    case .segment:
      Segmenter.create(unwrappedModelURL: unwrappedModelURL, isRealTime: true) { result in
        switch result {
        case .success(let predictor):
          handleSuccess(predictor: predictor)
        case .failure(let error):
          handleFailure(error)
        }
      }

    case .pose:
      PoseEstimater.create(unwrappedModelURL: unwrappedModelURL, isRealTime: true) { result in
        switch result {
        case .success(let predictor):
          handleSuccess(predictor: predictor)
        case .failure(let error):
          handleFailure(error)
        }
      }

    case .obb:
      ObbDetector.create(unwrappedModelURL: unwrappedModelURL, isRealTime: true) { [weak self] result in
        switch result {
        case .success(let predictor):
          self?.obbLayer?.isHidden = false
          handleSuccess(predictor: predictor)
        case .failure(let error):
          handleFailure(error)
        }
      }

    default:
      ObjectDetector.create(unwrappedModelURL: unwrappedModelURL, isRealTime: true) { result in
        switch result {
        case .success(let predictor):
          handleSuccess(predictor: predictor)
        case .failure(let error):
          handleFailure(error)
        }
      }
    }
  }

  private func start(position: AVCaptureDevice.Position) {
    if !busy {
      busy = true
      let orientation = UIDevice.current.orientation
      videoCapture.setUp(sessionPreset: .photo, position: position, orientation: orientation) { success in
        if success {
          if let previewLayer = self.videoCapture.previewLayer {
            self.layer.insertSublayer(previewLayer, at: 0)
            self.videoCapture.previewLayer?.frame = self.bounds
            for box in self.boundingBoxViews {
              box.addToLayer(previewLayer)
            }
          }
          self.videoCapture.previewLayer?.addSublayer(self.overlayLayer)
          self.videoCapture.start()
          self.busy = false
        }
      }
    }
  }

  public func stop() {
    videoCapture.stop()
    videoCapture.delegate = nil
    videoCapture.predictor = nil
  }

  public func resume() {
    videoCapture.start()
  }

  func setUpBoundingBoxViews() {
    while boundingBoxViews.count < maxBoundingBoxViews {
      boundingBoxViews.append(BoundingBoxView())
    }
  }

  func setupOverlayLayer() {
    let width = self.bounds.width
    let height = self.bounds.height

    var ratio: CGFloat = 1.0
    if videoCapture.captureSession.sessionPreset == .photo {
      ratio = (4.0 / 3.0)
    } else {
      ratio = (16.0 / 9.0)
    }
    var offSet = CGFloat.zero
    var margin = CGFloat.zero
    if self.bounds.width < self.bounds.height {
      offSet = height / ratio
      margin = (offSet - self.bounds.width) / 2
      self.overlayLayer.frame = CGRect(x: -margin, y: 0, width: offSet, height: self.bounds.height)
    } else {
      offSet = width / ratio
      margin = (offSet - self.bounds.height) / 2
      self.overlayLayer.frame = CGRect(x: 0, y: -margin, width: self.bounds.width, height: offSet)
    }

    if let maskLayer = self.maskLayer {
      maskLayer.frame = self.overlayLayer.bounds
    }
  }

  func setupMaskLayerIfNeeded() {
    if maskLayer == nil {
      let layer = CALayer()
      layer.frame = self.overlayLayer.bounds
      layer.opacity = 0.5
      layer.name = "maskLayer"
      self.overlayLayer.addSublayer(layer)
      self.maskLayer = layer
    }
  }

  func setupPoseLayerIfNeeded() {
    if poseLayer == nil {
      let layer = CALayer()
      layer.frame = self.overlayLayer.bounds
      layer.opacity = 0.5
      self.overlayLayer.addSublayer(layer)
      self.poseLayer = layer
    }
  }

  func setupObbLayerIfNeeded() {
    if obbLayer == nil {
      let layer = CALayer()
      layer.frame = self.overlayLayer.bounds
      layer.opacity = 0.5
      self.overlayLayer.addSublayer(layer)
      self.obbLayer = layer
    }
  }

  public func resetLayers() {
    removeAllSubLayers(parentLayer: maskLayer)
    removeAllSubLayers(parentLayer: poseLayer)
    removeAllSubLayers(parentLayer: overlayLayer)

    maskLayer = nil
    poseLayer = nil
    obbLayer?.isHidden = true
  }

  func setupSublayers() {
    resetLayers()

    switch task {
    case .segment:
      setupMaskLayerIfNeeded()
    case .pose:
      setupPoseLayerIfNeeded()
    case .obb:
      setupObbLayerIfNeeded()
      overlayLayer.addSublayer(obbLayer!)
      obbLayer?.isHidden = false
    default:
      break
    }
  }

  func removeAllSubLayers(parentLayer: CALayer?) {
    guard let parentLayer = parentLayer else { return }
    parentLayer.sublayers?.forEach { layer in
      layer.removeFromSuperlayer()
    }
    parentLayer.sublayers = nil
    parentLayer.contents = nil
  }

  func addMaskSubLayers() {
    guard let maskLayer = maskLayer else { return }
    self.overlayLayer.addSublayer(maskLayer)
  }

  func showBoxes(predictions: YOLOResult) {
    let width = self.bounds.width
    let height = self.bounds.height
    var resultCount = predictions.boxes.count

    print("showBoxes called, detections: \(predictions.boxes.count)")

    let depthInfo = videoCapture.latestDepthData()
    let depthPixelBuffer = depthInfo.depthPixelBuffer
    let calibrationData = depthInfo.calibrationData

    print("depth buffer available: \(depthPixelBuffer != nil)")

    var depthBaseAddress: UnsafeMutablePointer<Float32>?
    var depthRowStride: Int = 0
    var depthWidth: Int = 0
    var depthHeight: Int = 0
    var fxPixels: Float?
    var fyPixels: Float?

    if let depthPixelBuffer,
      CVPixelBufferGetPixelFormatType(depthPixelBuffer) == kCVPixelFormatType_DepthFloat32
    {
      CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
      depthWidth = CVPixelBufferGetWidth(depthPixelBuffer)
      depthHeight = CVPixelBufferGetHeight(depthPixelBuffer)
      depthRowStride = CVPixelBufferGetBytesPerRow(depthPixelBuffer) / MemoryLayout<Float32>.size

      if let baseAddress = CVPixelBufferGetBaseAddress(depthPixelBuffer) {
        depthBaseAddress = baseAddress.assumingMemoryBound(to: Float32.self)
      }

      if let calibrationData {
        let ref = calibrationData.intrinsicMatrixReferenceDimensions
        let scaleX = Float(predictions.orig_shape.width) / max(Float(ref.width), 1.0)
        let scaleY = Float(predictions.orig_shape.height) / max(Float(ref.height), 1.0)
        let m = calibrationData.intrinsicMatrix
        fxPixels = m.columns.0.x * scaleX
        fyPixels = m.columns.1.y * scaleY
      }
    }

    defer {
      if let depthPixelBuffer,
        CVPixelBufferGetPixelFormatType(depthPixelBuffer) == kCVPixelFormatType_DepthFloat32
      {
        CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
      }
    }

    func formatFeetInches(_ meters: Float) -> String {
      let totalInches = meters * 39.37007874
      if !totalInches.isFinite || totalInches <= 0 {
        return ""
      }
      var feet = Int(floor(totalInches / 12.0))
      var inches = Int(round(totalInches - Float(feet) * 12.0))
      if inches == 12 {
        feet += 1
        inches = 0
      }
      if feet > 0 {
        return "\(feet)ft \(inches)in"
      }
      return "\(inches)in"
    }


    func clampedNormalizedRect(_ rect: CGRect) -> CGRect {
      let minX = max(CGFloat(0.0), min(rect.minX, CGFloat(1.0)))
      let minY = max(CGFloat(0.0), min(rect.minY, CGFloat(1.0)))
      let maxX = max(CGFloat(0.0), min(rect.maxX, CGFloat(1.0)))
      let maxY = max(CGFloat(0.0), min(rect.maxY, CGFloat(1.0)))
      return CGRect(
        x: minX,
        y: minY,
        width: max(CGFloat(0.0), maxX - minX),
        height: max(CGFloat(0.0), maxY - minY))
    }

    func percentile(_ sortedValues: [Float], fraction: Float) -> Float? {
      guard !sortedValues.isEmpty else { return nil }
      if sortedValues.count == 1 { return sortedValues[0] }
      let clampedFraction = min(max(fraction, 0), 1)
      let index = Int(round(clampedFraction * Float(sortedValues.count - 1)))
      return sortedValues[index]
    }

    func depthMetersAtNormalizedPoint(_ point: CGPoint) -> Float? {
      guard let base = depthBaseAddress, depthWidth > 0, depthHeight > 0 else { return nil }

      let x = min(max(Int(point.x * CGFloat(depthWidth)), 0), depthWidth - 1)
      let y = min(max(Int(point.y * CGFloat(depthHeight)), 0), depthHeight - 1)

      let radius = 1
      var sum: Float = 0
      var count: Int = 0
      for dy in -radius...radius {
        let yy = y + dy
        if yy < 0 || yy >= depthHeight { continue }
        for dx in -radius...radius {
          let xx = x + dx
          if xx < 0 || xx >= depthWidth { continue }
          let d = base[yy * depthRowStride + xx]
          if d.isFinite && d > 0 {
            sum += d
            count += 1
          }
        }
      }
      if count == 0 { return nil }
      return sum / Float(count)
    }

    func depthSamples(inNormalizedRect rect: CGRect) -> [Float] {
      guard let base = depthBaseAddress, depthWidth > 0, depthHeight > 0 else { return [] }
      if rect.isEmpty || rect.width <= 0 || rect.height <= 0 { return [] }

      let minX = min(max(Int(floor(rect.minX * CGFloat(depthWidth))), 0), depthWidth - 1)
      let maxX = min(max(Int(ceil(rect.maxX * CGFloat(depthWidth))), 0), depthWidth - 1)
      let minY = min(max(Int(floor(rect.minY * CGFloat(depthHeight))), 0), depthHeight - 1)
      let maxY = min(max(Int(ceil(rect.maxY * CGFloat(depthHeight))), 0), depthHeight - 1)

      guard maxX >= minX, maxY >= minY else { return [] }

      let spanX = maxX - minX + 1
      let spanY = maxY - minY + 1
      let stepX = max(1, spanX / 12)
      let stepY = max(1, spanY / 12)

      var samples: [Float] = []
      samples.reserveCapacity(144)

      var y = minY
      while y <= maxY {
        var x = minX
        while x <= maxX {
          let d = base[y * depthRowStride + x]
          if d.isFinite && d > 0 {
            samples.append(d)
          }
          x += stepX
        }
        y += stepY
      }

      if samples.isEmpty {
        let centerPoint = CGPoint(x: rect.midX, y: rect.midY)
        if let centerDepth = depthMetersAtNormalizedPoint(centerPoint) {
          samples.append(centerDepth)
        }
      }

      return samples
    }

    func robustDistanceMeters(for box: Box) -> Float? {
      guard depthBaseAddress != nil else { return nil }

      let insetX = min(box.xywhn.width * 0.25, 0.12)
      let insetY = min(box.xywhn.height * 0.25, 0.12)
      let innerRect = clampedNormalizedRect(box.xywhn.insetBy(dx: insetX, dy: insetY))

      var samples = depthSamples(inNormalizedRect: innerRect)
      if samples.count < 6 {
        let centerRect = clampedNormalizedRect(
          CGRect(
            x: box.xywhn.midX - max(box.xywhn.width * 0.08, 0.01),
            y: box.xywhn.midY - max(box.xywhn.height * 0.08, 0.01),
            width: max(box.xywhn.width * 0.16, 0.02),
            height: max(box.xywhn.height * 0.16, 0.02)))
        samples.append(contentsOf: depthSamples(inNormalizedRect: centerRect))
      }

      if samples.isEmpty {
        return depthMetersAtNormalizedPoint(CGPoint(x: box.xywhn.midX, y: box.xywhn.midY))
      }

      samples.sort()

      guard let anchorDepth = percentile(samples, fraction: 0.25) else { return nil }

      let tolerance = max(0.05, anchorDepth * 0.12)
      let inliers = samples.filter { abs($0 - anchorDepth) <= tolerance }
      if !inliers.isEmpty {
        return inliers.reduce(0, +) / Float(inliers.count)
      }

      let nearCount = max(1, Int(ceil(Double(samples.count) * 0.33)))
      let nearSamples = Array(samples.prefix(nearCount))
      return nearSamples[nearSamples.count / 2]
    }

    func applyHardCodedDistanceCorrection(_ rawDistanceM: Float) -> Float {
      let rawInches = rawDistanceM * 39.37007874
      print(">>> DISTANCE CORRECTION V2: rawInches=\(rawInches)")
      if !rawInches.isFinite || rawInches <= 0 {
        return rawDistanceM
      }

      // Hard-coded distance correction (v2):
      // > 6 ft (72 in) raw: halve the distance
      // 3 ft – 5 ft (36–60 in) raw: multiply by 0.75
      // < 3 ft: no correction
      if rawInches > 72.0 {
        let corrected = (rawInches * 0.5) / 39.37007874
        print(">>> HALVED: \(rawInches)in -> \(rawInches * 0.5)in")
        return corrected
      } else if rawInches >= 36.0 && rawInches <= 60.0 {
        let corrected = (rawInches * 0.75) / 39.37007874
        print(">>> 0.75x: \(rawInches)in -> \(rawInches * 0.75)in")
        return corrected
      }

      print(">>> NO CORRECTION: \(rawInches)in")
      return rawDistanceM
    }

    func measurementSuffix(for box: Box) -> String? {
      guard depthBaseAddress != nil else { return nil }

      guard let rawDistanceM = robustDistanceMeters(for: box) else { return nil }
      let distanceM = applyHardCodedDistanceCorrection(rawDistanceM)
      let distanceText = formatFeetInches(distanceM)
      if distanceText.isEmpty {
        return nil
      }

      var sizeText: String = ""
      if let fx = fxPixels, let fy = fyPixels, fx > 0, fy > 0 {
        let wMeters = Float(box.xywh.width) * distanceM / fx
        let hMeters = Float(box.xywh.height) * distanceM / fy
        let wIn = wMeters * 39.37007874
        let hIn = hMeters * 39.37007874
        if wIn.isFinite, hIn.isFinite, wIn > 0, hIn > 0 {
          let wRounded = Int(round(wIn))
          let hRounded = Int(round(hIn))
          sizeText = "\(wRounded)x\(hRounded)in"
        }
      }

      print("distance for \(box.cls): raw=\(formatFeetInches(rawDistanceM)), corrected=\(distanceText), size: \(sizeText)")

      if sizeText.isEmpty {
        return distanceText
      }
      return "\(distanceText) \(sizeText)"
    }

    if UIDevice.current.orientation == .portrait {
      var ratio: CGFloat = 1.0

      if videoCapture.captureSession.sessionPreset == .photo {
        ratio = (height / width) / (4.0 / 3.0)
      } else {
        ratio = (height / width) / (16.0 / 9.0)
      }

      if showUIControls {
        self.labelSliderNumItems.text =
          String(resultCount) + " items (max " + String(Int(sliderNumItems.value)) + ")"
      }

      for i in 0..<boundingBoxViews.count {
        if i < resultCount && i < 50 {
          var rect = CGRect.zero
          var label = ""
          var boxColor: UIColor = .white
          var confidence: CGFloat = 0
          var alpha: CGFloat = 0.9
          var bestClass = ""

          switch task {
          case .detect:
            let prediction = predictions.boxes[i]
            rect = CGRect(
              x: prediction.xywhn.minX,
              y: 1 - prediction.xywhn.maxY,
              width: prediction.xywhn.width,
              height: prediction.xywhn.height
            )
            bestClass = prediction.cls
            confidence = CGFloat(prediction.conf)
            let colorIndex = prediction.index % ultralyticsColors.count
            boxColor = ultralyticsColors[colorIndex]
            label = String(format: "%@ %.1f", bestClass, confidence * 100)
            alpha = CGFloat((confidence - 0.2) / (1.0 - 0.2) * 0.9)

          default:
            let prediction = predictions.boxes[i]
            rect = prediction.xywhn
            bestClass = prediction.cls
            confidence = CGFloat(prediction.conf)
            label = String(format: "%@ %.1f", bestClass, confidence * 100)
            let colorIndex = prediction.index % ultralyticsColors.count
            boxColor = ultralyticsColors[colorIndex]
            alpha = CGFloat((confidence - 0.2) / (1.0 - 0.2) * 0.9)
          }

          let measuredSuffix = measurementSuffix(for: predictions.boxes[i])
          if let suffix = measuredSuffix {
            label = "\(label) \(suffix)"
            lastDistanceByBoxIndex[i] = suffix
          } else {
            lastDistanceByBoxIndex.removeValue(forKey: i)
          }

          var displayRect = rect
          switch UIDevice.current.orientation {
          case .portraitUpsideDown:
            displayRect = CGRect(
              x: 1.0 - rect.origin.x - rect.width,
              y: 1.0 - rect.origin.y - rect.height,
              width: rect.width,
              height: rect.height
            )
          case .landscapeLeft:
            displayRect = CGRect(
              x: rect.origin.x,
              y: rect.origin.y,
              width: rect.width,
              height: rect.height
            )
          case .landscapeRight:
            displayRect = CGRect(
              x: rect.origin.x,
              y: rect.origin.y,
              width: rect.width,
              height: rect.height
            )
          case .unknown:
            print("The device orientation is unknown, the predictions may be affected")
            fallthrough
          default:
            break
          }

          if ratio >= 1 {
            let offset = (1 - ratio) * (0.5 - displayRect.minX)
            if task == .detect {
              let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: offset, y: -1)
              displayRect = displayRect.applying(transform)
            } else {
              let transform = CGAffineTransform(translationX: offset, y: 0)
              displayRect = displayRect.applying(transform)
            }
            displayRect.size.width *= ratio
          } else {
            if task == .detect {
              let offset = (ratio - 1) * (0.5 - displayRect.maxY)
              let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: offset - 1)
              displayRect = displayRect.applying(transform)
            } else {
              let offset = (ratio - 1) * (0.5 - displayRect.minY)
              let transform = CGAffineTransform(translationX: 0, y: offset)
              displayRect = displayRect.applying(transform)
            }
            ratio = (height / width) / (3.0 / 4.0)
            displayRect.size.height /= ratio
          }

          displayRect = VNImageRectForNormalizedRect(displayRect, Int(width), Int(height))

          if _showOverlays {
            boundingBoxViews[i].show(
              frame: displayRect,
              label: label,
              color: boxColor,
              alpha: alpha
            )
          } else {
            boundingBoxViews[i].hide()
          }
        } else {
          boundingBoxViews[i].hide()
        }
      }
    } else {
      resultCount = predictions.boxes.count
      if showUIControls {
        self.labelSliderNumItems.text =
          String(resultCount) + " items (max " + String(Int(sliderNumItems.value)) + ")"
      }

      let frameAspectRatio = videoCapture.longSide / videoCapture.shortSide
      let viewAspectRatio = width / height
      var scaleX: CGFloat = 1.0
      var scaleY: CGFloat = 1.0
      var offsetX: CGFloat = 0.0
      var offsetY: CGFloat = 0.0

      if frameAspectRatio > viewAspectRatio {
        scaleY = height / videoCapture.shortSide
        scaleX = scaleY
        offsetX = (videoCapture.longSide * scaleX - width) / 2
      } else {
        scaleX = width / videoCapture.longSide
        scaleY = scaleX
        offsetY = (videoCapture.shortSide * scaleY - height) / 2
      }

      for i in 0..<boundingBoxViews.count {
        if i < resultCount && i < 50 {
          var rect = CGRect.zero
          var label = ""
          var boxColor: UIColor = .white
          var confidence: CGFloat = 0
          var alpha: CGFloat = 0.9
          var bestClass = ""

          switch task {
          case .detect:
            let prediction = predictions.boxes[i]
            rect = CGRect(
              x: prediction.xywhn.minX,
              y: 1 - prediction.xywhn.maxY,
              width: prediction.xywhn.width,
              height: prediction.xywhn.height
            )
            bestClass = prediction.cls
            confidence = CGFloat(prediction.conf)

          default:
            let prediction = predictions.boxes[i]
            rect = CGRect(
              x: prediction.xywhn.minX,
              y: 1 - prediction.xywhn.maxY,
              width: prediction.xywhn.width,
              height: prediction.xywhn.height
            )
            bestClass = prediction.cls
            confidence = CGFloat(prediction.conf)
          }

          let colorIndex = predictions.boxes[i].index % ultralyticsColors.count
          boxColor = ultralyticsColors[colorIndex]
          label = String(format: "%@ %.1f", bestClass, confidence * 100)

          let measuredSuffix2 = measurementSuffix(for: predictions.boxes[i])
          if let suffix = measuredSuffix2 {
            label = "\(label) \(suffix)"
            lastDistanceByBoxIndex[i] = suffix
          } else {
            lastDistanceByBoxIndex.removeValue(forKey: i)
          }

          alpha = CGFloat((confidence - 0.2) / (1.0 - 0.2) * 0.9)

          rect.origin.x = rect.origin.x * videoCapture.longSide * scaleX - offsetX
          rect.origin.y =
            height
            - (rect.origin.y * videoCapture.shortSide * scaleY
              - offsetY
              + rect.size.height * videoCapture.shortSide * scaleY)
          rect.size.width *= videoCapture.longSide * scaleX
          rect.size.height *= videoCapture.shortSide * scaleY

          if _showOverlays {
            boundingBoxViews[i].show(
              frame: rect,
              label: label,
              color: boxColor,
              alpha: alpha
            )
          } else {
            boundingBoxViews[i].hide()
          }
        } else {
          boundingBoxViews[i].hide()
        }
      }
    }
  }

  func removeClassificationLayers() {
    if let sublayers = self.layer.sublayers {
      for layer in sublayers where layer.name == "YOLOOverlayLayer" {
        layer.removeFromSuperlayer()
      }
    }
  }

  func overlayYOLOClassificationsCALayer(on view: UIView, result: YOLOResult) {
    removeClassificationLayers()

    let overlayLayer = CALayer()
    overlayLayer.frame = view.bounds
    overlayLayer.name = "YOLOOverlayLayer"

    guard let top1 = result.probs?.top1,
      let top1Conf = result.probs?.top1Conf
    else {
      return
    }

    var colorIndex = 0
    if let index = result.names.firstIndex(of: top1) {
      colorIndex = index % ultralyticsColors.count
    }
    let color = ultralyticsColors[colorIndex]

    let confidencePercent = round(top1Conf * 1000) / 10
    let labelText = " \(top1) \(confidencePercent)% "

    let textLayer = CATextLayer()
    textLayer.contentsScale = UIScreen.main.scale
    textLayer.alignmentMode = .left
    let fontSize = self.bounds.height * 0.02
    textLayer.font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
    textLayer.fontSize = fontSize
    textLayer.foregroundColor = UIColor.white.cgColor
    textLayer.backgroundColor = color.cgColor
    textLayer.cornerRadius = 4
    textLayer.masksToBounds = true

    textLayer.string = labelText
    let textAttributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold)
    ]
    let textSize = (labelText as NSString).size(withAttributes: textAttributes)
    let width: CGFloat = textSize.width + 10
    let x: CGFloat = self.center.x - (width / 2)
    let y: CGFloat = self.center.y - textSize.height
    let height: CGFloat = textSize.height + 4

    textLayer.frame = CGRect(x: x, y: y, width: width, height: height)

    overlayLayer.addSublayer(textLayer)
    view.layer.addSublayer(overlayLayer)
  }

  private func setupUI() {
    labelName.text = modelName
    labelName.textAlignment = .center
    labelName.font = UIFont.systemFont(ofSize: 24, weight: .medium)
    labelName.textColor = .black
    labelName.font = UIFont.preferredFont(forTextStyle: .title1)
    self.addSubview(labelName)

    labelFPS.text = String(format: "%.1f FPS - %.1f ms", 0.0, 0.0)
    labelFPS.textAlignment = .center
    labelFPS.textColor = .black
    labelFPS.font = UIFont.preferredFont(forTextStyle: .body)
    self.addSubview(labelFPS)

    labelSliderNumItems.text = "0 items (max 30)"
    labelSliderNumItems.textAlignment = .left
    labelSliderNumItems.textColor = .black
    labelSliderNumItems.font = UIFont.preferredFont(forTextStyle: .subheadline)
    self.addSubview(labelSliderNumItems)

    sliderNumItems.minimumValue = 0
    sliderNumItems.maximumValue = 100
    sliderNumItems.value = 30
    sliderNumItems.minimumTrackTintColor = .darkGray
    sliderNumItems.maximumTrackTintColor = .systemGray.withAlphaComponent(0.7)
    sliderNumItems.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
    self.addSubview(sliderNumItems)

    labelSliderConf.text = "0.25 Confidence Threshold"
    labelSliderConf.textAlignment = .left
    labelSliderConf.textColor = .black
    labelSliderConf.font = UIFont.preferredFont(forTextStyle: .subheadline)
    self.addSubview(labelSliderConf)

    sliderConf.minimumValue = 0
    sliderConf.maximumValue = 1
    sliderConf.value = 0.25
    sliderConf.minimumTrackTintColor = .darkGray
    sliderConf.maximumTrackTintColor = .systemGray.withAlphaComponent(0.7)
    sliderConf.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
    self.addSubview(sliderConf)

    labelSliderIoU.text = "0.45 IoU Threshold"
    labelSliderIoU.textAlignment = .left
    labelSliderIoU.textColor = .black
    labelSliderIoU.font = UIFont.preferredFont(forTextStyle: .subheadline)
    self.addSubview(labelSliderIoU)

    sliderIoU.minimumValue = 0
    sliderIoU.maximumValue = 1
    sliderIoU.value = 0.45
    sliderIoU.minimumTrackTintColor = .darkGray
    sliderIoU.maximumTrackTintColor = .systemGray.withAlphaComponent(0.7)
    sliderIoU.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
    self.addSubview(sliderIoU)

    if showUIControls {
      self.labelSliderNumItems.text = "0 items (max " + String(Int(sliderNumItems.value)) + ")"
    }
    self.labelSliderConf.text = "0.25 Confidence Threshold"
    self.labelSliderIoU.text = "0.45 IoU Threshold"

    labelZoom.text = "1.00x"
    labelZoom.textColor = .black
    labelZoom.font = UIFont.systemFont(ofSize: 14)
    labelZoom.textAlignment = .center
    labelZoom.font = UIFont.preferredFont(forTextStyle: .body)
    self.addSubview(labelZoom)

    let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular, scale: .default)

    playButton.setImage(UIImage(systemName: "play.fill", withConfiguration: config), for: .normal)
    playButton.tintColor = .systemGray
    pauseButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: config), for: .normal)
    pauseButton.tintColor = .systemGray
    switchCameraButton = UIButton()
    switchCameraButton.setImage(
      UIImage(systemName: "camera.rotate", withConfiguration: config), for: .normal
    )
    switchCameraButton.tintColor = .systemGray
    playButton.isEnabled = false
    pauseButton.isEnabled = true
    playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
    pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
    switchCameraButton.addTarget(self, action: #selector(switchCameraTapped), for: .touchUpInside)
    toolbar.backgroundColor = .darkGray.withAlphaComponent(0.7)
    self.addSubview(toolbar)
    toolbar.addSubview(playButton)
    toolbar.addSubview(pauseButton)
    toolbar.addSubview(switchCameraButton)

    self.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch)))
  }

  private func updateUIControlsVisibility() {
    let controlElements: [UIView] = [
      labelSliderNumItems, sliderNumItems,
      labelSliderConf, sliderConf,
      labelSliderIoU, sliderIoU,
      labelName, labelFPS, labelZoom,
      toolbar, playButton, pauseButton, switchCameraButton,
    ]

    for element in controlElements {
      element.isHidden = !_showUIControls
    }

    self.setNeedsLayout()
  }

  public override func layoutSubviews() {
    setupOverlayLayer()
    let isLandscape = bounds.width > bounds.height
    activityIndicator.frame = CGRect(x: center.x - 50, y: center.y - 50, width: 100, height: 100)

    if isLandscape {
      toolbar.backgroundColor = .clear
      playButton.tintColor = .darkGray
      pauseButton.tintColor = .darkGray
      switchCameraButton.tintColor = .darkGray

      let width = bounds.width
      let height = bounds.height

      let topMargin: CGFloat = 0
      let titleLabelHeight: CGFloat = height * 0.1
      labelName.frame = CGRect(x: 0, y: topMargin, width: width, height: titleLabelHeight)

      let subLabelHeight: CGFloat = height * 0.04
      labelFPS.frame = CGRect(
        x: 0,
        y: center.y - height * 0.24 - subLabelHeight,
        width: width,
        height: subLabelHeight
      )

      let sliderWidth: CGFloat = width * 0.2
      let sliderHeight: CGFloat = height * 0.1

      labelSliderNumItems.frame = CGRect(
        x: width * 0.1,
        y: labelFPS.frame.minY - sliderHeight,
        width: sliderWidth,
        height: sliderHeight
      )

      sliderNumItems.frame = CGRect(
        x: width * 0.1,
        y: labelSliderNumItems.frame.maxY + 10,
        width: sliderWidth,
        height: sliderHeight
      )

      labelSliderConf.frame = CGRect(
        x: width * 0.1,
        y: sliderNumItems.frame.maxY + 10,
        width: sliderWidth * 1.5,
        height: sliderHeight
      )

      sliderConf.frame = CGRect(
        x: width * 0.1,
        y: labelSliderConf.frame.maxY + 10,
        width: sliderWidth,
        height: sliderHeight
      )

      labelSliderIoU.frame = CGRect(
        x: width * 0.1,
        y: sliderConf.frame.maxY + 10,
        width: sliderWidth * 1.5,
        height: sliderHeight
      )

      sliderIoU.frame = CGRect(
        x: width * 0.1,
        y: labelSliderIoU.frame.maxY + 10,
        width: sliderWidth,
        height: sliderHeight
      )

      let zoomLabelWidth: CGFloat = width * 0.2
      labelZoom.frame = CGRect(
        x: center.x - zoomLabelWidth / 2,
        y: self.bounds.maxY - 120,
        width: zoomLabelWidth,
        height: height * 0.03
      )

      let toolBarHeight: CGFloat = 66
      let buttonHeihgt: CGFloat = toolBarHeight * 0.75
      toolbar.frame = CGRect(x: 0, y: height - toolBarHeight, width: width, height: toolBarHeight)
      playButton.frame = CGRect(x: 0, y: 0, width: buttonHeihgt, height: buttonHeihgt)
      pauseButton.frame = CGRect(x: playButton.frame.maxX, y: 0, width: buttonHeihgt, height: buttonHeihgt)
      switchCameraButton.frame = CGRect(
        x: pauseButton.frame.maxX, y: 0, width: buttonHeihgt, height: buttonHeihgt
      )
    } else {
      toolbar.backgroundColor = .darkGray.withAlphaComponent(0.7)
      playButton.tintColor = .systemGray
      pauseButton.tintColor = .systemGray
      switchCameraButton.tintColor = .systemGray

      let width = bounds.width
      let height = bounds.height

      let topMargin: CGFloat = height * 0.02
      let titleLabelHeight: CGFloat = height * 0.1
      labelName.frame = CGRect(x: 0, y: topMargin, width: width, height: titleLabelHeight)

      let subLabelHeight: CGFloat = height * 0.04
      labelFPS.frame = CGRect(x: 0, y: labelName.frame.maxY + 15, width: width, height: subLabelHeight)

      let sliderWidth: CGFloat = width * 0.46
      let sliderHeight: CGFloat = height * 0.02

      sliderNumItems.frame = CGRect(
        x: width * 0.01,
        y: center.y - sliderHeight - height * 0.24,
        width: sliderWidth,
        height: sliderHeight
      )

      labelSliderNumItems.frame = CGRect(
        x: width * 0.01,
        y: sliderNumItems.frame.minY - sliderHeight - 10,
        width: sliderWidth,
        height: sliderHeight
      )

      labelSliderConf.frame = CGRect(
        x: width * 0.01,
        y: center.y + height * 0.24,
        width: sliderWidth * 1.5,
        height: sliderHeight
      )

      sliderConf.frame = CGRect(
        x: width * 0.01,
        y: labelSliderConf.frame.maxY + 10,
        width: sliderWidth,
        height: sliderHeight
      )

      labelSliderIoU.frame = CGRect(
        x: width * 0.01,
        y: sliderConf.frame.maxY + 10,
        width: sliderWidth * 1.5,
        height: sliderHeight
      )

      sliderIoU.frame = CGRect(
        x: width * 0.01,
        y: labelSliderIoU.frame.maxY + 10,
        width: sliderWidth,
        height: sliderHeight
      )

      let zoomLabelWidth: CGFloat = width * 0.2
      labelZoom.frame = CGRect(
        x: center.x - zoomLabelWidth / 2,
        y: self.bounds.maxY - 120,
        width: zoomLabelWidth,
        height: height * 0.03
      )

      let toolBarHeight: CGFloat = 66
      let buttonHeihgt: CGFloat = toolBarHeight * 0.75
      toolbar.frame = CGRect(x: 0, y: height - toolBarHeight, width: width, height: toolBarHeight)
      playButton.frame = CGRect(x: 0, y: 0, width: buttonHeihgt, height: buttonHeihgt)
      pauseButton.frame = CGRect(x: playButton.frame.maxX, y: 0, width: buttonHeihgt, height: buttonHeihgt)
      switchCameraButton.frame = CGRect(
        x: pauseButton.frame.maxX, y: 0, width: buttonHeihgt, height: buttonHeihgt
      )
    }

    self.videoCapture.previewLayer?.frame = self.bounds
  }

  private func setUpOrientationChangeNotification() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(orientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )
  }

  @objc func orientationDidChange() {
    var orientation: AVCaptureVideoOrientation = .portrait
    switch UIDevice.current.orientation {
    case .portrait:
      orientation = .portrait
    case .portraitUpsideDown:
      orientation = .portraitUpsideDown
    case .landscapeRight:
      orientation = .landscapeLeft
    case .landscapeLeft:
      orientation = .landscapeRight
    default:
      return
    }
    videoCapture.updateVideoOrientation(orientation: orientation)
  }

  @objc func sliderChanged(_ sender: Any) {
    if sender as? UISlider === sliderNumItems {
      if let basePredictor = videoCapture.predictor as? BasePredictor {
        let numItems = Int(sliderNumItems.value)
        basePredictor.setNumItemsThreshold(numItems: numItems)
      }
    }

    let conf = Double(round(100 * sliderConf.value)) / 100
    let iou = Double(round(100 * sliderIoU.value)) / 100
    self.labelSliderConf.text = String(conf) + " Confidence Threshold"
    self.labelSliderIoU.text = String(iou) + " IoU Threshold"

    if let basePredictor = videoCapture.predictor as? BasePredictor {
      basePredictor.setIouThreshold(iou: iou)
      basePredictor.setConfidenceThreshold(confidence: conf)
    }
  }

  @objc func pinch(_ pinch: UIPinchGestureRecognizer) {
    guard let device = videoCapture.captureDevice else { return }

    func minMaxZoom(_ factor: CGFloat) -> CGFloat {
      return min(min(max(factor, minimumZoom), maximumZoom), device.activeFormat.videoMaxZoomFactor)
    }

    func update(scale factor: CGFloat) {
      do {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.videoZoomFactor = factor
      } catch {
        print("\(error.localizedDescription)")
      }
    }

    let newScaleFactor = minMaxZoom(pinch.scale * lastZoomFactor)
    switch pinch.state {
    case .began, .changed:
      update(scale: newScaleFactor)
      self.labelZoom.text = String(format: "%.2fx", newScaleFactor)
      self.labelZoom.font = UIFont.preferredFont(forTextStyle: .title2)
      onZoomChanged?(newScaleFactor)
    case .ended:
      lastZoomFactor = minMaxZoom(newScaleFactor)
      update(scale: lastZoomFactor)
      self.labelZoom.font = UIFont.preferredFont(forTextStyle: .body)
      onZoomChanged?(lastZoomFactor)
    default:
      break
    }
  }

  public func setZoomLevel(_ zoomLevel: CGFloat) {
    guard let device = videoCapture.captureDevice else { return }

    func minMaxZoom(_ factor: CGFloat) -> CGFloat {
      return min(min(max(factor, minimumZoom), maximumZoom), device.activeFormat.videoMaxZoomFactor)
    }

    let newZoomFactor = minMaxZoom(zoomLevel)

    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      device.videoZoomFactor = newZoomFactor
      lastZoomFactor = newZoomFactor
      self.labelZoom.text = String(format: "%.1fx", newZoomFactor)
      onZoomChanged?(newZoomFactor)
    } catch {
      print("Failed to set zoom level: \(error.localizedDescription)")
    }
  }

  @objc func playTapped() {
    selection.selectionChanged()
    self.videoCapture.start()
    playButton.isEnabled = false
    pauseButton.isEnabled = true
  }

  @objc func pauseTapped() {
    selection.selectionChanged()
    self.videoCapture.stop()
    playButton.isEnabled = true
    pauseButton.isEnabled = false
  }

  @objc func switchCameraTapped() {
    self.videoCapture.captureSession.beginConfiguration()
    let currentInput = self.videoCapture.captureSession.inputs.first as? AVCaptureDeviceInput
    self.videoCapture.captureSession.removeInput(currentInput!)
    guard let currentPosition = currentInput?.device.position else { return }

    let nextCameraPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
    let newCameraDevice = bestCaptureDevice(position: nextCameraPosition)

    guard let videoInput1 = try? AVCaptureDeviceInput(device: newCameraDevice) else {
      return
    }

    self.videoCapture.captureSession.addInput(videoInput1)

    var orientation: AVCaptureVideoOrientation = .portrait
    switch UIDevice.current.orientation {
    case .portrait:
      orientation = .portrait
    case .portraitUpsideDown:
      orientation = .portraitUpsideDown
    case .landscapeRight:
      orientation = .landscapeLeft
    case .landscapeLeft:
      orientation = .landscapeRight
    default:
      return
    }
    self.videoCapture.updateVideoOrientation(orientation: orientation)

    self.videoCapture.captureSession.commitConfiguration()
  }

  public func capturePhoto(completion: @escaping (UIImage?) -> Void) {
    self.photoCaptureCompletion = completion
    let settings = AVCapturePhotoSettings()
    usleep(20_000)
    self.videoCapture.photoOutput.capturePhoto(
      with: settings,
      delegate: self as AVCapturePhotoCaptureDelegate
    )
  }

  public func setInferenceFlag(ok: Bool) {
    videoCapture.inferenceOK = ok
  }

  deinit {
    videoCapture.stop()
    videoCapture.delegate = nil
    videoCapture.predictor = nil
    onDetection = nil
    onStream = nil
    onZoomChanged = nil
    NotificationCenter.default.removeObserver(self)
  }
}

extension YOLOView: AVCapturePhotoCaptureDelegate {
  public func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    if let error = error {
      print("error occurred : \(error.localizedDescription)")
    }
    if let dataImage = photo.fileDataRepresentation() {
      let dataProvider = CGDataProvider(data: dataImage as CFData)
      let cgImageRef: CGImage! = CGImage(
        jpegDataProviderSource: dataProvider!,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
      var isCameraFront = false
      if let currentInput = self.videoCapture.captureSession.inputs.first as? AVCaptureDeviceInput,
        currentInput.device.position == .front
      {
        isCameraFront = true
      }
      var orientation: CGImagePropertyOrientation = isCameraFront ? .leftMirrored : .right
      switch UIDevice.current.orientation {
      case .landscapeLeft:
        orientation = isCameraFront ? .downMirrored : .up
      case .landscapeRight:
        orientation = isCameraFront ? .upMirrored : .down
      default:
        break
      }
      var image = UIImage(cgImage: cgImageRef, scale: 0.5, orientation: .right)
      if let orientedCIImage = CIImage(image: image)?.oriented(orientation),
        let cgImage = CIContext().createCGImage(orientedCIImage, from: orientedCIImage.extent)
      {
        image = UIImage(cgImage: cgImage)
      }
      let imageView = UIImageView(image: image)
      imageView.contentMode = .scaleAspectFill
      imageView.frame = self.frame
      let imageLayer = imageView.layer
      self.layer.insertSublayer(imageLayer, above: videoCapture.previewLayer)

      var tempMaskLayer: CALayer?
      if let maskLayer = self.maskLayer, !maskLayer.isHidden {
        let tempLayer = CALayer()
        let overlayFrame = self.overlayLayer.frame
        let maskFrame = maskLayer.frame

        tempLayer.frame = CGRect(
          x: overlayFrame.origin.x + maskFrame.origin.x,
          y: overlayFrame.origin.y + maskFrame.origin.y,
          width: maskFrame.width,
          height: maskFrame.height
        )
        tempLayer.contents = maskLayer.contents
        tempLayer.contentsGravity = maskLayer.contentsGravity
        tempLayer.contentsRect = maskLayer.contentsRect
        tempLayer.contentsCenter = maskLayer.contentsCenter
        tempLayer.opacity = maskLayer.opacity
        tempLayer.compositingFilter = maskLayer.compositingFilter
        tempLayer.transform = maskLayer.transform
        tempLayer.masksToBounds = maskLayer.masksToBounds
        self.layer.insertSublayer(tempLayer, above: imageLayer)
        tempMaskLayer = tempLayer
      }

      var tempPoseLayer: CALayer?
      if let poseLayer = self.poseLayer {
        let tempLayer = CALayer()
        let overlayFrame = self.overlayLayer.frame

        tempLayer.frame = CGRect(
          x: overlayFrame.origin.x,
          y: overlayFrame.origin.y,
          width: overlayFrame.width,
          height: overlayFrame.height
        )
        tempLayer.opacity = poseLayer.opacity

        if let sublayers = poseLayer.sublayers {
          for sublayer in sublayers {
            let copyLayer = CALayer()
            copyLayer.frame = sublayer.frame
            copyLayer.backgroundColor = sublayer.backgroundColor
            copyLayer.cornerRadius = sublayer.cornerRadius
            copyLayer.opacity = sublayer.opacity

            if let shapeLayer = sublayer as? CAShapeLayer {
              let copyShapeLayer = CAShapeLayer()
              copyShapeLayer.frame = shapeLayer.frame
              copyShapeLayer.path = shapeLayer.path
              copyShapeLayer.strokeColor = shapeLayer.strokeColor
              copyShapeLayer.lineWidth = shapeLayer.lineWidth
              copyShapeLayer.fillColor = shapeLayer.fillColor
              copyShapeLayer.opacity = shapeLayer.opacity
              tempLayer.addSublayer(copyShapeLayer)
            } else {
              tempLayer.addSublayer(copyLayer)
            }
          }
        }

        self.layer.insertSublayer(tempLayer, above: imageLayer)
        tempPoseLayer = tempLayer
      }

      var tempObbLayer: CALayer?
      if let obbLayer = self.obbLayer, !obbLayer.isHidden {
        let tempLayer = CALayer()
        let overlayFrame = self.overlayLayer.frame

        tempLayer.frame = CGRect(
          x: overlayFrame.origin.x,
          y: overlayFrame.origin.y,
          width: overlayFrame.width,
          height: overlayFrame.height
        )
        tempLayer.opacity = obbLayer.opacity

        if let sublayers = obbLayer.sublayers {
          for sublayer in sublayers {
            if let shapeLayer = sublayer as? CAShapeLayer {
              let copyShapeLayer = CAShapeLayer()
              copyShapeLayer.frame = shapeLayer.frame
              copyShapeLayer.path = shapeLayer.path
              copyShapeLayer.strokeColor = shapeLayer.strokeColor
              copyShapeLayer.lineWidth = shapeLayer.lineWidth
              copyShapeLayer.fillColor = shapeLayer.fillColor
              copyShapeLayer.opacity = shapeLayer.opacity
              tempLayer.addSublayer(copyShapeLayer)
            } else if let textLayer = sublayer as? CATextLayer {
              let copyTextLayer = CATextLayer()
              copyTextLayer.frame = textLayer.frame
              copyTextLayer.string = textLayer.string
              copyTextLayer.font = textLayer.font
              copyTextLayer.fontSize = textLayer.fontSize
              copyTextLayer.foregroundColor = textLayer.foregroundColor
              copyTextLayer.backgroundColor = textLayer.backgroundColor
              copyTextLayer.alignmentMode = textLayer.alignmentMode
              copyTextLayer.opacity = textLayer.opacity
              tempLayer.addSublayer(copyTextLayer)
            }
          }
        }

        self.layer.insertSublayer(tempLayer, above: imageLayer)
        tempObbLayer = tempLayer
      }

      var tempViews = [UIView]()
      let boundingBoxInfos = makeBoundingBoxInfos(from: boundingBoxViews)
      for info in boundingBoxInfos where !info.isHidden {
        let boxView = createBoxView(from: info)
        boxView.frame = info.rect
        self.addSubview(boxView)
        tempViews.append(boxView)
      }
      let bounds = UIScreen.main.bounds
      UIGraphicsBeginImageContextWithOptions(bounds.size, true, 0.0)
      self.drawHierarchy(in: bounds, afterScreenUpdates: true)
      let img = UIGraphicsGetImageFromCurrentImageContext()
      UIGraphicsEndImageContext()

      imageLayer.removeFromSuperlayer()
      tempMaskLayer?.removeFromSuperlayer()
      tempPoseLayer?.removeFromSuperlayer()
      tempObbLayer?.removeFromSuperlayer()
      for v in tempViews {
        v.removeFromSuperview()
      }
      photoCaptureCompletion?(img)
      photoCaptureCompletion = nil
    }
  }

  public func setStreamConfig(_ config: YOLOStreamConfig?) {
    self.streamConfig = config
    setupThrottlingFromConfig()
  }

  public func setStreamCallback(_ callback: (([String: Any]) -> Void)?) {
    self.onStream = callback
  }

  private func setupThrottlingFromConfig() {
    guard let config = streamConfig else { return }

    if let maxFPS = config.maxFPS, maxFPS > 0 {
      targetFrameInterval = 1.0 / Double(maxFPS)
    } else {
      targetFrameInterval = nil
    }

    if let throttleMs = config.throttleIntervalMs, throttleMs > 0 {
      throttleInterval = Double(throttleMs) / 1000.0
    } else {
      throttleInterval = nil
    }

    if let inferenceFreq = config.inferenceFrequency, inferenceFreq > 0 {
      inferenceFrameInterval = 1.0 / Double(inferenceFreq)
    } else {
      inferenceFrameInterval = nil
    }

    if let skipFrames = config.skipFrames, skipFrames > 0 {
      targetSkipFrames = skipFrames
      frameSkipCount = 0
    } else {
      targetSkipFrames = 0
      frameSkipCount = 0
    }

    lastInferenceTime = CACurrentMediaTime()
  }

  private func shouldRunInference() -> Bool {
    let now = CACurrentMediaTime()

    if targetSkipFrames > 0 {
      frameSkipCount += 1
      if frameSkipCount <= targetSkipFrames {
        return false
      } else {
        frameSkipCount = 0
        return true
      }
    }

    if let interval = inferenceFrameInterval {
      if now - lastInferenceTime < interval {
        return false
      }
    }

    return true
  }

  private func shouldProcessFrame() -> Bool {
    let now = CACurrentMediaTime()

    if let interval = targetFrameInterval {
      if now - lastInferenceTime < interval {
        return false
      }
    }

    if let interval = throttleInterval {
      if now - lastInferenceTime < interval {
        return false
      }
    }

    return true
  }

  private func updateLastInferenceTime() {
    lastInferenceTime = CACurrentMediaTime()
  }

  private func convertResultToStreamData(_ result: YOLOResult) -> [String: Any] {
    var map: [String: Any] = [:]
    let config = streamConfig ?? YOLOStreamConfig.DEFAULT

    if config.includeDetections {
      var detections: [[String: Any]] = []

      if config.includePoses && !result.keypointsList.isEmpty && result.boxes.isEmpty {
        for keypoints in result.keypointsList {
          var detection: [String: Any] = [:]
          detection["classIndex"] = 0
          detection["className"] = "person"
          detection["confidence"] = 1.0
          var minX = Float.greatestFiniteMagnitude
          var minY = Float.greatestFiniteMagnitude
          var maxX = -Float.greatestFiniteMagnitude
          var maxY = -Float.greatestFiniteMagnitude

          for kp in keypoints.xy {
            if kp.x > 0 && kp.y > 0 {
              minX = min(minX, kp.x)
              minY = min(minY, kp.y)
              maxX = max(maxX, kp.x)
              maxY = max(maxY, kp.y)
            }
          }
          let boundingBox: [String: Any] = [
            "left": Double(minX),
            "top": Double(minY),
            "right": Double(maxX),
            "bottom": Double(maxY),
          ]
          detection["boundingBox"] = boundingBox

          let normalizedBox: [String: Any] = [
            "left": Double(minX / Float(result.orig_shape.width)),
            "top": Double(minY / Float(result.orig_shape.height)),
            "right": Double(maxX / Float(result.orig_shape.width)),
            "bottom": Double(maxY / Float(result.orig_shape.height)),
          ]
          detection["normalizedBox"] = normalizedBox

          var keypointsFlat: [Double] = []
          for i in 0..<keypoints.xy.count {
            keypointsFlat.append(Double(keypoints.xy[i].x))
            keypointsFlat.append(Double(keypoints.xy[i].y))
            if i < keypoints.conf.count {
              keypointsFlat.append(Double(keypoints.conf[i]))
            } else {
              keypointsFlat.append(0.0)
            }
          }
          detection["keypoints"] = keypointsFlat
          detections.append(detection)
        }
      }

      for (detectionIndex, box) in result.boxes.enumerated() {
        var detection: [String: Any] = [:]
        detection["classIndex"] = box.index
        detection["className"] = box.cls
        detection["confidence"] = Double(box.conf)
        if let distText = lastDistanceByBoxIndex[detectionIndex] {
          detection["distanceText"] = distText
        }

        let boundingBox: [String: Any] = [
          "left": Double(box.xywh.minX),
          "top": Double(box.xywh.minY),
          "right": Double(box.xywh.maxX),
          "bottom": Double(box.xywh.maxY),
        ]
        detection["boundingBox"] = boundingBox

        let normalizedBox: [String: Any] = [
          "left": Double(box.xywhn.minX),
          "top": Double(box.xywhn.minY),
          "right": Double(box.xywhn.maxX),
          "bottom": Double(box.xywhn.maxY),
        ]
        detection["normalizedBox"] = normalizedBox

        if config.includeMasks && result.masks?.masks != nil && detectionIndex < result.masks!.masks.count {
          if let maskData = result.masks?.masks[detectionIndex] {
            let maskDataDouble = maskData.map { row in
              row.map { Double($0) }
            }
            detection["mask"] = maskDataDouble
          }
        }

        if config.includePoses && detectionIndex < result.keypointsList.count {
          let keypoints = result.keypointsList[detectionIndex]
          var keypointsFlat: [Double] = []
          for i in 0..<keypoints.xy.count {
            keypointsFlat.append(Double(keypoints.xy[i].x))
            keypointsFlat.append(Double(keypoints.xy[i].y))
            if i < keypoints.conf.count {
              keypointsFlat.append(Double(keypoints.conf[i]))
            } else {
              keypointsFlat.append(0.0)
            }
          }
          detection["keypoints"] = keypointsFlat
        }

        if config.includeOBB && detectionIndex < result.obb.count {
          let obbResult = result.obb[detectionIndex]
          let obbBox = obbResult.box

          let polygon = obbBox.toPolygon()
          let points = polygon.map { point in
            [
              "x": Double(point.x),
              "y": Double(point.y),
            ]
          }

          let obbDataMap: [String: Any] = [
            "centerX": Double(obbBox.cx),
            "centerY": Double(obbBox.cy),
            "width": Double(obbBox.w),
            "height": Double(obbBox.h),
            "angle": Double(obbBox.angle),
            "angleDegrees": (Double(obbBox.angle) * 180.0 / Double.pi),
            "area": Double(obbBox.area),
            "points": points,
            "confidence": Double(obbResult.confidence),
            "className": obbResult.cls,
            "classIndex": obbResult.index,
          ]

          detection["obb"] = obbDataMap
        }

        detections.append(detection)
      }
      map["detections"] = detections
    }

    if config.includeProcessingTimeMs {
      map["processingTimeMs"] = result.speed * 1000
    }

    if config.includeFps {
      map["fps"] = result.fps ?? 0.0
    }

    if config.includeOriginalImage {
      if let originalImage = result.originalImage {
        if let imageData = originalImage.jpegData(compressionQuality: 0.9) {
          map["originalImage"] = imageData
        }
      }
    }

    return map
  }
}