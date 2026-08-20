import AVFoundation
import Combine
import CoreVideo
import Foundation

/// Port of Android MainViewModel + the camera/vision wiring that MainActivity performs. Owns the
/// capture pipeline: camera frames are routed to the hand or ArUco processor by the current mode,
/// results are forwarded to the WebSocket client, and the derived ProductionUiState is published to
/// the SwiftUI screen.
@MainActor
final class MainViewModel: ObservableObject {
    @Published private(set) var productionState = ProductionUiState()
    @Published private(set) var settings: AppSettings
    @Published private(set) var connection = ConnectionSnapshot(.disconnected)
    @Published private(set) var captureMode: CaptureMode = .tracking

    private let defaults: UserDefaults
    private let trustedStore: TrustedConnectionStore
    private var trustedConnection: TrustedConnection?
    private var currentMode: CaptureMode = .tracking

    private var webSocketClient: YubiBoardWebSocketClient!
    private var trustedCoordinator: TrustedConnectionCoordinator!
    /// Bonjour(_screact._tcp) による PC 自動発見。発見→キー入力ゼロで自動接続する。
    private var bonjour: BonjourDiscovery?
    /// 自動接続を許可しているか。ユーザが明示的に切断したら false にし、勝手な再接続を防ぐ。
    private var bonjourArmed = false

    private(set) lazy var cameraSession: CameraSession = makeCameraSession()
    private var handProcessor: HandLandmarkerProcessor!
    private var arucoProcessor: ArucoMarkerProcessor!

    var savedHost: String { trustedConnection?.host ?? "" }
    var savedPort: Int { trustedConnection?.port ?? Self.defaultPort }
    var hasTrustedPc: Bool { trustedConnection != nil }
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.trustedStore = TrustedConnectionStore(
            values: UserDefaultsTrustedConnectionValues(defaults),
            protector: KeychainResumeTokenProtector()
        )
        self.settings = Self.loadSettings(from: defaults)
        self.trustedConnection = trustedStore.load()

