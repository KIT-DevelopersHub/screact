import AVFoundation

/// Port of Android CameraProfile. The production order mirrors Android (720p -> 540p -> 480p),
/// and — like Android's DEFAULT_BACK_CAMERA — Screact uses the rear camera.
enum CameraProfile: CaseIterable {
    case hd720
    case qhd540
    case vga480
    case fhd1080

    var width: Int {
        switch self {
        case .hd720: return 1280
        case .qhd540: return 960
        case .vga480: return 640
        case .fhd1080: return 1920
        }
    }

    var height: Int {
        switch self {
        case .hd720: return 720
        case .qhd540: return 540
        case .vga480: return 480
        case .fhd1080: return 1080
        }
    }

    var debugOnly: Bool { self == .fhd1080 }

    /// The closest AVCaptureSession preset for this profile.
    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd720: return .hd1280x720
        case .qhd540: return .iFrame960x540
        case .vga480: return .vga640x480
        case .fhd1080: return .hd1920x1080
        }
    }

    static let productionOrder: [CameraProfile] = [.hd720, .qhd540, .vga480]

    static func from(width: Int, height: Int) -> CameraProfile {
        allCases.first { $0.width == width && $0.height == height } ?? .hd720
    }
}

struct CameraFrameInfo {
    let requestedProfile: CameraProfile
    let actualWidth: Int
    let actualHeight: Int
    let rotationDegrees: Int
}
