import Foundation

/// Encodes client messages and decodes server messages, mirroring Android's ProtocolCodec.
/// JSONEncoder with `.sortedKeys` is intentionally NOT set: field order is irrelevant to the
/// desktop server (it parses a Map), and property declaration order already follows Android.
enum ProtocolCodec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Match Android: nil optionals are omitted (Swift synthesized Codable already does this
        // via encodeIfPresent), non-optional stored properties (incl. defaults) are always emitted.
        return e
    }()

    static let decoder = JSONDecoder()

    static func encode(_ message: HelloMessage) -> String { encodeToString(message) }
    static func encode(_ message: HandFrameMessage) -> String { encodeToString(message) }
    static func encode(_ message: CalibrationMarkersMessage) -> String { encodeToString(message) }
    static func encode(_ message: HeartbeatMessage) -> String { encodeToString(message) }

    private static func encodeToString<T: Encodable>(_ message: T) -> String {
        guard let data = try? encoder.encode(message),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Returns a decoded server message or nil for unknown / malformed input.
    static func decodeServerMessage(_ text: String) -> ServerMessage? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = root["messageType"] as? String else {
            return nil
        }
        switch messageType {
        case "hello_ack": return try? decoder.decode(HelloAckMessage.self, from: data)
        case "control_message": return try? decoder.decode(ControlMessage.self, from: data)
        case "hello_error": return try? decoder.decode(HelloErrorMessage.self, from: data)
        case "calibration_status": return try? decoder.decode(CalibrationStatusMessage.self, from: data)
        default: return nil
        }
    }
}
