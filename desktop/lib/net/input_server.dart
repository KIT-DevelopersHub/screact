import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../core/homography.dart';
import '../core/interaction_engine.dart';
import '../protocol/messages.dart';

/// 接続状態のスナップショット（デバッグ表示用）。
class ServerStatus {
  final bool listening;
  final String? clientId;
  final String? sessionId;
  final EngineMode mode;
  final int frames;
  final int? lastFrameId;
  final bool handDetected;
  final String? lastError;
  const ServerStatus({
    this.listening = false,
    this.clientId,
    this.sessionId,
    this.mode = EngineMode.calibration,
    this.frames = 0,
    this.lastFrameId,
    this.handDetected = false,
    this.lastError,
  });
}

/// PC側のWebSocketサーバ。`ws://<PCのIP>:<port>/ws/v1/input` で待受け、
/// Androidの hello/hand_frame/calibration_markers/heartbeat を捌く（protocol v1）。
/// hand_frame は「常に最新の1枚だけ処理」= 未処理の古いフレームは新着で置換する。
class InputServer {
  final InteractionEngine engine;
  final void Function(List<InteractionEvent>) onEvents;
  final void Function(ServerStatus) onStatus;
  final void Function(HandFrame)? onFrame;
  final int port;

  /// 6桁ペアリングコード（null なら照合しない）。UIがサーバ開始時に生成して表示する。
  final String? pairingCode;

  /// コード照合を行うか（UIのトグルで切替可能・既定ON）。
  bool enforcePairing;

  HttpServer? _http;
  WebSocket? _socket;
  String? _sessionId;
  String? _clientId;
  int _frames = 0;
  int? _lastFrameId;
  bool _handDetected = false;

  // 単一スロット（最新フレームだけ保持）
  HandFrame? _pending;
  bool _processing = false;

  InputServer({
    required this.engine,
    required this.onEvents,
    required this.onStatus,
    this.onFrame,
    this.port = 8765,
    this.pairingCode,
    this.enforcePairing = true,
  });

