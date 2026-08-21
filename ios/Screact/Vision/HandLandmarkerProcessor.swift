import CoreVideo
import Foundation

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision

/// Port of Android HandLandmarkerProcessor using MediaPipe Tasks Vision for iOS. Same model
/// (hand_landmarker.task, 21 points), same LIVE_STREAM running mode, numHands=1, and default 0.5
/// confidences — so detection parity with Android is preserved.
final class HandLandmarkerProcessor: NSObject, HandLandmarkerLiveStreamDelegate {
    private static let modelName = "hand_landmarker"
    private static let handLandmarkCount = 21
    private static let fpsWindowMs: Int64 = 1_000

    private var handLandmarker: HandLandmarker?
    private let onResult: (HandDetectionResult) -> Void
    private let onError: (Error) -> Void
    private let trackingStateMachine = TrackingStateMachine()
    private var frameTimes: [Int64] = []
    // detectAsync requires strictly increasing timestamps; guard against camera clock collisions.
    private var lastTimestampMs: Int = -1

    var isAvailable: Bool { handLandmarker != nil }

    init(onResult: @escaping (HandDetectionResult) -> Void,
         onError: @escaping (Error) -> Void,
         minDetectionConfidence: Float = 0.5,
         minPresenceConfidence: Float = 0.5,
         minTrackingConfidence: Float = 0.5) {
        self.onResult = onResult
        self.onError = onError
        super.init()
        guard let modelPath = Bundle.main.path(forResource: Self.modelName, ofType: "task") else {
            onError(NSError(domain: "Screact.Hand", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "hand_landmarker.task が見つかりません"]))
            return
        }
        let options = HandLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .liveStream
        options.numHands = 1
        options.minHandDetectionConfidence = minDetectionConfidence
        options.minHandPresenceConfidence = minPresenceConfidence
        options.minTrackingConfidence = minTrackingConfidence
        options.handLandmarkerLiveStreamDelegate = self
        do {
            handLandmarker = try HandLandmarker(options: options)
        } catch {
            onError(error)
        }
    }

    func process(_ pixelBuffer: CVPixelBuffer, capturedAtMonotonicMs: Int64) {
        guard let handLandmarker else { return }
        AppDiagnostics.shared.increment("hand.frames_submitted")
        var timestampMs = Int(capturedAtMonotonicMs)
        if timestampMs <= lastTimestampMs { timestampMs = lastTimestampMs + 1 }
        lastTimestampMs = timestampMs
        do {
            let image = try MPImage(pixelBuffer: pixelBuffer)
            try handLandmarker.detectAsync(image: image, timestampInMilliseconds: timestampMs)
        } catch {
            onError(error)
        }
    }

    func handLandmarker(_ handLandmarker: HandLandmarker,
                        didFinishDetection result: HandLandmarkerResult?,
                        timestampInMilliseconds: Int,
                        error: Error?) {
        if let error { onError(error); return }
        let now = AppDiagnostics.monotonicMs()
        frameTimes.append(now)
        frameTimes.removeAll { $0 < now - Self.fpsWindowMs }

        let landmarks = (result?.landmarks.first ?? []).map { LandmarkPoint(x: $0.x, y: $0.y, z: $0.z) }
        let category = result?.handedness.first?.first
        let detected = landmarks.count == Self.handLandmarkCount
        AppDiagnostics.shared.increment("hand.results")
        AppDiagnostics.shared.increment(detected ? "hand.detected" : "hand.missing")

        let timestampMs = Int64(timestampInMilliseconds)
        let trackingState = trackingStateMachine.update(detected: detected, timestampMs: timestampMs)
        let fps = Float(frameTimes.count) * 1000 / Float(Self.fpsWindowMs)
        onResult(HandDetectionResult(
            capturedAtMonotonicMs: timestampMs,
            sourceWidth: 0,
            sourceHeight: 0,
            detected: detected,
            trackingState: trackingState,
            landmarks: landmarks,
            handedness: category?.categoryName?.uppercased(),
            handednessScore: category?.score,
            inferenceTimeMs: max(now - timestampMs, 0),
            framesPerSecond: fps
        ))
    }

    func close() {
        handLandmarker = nil
    }
}

#else

/// Stub used until the MediaPipe pod is installed. Keeps the app + tests building; reports that hand
/// detection is unavailable so the UI can surface it, exactly like a failed initializer on Android.
final class HandLandmarkerProcessor {
    private let onResult: (HandDetectionResult) -> Void
    private let onError: (Error) -> Void
    var isAvailable: Bool { false }

    init(onResult: @escaping (HandDetectionResult) -> Void,
         onError: @escaping (Error) -> Void,
         minDetectionConfidence: Float = 0.5,
         minPresenceConfidence: Float = 0.5,
         minTrackingConfidence: Float = 0.5) {
        self.onResult = onResult
        self.onError = onError
        onError(NSError(domain: "Screact.Hand", code: 2,
                        userInfo: [NSLocalizedDescriptionKey:
                            "MediaPipe未リンク。`pod install` 後に手検出が有効になります。"]))
    }

    func process(_ pixelBuffer: CVPixelBuffer, capturedAtMonotonicMs: Int64) {}
    func close() {}
}

#endif
