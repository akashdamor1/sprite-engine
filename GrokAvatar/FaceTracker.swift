import Foundation
import Combine
import AVFoundation
import Vision
import AppKit

/// Camera-based face rect tracking → smoothed yaw/pitch for head + eye look.
final class FaceTracker: NSObject, ObservableObject {
    @Published private(set) var faceDetected: Bool = false
    @Published private(set) var yaw: Float = 0      // −1…1
    @Published private(set) var pitch: Float = 0    // −1…1
    @Published private(set) var cameraAuthorized: Bool = false
    @Published private(set) var statusNote: String = "Camera…"

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.akashdamor.GrokAvatar.faceTracker.session")
    private let visionQueue = DispatchQueue(label: "com.akashdamor.GrokAvatar.faceTracker.vision")
    private var output: AVCaptureVideoDataOutput?
    private var started = false
    private var authorizedLocal = false

    private var smoothYaw: Float = 0
    private var smoothPitch: Float = 0
    private let ema: Float = 0.45
    private var lastFaceAt: CFTimeInterval = 0
    /// Hold last pose longer so brief left-edge Vision misses don't snap eyes to idle.
    private let faceHoldSeconds: CFTimeInterval = 0.55
    private var lastRawYaw: Float = 0
    private var lastRawPitch: Float = 0

    func start() {
        guard !started else { return }
        started = true
        checkAndStart()
    }

    func stop() {
        started = false
        smoothYaw = 0
        smoothPitch = 0
        lastFaceAt = 0
        lastRawYaw = 0
        lastRawPitch = 0
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.faceDetected = false
            self?.yaw = 0
            self?.pitch = 0
            self?.statusNote = "Camera off"
        }
    }

    private func checkAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizedLocal = true
            DispatchQueue.main.async { self.cameraAuthorized = true }
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.authorizedLocal = granted
                DispatchQueue.main.async {
                    self?.cameraAuthorized = granted
                    if granted {
                        self?.configureAndRun()
                    } else {
                        self?.faceDetected = false
                        self?.statusNote = "Camera denied — Settings → Privacy → Camera"
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.cameraAuthorized = false
                self.faceDetected = false
                self.statusNote = "Camera denied — Settings → Privacy → Camera"
            }
        @unknown default:
            DispatchQueue.main.async {
                self.cameraAuthorized = false
                self.statusNote = "Camera status unknown"
            }
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .medium

        // Remove old inputs/outputs if reconfiguring
        for input in session.inputs { session.removeInput(input) }
        for out in session.outputs { session.removeOutput(out) }

        let device =
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)

        guard let device else {
            DispatchQueue.main.async {
                self.cameraAuthorized = true
                self.faceDetected = false
                self.statusNote = "No camera device"
            }
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                DispatchQueue.main.async { self.statusNote = "Cannot add camera input" }
                session.commitConfiguration()
                return
            }
            session.addInput(input)
        } catch {
            DispatchQueue.main.async {
                self.statusNote = "Camera input error: \(error.localizedDescription)"
            }
            session.commitConfiguration()
            return
        }

        let videoOut = AVCaptureVideoDataOutput()
        videoOut.alwaysDiscardsLateVideoFrames = true
        videoOut.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOut.setSampleBufferDelegate(self, queue: visionQueue)
        guard session.canAddOutput(videoOut) else {
            DispatchQueue.main.async { self.statusNote = "Cannot add video output" }
            session.commitConfiguration()
            return
        }
        session.addOutput(videoOut)
        if let conn = videoOut.connection(with: .video) {
            // Mirrored selfie feel for front camera when supported
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
        }
        output = videoOut
        session.commitConfiguration()

        if !session.isRunning {
            session.startRunning()
        }
        authorizedLocal = true
        DispatchQueue.main.async {
            self.cameraAuthorized = true
            self.statusNote = "cam ok · seeking face"
            NSLog("GrokAvatar FaceTracker: session started on %@", device.localizedName)
        }
    }

    private func publish(face: Bool, rawYaw: Float, rawPitch: Float) {
        let now = CACurrentMediaTime()
        if face {
            lastFaceAt = now
            smoothYaw += (rawYaw - smoothYaw) * ema
            smoothPitch += (rawPitch - smoothPitch) * ema
        } else if now - lastFaceAt > faceHoldSeconds {
            // Decay toward neutral
            smoothYaw += (0 - smoothYaw) * 0.12
            smoothPitch += (0 - smoothPitch) * 0.12
            if abs(smoothYaw) < 0.01 { smoothYaw = 0 }
            if abs(smoothPitch) < 0.01 { smoothPitch = 0 }
        }

        let detected = face || (now - lastFaceAt <= faceHoldSeconds)
        let y = max(-1, min(1, smoothYaw))
        let p = max(-1, min(1, smoothPitch))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.faceDetected = detected
            self.yaw = y
            self.pitch = p
            if self.cameraAuthorized {
                if detected {
                    self.statusNote = String(format: "cam ok · face y%.2f p%.2f", y, p)
                } else {
                    self.statusNote = "cam ok · no face"
                }
            }
        }
    }
}