  /// 6桁コードの生成（サーバ開始時にUIが呼ぶ）。
  static String generatePairingCode() {
    final r = math.Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  /// バインド済みポート（port=0 指定時のテスト用）。未起動なら null。
  int? get boundPort => _http?.port;

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _emit(listening: true);
    _http!.listen((req) async {
      if (req.uri.path == '/ws/v1/input' &&
          WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        _attach(ws);
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    });
  }

  void _attach(WebSocket ws) {
    // 単一クライアント運用（single_user）。既存があれば置き換える。
    _socket?.close();
    _socket = ws;
    _clientId = null;
    _frames = 0;
    ws.listen(
      (data) => _onMessage(data),
      onDone: _onClose,
      onError: (_) => _onClose(),
      cancelOnError: true,
    );
    _emit();
  }

  void _onMessage(dynamic data) {
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(data as String) as Map).cast<String, dynamic>();
    } catch (_) {
      _emit(error: 'invalid json');
      return;
    }
    final type = j['messageType'];
    switch (type) {
      case 'hello':
        _onHello(Hello.fromJson(j));
        break;
      case 'hand_frame':
        _enqueueFrame(HandFrame.fromJson(j));
        break;
      case 'calibration_markers':
        _onCalibration(CalibrationMarkers.fromJson(j));
        break;
      case 'slide_corners':
        _onSlideCorners(SlideCorners.fromJson(j));
        break;
      case 'heartbeat':
        break; // 受信のみ（生存確認）
      default:
        _emit(error: 'unknown messageType: $type');
    }
  }

  void _onHello(Hello hello) {
    // 6桁コード照合（不一致は hello_error で拒否して切断）。
    if (enforcePairing &&
        pairingCode != null &&
        hello.pairingToken != pairingCode) {
      _send(const HelloError(
        code: 'pairing_code_mismatch',
        message: '6桁コードが一致しません',
      ).toJson());
      _socket?.close(4001, 'pairing_code_mismatch');
      _socket = null;
      _emit(error: 'コード不一致の接続を拒否しました (端末: ${hello.deviceId})');
      return;
    }
    _clientId = hello.deviceId;
    _sessionId = 'session-${_randHex(8)}';
    final ack = HelloAck(
      sessionId: _sessionId!,
      surfaceId: 'primary-display',
      widthPx: 1920,
      heightPx: 1080,
      calibrationRequired: !engine.isCalibrated,
    );
    _send(ack.toJson());
    engine.mode =
        engine.isCalibrated ? EngineMode.tracking : EngineMode.calibration;
    _emit();
  }

  void _onCalibration(CalibrationMarkers markers) {
    if (!engine.config.acceptsAruco) {
      _emit(); // 設定で除外中のソースは静かに無視
      return;
    }
    final ok = engine.calibrate(markers);
    if (ok) {
      // 「画面位置合わせ完了」の通知（チームシーケンス図）。Androidはこれで
      // マーカー検出ループを抜けて通常トラッキングへ移る。
      _send(ControlMessage.setMode(_sessionId ?? '', 'tracking').toJson());
    }
    // 安定判定の蓄積中（4マーカー揃いだが未確定）はエラーにしない。
    final invalid = markers.markers.length < 4;
    _emit(error: invalid ? 'calibration failed (need 4 markers)' : null);
  }

  /// スマホ検出のスライド四隅で位置合わせ（ArUcoなしの経路）。
  void _onSlideCorners(SlideCorners sc) {
    if (!engine.config.acceptsSlideCorners) {
      _emit(); // 設定で除外中のソースは静かに無視
      return;
    }
    if (!sc.isValid) {
      _emit(error: 'slide_corners requires 4 finite corners');
      return;
    }
    final ok = engine.calibrateFromCorners(sc.corners);
    if (ok) {
      _send(ControlMessage.setMode(_sessionId ?? '', 'tracking').toJson());
    }
    // 安定判定の蓄積中はエラーにしない（退化した四隅だけを報告）。
    final degenerate = Homography.fromCorners(sc.corners) == null;
    _emit(error: degenerate ? 'slide_corners calibration failed (degenerate quad)' : null);
  }

  void _enqueueFrame(HandFrame f) {
    if (_sessionId == null) return; // ハンドシェイク前は無視
    _pending = f; // 最新で置換
    _drain();
  }

  Future<void> _drain() async {
    if (_processing) return;
    _processing = true;
    while (_pending != null) {
      final f = _pending!;
      _pending = null;
      _frames++;
      _lastFrameId = f.frameId;
      _handDetected = f.detected;
      onFrame?.call(f);
      final events = engine.onFrame(f);
      if (events.isNotEmpty) onEvents(events);
      _emit();
      await Future<void>.delayed(Duration.zero); // 他イベントに譲る
    }
    _processing = false;
  }

  void requestMode(String mode) {
    if (_sessionId == null) return;
    engine.mode =
        mode == 'tracking' ? EngineMode.tracking : EngineMode.calibration;
    _send(ControlMessage.setMode(_sessionId!, mode).toJson());
    _emit();
  }

  void _send(Map<String, dynamic> j) => _socket?.add(jsonEncode(j));

  void _onClose() {
    _socket = null;
    _clientId = null;
    onEvents(engine.onFrame(const HandFrame(
        frameId: -1, capturedAtMonotonicMs: 0, detected: false)));
    _emit();
  }

  Future<void> stop() async {
    await _socket?.close();
    await _http?.close(force: true);
    _http = null;
    _emit(listening: false);
  }

  void _emit({bool? listening, String? error}) {
    onStatus(ServerStatus(
      listening: listening ?? (_http != null),
      clientId: _clientId,
      sessionId: _sessionId,
      mode: engine.mode,
      frames: _frames,
      lastFrameId: _lastFrameId,
      handDetected: _handDetected,
      lastError: error,
    ));
  }

  static String _randHex(int n) {
    final r = math.Random();
    const hex = '0123456789abcdef';
    return List.generate(n, (_) => hex[r.nextInt(16)]).join();
  }
}
