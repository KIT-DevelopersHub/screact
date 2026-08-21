import XCTest
@testable import Screact

/// Ports of the Android vision-logic expectations (stability + tracking state machine + the
/// calibration UI reducer) so parity is enforced by tests.
final class VisionLogicTests: XCTestCase {

    private func validLayout() -> [DetectedMarker] {
        func marker(_ id: Int, _ x: Float, _ y: Float) -> DetectedMarker {
            DetectedMarker(id: id,
                           center: NormalizedPoint(x: x, y: y),
                           corners: [NormalizedPoint(x: x - 0.03, y: y - 0.03),
                                     NormalizedPoint(x: x + 0.03, y: y - 0.03),
                                     NormalizedPoint(x: x + 0.03, y: y + 0.03),
                                     NormalizedPoint(x: x - 0.03, y: y + 0.03)])
        }
        return [marker(10, 0.1, 0.1), marker(11, 0.9, 0.1), marker(12, 0.9, 0.9), marker(13, 0.1, 0.9)]
    }

    func testStabilityConfirmsAfterRequiredFrames() {
        let tracker = MarkerStabilityTracker()
        let layout = validLayout()
        var stable = false
        for _ in 0..<4 { stable = tracker.update(layout) }
        XCTAssertFalse(stable, "must not be stable before 5 frames")
        stable = tracker.update(layout)
        XCTAssertTrue(stable, "stable on the 5th consistent frame")
        XCTAssertEqual(tracker.stableFrameCount, 5)
    }

    func testStabilityRejectsWrongIds() {
        let tracker = MarkerStabilityTracker()
        let wrong = [DetectedMarker(id: 1, center: NormalizedPoint(x: 0.1, y: 0.1),
                                    corners: [NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 0.1, y: 0),
                                              NormalizedPoint(x: 0.1, y: 0.1), NormalizedPoint(x: 0, y: 0.1)])]
        for _ in 0..<6 { XCTAssertFalse(tracker.update(wrong)) }
    }

    func testStabilityResetsWhenMarkerMovesTooFar() {
        let tracker = MarkerStabilityTracker()
        for _ in 0..<4 { _ = tracker.update(validLayout()) }
        var moved = validLayout()
        moved[0] = DetectedMarker(id: 10, center: NormalizedPoint(x: 0.5, y: 0.5), corners: moved[0].corners)
        XCTAssertFalse(tracker.update(moved))
        XCTAssertLessThan(tracker.stableFrameCount, 5)
    }

    func testTrackingStateMachinePromotesAndLoses() {
        let machine = TrackingStateMachine(detectionsRequired: 3, lossTimeoutMs: 300)
        XCTAssertEqual(machine.update(detected: true, timestampMs: 0), .candidate)
        XCTAssertEqual(machine.update(detected: true, timestampMs: 10), .candidate)
        XCTAssertEqual(machine.update(detected: true, timestampMs: 20), .tracking)
        XCTAssertEqual(machine.update(detected: false, timestampMs: 30), .temporarilyLost)
        XCTAssertEqual(machine.update(detected: false, timestampMs: 100), .temporarilyLost)
        XCTAssertEqual(machine.update(detected: false, timestampMs: 400), .undetected)
    }

    func testCalibrationReducerFollowsAndroid() {
        let base = MarkerDetectionResult(capturedAtMonotonicMs: 0, sourceWidth: 1, sourceHeight: 1,
                                         markers: [], stable: false)
        XCTAssertEqual(calibrationUiStateAfterFrame(.placementWaiting, base), .placementWaiting)

        let twoMarkers = MarkerDetectionResult(capturedAtMonotonicMs: 0, sourceWidth: 1, sourceHeight: 1,
                                               markers: Array(validLayout().prefix(2)), stable: false)
        XCTAssertEqual(calibrationUiStateAfterFrame(.findingMarkers(found: 0), twoMarkers),
                       .findingMarkers(found: 2))

        let stableResult = MarkerDetectionResult(capturedAtMonotonicMs: 0, sourceWidth: 1, sourceHeight: 1,
                                                 markers: validLayout(), stable: true, stableFrameCount: 5)
        XCTAssertEqual(calibrationUiStateAfterFrame(.stabilizing(current: 3, required: 5), stableResult),
                       .waitingForPc)
    }
}
