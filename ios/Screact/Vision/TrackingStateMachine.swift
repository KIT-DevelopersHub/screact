import Foundation

enum TrackingState {
    case undetected
    case candidate
    case tracking
    case temporarilyLost
}

/// Direct port of Android's TrackingStateMachine. Promotes to `.tracking` after
/// `detectionsRequired` consecutive detections and tolerates short losses up to `lossTimeoutMs`.
final class TrackingStateMachine {
    private let detectionsRequired: Int
    private let lossTimeoutMs: Int64
    private(set) var state: TrackingState = .undetected
    private var consecutiveDetections = 0
    private var lostAtMs: Int64?

    init(detectionsRequired: Int = 3, lossTimeoutMs: Int64 = 300) {
        self.detectionsRequired = detectionsRequired
        self.lossTimeoutMs = lossTimeoutMs
    }

    @discardableResult
    func update(detected: Bool, timestampMs: Int64) -> TrackingState {
        if detected {
            lostAtMs = nil
            consecutiveDetections += 1
            switch state {
            case .tracking, .temporarilyLost:
                state = .tracking
            case .undetected, .candidate:
                state = consecutiveDetections >= detectionsRequired ? .tracking : .candidate
            }
        } else {
            consecutiveDetections = 0
            switch state {
            case .tracking:
                lostAtMs = timestampMs
                state = .temporarilyLost
            case .temporarilyLost:
                if timestampMs - (lostAtMs ?? timestampMs) >= lossTimeoutMs {
                    lostAtMs = nil
                    state = .undetected
                } else {
                    state = .temporarilyLost
                }
            default:
                state = .undetected
            }
        }
        return state
    }
}
