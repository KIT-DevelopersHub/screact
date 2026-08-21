import Foundation

/// Port of Android AppSettings. Analysis resolution / confidences / max send fps / debug flag,
/// persisted via UserDefaults in MainViewModel.
struct AppSettings: Equatable {
    var analysisWidth: Int = 1280
    var analysisHeight: Int = 720
    var minDetectionConfidence: Float = 0.5
    var minPresenceConfidence: Float = 0.5
    var minTrackingConfidence: Float = 0.5
    var maxSendFps: Int = 20
    var debugModeEnabled: Bool = false

    static let supportedResolutions: Set<[Int]> = [
        [640, 480],
        [960, 540],
        [1280, 720],
        [1920, 1080],
    ]

    func validate() -> String? {
        if !Self.supportedResolutions.contains([analysisWidth, analysisHeight]) {
            return "未対応の解析解像度です"
        }
        if !(0...1).contains(minDetectionConfidence) { return "検出信頼度は0.0〜1.0です" }
        if !(0...1).contains(minPresenceConfidence) { return "存在信頼度は0.0〜1.0です" }
        if !(0...1).contains(minTrackingConfidence) { return "追跡信頼度は0.0〜1.0です" }
        if !(5...20).contains(maxSendFps) { return "送信fpsは5〜20です" }
        return nil
    }

    func toggledResolution() -> AppSettings {
        var copy = self
        switch [analysisWidth, analysisHeight] {
        case [1280, 720]: copy.analysisWidth = 960; copy.analysisHeight = 540
        case [960, 540]: copy.analysisWidth = 640; copy.analysisHeight = 480
        default: copy.analysisWidth = 1280; copy.analysisHeight = 720
        }
        return copy
    }
}
