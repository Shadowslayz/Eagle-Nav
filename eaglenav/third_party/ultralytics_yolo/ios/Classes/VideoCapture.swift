// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//
//  Patched VideoCapture.swift
//  Adds depth capture support for LiDAR / TrueDepth-capable back cameras,
//  while keeping the original Ultralytics camera pipeline intact.
//

import AVFoundation
import CoreVideo
import UIKit
import Vision

@MainActor
protocol VideoCaptureDelegate: AnyObject {
  func onPredict(result: YOLOResult)
  func onInferenceTime(speed: Double, fps: Double)
}

func bestCaptureDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice {
  if position == .back {
      if #available(iOS 15.4, *) {
          if let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: position) {
              return device
          }
      } else {
          // Fallback on earlier versions
      }
    if UserDefaults.standard.bool(forKey: "use_telephoto"),
      let device = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: position)
    {
      return device
    }
    if let device = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: position) {
      return device
    }
    if let device = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: position) {
      return device
    }
  }

  if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
    return device
  }

  fatalError("Missing expected camera device.")
}

class VideoCapture: NSObject, @unchecked Sendable {
  var predictor: Predictor!
  var previewLayer: AVCaptureVideoPreviewLayer?
  weak var delegate: VideoCaptureDelegate?
  var captureDevice: AVCaptureDevice?
  let captureSession = AVCaptureSession()
  var videoInput: AVCaptureDeviceInput? = nil
  let videoOutput = AVCaptureVideoDataOutput()
  var photoOutput = AVCapturePhotoOutput()
  let depthOutput = AVCaptureDepthDataOutput()
  let cameraQueue = DispatchQueue(label: "camera-queue")
  let depthQueue = DispatchQueue(label: "depth-queue")
  var lastCapturedPhoto: UIImage? = nil
  var inferenceOK = true
  var longSide: CGFloat = 3
  var shortSide: CGFloat = 4
  var frameSizeCaptured = false
  private var currentBuffer: CVPixelBuffer?
  private let depthLock = NSLock()
  private var cachedDepthPixelBuffer: CVPixelBuffer?
  private var cachedCalibrationData: AVCameraCalibrationData?

  func latestDepthData() -> (depthPixelBuffer: CVPixelBuffer?, calibrationData: AVCameraCalibrationData?) {
    depthLock.lock()
    defer { depthLock.unlock() }
    return (cachedDepthPixelBuffer, cachedCalibrationData)
  }

  private func clearDepthData() {
    depthLock.lock()
    cachedDepthPixelBuffer = nil
    cachedCalibrationData = nil
    depthLock.unlock()
  }

  private func storeDepthData(_ depthData: AVDepthData) {
    let convertedDepth: AVDepthData
    if depthData.depthDataType == kCVPixelFormatType_DepthFloat32 {
      convertedDepth = depthData
    } else {
      convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    }

    depthLock.lock()
    cachedDepthPixelBuffer = convertedDepth.depthDataMap
    cachedCalibrationData = convertedDepth.cameraCalibrationData
    depthLock.unlock()
  }

  func setUp(
    sessionPreset: AVCaptureSession.Preset = .hd1280x720,
    position: AVCaptureDevice.Position,
    orientation: UIDeviceOrientation,
    completion: @escaping (Bool) -> Void
  ) {
    cameraQueue.async {
      let success = self.setUpCamera(
        sessionPreset: sessionPreset,
        position: position,
        orientation: orientation)
      DispatchQueue.main.async {
        completion(success)
      }
    }
  }

