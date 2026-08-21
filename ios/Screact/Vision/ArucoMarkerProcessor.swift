import CoreVideo
import Foundation

/// Port of Android ArucoMarkerProcessor. Delegates raw detection to the OpenCV ObjC++ bridge
/// (DICT_4X4_50), keeps only the four expected IDs (10/11/12/13), normalizes corners, and confirms
/// stability via MarkerStabilityTracker — identical dictionary, IDs, and stability rules to Android.
final class ArucoMarkerProcessor {
    private let stabilityTracker = MarkerStabilityTracker()
    private let bridge = ArucoBridge()
    private let onResult: (MarkerDetectionResult) -> Void
    private let onError: (Error) -> Void

    /// True once OpenCV is linked (after `pod install`). When false, detection is a no-op.
    var isAvailable: Bool { ArucoBridge.isAvailable }

    init(onResult: @escaping (MarkerDetectionResult) -> Void,
         onError: @escaping (Error) -> Void) {
        self.onResult = onResult
        self.onError = onError
        if !ArucoBridge.isAvailable {
            onError(NSError(domain: "Screact.Aruco", code: 1,
                            userInfo: [NSLocalizedDescriptionKey:
                                "OpenCV未リンク。`pod install` 後に ArUco 検出が有効になります。"]))
        }
    }

    func process(_ pixelBuffer: CVPixelBuffer, capturedAtMonotonicMs: Int64) {
        guard ArucoBridge.isAvailable else { return }
        let raw = bridge.detectMarkers(in: pixelBuffer)
        var width = CVPixelBufferGetWidth(pixelBuffer)
        var height = CVPixelBufferGetHeight(pixelBuffer)

        var markers: [DetectedMarker] = []
        for entry in raw {
            guard let id = entry["id"] as? Int,
                  MarkerStabilityTracker.expectedIds.contains(id),
                  let flat = entry["corners"] as? [NSNumber], flat.count == 8 else { continue }
            if let w = entry["width"] as? Int { width = w }
            if let h = entry["height"] as? Int { height = h }
            let w = Float(max(width, 1))
            let h = Float(max(height, 1))
            var corners: [NormalizedPoint] = []
            for i in stride(from: 0, to: 8, by: 2) {
                corners.append(NormalizedPoint(x: flat[i].floatValue / w, y: flat[i + 1].floatValue / h))
            }
            let cx = corners.map { $0.x }.reduce(0, +) / Float(corners.count)
            let cy = corners.map { $0.y }.reduce(0, +) / Float(corners.count)
            markers.append(DetectedMarker(id: id, center: NormalizedPoint(x: cx, y: cy), corners: corners))
        }
        markers.sort { $0.id < $1.id }

        let isStable = stabilityTracker.update(markers)
        AppDiagnostics.shared.increment("aruco.frames")
        if isStable { AppDiagnostics.shared.increment("aruco.stable_frames") }
        AppDiagnostics.shared.gauge("aruco.marker_count", markers.count)
        AppDiagnostics.shared.gauge("aruco.stable", isStable)

        onResult(MarkerDetectionResult(
            capturedAtMonotonicMs: capturedAtMonotonicMs,
            sourceWidth: width,
            sourceHeight: height,
            markers: markers,
            stable: isStable,
            stableFrameCount: stabilityTracker.stableFrameCount,
            requiredStableFrames: MarkerStabilityTracker.defaultRequiredStableFrames
        ))
    }

    func reset() {
        stabilityTracker.reset()
        AppDiagnostics.shared.event("vision", "aruco_reset")
    }
}
