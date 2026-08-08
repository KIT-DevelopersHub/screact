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

  /// WebSocket確立後、helloを送らない接続が単一クライアント枠を占有できる時間。
  final Duration helloTimeout;

  /// 6桁ペアリングコード（null なら照合しない）。UIがサーバ開始時に生成して表示する。
  final String? pairingCode;

  /// コード照合を行うか（UIのトグルで切替可能・既定ON）。
  bool enforcePairing;

  /// UIが全画面ターゲットを表示している間だけ位置合わせ入力を受け付ける。
  /// 既定trueは既存の直接利用・テストとの互換性を保つ。
  bool acceptCalibrationMessages;

  /// 接続診断ログ（UI/ファイルへ流す。null なら無効）。
  final void Function(String)? onLog;

  HttpServer? _http;
  WebSocket? _socket;
  Timer? _helloTimer;
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
    this.helloTimeout = const Duration(seconds: 5),
    this.pairingCode,
    this.enforcePairing = true,
    this.acceptCalibrationMessages = true,
    this.onLog,
  });

  void _log(String m) => onLog?.call(m);

  /// 6桁コードの生成（サーバ開始時にUIが呼ぶ）。
  static String generatePairingCode() {
    final r = math.Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  /// バインド済みポート（port=0 指定時のテスト用）。未起動なら null。
  int? get boundPort => _http?.port;

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _log(
      'listen 開始: ws://0.0.0.0:${_http!.port}/ws/v1/input '
      '(全インターフェースで待受・コード照合=${enforcePairing ? "ON" : "OFF"})',
    );
    if (pairingCode != null) _log('6桁コード: $pairingCode');
    _emit(listening: true);
    _http!.listen((req) async {
      final from = _remoteOf(req);
      try {
        if (req.uri.path == '/ws/v1/input' &&
            WebSocketTransformer.isUpgradeRequest(req)) {
          _log('http request from $from path=${req.uri.path} (WS upgrade要求)');
          // 圧縮拡張は必ずオフにする。Dart既定の permessage-deflate 応答
          // （client_max_window_bits付き）を Android の OkHttp が拒否し、
          // closeCode=1010 で即切断される（実機で確認した接続不可の根本原因）。
          final ws = await WebSocketTransformer.upgrade(
            req,
            compression: CompressionOptions.compressionOff,
          );
          _log('ws upgraded ($from) — WebSocket確立');
          _attach(ws, from);
        } else {
          _log(
            'http request from $from path=${req.uri.path} '
            '(upgrade無し→404: パス誤りか疎通確認)',
          );
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        }
      } catch (e) {
        _log('upgrade失敗 ($from): $e');
      }
    }, onError: (Object e) => _log('listenエラー: $e'));
  }

  static String _remoteOf(HttpRequest req) {
    final info = req.connectionInfo;
    return info == null
        ? '(不明)'
        : '${info.remoteAddress.address}:${info.remotePort}';
  }

  void _attach(WebSocket ws, String from) {
    // single_user: 最初に到着したソケットが接続枠を確保する。後着接続で
    // 現在の操作端末を追い出すと、同じ offer を受けた複数端末が互いを切断し
    // 続けるため、既存接続は維持して後着側だけを明示的に拒否する。
    if (_socket != null) {
      _log('後着接続を拒否 ($from): 既存端末が接続中 (server_busy)');
      ws.listen((_) {}, onError: (_) {}, cancelOnError: true);
      _sendTo(
        ws,
        const HelloError(
          code: 'server_busy',
          message: '別の端末が接続中です',
          retryable: true,
        ).toJson(),
      );
      unawaited(ws.close(4002, 'server_busy'));
      return;
    }

    _socket = ws;
    _clearConnectionState(releaseInput: false);
    _helloTimer = Timer(helloTimeout, () => _onHelloTimeout(ws, from));
    ws.listen(
      (data) => _onMessage(ws, data),
      onDone: () {
        _log(
          '切断 ($from) closeCode=${ws.closeCode ?? "-"} '
          'reason=${ws.closeReason ?? "-"}',
        );
        _onClose(ws);
      },
      onError: (Object e) {
        _log('ソケットエラー ($from): $e');
        _onClose(ws);
      },
      cancelOnError: true,
    );
    _emit();
  }

  void _onMessage(WebSocket source, dynamic data) {
    // close/error の遅延通知や拒否済みソケットからのデータが、後から確立した
    // 現在のセッションを変更しないよう、全受信をソケットidentityで守る。
    if (!identical(_socket, source)) return;
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(data as String) as Map).cast<String, dynamic>();
    } catch (_) {
      _log('不正JSONを受信（無視）');
      _emit(error: 'invalid json');
      return;
    }
    final type = j['messageType'];
    try {
      switch (type) {
        case 'hello':
          _onHello(source, Hello.fromJson(j));
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
    } catch (error) {
      // スキーマ不正なJSONでstream callbackを例外終了させず、その接続を
      // hello timeout/次メッセージで回復可能な状態に保つ。
      _log('不正メッセージを受信（無視）: type=$type error=$error');
      _emit(error: 'invalid payload: $type');
    }
  }

  void _onHello(WebSocket source, Hello hello) {
    if (!identical(_socket, source)) return;
    _log(
      'hello 受信: deviceId=${hello.deviceId} '
      'version=${hello.clientVersion ?? "-"} '
      'token=${hello.pairingToken == null ? "(なし)" : "(あり)"}',
    );
    // 6桁コード照合（不一致は hello_error で拒否して切断）。
    if (enforcePairing &&
        pairingCode != null &&
        hello.pairingToken != pairingCode) {
      _log('hello_error 送信: 6桁コード不一致 → 切断 (端末: ${hello.deviceId})');
      _sendTo(
        source,
        const HelloError(
          code: 'pairing_code_mismatch',
          message: '6桁コードが一致しません',
        ).toJson(),
      );
      // close完了を待たず枠を解放する。遅れて届くこのソケットの onDone は
      // _onClose のidentity guardにより、次の正常セッションを消さない。
      if (identical(_socket, source)) {
        _socket = null;
        _clearConnectionState(releaseInput: false);
      }
      unawaited(source.close(4001, 'pairing_code_mismatch'));
      _emit(error: 'コード不一致の接続を拒否しました (端末: ${hello.deviceId})');
      return;
    }
    _clientId = hello.deviceId;
    _helloTimer?.cancel();
    _helloTimer = null;
    _sessionId = 'session-${_randHex(8)}';
    _log(
      'hello_ack 送信: session=$_sessionId '
      'calibrationRequired=${!engine.isCalibrated} — 接続完了',
    );
    final ack = HelloAck(
      sessionId: _sessionId!,
      surfaceId: 'primary-display',
      widthPx: 1920,
      heightPx: 1080,
      calibrationRequired: !engine.isCalibrated,
    );
    _sendTo(source, ack.toJson());
    engine.mode =
        engine.isCalibrated ? EngineMode.tracking : EngineMode.calibration;
    _emit();
  }

  void _onCalibration(CalibrationMarkers markers) {
    if (!acceptCalibrationMessages) {
      _emit();
      return;
    }
    if (!engine.config.acceptsAruco) {
      _emit(); // 設定で除外中のソースは静かに無視
      return;
    }
    final ok = engine.calibrate(markers);
    if (ok) {
      _log('calibration_markers で位置合わせ成功 → set_mode tracking 送信');
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
    if (!acceptCalibrationMessages) {
      _emit();
      return;
    }
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
    _emit(
      error:
          degenerate
              ? 'slide_corners calibration failed (degenerate quad)'
              : null,
    );
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
      if (_frames == 1) _log('hand_frame 受信開始 (frameId=${f.frameId})');
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

  static void _sendTo(WebSocket socket, Map<String, dynamic> j) {
    socket.add(jsonEncode(j));
  }

  void _onClose(WebSocket source) {
    // 旧ソケットの onDone/onError は非同期で遅れて届く。別のソケットが既に
    // 接続済みなら、その現行session/client状態には一切触れない。
    if (!identical(_socket, source)) return;
    _socket = null;
    _clearConnectionState(releaseInput: true);
    _emit();
  }

  void _onHelloTimeout(WebSocket source, String from) {
    if (!identical(_socket, source) || _clientId != null) return;
    _log('hello timeout ($from): 認証メッセージ未受信のため切断');
    _sendTo(
      source,
      const HelloError(
        code: 'hello_timeout',
        message: '接続の初期化が時間切れになりました',
        retryable: true,
      ).toJson(),
    );
    _socket = null;
    _clearConnectionState(releaseInput: false);
    unawaited(source.close(4003, 'hello_timeout'));
    _emit(error: 'helloを受信できず接続を終了しました');
  }

  void _clearConnectionState({required bool releaseInput}) {
    _helloTimer?.cancel();
    _helloTimer = null;
    _sessionId = null;
    _clientId = null;
    _frames = 0;
    _lastFrameId = null;
    _handDetected = false;
    _pending = null;
    if (!releaseInput) return;
    onEvents(
      engine.onFrame(
        const HandFrame(frameId: -1, capturedAtMonotonicMs: 0, detected: false),
      ),
    );
  }

  Future<void> stop() async {
    _log('サーバ停止');
    final socket = _socket;
    final http = _http;
    // close のコールバックより先にidentityを外して状態を消す。これにより
    // stop完了時に古いsessionIdがstatusへ残らない。
    _socket = null;
    _http = null;
    _clearConnectionState(releaseInput: socket != null);
    await socket?.close();
    await http?.close(force: true);
    _emit(listening: false);
  }

  void _emit({bool? listening, String? error}) {
    onStatus(
      ServerStatus(
        listening: listening ?? (_http != null),
        clientId: _clientId,
        sessionId: _sessionId,
        mode: engine.mode,
        frames: _frames,
        lastFrameId: _lastFrameId,
        handDetected: _handDetected,
        lastError: error,
      ),
    );
  }

  static String _randHex(int n) {
    final r = math.Random();
    const hex = '0123456789abcdef';
    return List.generate(n, (_) => hex[r.nextInt(16)]).join();
  }
}
