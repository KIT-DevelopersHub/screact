import XCTest
@testable import Screact

/// Verifies the on-the-wire JSON matches what the desktop server (desktop/lib/protocol/messages.dart)
/// parses, and that server messages decode. This is the compatibility contract with the PC app.
final class ProtocolCodecTests: XCTestCase {

    private func json(_ text: String) -> [String: Any] {
        let data = text.data(using: .utf8)!
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func testHelloEncodesExpectedFields() {
        let hello = HelloMessage(deviceId: "ios-abc123", clientVersion: "0.1.0", pairingToken: "123456")
        let obj = json(ProtocolCodec.encode(hello))
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertEqual(obj["messageType"] as? String, "hello")
        XCTAssertEqual(obj["deviceId"] as? String, "ios-abc123")
        XCTAssertEqual(obj["clientVersion"] as? String, "0.1.0")
        XCTAssertEqual(obj["pairingToken"] as? String, "123456")
        XCTAssertNil(obj["resumeToken"], "explicitNulls=false: nil optionals must be omitted")
        XCTAssertEqual(obj["interactionProfile"] as? String, "single_user_single_active_hand")
        XCTAssertEqual((obj["capabilities"] as? [String])?.contains("hand_landmarks_21"), true)
    }

    func testHelloValidationMatchesAndroidInvariants() {
        XCTAssertNil(HelloMessage.validationError(pairingToken: "123456", resumeToken: nil))
        XCTAssertNotNil(HelloMessage.validationError(pairingToken: "123456", resumeToken: "r"))
        XCTAssertNotNil(HelloMessage.validationError(pairingToken: nil, resumeToken: nil))
        XCTAssertNotNil(HelloMessage.validationError(pairingToken: "12", resumeToken: nil))
        XCTAssertNil(HelloMessage.validationError(pairingToken: nil, resumeToken: "resume-token"))
    }

    func testHandFrameDetectedRoundTrip() {
        let landmarks: [[Float]] = (0..<21).map { [Float($0) / 20.0, Float($0) / 40.0, -Float($0) / 100.0] }
        let message = HandFrameMessage(
            sessionId: "session-1",
            frameId: 7,
            capturedAtMonotonicMs: 12345,
            source: SourceInfo(width: 1280, height: 720),
            hand: HandPayload(detected: true, handedness: "RIGHT", handednessScore: 0.98, landmarks: landmarks)
        )
        let obj = json(ProtocolCodec.encode(message))
        XCTAssertEqual(obj["messageType"] as? String, "hand_frame")
        XCTAssertEqual(obj["sessionId"] as? String, "session-1")
        XCTAssertEqual(obj["frameId"] as? Int, 7)
        let source = obj["source"] as? [String: Any]
        XCTAssertEqual(source?["width"] as? Int, 1280)
        XCTAssertEqual(source?["rotationCorrected"] as? Bool, true)
        let hand = obj["hand"] as? [String: Any]
        XCTAssertEqual(hand?["detected"] as? Bool, true)
        XCTAssertEqual(hand?["handedness"] as? String, "RIGHT")
        XCTAssertEqual(hand?["coordinateSpace"] as? String, "normalized_camera")
        XCTAssertEqual(hand?["landmarkFormat"] as? String, "mediapipe_hand_21")
        let lms = hand?["landmarks"] as? [[Double]]
        XCTAssertEqual(lms?.count, 21)
        XCTAssertEqual(lms?.first?.count, 3)
    }

    func testHandFrameNotDetectedOmitsHints() {
        let message = HandFrameMessage(
            sessionId: "s", frameId: 1, capturedAtMonotonicMs: 0,
            source: SourceInfo(width: 640, height: 480),
            hand: HandPayload(detected: false)
        )
        let hand = json(ProtocolCodec.encode(message))["hand"] as? [String: Any]
        XCTAssertEqual(hand?["detected"] as? Bool, false)
        XCTAssertNil(hand?["landmarks"])
        XCTAssertNil(hand?["coordinateSpace"])
        XCTAssertNil(hand?["handedness"])
    }

    func testCalibrationMarkersRoundTrip() {
        let marker = MarkerPayload(id: 10, center: [0.1, 0.1],
                                   corners: [[0.05, 0.05], [0.15, 0.05], [0.15, 0.15], [0.05, 0.15]])
        let message = CalibrationMarkersMessage(
            sessionId: "s", capturedAtMonotonicMs: 42,
            source: SourceInfo(width: 1280, height: 720), markers: [marker])
        let obj = json(ProtocolCodec.encode(message))
        XCTAssertEqual(obj["messageType"] as? String, "calibration_markers")
        let markers = obj["markers"] as? [[String: Any]]
        XCTAssertEqual(markers?.first?["id"] as? Int, 10)
        XCTAssertEqual((markers?.first?["center"] as? [Double])?.count, 2)
        XCTAssertEqual((markers?.first?["corners"] as? [[Double]])?.count, 4)
    }

    func testHeartbeatRoundTrip() {
        let obj = json(ProtocolCodec.encode(HeartbeatMessage(sessionId: "s", sentAtMonotonicMs: 99)))
        XCTAssertEqual(obj["messageType"] as? String, "heartbeat")
        XCTAssertEqual(obj["sentAtMonotonicMs"] as? Int, 99)
    }

    func testDecodeHelloAckFromDesktopShape() {
        // Exactly the shape emitted by desktop/lib/protocol/messages.dart HelloAck.toJson().
        let text = """
        {"schemaVersion":1,"messageType":"hello_ack","sessionId":"session-abcd",
         "surface":{"surfaceId":"primary-display","widthPx":1920,"heightPx":1080},
         "calibrationRequired":true}
        """
        let message = ProtocolCodec.decodeServerMessage(text)
        let ack = message as? HelloAckMessage
        XCTAssertNotNil(ack)
        XCTAssertEqual(ack?.sessionId, "session-abcd")
        XCTAssertEqual(ack?.surface.widthPx, 1920)
        XCTAssertEqual(ack?.calibrationRequired, true)
        XCTAssertNil(ack?.resumeToken)
    }

    func testDecodeControlAndErrorAndStatus() {
        let control = ProtocolCodec.decodeServerMessage(
            #"{"schemaVersion":1,"messageType":"control_message","sessionId":"s","command":"set_mode","mode":"tracking"}"#
        ) as? ControlMessage
        XCTAssertEqual(control?.command, "set_mode")
        XCTAssertEqual(control?.mode, "tracking")

        // Desktop includes a "message" field the client does not model — must be ignored.
        let error = ProtocolCodec.decodeServerMessage(
            #"{"schemaVersion":1,"messageType":"hello_error","code":"pairing_code_mismatch","message":"x","retryable":false}"#
        ) as? HelloErrorMessage
        XCTAssertEqual(error?.code, "pairing_code_mismatch")
        XCTAssertEqual(error?.retryable, false)

        let status = ProtocolCodec.decodeServerMessage(
            #"{"schemaVersion":1,"messageType":"calibration_status","sessionId":"s","status":"complete"}"#
        ) as? CalibrationStatusMessage
        XCTAssertEqual(status?.status, "complete")
    }

    func testDecodeUnknownReturnsNil() {
        XCTAssertNil(ProtocolCodec.decodeServerMessage(#"{"messageType":"totally_unknown"}"#))
        XCTAssertNil(ProtocolCodec.decodeServerMessage("not json"))
    }
}