        AppDiagnostics.shared.setEnabled(settings.debugModeEnabled)
        webSocketClient = YubiBoardWebSocketClient(
            deviceId: getOrCreateDeviceId(),
            clientVersion: appVersion,
            onStateChanged: { [weak self] snapshot in
                Task { @MainActor in self?.handleConnectionChanged(snapshot) }
            },
            onModeChanged: { [weak self] mode in
                Task { @MainActor in self?.handleModeChanged(mode) }
            },
            onCalibrationStatus: { [weak self] message in
                Task { @MainActor in self?.handleCalibrationStatus(message) }
            },
            onTrustedConnectionIssued: { [weak self] config, token in
                Task { @MainActor in self?.handleTrustedConnectionIssued(config, token) }
            },
            onTrustedConnectionInvalid: { [weak self] in
                Task { @MainActor in self?.handleTrustedConnectionInvalid() }
            },
            onCalibrationReuseQueued: { [weak self] in
                Task { @MainActor in self?.updateProduction { $0.calibration = .waitingForPc } }
            },
            onLog: { message in AppDiagnostics.shared.event("ui", "log", ["message": message]) }
        )
        trustedCoordinator = TrustedConnectionCoordinator(store: trustedStore) { [weak self] config, automatic in
            self?.webSocketClient.connect(config, automatic: automatic)
        }
        webSocketClient.setMaxFrameRate(settings.maxSendFps)
        makeProcessors()
        trustedCoordinator.autoConnect()
        // 信頼済みPCが無い場合のみ Bonjour 自動発見を起動する（信頼済みなら resume で自動接続され、
        // 無効化されたら handleTrustedConnectionInvalid が Bonjour を起こす）。
        if !hasTrustedPc { armBonjour() }
    }

    // MARK: - Bonjour 自動発見（iOS のゼロコンフィグ接続）

    /// Bonjour ブラウズを開始し、自動接続を許可する。
    private func armBonjour() {
        bonjourArmed = true
        if bonjour == nil {
            bonjour = BonjourDiscovery(
                onDiscovered: { [weak self] config in
                    Task { @MainActor in self?.handleBonjourDiscovered(config) }
                },
                onLog: { message in AppDiagnostics.shared.event("network", "bonjour", ["message": message]) }
            )
        }
        bonjour?.start()
    }

    /// Bonjour ブラウズを停止し、自動接続を止める。
    private func stopBonjour() {
        bonjourArmed = false
        bonjour?.stop()
    }

    /// 発見した PC へ、切断中かつ許可されている時だけ自動接続する（6桁コード入力ゼロ）。
    private func handleBonjourDiscovered(_ config: ConnectionConfig) {
        guard bonjourArmed, connection.status == .disconnected else { return }
        // 1回発見したら発火を止め、以後の再接続は WebSocket クライアントの再接続ロジックに委ねる。
        bonjourArmed = false
        bonjour?.stop()
        updateProduction { $0.notice = nil }
        webSocketClient.connect(config)
    }

    private func makeProcessors() {
        handProcessor = HandLandmarkerProcessor(
            onResult: { [weak self] result in
                Task { @MainActor in self?.submitHand(result) }
            },
            onError: { message in AppDiagnostics.shared.event("vision", "hand_error",
                                                              ["message": message.localizedDescription]) },
            minDetectionConfidence: settings.minDetectionConfidence,
            minPresenceConfidence: settings.minPresenceConfidence,
            minTrackingConfidence: settings.minTrackingConfidence
        )
        arucoProcessor = ArucoMarkerProcessor(
            onResult: { [weak self] result in
                Task { @MainActor in self?.submitCalibration(result) }
            },
            onError: { message in AppDiagnostics.shared.event("vision", "aruco_error",
                                                              ["message": message.localizedDescription]) }
        )
    }

    private func makeCameraSession() -> CameraSession {
        let session = CameraSession(
            onReady: { [weak self] in Task { @MainActor in self?.updateCameraState(.ready) } },
            onError: { [weak self] _ in Task { @MainActor in self?.updateCameraState(.error) } },
            onFrameInfo: { info in
                AppDiagnostics.shared.event("camera", "production_frame_info",
                                            ["actual": "\(info.actualWidth)x\(info.actualHeight)"])
            }
        )
        session.frameConsumer = { [weak self] pixelBuffer, timestamp in
            guard let self else { return }
            // frameConsumer runs on the camera queue; read currentMode (set on main) atomically-ish.
            if self.currentMode == .calibration {
                self.arucoProcessor.process(pixelBuffer, capturedAtMonotonicMs: timestamp)
            } else {
                self.handProcessor.process(pixelBuffer, capturedAtMonotonicMs: timestamp)
            }
        }
        return session
    }

    // MARK: - Camera control

    func startCameraIfAuthorized() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            updateCameraState(.starting)
            cameraSession.start(preferred: .hd720)
        case .notDetermined:
            updateCameraState(.permissionRequired)
        case .denied, .restricted:
            updateCameraState(.permissionDenied)
        @unknown default:
            updateCameraState(.permissionRequired)
        }
    }

    func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.startCameraIfAuthorized()
                } else {
                    self.updateCameraState(.permissionDenied)
                }
            }
        }
    }

    func retryCamera() {
        updateCameraState(.starting)
        cameraSession.start(preferred: .hd720)
    }

    func updateCameraState(_ state: CameraUiState, notice: String? = nil) {
        updateProduction { $0.camera = state; $0.notice = notice }
    }

    // MARK: - Connection actions (mirror Android MainViewModel)

    func connect(host: String, portText: String, pairingToken: String) -> String? {
        guard let port = Int(portText) else { return "ポートは数字で入力してください" }
        let config = ConnectionConfig(host: host.trimmingCharacters(in: .whitespaces),
                                      port: port,
                                      pairingToken: pairingToken.trimmingCharacters(in: .whitespaces))
        if let error = config.validate() { return error }
        webSocketClient.connect(config)
        return nil
    }

    func disconnect() {
        // ユーザが明示的に切断した場合は自動再接続しない。
        stopBonjour()
        webSocketClient.disconnect()
        trustedCoordinator.forget()
        trustedConnection = nil
    }

    func retryNow() { webSocketClient.retryNow() }

    func changeConnectionSettings() {
        webSocketClient.disconnect()
        trustedCoordinator.forget()
        trustedConnection = nil
        updateProduction {
            $0.connection = ConnectionSnapshot(.disconnected)
            $0.calibration = .inactive
            $0.tracking = .inactive
        }
        // 接続先の再選択なので、Bonjour 自動発見を再開してゼロコンフィグ接続へ戻す。
        armBonjour()
    }

    func forgetTrustedPc() { changeConnectionSettings() }

    // MARK: - Vision result handling

    func submitHand(_ result: HandDetectionResult) {
        webSocketClient.submitHand(result)
        updateProduction { current in
            guard current.captureMode == .tracking else { return }
            let nextTracking: TrackingUiState
            switch result.trackingState {
            case .candidate: nextTracking = .candidate
            case .tracking: nextTracking = .tracking
            case .temporarilyLost: nextTracking = .temporarilyLost
            case .undetected:
                if [.tracking, .temporarilyLost, .longLost].contains(current.tracking) {
                    nextTracking = .longLost
                } else {
                    nextTracking = .readyNoHand
                }
            }
            current.tracking = nextTracking
            current.indexTip = result.landmarks.count > 8 ? result.landmarks[8] : nil
            current.sourceWidth = result.sourceWidth
            current.sourceHeight = result.sourceHeight
        }
    }

    func submitCalibration(_ result: MarkerDetectionResult) {
        if result.stable { webSocketClient.submitCalibration(result) }
        updateProduction { current in
            guard current.captureMode == .calibration else { return }
            current.calibration = calibrationUiStateAfterFrame(current.calibration, result)
            current.markers = result.markers
            current.sourceWidth = result.sourceWidth
            current.sourceHeight = result.sourceHeight
        }
    }

    // MARK: - Callbacks from the WebSocket client

    private func handleConnectionChanged(_ snapshot: ConnectionSnapshot) {
        connection = snapshot
        // 接続確立中は Bonjour ブラウズを止めて電力を節約する（再接続は WS クライアントが担う）。
        if snapshot.status == .connected { bonjour?.stop() }
        updateProduction { current in
            let resetCaptureState = snapshot.status != .connected
            current.connection = snapshot
            if resetCaptureState {
                current.calibration = .inactive
                current.tracking = .inactive
            }
        }
    }

    private func handleModeChanged(_ mode: CaptureMode) {
        captureMode = mode
        currentMode = mode
        if mode == .calibration { arucoProcessor.reset() }
        updateProduction { current in
            current.captureMode = mode
            if mode == .calibration {
                current.calibration = .placementWaiting
                current.tracking = .inactive
                current.markers = []
                current.indexTip = nil
            } else {
                current.calibration = .complete
                current.tracking = .readyNoHand
                current.markers = []
            }
        }
    }

    private func handleCalibrationStatus(_ message: CalibrationStatusMessage) {
        let state: CalibrationUiState
        switch message.status {
        case "processing": state = .waitingForPc
        case "complete": state = .complete
        case "retry_required":
            let reason: CalibrationRetryReason
            switch message.reason {
            case "markers_not_visible": reason = .markersNotVisible
            case "invalid_geometry": reason = .invalidGeometry
            case "unstable": reason = .unstable
            case "screen_mismatch": reason = .screenMismatch
            case "internal_error": reason = .internalError
            default: reason = .unknown
            }
            state = .retryRequired(reason: reason)
        default: return
        }
        if case .retryRequired = state { arucoProcessor.reset() }
        updateProduction { $0.calibration = state }
    }

    private func handleTrustedConnectionIssued(_ config: ConnectionConfig, _ resumeToken: String) {
        if trustedCoordinator.save(host: config.host, port: config.port, resumeToken: resumeToken) {
            trustedConnection = trustedStore.load()
        } else {
            updateProduction { $0.notice = "信頼済み接続情報を安全に保存できませんでした。次回は6桁コードが必要です。" }
        }
    }

    private func handleTrustedConnectionInvalid() {
        trustedCoordinator.forget()
        trustedConnection = nil
        updateProduction { $0.notice = "保存済みの接続情報が無効です。6桁コードで接続し直してください。" }
        // 信頼済み接続が無効化されたので、Bonjour 自動発見で PC を探し直す。
        armBonjour()
    }

    // MARK: - Settings

    func updateSettings(_ candidate: AppSettings) -> String? {
        var effective = candidate
        effective.debugModeEnabled = false
        if let error = effective.validate() { return error }
        defaults.set(effective.analysisWidth, forKey: Self.keyAnalysisWidth)
        defaults.set(effective.analysisHeight, forKey: Self.keyAnalysisHeight)
        defaults.set(effective.minDetectionConfidence, forKey: Self.keyDetectionConfidence)
        defaults.set(effective.minPresenceConfidence, forKey: Self.keyPresenceConfidence)
        defaults.set(effective.minTrackingConfidence, forKey: Self.keyTrackingConfidence)
        defaults.set(effective.maxSendFps, forKey: Self.keyMaxSendFps)
        webSocketClient.setMaxFrameRate(effective.maxSendFps)
        AppDiagnostics.shared.setEnabled(effective.debugModeEnabled)
        settings = effective
        return nil
    }

    // MARK: - State plumbing

    private func updateProduction(_ transform: (inout ProductionUiState) -> Void) {
        var next = productionState
        transform(&next)
        productionState = next
    }

    private func getOrCreateDeviceId() -> String {
        if let existing = defaults.string(forKey: Self.keyDeviceId) { return existing }
        let deviceId = "ios-" + UUID().uuidString.prefix(8)
        defaults.set(deviceId, forKey: Self.keyDeviceId)
        return deviceId
    }

    private static func loadSettings(from defaults: UserDefaults) -> AppSettings {
        var s = AppSettings()
        if defaults.object(forKey: keyAnalysisWidth) != nil {
            s.analysisWidth = defaults.integer(forKey: keyAnalysisWidth)
            s.analysisHeight = defaults.integer(forKey: keyAnalysisHeight)
            s.minDetectionConfidence = defaults.float(forKey: keyDetectionConfidence)
            s.minPresenceConfidence = defaults.float(forKey: keyPresenceConfidence)
            s.minTrackingConfidence = defaults.float(forKey: keyTrackingConfidence)
            s.maxSendFps = defaults.integer(forKey: keyMaxSendFps)
        }
        s.debugModeEnabled = false
        return s.validate() == nil ? s : AppSettings()
    }

    func onNetworkLost() { webSocketClient.onNetworkLost() }
    func onNetworkAvailable() { webSocketClient.onNetworkAvailable() }

    func teardown() {
        bonjour?.stop()
        webSocketClient.close()
        cameraSession.stop()
        handProcessor.close()
    }

    // Default desktop port — matches desktop/lib/net/input_server.dart and Android's DEFAULT_PORT.
    static let defaultPort = 8765
    private static let keyDeviceId = "device_id"
    private static let keyAnalysisWidth = "analysis_width"
    private static let keyAnalysisHeight = "analysis_height"
    private static let keyDetectionConfidence = "detection_confidence"
    private static let keyPresenceConfidence = "presence_confidence"
    private static let keyTrackingConfidence = "tracking_confidence"
    private static let keyMaxSendFps = "max_send_fps"
}
