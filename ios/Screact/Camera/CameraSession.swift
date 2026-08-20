import AVFoundation
import CoreVideo

/// Port of Android CameraSession onto AVFoundation. Binds the rear camera, streams BGRA frames on a
/// background queue, and picks the first working profile from the production order (720p -> 540p ->
/// 480p). The pixel-buffer callback feeds the vision processors, mirroring CameraX's analyzer.
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.nxtend.team35.yubiboard.camera")
    private var firstFrameReported = false
    private var activeProfile: CameraProfile = .hd720

    private let onReady: () -> Void
    private let onError: (Error) -> Void
    private let onFrameInfo: (CameraFrameInfo) -> Void

    /// Receives each camera frame as a pixel buffer. Defaults to a no-op.
    var frameConsumer: (CVPixelBuffer, Int64) -> Void = { _, _ in }

    init(onReady: @escaping () -> Void,
         onError: @escaping (Error) -> Void,
         onFrameInfo: @escaping (CameraFrameInfo) -> Void = { _ in }) {
        self.onReady = onReady
        self.onError = onError
        self.onFrameInfo = onFrameInfo
        super.init()
    }

    enum CameraError: Error { case noProfileAvailable, noCamera }

    func start(preferred: CameraProfile = .hd720, allowFallback: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            let profiles: [CameraProfile]
            if allowFallback && !preferred.debugOnly {
                let startIndex = max(CameraProfile.productionOrder.firstIndex(of: preferred) ?? 0, 0)
                profiles = Array(CameraProfile.productionOrder[startIndex...])
            } else {
                profiles = [preferred]
            }
            AppDiagnostics.shared.event("camera", "start_requested",
                                        ["profiles": profiles.map { "\($0.width)x\($0.height)" }.joined(separator: ",")])
            self.bindFirstSupported(profiles)
        }
    }

    private func bindFirstSupported(_ profiles: [CameraProfile]) {
        var lastError: Error = CameraError.noProfileAvailable
        for profile in profiles {
            do {
                try bind(profile)
                return
            } catch {
                lastError = error
                AppDiagnostics.shared.event("camera", "profile_rejected",
                                            ["profile": "\(profile.width)x\(profile.height)",
                                             "message": error.localizedDescription])
            }
        }
        DispatchQueue.main.async { self.onError(lastError) }
    }

    private func bind(_ profile: CameraProfile) throws {
        session.beginConfiguration()
        // Reset inputs/outputs so a fallback profile can rebind cleanly.
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.noProfileAvailable
        }
        session.addInput(input)

        if session.canSetSessionPreset(profile.sessionPreset) {
            session.sessionPreset = profile.sessionPreset
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true // matches STRATEGY_KEEP_ONLY_LATEST
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.noProfileAvailable
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        session.commitConfiguration()
        activeProfile = profile
        firstFrameReported = false
        if !session.isRunning { session.startRunning() }
        AppDiagnostics.shared.gauge("camera.requested_resolution", "\(profile.width)x\(profile.height)")
        AppDiagnostics.shared.event("camera", "ready", ["profile": "\(profile.width)x\(profile.height)"])
        DispatchQueue.main.async { self.onReady() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !firstFrameReported {
            firstFrameReported = true
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let info = CameraFrameInfo(requestedProfile: activeProfile,
                                       actualWidth: width, actualHeight: height, rotationDegrees: 0)
            AppDiagnostics.shared.gauge("camera.actual_resolution", "\(width)x\(height)")
            DispatchQueue.main.async { self.onFrameInfo(info) }
        }
        frameConsumer(pixelBuffer, AppDiagnostics.monotonicMs())
    }
}
