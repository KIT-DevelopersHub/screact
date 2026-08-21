import Foundation
import Network
import CryptoKit

/// WebSocket client for the desktop server (desktop/lib/net/input_server.dart).
///
/// Transport: a hand-rolled RFC6455 client over `NWConnection.tcp`.
///
/// Why not `URLSessionWebSocketTask`: on iOS 26 devices its `send(_:)` reports success but never
/// writes the frame to the socket for this local `ws://` server (verified at the packet level:
/// the HTTP upgrade completes, then zero application bytes are transmitted before the task times
/// out). A raw-TCP RFC6455 implementation transmits correctly, matching the Android (OkHttp) path.
///
/// Wire compatibility:
///   - Endpoint ws://host:port/ws/v1/input, default port 8765.
///   - No permessage-deflate is offered, matching the server's compression-off requirement.
///   - Sends hello / hand_frame / calibration_markers / heartbeat; handles hello_ack /
///     hello_error / control_message / calibration_status.
///
/// Backpressure: approximates Android's MAX_QUEUE_BYTES gate with an in-flight byte counter.
final class YubiBoardWebSocketClient {
    // Tunables mirror the Android companion constants.
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

    // State (guarded by `lock`).
    private var frameId: Int64 = 0
    private var targetFrameIntervalMs: Int64 = frameIntervalMsDefault
    private var lastHandSentAtMs: Int64 = 0
    private var latestHand: HandDetectionResult?
    private var latestCalibration: MarkerDetectionResult?
    private var lastStableCalibration: MarkerDetectionResult?
    private var desiredConfig: ConnectionConfig?
    private var automaticConnection = false
    private var transport: NWWebSocketTransport?
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
            self.transport?.cancel()
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
            self.transport?.cancel()
            self.transport = nil
            self.publishLocked(ConnectionSnapshot(.disconnected))
        }
    }

    func retryNow() {
        lock.async {
            guard let config = self.desiredConfig, !self.manuallyStopped, self.sessionId == nil else { return }
            self.reconnectWork?.cancel()
            self.countdownTimer?.cancel()
            self.transport?.cancel()
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
            self.transport?.cancel()
            self.transport = nil
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
            self.transport?.cancel()
            self.openSocketLocked(config, reconnecting: true)
        }
    }

    func close() {
        disconnect()
        lock.async {
            self.senderTimer?.cancel()
            self.calibrationTimer?.cancel()
        }
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
        guard let ws = NWWebSocketTransport(host: config.host, port: config.port, path: "/ws/v1/input") else {
            pendingErrorCode = .unreachable
            handleSocketEndedLocked(nil, detail: "接続先が不正です")
            return
        }
        transport = ws

        ws.onOpen = { [weak self] in
            guard let self else { return }
            self.lock.async {
                guard self.transport === ws, !self.manuallyStopped, let config = self.desiredConfig else { return }
                self.publishLocked(ConnectionSnapshot(.awaitingAck, automatic: self.automaticConnection))
                let hello = HelloMessage(deviceId: self.deviceId,
                                         clientVersion: self.clientVersion,
                                         pairingToken: config.pairingToken,
                                         resumeToken: config.resumeToken)
                let encoded = ProtocolCodec.encode(hello)
                self.sendLocked(ws, text: encoded) { _ in
                    AppDiagnostics.shared.event("network", "hello_sent")
                }
            }
        }
        ws.onText = { [weak self] text in
            guard let self else { return }
            self.lock.async { self.handleServerMessageLocked(ws, text: text) }
        }
        ws.onEnded = { [weak self] detail in
            guard let self else { return }
            self.lock.async { self.handleSocketEndedLocked(ws, detail: detail) }
        }
        ws.start()

        // hello_ack timeout.
        lock.asyncAfter(deadline: .now() + Self.ackTimeoutSeconds) { [weak self] in
            guard let self else { return }
            if self.transport === ws, self.sessionId == nil, !self.manuallyStopped {
                AppDiagnostics.shared.increment("network.ack_timeouts")
                AppDiagnostics.shared.event("network", "hello_ack_timeout")
                self.onLog("hello_ack timeout")
                self.pendingErrorCode = .ackTimeout
                ws.cancel()
            }
        }
    }

    // MARK: - Senders

    private func flushLatestHandLocked() {
        let now = Self.monotonicMs()
        if now - lastHandSentAtMs < targetFrameIntervalMs { return }
        guard let socket = transport, let activeSession = sessionId else { return }
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
        guard let socket = transport, let activeSession = sessionId else { return }
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

    private func startHeartbeatLocked(_ socket: NWWebSocketTransport, session activeSession: String) {
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

    private func sendLocked(_ socket: NWWebSocketTransport,
                            text: String,
                            restoreHandOnFailure hand: HandDetectionResult? = nil,
                            restoreCalibrationOnFailure calibration: MarkerDetectionResult? = nil,
                            completion: @escaping (Bool) -> Void) {
        let bytes = text.utf8.count
        inFlightBytes += bytes
        socket.send(text: text) { [weak self] ok in
            guard let self else { return }
            self.lock.async {
                self.inFlightBytes = max(0, self.inFlightBytes - bytes)
                if !ok {
                    AppDiagnostics.shared.increment("network.send_failures")
                    self.onLog("send failed")
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

    private func handleServerMessageLocked(_ socket: NWWebSocketTransport, text: String) {
        guard let message = ProtocolCodec.decodeServerMessage(text) else {
            AppDiagnostics.shared.increment("network.invalid_messages")
            AppDiagnostics.shared.event("network", "invalid_server_json")
            onLog("Invalid server JSON")
            return
        }
        switch message {
        case let ack as HelloAckMessage:
            guard ack.schemaVersion == kSchemaVersion, transport === socket else { return }
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
            guard error.schemaVersion == kSchemaVersion, transport === socket else { return }
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
                socket.cancel()
            } else {
                manuallyStopped = true
                desiredConfig = nil
                sessionId = nil
                socket.cancel()
                transport = nil
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

    private func handleSocketEndedLocked(_ endedTransport: NWWebSocketTransport?, detail: String) {
        if let endedTransport, transport !== endedTransport { return }
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
}

// MARK: - RFC6455 WebSocket over raw TCP (NWConnection)

/// Minimal RFC6455 client-side WebSocket transport over `NWConnection.tcp`.
/// Used instead of `URLSessionWebSocketTask`, which does not transmit frames on iOS 26 for this
/// local `ws://` server (see YubiBoardWebSocketClient docs). Callbacks are delivered on `queue`.
final class NWWebSocketTransport {
    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onEnded: ((String) -> Void)?

    private let conn: NWConnection
    private let queue: DispatchQueue
    private let host: String
    private let port: Int
    private let path: String
    private let acceptExpected: String

    private var opened = false
    private var ended = false
    private var buf = [UInt8]()
    private var fragmentOpcode: UInt8 = 0
    private var fragmentBuffer = [UInt8]()

    init?(host: String, port: Int, path: String) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port > 0 else { return nil }
        self.host = host
        self.port = port
        self.path = path
        self.queue = DispatchQueue(label: "com.nxtend.team35.yubiboard.nwws")

        // 16 random bytes -> Sec-WebSocket-Key; expected accept = base64(sha1(key + GUID)).
        let keyBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        self.secWebSocketKey = Data(keyBytes).base64EncodedString()
        let acceptInput = Data((self.secWebSocketKey + Self.wsGUID).utf8)
        let digest = Insecure.SHA1.hash(data: acceptInput)
        self.acceptExpected = Data(digest).base64EncodedString()

        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        self.conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    }

    private let secWebSocketKey: String

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendUpgradeRequest()
            case .failed(let error):
                self.finish("接続に失敗しました: \(error)")
            case .cancelled:
                self.finish("接続が閉じられました")
            default:
                break
            }
        }
        receiveLoop()
        conn.start(queue: queue)
    }

    /// Send a text frame (client->server frames MUST be masked). `completion(true)` on success.
    func send(text: String, completion: @escaping (Bool) -> Void) {
        let frame = Self.frame(opcode: 0x1, payload: Array(text.utf8))
        conn.send(content: frame, completion: .contentProcessed { error in
            completion(error == nil)
        })
    }

    /// Best-effort graceful close (send Close frame, then cancel the TCP connection).
    func cancel() {
        let close = Self.frame(opcode: 0x8, payload: [])
        conn.send(content: close, completion: .contentProcessed { [weak self] _ in
            self?.conn.cancel()
        })
    }

    // MARK: - Handshake

    private func sendUpgradeRequest() {
        let request =
            "GET \(path) HTTP/1.1\r\n" +
            "Host: \(host):\(port)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(secWebSocketKey)\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            "\r\n"
        conn.send(content: request.data(using: .ascii), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish("ハンドシェイク送信に失敗しました: \(error)") }
        })
    }

    // MARK: - Receive

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buf.append(contentsOf: data)
                self.drain()
            }
            if let error {
                self.finish("受信エラー: \(error)")
                return
            }
            if isComplete {
                self.finish("接続が閉じられました")
                return
            }
            self.receiveLoop()
        }
    }

    private func drain() {
        if !opened {
            // Wait for end of HTTP response headers.
            guard let headerEnd = indexAfterHeaderTerminator() else { return }
            let headerBytes = Array(buf[0..<headerEnd])
            buf.removeFirst(headerEnd)
            let header = String(decoding: headerBytes, as: UTF8.self)
            let lines = header.components(separatedBy: "\r\n")
            let statusOK = (lines.first ?? "").contains(" 101 ")
            var acceptOK = false
            for line in lines {
                let lower = line.lowercased()
                if lower.hasPrefix("sec-websocket-accept:") {
                    let value = line.dropFirst("sec-websocket-accept:".count).trimmingCharacters(in: .whitespaces)
                    acceptOK = (value == acceptExpected)
                }
            }
            guard statusOK, acceptOK else {
                finish("WebSocketハンドシェイクに失敗しました")
                return
            }
            opened = true
            onOpen?()
        }
        parseFrames()
    }

    private func indexAfterHeaderTerminator() -> Int? {
        guard buf.count >= 4 else { return nil }
        var i = 0
        while i <= buf.count - 4 {
            if buf[i] == 0x0d, buf[i + 1] == 0x0a, buf[i + 2] == 0x0d, buf[i + 3] == 0x0a {
                return i + 4
            }
            i += 1
        }
        return nil
    }

    private func parseFrames() {
        while true {
            guard buf.count >= 2 else { return }
            let b0 = buf[0]
            let b1 = buf[1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0f
            let masked = (b1 & 0x80) != 0
            var length = Int(b1 & 0x7f)
            var index = 2
            if length == 126 {
                guard buf.count >= 4 else { return }
                length = (Int(buf[2]) << 8) | Int(buf[3])
                index = 4
            } else if length == 127 {
                guard buf.count >= 10 else { return }
                length = 0
                for i in 2..<10 { length = (length << 8) | Int(buf[i]) }
                index = 10
            }
            var maskKey = [UInt8]()
            if masked {
                guard buf.count >= index + 4 else { return }
                maskKey = Array(buf[index..<index + 4])
                index += 4
            }
            guard buf.count >= index + length else { return }
            var payload = Array(buf[index..<index + length])
            if masked {
                for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
            }
            buf.removeFirst(index + length)
            handleFrame(fin: fin, opcode: opcode, payload: payload)
            if ended { return }
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: [UInt8]) {
        switch opcode {
        case 0x1, 0x2: // text / binary
            if fin {
                deliver(payload)
            } else {
                fragmentOpcode = opcode
                fragmentBuffer = payload
            }
        case 0x0: // continuation
            fragmentBuffer.append(contentsOf: payload)
            if fin {
                let assembled = fragmentBuffer
                fragmentBuffer = []
                deliver(assembled)
            }
        case 0x8: // close
            finish("サーバーが接続を閉じました")
            conn.cancel()
        case 0x9: // ping -> pong
            let pong = Self.frame(opcode: 0xA, payload: payload)
            conn.send(content: pong, completion: .idempotent)
        case 0xA: // pong
            break
        default:
            break
        }
    }

    private func deliver(_ payload: [UInt8]) {
        let text = String(decoding: payload, as: UTF8.self)
        onText?(text)
    }

    private func finish(_ detail: String) {
        if ended { return }
        ended = true
        onEnded?(detail)
    }

    // MARK: - Framing (client -> server, masked)

    private static func frame(opcode: UInt8, payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            bytes.append(0x80 | UInt8(n))
        } else if n < 65536 {
            bytes.append(0x80 | 126)
            bytes.append(UInt8((n >> 8) & 0xff))
            bytes.append(UInt8(n & 0xff))
        } else {
            bytes.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((n >> shift) & 0xff))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        bytes.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() {
            bytes.append(byte ^ mask[i % 4])
        }
        return Data(bytes)
    }
}
