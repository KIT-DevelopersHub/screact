import Foundation

struct NormalizedPoint: Equatable {
    let x: Float
    let y: Float
}

struct DetectedMarker: Equatable {
    let id: Int
    let center: NormalizedPoint
    let corners: [NormalizedPoint]
}

struct MarkerDetectionResult {
    let capturedAtMonotonicMs: Int64
    let sourceWidth: Int
    let sourceHeight: Int
    let markers: [DetectedMarker]
    let stable: Bool
    let stableFrameCount: Int
    let requiredStableFrames: Int

    init(capturedAtMonotonicMs: Int64,
         sourceWidth: Int,
         sourceHeight: Int,
         markers: [DetectedMarker],
         stable: Bool,
         stableFrameCount: Int = 0,
         requiredStableFrames: Int = MarkerStabilityTracker.defaultRequiredStableFrames) {
        self.capturedAtMonotonicMs = capturedAtMonotonicMs
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.markers = markers
        self.stable = stable
        self.stableFrameCount = stableFrameCount
        self.requiredStableFrames = requiredStableFrames
    }
}
