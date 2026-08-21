import Foundation

/// Protocol v1 message models. JSON field names are camelCase and MUST stay byte-compatible with
/// the Android client (android/.../protocol/Messages.kt) so the existing desktop server
/// (desktop/lib/net/input_server.dart, desktop/lib/protocol/messages.dart) accepts them unchanged.
///
/// Encoding rules matched to Android's kotlinx.serialization config:
///   - encodeDefaults = true  -> Swift stored properties (incl. defaults) are always encoded.
///   - explicitNulls = false  -> Swift's synthesized Codable omits nil optionals (encodeIfPresent).
///   - ignoreUnknownKeys = true (decode) -> Swift Codable ignores keys it does not declare.

let kSchemaVersion = 1

// MARK: - Client -> Server

struct HelloMessage: Encodable {
    var schemaVersion: Int = kSchemaVersion
    var messageType: String = "hello"
    let deviceId: String
    var client: String = "yubiboard-ios"
    let clientVersion: String
    var pairingToken: String?
    var resumeToken: String?
    var interactionProfile: String = "single_user_single_active_hand"
    var coordinateSpace: String = "normalized_camera"
    var capabilities: [String] = [
        "aruco_calibration",
        "hand_landmarks_21",
        "calibration_status",
        "hello_error",
        "trusted_reconnect",
    ]

    /// Mirrors the Android `init` invariants: exactly one of pairingToken/resumeToken,
    /// pairingToken must be six digits. Returns nil when valid, otherwise an error string.
    static func validationError(pairingToken: String?, resumeToken: String?) -> String? {
        if (pairingToken != nil) == (resumeToken != nil) {
            return "Exactly one of pairingToken or resumeToken is required"
        }
        if let token = pairingToken, token.range(of: "^[0-9]{6}$", options: .regularExpression) == nil {
            return "pairingToken must be six digits"
        }
        if let resume = resumeToken, resume.isEmpty {
            return "resumeToken must not be blank"
        }
        return nil
    }
}

struct SourceInfo: Encodable {
    let width: Int
    let height: Int
    var rotationDegrees: Int = 0
    var rotationCorrected: Bool = true
    var mirrorCorrected: Bool = true
}

struct HandPayload: Encodable {
    let detected: Bool
    var handedness: String?
    var handednessScore: Float?
    var coordinateSpace: String?
    var landmarkFormat: String?
    var landmarks: [[Float]]?

    /// Matches Android's computed defaults: the coordinate-space / format hints are only present
    /// when a hand is detected.
    init(detected: Bool,
         handedness: String? = nil,
         handednessScore: Float? = nil,
         landmarks: [[Float]]? = nil) {
        self.detected = detected
        self.handedness = handedness
        self.handednessScore = handednessScore
        self.coordinateSpace = detected ? "normalized_camera" : nil
        self.landmarkFormat = detected ? "mediapipe_hand_21" : nil
        self.landmarks = landmarks
    }
}

struct HandFrameMessage: Encodable {
    var schemaVersion: Int = kSchemaVersion
    var messageType: String = "hand_frame"
    let sessionId: String
    let frameId: Int64
    let capturedAtMonotonicMs: Int64
    var source: SourceInfo?
    let hand: HandPayload
}

struct MarkerPayload: Encodable {
    let id: Int
    let center: [Float]
    let corners: [[Float]]
}

struct CalibrationMarkersMessage: Encodable {
    var schemaVersion: Int = kSchemaVersion
    var messageType: String = "calibration_markers"
    let sessionId: String
    let capturedAtMonotonicMs: Int64
    let source: SourceInfo
    let markers: [MarkerPayload]
}

struct HeartbeatMessage: Encodable {
    var schemaVersion: Int = kSchemaVersion
    var messageType: String = "heartbeat"
    let sessionId: String
    let sentAtMonotonicMs: Int64
}

// MARK: - Server -> Client

protocol ServerMessage {}

struct SurfaceInfo: Decodable {
    let surfaceId: String
    let widthPx: Int
    let heightPx: Int
}

struct HelloAckMessage: Decodable, ServerMessage {
    let schemaVersion: Int
    let messageType: String
    let sessionId: String
    let surface: SurfaceInfo
    let calibrationRequired: Bool
    let resumeToken: String?
}

struct ControlMessage: Decodable, ServerMessage {
    let schemaVersion: Int
    let messageType: String
    let sessionId: String
    let command: String
    let mode: String?
}

struct HelloErrorMessage: Decodable, ServerMessage {
    let schemaVersion: Int
    let messageType: String
    let code: String
    var retryable: Bool = false

    enum CodingKeys: String, CodingKey {
        case schemaVersion, messageType, code, retryable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        messageType = try c.decode(String.self, forKey: .messageType)
        code = try c.decode(String.self, forKey: .code)
        retryable = (try? c.decode(Bool.self, forKey: .retryable)) ?? false
    }
}

struct CalibrationStatusMessage: Decodable, ServerMessage {
    let schemaVersion: Int
    let messageType: String
    let sessionId: String
    let status: String
    let reason: String?
}
