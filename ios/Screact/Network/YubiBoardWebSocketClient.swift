import Foundation

/// Port of Android YubiBoardWebSocketClient using URLSessionWebSocketTask.
///
/// Wire compatibility with the desktop server (desktop/lib/net/input_server.dart):
///   - Endpoint ws://host:port/ws/v1/input, default port 8765.
///   - URLSessionWebSocketTask does NOT negotiate permessage-deflate, matching the server's
///     compression-off requirement (the reason Android disabled OkHttp compression).
///   - Sends hello / hand_frame / calibration_markers / heartbeat; handles hello_ack /
///     hello_error / control_message / calibration_status.
///
/// Backpressure: URLSession has no queueSize API, so we approximate Android's MAX_QUEUE_BYTES gate
/// with an in-flight byte counter (incremented before send, decremented on completion).
final class YubiBoardWebSocketClient: NSObject, URLSessionWebSocketDelegate {
    // Tunables mirror the Android companion constants.
    private static let normalCloseCode = URLSessionWebSocketTask.CloseCode.normalClosure
    private static let ackTimeoutSeconds: TimeInterval = 5
    private static let heartbeatSeconds: TimeInterval = 5
    private static let frameIntervalMsDefault: Int64 = 50
    private static let senderTickMs: Int = 20
    private static let calibrationIntervalMs: Int = 200
    private static let maxQueueBytes: Int = 256 * 1024
    private static let retryDelaysMs: [Int] = [1_000, 2_000, 4_000, 8_000, 10_000]

    private let deviceId: String
    private let clientVersion: String

    var onStateChanged: (ConnectionSnapshot) -> Void
    var onModeChanged: (CaptureMode) -> Void
    var onCalibrationStatus: (CalibrationStatusMessage) -> Void
    var onTrustedConnectionIssued: (ConnectionConfig, String) -> Void
    var onTrustedConnectionInvalid: () -> Void
    var onCalibrationReuseQueued: () -> Void
    var onLog: (String) -> Void

    private let lock = DispatchQueue(label: "com.nxtend.team35.yubiboard.ws")
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // State (guarded by `lock`).
    private var frameId: Int64 = 0
    private var targetFrameIntervalMs: Int64 = frameIntervalMsDefault
    private var lastHandSentAtMs: Int64 = 0
    private var latestHand: HandDetectionResult?
    private var latestCalibration: MarkerDetectionResult?
    private var lastStableCalibration: MarkerDetectionResult?
    private var desiredConfig: ConnectionConfig?
    private var automaticConnection = false
    private var task: URLSessionWebSocketTask?
    private var sessionId: String?
    private var reconnectAttempt = 0
    private var manuallyStopped = true
    private var pendingErrorCode: ConnectionErrorCode?
    private var calibrationConfirmed = false
    private var calibrationRequested = false
    private var inFlightBytes = 0

    private var heartbeatTimer: DispatchSourceTimer?
    private var reconnectWork: DispatchWorkItem?
    private var countdownTimer: DispatchSourceTimer?
    private var senderTimer: DispatchSourceTimer?
    private var calibrationTimer: DispatchSourceTimer?

    init(deviceId: String,
         clientVersion: String,
         onStateChanged: @escaping (ConnectionSnapshot) -> Void,
         onModeChanged: @escaping (CaptureMode) -> Void,
         onCalibrationStatus: @escaping (CalibrationStatusMessage) -> Void = { _ in },
         onTrustedConnectionIssued: @escaping (ConnectionConfig, String) -> Void = { _, _ in },
         onTrustedConnectionInvalid: @escaping () -> Void = {},
         onCalibrationReuseQueued: @escaping () -> Void = {},
         onLog: @escaping (String) -> Void = { _ in }) {
        self.deviceId = deviceId
        self.clientVersion = clientVersion
        self.onStateChanged = onStateChanged
        self.onModeChanged = onModeChanged
        self.onCalibrationStatus = onCalibrationStatus
        self.onTrustedConnectionIssued = onTrustedConnectionIssued
        self.onTrustedConnectionInvalid = onTrustedConnectionInvalid
        self.onCalibrationReuseQueued = onCalibrationReuseQueued
        self.onLog = onLog
        super.init()
        startSenderTimers()
    }