  func setUpCamera(
    sessionPreset: AVCaptureSession.Preset,
    position: AVCaptureDevice.Position,
    orientation: UIDeviceOrientation
  ) -> Bool {
    captureSession.beginConfiguration()
    captureSession.sessionPreset = sessionPreset

    clearDepthData()

    let selectedDevice = bestCaptureDevice(position: position)
    captureDevice = selectedDevice

    guard let videoInput = try? AVCaptureDeviceInput(device: selectedDevice) else {
      print("VideoCapture: Failed to create AVCaptureDeviceInput for \(selectedDevice)")
      captureSession.commitConfiguration()
      return false
    }
    self.videoInput = videoInput

    if captureSession.canAddInput(videoInput) {
      captureSession.addInput(videoInput)
    } else {
      print("VideoCapture: Could not add video input to capture session")
      captureSession.commitConfiguration()
      return false
    }

    var videoOrientation = AVCaptureVideoOrientation.portrait
    switch orientation {
    case .portrait:
      videoOrientation = .portrait
    case .landscapeLeft:
      videoOrientation = .landscapeRight
    case .landscapeRight:
      videoOrientation = .landscapeLeft
    default:
      videoOrientation = .portrait
    }

    let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    previewLayer.videoGravity = .resizeAspectFill
    previewLayer.connection?.videoOrientation = videoOrientation
    self.previewLayer = previewLayer

    let settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
    ]
    videoOutput.videoSettings = settings
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)
    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    } else {
      print("VideoCapture: Could not add video output to capture session")
      captureSession.commitConfiguration()
      return false
    }

    if captureSession.canAddOutput(photoOutput) {
      captureSession.addOutput(photoOutput)
      photoOutput.isHighResolutionCaptureEnabled = true
    }

    configureDepthCaptureIfPossible(for: selectedDevice, orientation: videoOrientation)

    let connection = videoOutput.connection(with: .video)
    connection?.videoOrientation = videoOrientation
    connection?.isVideoMirrored = (position == .front)

    do {
      try selectedDevice.lockForConfiguration()
      defer { selectedDevice.unlockForConfiguration() }

      if selectedDevice.isFocusModeSupported(.continuousAutoFocus),
        selectedDevice.isFocusPointOfInterestSupported
      {
        selectedDevice.focusMode = .continuousAutoFocus
        selectedDevice.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
      }

      if selectedDevice.isExposureModeSupported(.continuousAutoExposure) {
        selectedDevice.exposureMode = .continuousAutoExposure
      }
    } catch {
      print("VideoCapture: device configuration failed: \(error.localizedDescription)")
    }

    captureSession.commitConfiguration()
    return true
  }

  private func configureDepthCaptureIfPossible(
    for device: AVCaptureDevice,
    orientation: AVCaptureVideoOrientation
  ) {
    guard !device.activeFormat.supportedDepthDataFormats.isEmpty else {
      return
    }

    guard captureSession.canAddOutput(depthOutput) else {
      print("VideoCapture: Depth output is not supported for this session/device combination")
      return
    }

    captureSession.addOutput(depthOutput)
    depthOutput.isFilteringEnabled = true
    depthOutput.setDelegate(self, callbackQueue: depthQueue)

    if let depthConnection = depthOutput.connection(with: .depthData) {
      depthConnection.isEnabled = true
      if depthConnection.isVideoOrientationSupported {
        depthConnection.videoOrientation = orientation
      }
    }

    let preferredFormat = device.activeFormat.supportedDepthDataFormats.first {
      CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
    } ?? device.activeFormat.supportedDepthDataFormats.first

    guard let selectedDepthFormat = preferredFormat else {
      return
    }

    do {
      try device.lockForConfiguration()
      device.activeDepthDataFormat = selectedDepthFormat
      device.unlockForConfiguration()
    } catch {
      print("VideoCapture: Failed to configure depth format: \(error.localizedDescription)")
    }
  }

  func start() {
    if !captureSession.isRunning {
      DispatchQueue.global().async {
        self.captureSession.startRunning()
      }
    }
  }

  func stop() {
    if captureSession.isRunning {
      DispatchQueue.global().async {
        self.captureSession.stopRunning()
      }
    }
  }

  func setZoomRatio(ratio: CGFloat) {
    guard let captureDevice else { return }
    do {
      try captureDevice.lockForConfiguration()
      defer { captureDevice.unlockForConfiguration() }
      captureDevice.videoZoomFactor = ratio
    } catch {
      print("VideoCapture: Failed to set zoom ratio: \(error.localizedDescription)")
    }
  }

  private func predictOnFrame(sampleBuffer: CMSampleBuffer) {
    guard let predictor = predictor else {
      print("predictor is nil")
      return
    }

    if currentBuffer == nil, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      currentBuffer = pixelBuffer
      if !frameSizeCaptured {
        let frameWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        longSide = max(frameWidth, frameHeight)
        shortSide = min(frameWidth, frameHeight)
        frameSizeCaptured = true
      }

      predictor.predict(sampleBuffer: sampleBuffer, onResultsListener: self, onInferenceTime: self)
      currentBuffer = nil
    }
  }

  func updateVideoOrientation(orientation: AVCaptureVideoOrientation) {
    guard let connection = videoOutput.connection(with: .video) else {
      return
    }
    connection.videoOrientation = orientation
    let currentInput = self.captureSession.inputs.first as? AVCaptureDeviceInput
    connection.isVideoMirrored = (currentInput?.device.position == .front)
    self.previewLayer?.connection?.videoOrientation = connection.videoOrientation

    if let depthConnection = depthOutput.connection(with: .depthData),
      depthConnection.isVideoOrientationSupported
    {
      depthConnection.videoOrientation = orientation
    }
  }

  deinit {
    print("VideoCapture: deinit called - ensuring capture session is stopped")
    clearDepthData()

    if captureSession.isRunning {
      captureSession.stopRunning()
    }

    if let inputs = captureSession.inputs as? [AVCaptureInput] {
      for input in inputs {
        captureSession.removeInput(input)
      }
    }

    if let outputs = captureSession.outputs as? [AVCaptureOutput] {
      for output in outputs {
        captureSession.removeOutput(output)
      }
    }

    print("VideoCapture: deinit completed")
  }
}

extension VideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard inferenceOK else { return }
    predictOnFrame(sampleBuffer: sampleBuffer)
  }
}

extension VideoCapture: AVCaptureDepthDataOutputDelegate {
  func depthDataOutput(
    _ output: AVCaptureDepthDataOutput,
    didOutput depthData: AVDepthData,
    timestamp: CMTime,
    connection: AVCaptureConnection
  ) {
    storeDepthData(depthData)
  }
}

extension VideoCapture: AVCapturePhotoCaptureDelegate {
  @available(iOS 11.0, *)
  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
      return
    }
    self.lastCapturedPhoto = image
  }
}

extension VideoCapture: ResultsListener, InferenceTimeListener {
  func on(inferenceTime: Double, fpsRate: Double) {
    DispatchQueue.main.async {
      self.delegate?.onInferenceTime(speed: inferenceTime, fps: fpsRate)
    }
  }

  func on(result: YOLOResult) {
    DispatchQueue.main.async {
      self.delegate?.onPredict(result: result)
    }
  }
}
