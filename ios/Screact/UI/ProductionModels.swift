import Foundation

/// Port of Android ProductionModels: the UI state machine that drives the guide panel. The stage /
/// visualState mapping is a faithful translation so the SwiftUI screen follows the exact same
/// connection / calibration / tracking transitions as Compose.

enum CameraUiState {
    case permissionRequired
    case permissionDenied
    case starting
    case ready
    case error
}

enum CalibrationRetryReason {
    case markersNotVisible
    case invalidGeometry
    case unstable
    case screenMismatch
    case internalError
    case unknown
}

enum CalibrationUiState: Equatable {
    case inactive
    case placementWaiting
    case findingMarkers(found: Int)
    case stabilizing(current: Int, required: Int)
    case waitingForPc
    case retryRequired(reason: CalibrationRetryReason)
    case complete
}

func calibrationUiStateAfterFrame(_ current: CalibrationUiState,
                                  _ result: MarkerDetectionResult) -> CalibrationUiState {
    if current == .waitingForPc || current == .complete { return current }
    if result.stable { return .waitingForPc }
    if current == .placementWaiting && result.markers.isEmpty { return .placementWaiting }
    if case .retryRequired = current, result.markers.isEmpty { return current }
    if result.markers.count < 4 { return .findingMarkers(found: result.markers.count) }
    return .stabilizing(current: result.stableFrameCount, required: result.requiredStableFrames)
}

enum TrackingUiState {
    case inactive
    case readyNoHand
    case candidate
    case tracking
    case temporarilyLost
    case longLost
}

enum ProductionStage {
    case cameraPermission
    case cameraError
    case connect
    case connecting
    case autoConnecting
    case connectionError
    case reconnecting
    case calibration
    case ready
}

enum ProductionVisualState {
    case cameraPermission
    case cameraError
    case connectionForm
    case connectionProgress
    case reconnecting
    case placement
    case calibrationProgress
    case readyIdle
    case readyActive
}

struct ProductionUiState {
    var camera: CameraUiState = .starting
    var connection: ConnectionSnapshot = ConnectionSnapshot(.disconnected)
    var captureMode: CaptureMode = .tracking
    var calibration: CalibrationUiState = .inactive
    var tracking: TrackingUiState = .inactive
    var indexTip: LandmarkPoint?
    var markers: [DetectedMarker] = []
    var sourceWidth: Int = 0
    var sourceHeight: Int = 0
    var notice: String?

    var stage: ProductionStage {
        if camera == .permissionRequired || camera == .permissionDenied { return .cameraPermission }
        if camera == .error { return .cameraError }
        switch connection.status {
        case .error: return .connectionError
        case .reconnecting: return .reconnecting
        case .connecting, .awaitingAck: return connection.automatic ? .autoConnecting : .connecting
        case .disconnected: return .connect
        case .connected:
            return captureMode == .calibration ? .calibration : .ready
        }
    }

    var visualState: ProductionVisualState {
        switch stage {
        case .cameraPermission: return .cameraPermission
        case .cameraError: return .cameraError
        case .connect, .connectionError: return .connectionForm
        case .connecting, .autoConnecting: return .connectionProgress
        case .reconnecting: return .reconnecting
        case .calibration:
            return calibration == .placementWaiting ? .placement : .calibrationProgress
        case .ready:
            switch tracking {
            case .candidate, .tracking, .temporarilyLost, .longLost: return .readyActive
            default: return .readyIdle
            }
        }
    }
}