    private func startSenderTimers() {
        let sender = DispatchSource.makeTimerSource(queue: lock)
        sender.schedule(deadline: .now(), repeating: .milliseconds(Self.senderTickMs))
        sender.setEventHandler { [weak self] in self?.flushLatestHandLocked() }
        sender.resume()
        senderTimer = sender

        let calibration = DispatchSource.makeTimerSource(queue: lock)
        calibration.schedule(deadline: .now(), repeating: .milliseconds(Self.calibrationIntervalMs))
        calibration.setEventHandler { [weak self] in self?.flushLatestCalibrationLocked() }
        calibration.resume()
        calibrationTimer = calibration
    }

    // MARK: - Public API

    func connect(_ config: ConnectionConfig, automatic: Bool = false) {
        precondition(config.validate() == nil, config.validate() ?? "")
        lock.async {
            AppDiagnostics.shared.event("network", "connect_requested",
                                        ["host": config.host, "port": config.port])
            self.manuallyStopped = false
            self.desiredConfig = config
            self.automaticConnection = automatic
            self.reconnectAttempt = 0
            self.calibrationConfirmed = false
            self.calibrationRequested = false
            self.lastStableCalibration = nil
            self.cancelTimersLocked()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.openSocketLocked(config, reconnecting: false)
        }
    }

    func submitHand(_ result: HandDetectionResult) {
        lock.async {
            if self.latestHand != nil { AppDiagnostics.shared.increment("network.hand_replaced") }
            self.latestHand = result
        }
    }

    func submitCalibration(_ result: MarkerDetectionResult) {
        guard result.stable else { return }
        lock.async {
            self.lastStableCalibration = result
            if self.latestCalibration != nil { AppDiagnostics.shared.increment("network.calibration_replaced") }
            self.latestCalibration = result
        }
    }

    func setMaxFrameRate(_ framesPerSecond: Int) {
        precondition((5...20).contains(framesPerSecond))
        lock.async { self.targetFrameIntervalMs = Int64(1_000 / framesPerSecond) }
    }

    func disconnect() {
        lock.async {
            AppDiagnostics.shared.event("network", "disconnect_requested")
            self.manuallyStopped = true
            self.desiredConfig = nil
            self.automaticConnection = false
            self.sessionId = nil
            self.latestHand = nil
            self.latestCalibration = nil
            self.lastStableCalibration = nil
            self.calibrationConfirmed = false
            self.calibrationRequested = false
            self.cancelTimersLocked()
            self.task?.cancel(with: Self.normalCloseCode, reason: "user disconnect".data(using: .utf8))
            self.task = nil
            self.publishLocked(ConnectionSnapshot(.disconnected))
        }
    }

    func retryNow() {
        lock.async {
            guard let config = self.desiredConfig, !self.manuallyStopped, self.sessionId == nil else { return }
            self.reconnectWork?.cancel()
            self.countdownTimer?.cancel()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.openSocketLocked(config, reconnecting: true)
        }
    }

    func onNetworkLost() {
        lock.async {
            guard !self.manuallyStopped, self.desiredConfig != nil else { return }
            AppDiagnostics.shared.event("network", "default_network_lost")
            self.sessionId = nil
            self.heartbeatTimer?.cancel()
            self.reconnectWork?.cancel()
            self.countdownTimer?.cancel()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.publishLocked(ConnectionSnapshot(.reconnecting,
                                                  detail: "ネットワーク接続を待っています",
                                                  errorCode: .unreachable))
        }
    }

    func onNetworkAvailable() {
        lock.async {
            guard let config = self.desiredConfig, !self.manuallyStopped, self.sessionId == nil else { return }
            AppDiagnostics.shared.event("network", "default_network_available")
            self.reconnectWork?.cancel()
            self.countdownTimer?.cancel()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.openSocketLocked(config, reconnecting: true)
        }
    }

    func close() {
        disconnect()
        lock.async {
            self.senderTimer?.cancel()
            self.calibrationTimer?.cancel()
        }
        session.invalidateAndCancel()
    }

    // MARK: - Socket lifecycle (all *Locked run on `lock`)

    private func cancelTimersLocked() {
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        reconnectWork?.cancel(); reconnectWork = nil
        countdownTimer?.cancel(); countdownTimer = nil
    }

