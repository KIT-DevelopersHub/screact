import Foundation

struct LandmarkPoint: Equatable {
    let x: Float
    let y: Float
    let z: Float
}

struct HandDetectionResult {
    let capturedAtMonotonicMs: Int64
    let sourceWidth: Int
    let sourceHeight: Int
    let detected: Bool
    let trackingState: TrackingState
    let landmarks: [LandmarkPoint]
    let handedness: String?
    let handednessScore: Float?
    let inferenceTimeMs: Int64
    let framesPerSecond: Float

    init(capturedAtMonotonicMs: Int64,
         sourceWidth: Int,
         sourceHeight: Int,
         detected: Bool,
         trackingState: TrackingState? = nil,
         landmarks: [LandmarkPoint] = [],
         handedness: String? = nil,
         handednessScore: Float? = nil,
         inferenceTimeMs: Int64 = 0,
         framesPerSecond: Float = 0) {
        self.capturedAtMonotonicMs = capturedAtMonotonicMs
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.detected = detected
        self.trackingState = trackingState ?? (detected ? .tracking : .undetected)
        self.landmarks = landmarks
        self.handedness = handedness
        self.handednessScore = handednessScore
        self.inferenceTimeMs = inferenceTimeMs
        self.framesPerSecond = framesPerSecond
    }
}
