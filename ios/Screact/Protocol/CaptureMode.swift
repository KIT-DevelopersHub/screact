import Foundation

/// Capture mode requested by the desktop server (protocol v1).
/// JSON string values ("tracking" / "calibration") mirror the Android enum's @SerialName values.
enum CaptureMode: String {
    case tracking
    case calibration
}