extension FaceTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard started, authorizedLocal else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            // Keep last pose — do not zero (zeros were decaying left looks on dropped frames).
            publish(face: false, rawYaw: lastRawYaw, rawPitch: lastRawPitch)
            return
        }

        // MacBook webcam buffers are upright landscape. `.leftMirrored` is an iPhone
        // portrait EXIF; it skewed Vision's coordinate map and dropped faces more often
        // on one horizontal side (user: right OK, left fails). Use `.up`.
        let landmarksReq = VNDetectFaceLandmarksRequest()
        let rectsReq = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([landmarksReq, rectsReq])
            let landmarkFaces = landmarksReq.results ?? []
            let rectFaces = rectsReq.results ?? []
            // Prefer landmarks obs; fall back to rectangles so left-edge faces still track.
            let faces = landmarkFaces.isEmpty ? rectFaces : landmarkFaces
            guard let face = faces.max(by: { $0.confidence < $1.confidence }) else {
                publish(face: false, rawYaw: lastRawYaw, rawPitch: lastRawPitch)
                return
            }
            let box = face.boundingBox
            // Ignore tiny / garbage boxes (often appear when face is half off left/right).
            guard box.width >= 0.04, box.height >= 0.04 else {
                publish(face: false, rawYaw: lastRawYaw, rawPitch: lastRawPitch)
                return
            }
            var midX = Float(box.midX)
            var midY = Float(box.midY)
            if let lm = face.landmarks {
                func centroid(_ r: VNFaceLandmarkRegion2D?) -> CGPoint? {
                    guard let pts = r?.normalizedPoints, !pts.isEmpty else { return nil }
                    var sx: CGFloat = 0, sy: CGFloat = 0
                    for p in pts { sx += p.x; sy += p.y }
                    let n = CGFloat(pts.count)
                    return CGPoint(x: sx / n, y: sy / n)
                }
                // Prefer both eyes; else nose. If only one eye survives at the left
                // frame edge, keep boundingBox mid (single-eye centroid biases yaw).
                let l = centroid(lm.leftEye)
                let r = centroid(lm.rightEye)
                let nose = centroid(lm.noseCrest) ?? centroid(lm.nose)
                if let l, let r {
                    midX = Float(box.minX) + Float((l.x + r.x) * 0.5) * Float(box.width)
                    midY = Float(box.minY) + Float((l.y + r.y) * 0.5) * Float(box.height)
                } else if let nose {
                    midX = Float(box.minX) + Float(nose.x) * Float(box.width)
                    midY = Float(box.minY) + Float(nose.y) * Float(box.height)
                }
            }
            // Mirror selfie buffers (isVideoMirrored): face left of frame → negative yaw
            // → left sprites. No blanket negate — right-side path already matched UX.
            var rawYaw = (midX - 0.5) * 2.6
            var rawPitch = (midY - 0.52) * 2.4
            rawYaw = max(-1, min(1, rawYaw))
            rawPitch = max(-1, min(1, rawPitch))
            lastRawYaw = rawYaw
            lastRawPitch = rawPitch
            publish(face: true, rawYaw: rawYaw, rawPitch: rawPitch)
        } catch {
            publish(face: false, rawYaw: lastRawYaw, rawPitch: lastRawPitch)
        }
    }
}