    private func openSocketLocked(_ config: ConnectionConfig, reconnecting: Bool) {
        countdownTimer?.cancel()
        AppDiagnostics.shared.event("network", reconnecting ? "reconnect_started" : "socket_started",
                                    ["attempt": reconnectAttempt])
        publishLocked(ConnectionSnapshot(reconnecting ? .reconnecting : .connecting, automatic: automaticConnection))
        sessionId = nil
        inFlightBytes = 0
        guard let url = URL(string: config.webSocketUrl) else {
            pendingErrorCode = .unreachable
            handleSocketEndedLocked(nil, detail: "URL不正")
            return
        }
        let newTask = session.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        receiveNext(on: newTask)

        // hello_ack timeout.
        lock.asyncAfter(deadline: .now() + Self.ackTimeoutSeconds) { [weak self] in
            guard let self else { return }
            if self.task === newTask, self.sessionId == nil, !self.manuallyStopped {
                AppDiagnostics.shared.increment("network.ack_timeouts")
                AppDiagnostics.shared.event("network", "hello_ack_timeout")
                self.onLog("hello_ack timeout")
                self.pendingErrorCode = .ackTimeout
                newTask.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func receiveNext(on receivingTask: URLSessionWebSocketTask) {
        receivingTask.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.lock.async { self.handleServerMessageLocked(receivingTask, text: text) }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.lock.async { self.handleServerMessageLocked(receivingTask, text: text) }
                    }
                @unknown default:
                    break
                }
                self.receiveNext(on: receivingTask)
            case .failure:
                // Socket end is handled by the delegate didCompleteWithError callback.
                break
            }
        }
    }

    // MARK: - Senders

    private func flushLatestHandLocked() {
        let now = Self.monotonicMs()
        if now - lastHandSentAtMs < targetFrameIntervalMs { return }
        guard let socket = task, let activeSession = sessionId else { return }
        AppDiagnostics.shared.gauge("network.queue_bytes", inFlightBytes)
        if inFlightBytes > Self.maxQueueBytes {
            AppDiagnostics.shared.increment("network.queue_throttled")
            return
        }
        guard let result = latestHand else { return }
        latestHand = nil

        frameId += 1
        let currentFrameId = frameId
        let hand: HandPayload
        if result.detected {
            hand = HandPayload(
                detected: true,
                handedness: result.handedness,
                handednessScore: result.handednessScore,
                landmarks: result.landmarks.map { [min(max($0.x, 0), 1), min(max($0.y, 0), 1), $0.z] }
            )
        } else {
            hand = HandPayload(detected: false)
        }
        let message = HandFrameMessage(
            sessionId: activeSession,
            frameId: currentFrameId,
            capturedAtMonotonicMs: result.capturedAtMonotonicMs,
            source: SourceInfo(width: result.sourceWidth, height: result.sourceHeight),
            hand: hand
        )
        let encoded = ProtocolCodec.encode(message)
        sendLocked(socket, text: encoded, restoreHandOnFailure: result) { success in
            if success {
                self.lastHandSentAtMs = now
                AppDiagnostics.shared.increment("network.hand_sent")
                AppDiagnostics.shared.gauge("network.last_frame_id", currentFrameId)
            }
        }
    }

    private func flushLatestCalibrationLocked() {
        guard let socket = task, let activeSession = sessionId else { return }
        if inFlightBytes > Self.maxQueueBytes {
            AppDiagnostics.shared.increment("network.queue_throttled")
            return
        }
        guard let result = latestCalibration else { return }
        latestCalibration = nil
        let message = CalibrationMarkersMessage(
            sessionId: activeSession,
            capturedAtMonotonicMs: result.capturedAtMonotonicMs,
            source: SourceInfo(width: result.sourceWidth, height: result.sourceHeight),
            markers: result.markers.map { marker in
                MarkerPayload(id: marker.id,
                              center: [marker.center.x, marker.center.y],
                              corners: marker.corners.map { [$0.x, $0.y] })
            }
        )
        let encoded = ProtocolCodec.encode(message)
        let markerCount = result.markers.count
        sendLocked(socket, text: encoded, restoreCalibrationOnFailure: result) { success in
            if success {
                AppDiagnostics.shared.increment("network.calibration_sent")
                AppDiagnostics.shared.event("network", "calibration_sent", ["markers": markerCount])
            }
        }
    }

    private func startHeartbeatLocked(_ socket: URLSessionWebSocketTask, session activeSession: String) {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: lock)
        timer.schedule(deadline: .now() + Self.heartbeatSeconds, repeating: Self.heartbeatSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let encoded = ProtocolCodec.encode(HeartbeatMessage(sessionId: activeSession,
                                                                sentAtMonotonicMs: Self.monotonicMs()))
            self.sendLocked(socket, text: encoded) { success in
                if success { AppDiagnostics.shared.increment("network.heartbeats_sent") }
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func sendLocked(_ socket: URLSessionWebSocketTask,
                            text: String,
                            restoreHandOnFailure hand: HandDetectionResult? = nil,
                            restoreCalibrationOnFailure calibration: MarkerDetectionResult? = nil,
                            completion: @escaping (Bool) -> Void) {
        let bytes = text.utf8.count
        inFlightBytes += bytes
        socket.send(.string(text)) { [weak self] error in
            guard let self else { return }
            self.lock.async {
                self.inFlightBytes = max(0, self.inFlightBytes - bytes)
                if let error {
                    AppDiagnostics.shared.increment("network.send_failures")
                    self.onLog("send failed: \(error.localizedDescription)")
                    if let hand, self.latestHand == nil { self.latestHand = hand }
                    if let calibration, self.latestCalibration == nil { self.latestCalibration = calibration }
                    completion(false)
                } else {
                    completion(true)
                }
            }
        }
    }

    // MARK: - Server message handling

    private func handleServerMessageLocked(_ socket: URLSessionWebSocketTask, text: String) {
        guard let message = ProtocolCodec.decodeServerMessage(text) else {
            AppDiagnostics.shared.increment("network.invalid_messages")
            AppDiagnostics.shared.event("network", "invalid_server_json")
            onLog("Invalid server JSON")
            return
        }
        switch message {
        case let ack as HelloAckMessage:
            guard ack.schemaVersion == kSchemaVersion, task === socket else { return }
            if let token = ack.resumeToken, let activeConfig = desiredConfig {
                onTrustedConnectionIssued(activeConfig, token)
            }
            sessionId = ack.sessionId
            let cachedCalibration = lastStableCalibration
            let reconnecting = reconnectAttempt > 0
            let reuseCalibration = reconnecting && calibrationConfirmed && cachedCalibration != nil
            calibrationRequested = ack.calibrationRequired && !reuseCalibration
            AppDiagnostics.shared.event("network", "hello_ack",
                                        ["sessionId": ack.sessionId,
                                         "calibrationRequired": ack.calibrationRequired,
                                         "calibrationReused": reuseCalibration])
            reconnectAttempt = 0
            publishLocked(ConnectionSnapshot(.connected, sessionId: ack.sessionId))
            if reuseCalibration, let cachedCalibration {
                latestCalibration = cachedCalibration
                AppDiagnostics.shared.event("network", "cached_calibration_queued")
                onModeChanged(.calibration)
                onCalibrationReuseQueued()
            } else {
                onModeChanged(ack.calibrationRequired ? .calibration : .tracking)
            }
            startHeartbeatLocked(socket, session: ack.sessionId)

        case let error as HelloErrorMessage:
            guard error.schemaVersion == kSchemaVersion, task === socket else { return }
            let errorCode: ConnectionErrorCode
            switch error.code {
            case "pairing_code_mismatch": errorCode = .pairingCodeMismatch
            case "unsupported_version": errorCode = .unsupportedVersion
            case "server_busy": errorCode = .serverBusy
            case "resume_token_invalid": errorCode = .resumeTokenInvalid
            default: errorCode = .unknown
            }
            AppDiagnostics.shared.event("network", "hello_error",
                                        ["code": error.code, "retryable": error.retryable])
            if error.retryable {
                pendingErrorCode = errorCode
                socket.cancel(with: .goingAway, reason: nil)
            } else {
                manuallyStopped = true
                desiredConfig = nil
                sessionId = nil
                socket.cancel(with: Self.normalCloseCode, reason: "hello rejected".data(using: .utf8))
                task = nil
                if errorCode == .resumeTokenInvalid {
                    automaticConnection = false
                    onTrustedConnectionInvalid()
                    publishLocked(ConnectionSnapshot(.disconnected,
                                                     detail: "保存済みの接続情報が無効です。6桁コードで接続し直してください。",
                                                     errorCode: errorCode))
                } else {
                    publishLocked(ConnectionSnapshot(.error, errorCode: errorCode))
                }
            }

        case let status as CalibrationStatusMessage:
            guard status.schemaVersion == kSchemaVersion, status.sessionId == sessionId else {
                AppDiagnostics.shared.increment("network.ignored_calibration_status")
                return
            }
            AppDiagnostics.shared.event("network", "calibration_status",
                                        ["status": status.status, "reason": status.reason])
            switch status.status {
            case "complete": calibrationConfirmed = true; calibrationRequested = false
            case "retry_required": calibrationConfirmed = false
            default: break
            }
            onCalibrationStatus(status)

        case let control as ControlMessage:
            guard control.sessionId == sessionId else {
                AppDiagnostics.shared.increment("network.ignored_controls")
                onLog("Ignored control message for another session")
                return
            }
            switch control.command {
            case "set_mode":
                switch control.mode {
                case "calibration":
                    calibrationConfirmed = false
                    calibrationRequested = true
                    AppDiagnostics.shared.event("network", "remote_mode", ["mode": "calibration"])
                    onModeChanged(.calibration)
                case "tracking":
                    if calibrationRequested && lastStableCalibration != nil { calibrationConfirmed = true }
                    calibrationRequested = false
                    AppDiagnostics.shared.event("network", "remote_mode", ["mode": "tracking"])
                    onModeChanged(.tracking)
                default:
                    onLog("Unknown capture mode: \(control.mode ?? "nil")")
                }
            case "disconnect":
                disconnect()
            default:
                onLog("Unknown control command: \(control.command)")
            }

        default:
            break
        }
    }

    private func handleSocketEndedLocked(_ endedTask: URLSessionWebSocketTask?, detail: String) {
        if let endedTask, task !== endedTask { return }
        if manuallyStopped { return }
        AppDiagnostics.shared.increment("network.disconnects")
        AppDiagnostics.shared.event("network", "socket_ended", ["detail": detail])
        sessionId = nil
        heartbeatTimer?.cancel()
        let errorCode = pendingErrorCode ?? .unreachable
        pendingErrorCode = nil
        scheduleReconnectLocked(detail: detail, errorCode: errorCode)
    }

    private func scheduleReconnectLocked(detail: String, errorCode: ConnectionErrorCode) {
        guard let config = desiredConfig else { return }
        let delayMs = Self.retryDelaysMs[min(reconnectAttempt, Self.retryDelaysMs.count - 1)]
        let deadlineMs = Self.monotonicMs() + Int64(delayMs)
        reconnectAttempt += 1
        AppDiagnostics.shared.event("network", "reconnect_scheduled", ["delayMs": delayMs, "detail": detail])
        publishLocked(ConnectionSnapshot(.reconnecting,
                                         retryInSeconds: delayMs / 1_000,
                                         detail: detail,
                                         errorCode: errorCode,
                                         automatic: automaticConnection))
        reconnectWork?.cancel()
        countdownTimer?.cancel()

        let countdown = DispatchSource.makeTimerSource(queue: lock)
        countdown.schedule(deadline: .now() + 1, repeating: 1)
        countdown.setEventHandler { [weak self] in
            guard let self else { return }
            if self.manuallyStopped || self.desiredConfig?.webSocketUrl != config.webSocketUrl { return }
            let remaining = Int((max(deadlineMs - Self.monotonicMs(), 0) + 999) / 1_000)
            self.publishLocked(ConnectionSnapshot(.reconnecting,
                                                  retryInSeconds: remaining,
                                                  detail: detail,
                                                  errorCode: errorCode,
                                                  automatic: self.automaticConnection))
        }
        countdown.resume()
        countdownTimer = countdown

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.manuallyStopped && self.desiredConfig?.webSocketUrl == config.webSocketUrl {
                self.openSocketLocked(config, reconnecting: true)
            }
        }
        reconnectWork = work
        lock.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
    }

    private func publishLocked(_ snapshot: ConnectionSnapshot) {
        AppDiagnostics.shared.gauge("network.status", "\(snapshot.status)")
        onStateChanged(snapshot)
    }

    static func monotonicMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.async {
            guard self.task === webSocketTask, !self.manuallyStopped, let config = self.desiredConfig else { return }
            self.publishLocked(ConnectionSnapshot(.awaitingAck, automatic: self.automaticConnection))
            let hello = HelloMessage(deviceId: self.deviceId,
                                     clientVersion: self.clientVersion,
                                     pairingToken: config.pairingToken,
                                     resumeToken: config.resumeToken)
            let encoded = ProtocolCodec.encode(hello)
            self.sendLocked(webSocketTask, text: encoded) { _ in
                AppDiagnostics.shared.event("network", "hello_sent")
            }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "-"
        lock.async {
            self.handleSocketEndedLocked(webSocketTask, detail: "接続が閉じられました: \(closeCode.rawValue) \(reasonText)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else { return }
        let detail = error?.localizedDescription ?? "通信エラー"
        lock.async {
            // If a normal close already handled the end, this is a no-op (task identity guard).
            self.handleSocketEndedLocked(webSocketTask, detail: detail)
        }
    }
}
