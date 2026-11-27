import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/homography.dart';
import '../core/interaction_engine.dart';
import '../core/multi_hand_engine.dart';
import '../protocol/input_frame.dart';
import '../protocol/messages.dart';
import 'input_transport.dart';
import 'latency_probe.dart';

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

/// 通信路に依存しないセッション処理（protocol v1）。
///
/// 単一クライアント枠・hello 認証・sessionId・hello/無通信タイムアウト・
/// hand_frame の「常に最新の1枚だけ処理」・位置合わせ・猶予タイマー・
/// 区間計測・イベントの dispatch を持つ。通信路は [InputTransportHandler] として
/// 接続の出来事を渡し、送信と切断は [TransportConnection] 越しに行う。
class InputSession implements InputTransportHandler {
  final MultiHandEngine engine;

  /// OS入力（単一カーソル）へ流す主トラック（最小trackId）の操作イベント。
  final void Function(List<InteractionEvent>) onEvents;

  /// 各トラックの操作イベント（オーバーレイの2カーソル/2色描画用）。任意。
  final void Function(Map<int, List<InteractionEvent>>)? onTrackEvents;

  final void Function(ServerStatus) onStatus;

  /// カメラ切替で位置合わせが失効した時、UIへ再位置合わせ表示を要求する。
  final void Function()? onCalibrationInvalidated;

  /// 受信フレーム全体（0〜2トラックの骨格・骨格表示/状態用）。任意。
  final void Function(InputFrame)? onFrame;

  /// 接続確立後、helloを送らない接続が単一クライアント枠を占有できる時間。
  final Duration helloTimeout;

  /// 認証後にメッセージを受信しない接続を半開きとみなすまでの時間。
  final Duration inactivityTimeout;

  /// 6桁ペアリングコード（null なら照合しない）。
  final String? pairingCode;

  /// コード照合を行うか。
  bool enforcePairing;

  /// 位置合わせ入力（calibration_markers / slide_corners）を受け付けるか。
  bool acceptCalibrationMessages;

  /// 接続診断ログ（null なら無効）。
  final void Function(String)? onLog;

  /// 一時欠落の猶予中のトラックがある間、時計で猶予切れを確かめる周期。
  final Duration lostTrackCheckInterval;

  /// hand_frame の区間計測（null なら計測しない）。
  final LatencyProbe? latencyProbe;

  /// 状態通知の `listening` の既定値（通信路が待受中か）。
  final bool Function() isListening;

  TransportConnection? _connection;
  Timer? _helloTimer;
  Timer? _inactivityTimer;
  Timer? _lostTrackTimer;
  String? _sessionId;
  String? _clientId;
  int _frames = 0;
  int? _lastFrameId;
  bool _handDetected = false;
  String? _calibratedCameraFacing;

  // 単一スロット（最新フレームだけ保持）
  InputFrame? _pending;
  bool _processing = false;

  // 区間計測用の時刻（latencyProbe が null の間は使わない）。
  int _pendingReceiveMicros = 0;
  int _pendingParseMicros = 0;
  int _osMicros = 0;
  int _overlayMicros = 0;

  InputSession({
    required this.engine,
    required this.onEvents,
    required this.onStatus,
    required this.isListening,
    this.onCalibrationInvalidated,
    this.onTrackEvents,
    this.onFrame,
    this.helloTimeout = const Duration(seconds: 5),
    this.inactivityTimeout = const Duration(seconds: 12),
    this.pairingCode,
    this.enforcePairing = true,
    this.acceptCalibrationMessages = true,
    this.onLog,
    this.lostTrackCheckInterval = const Duration(milliseconds: 100),
    this.latencyProbe,
  });

  void _log(String m) => onLog?.call(m);

  /// 現在の接続（hello 前を含む）。なければ null。
  TransportConnection? get connection => _connection;

  @override
  bool onOpened(TransportConnection connection) {
    // single_user: 最初に到着した接続が枠を確保する。後着接続で現在の
    // 操作端末を追い出すと、同じ offer を受けた複数端末が互いを切断し
    // 続けるため、既存接続は維持して後着側だけを明示的に拒否する。
    if (_connection != null) {
      _log('後着接続を拒否 (${connection.label}): 既存端末が接続中 (server_busy)');
      _sendTo(
        connection,
        const HelloError(
          code: 'server_busy',
          message: '別の端末が接続中です',
          retryable: true,
        ).toJson(),
      );
      unawaited(connection.close(4002, 'server_busy'));
      return false;
    }

    _connection = connection;
    _clearConnectionState(releaseInput: false);
    _helloTimer = Timer(helloTimeout, () => _onHelloTimeout(connection));
    emit();
    return true;
  }

  /// 受信の共通前処理。現在の接続からなら受信時刻を返し、そうでなければ null。
  int? _beginReceive(TransportConnection source) {
    // close/error の遅延通知や拒否済み接続からのデータが、後から確立した
    // 現在のセッションを変更しないよう、全受信を接続のidentityで守る。
    if (!identical(_connection, source)) return null;
    final receiveMicros = latencyProbe?.now() ?? 0;
    if (_sessionId != null) _armInactivityTimeout(source);
    return receiveMicros;
  }

  @override
  void onBinary(TransportConnection connection, Uint8List message) {
    if (_beginReceive(connection) == null) return;
    // バイナリ形式（binary_hand_frame）は未接続。テキストでない受信は
    // 従来どおり不正JSONとして扱う。
    _rejectInvalidJson();
  }

  void _rejectInvalidJson() {
    _log('不正JSONを受信（無視）');
    emit(error: 'invalid json');
  }

  @override
  void onText(TransportConnection connection, String message) {
    final receiveMicros = _beginReceive(connection);
    if (receiveMicros == null) return;
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(message) as Map).cast<String, dynamic>();
    } catch (_) {
      _rejectInvalidJson();
      return;
    }
    final type = j['messageType'];
    try {
      switch (type) {
        case 'hello':
          _onHello(connection, Hello.fromJson(j));
          break;
        case 'hand_frame':
          final frame = InputFrame.parse(j, expectedSessionId: _sessionId);
          if (frame == null) {
            // 手数超過・trackId重複・21点以外・NaN/範囲外・session不一致等は
            // 一部採用せず、その hand_frame 全体を破棄する。
            _log('不正な hand_frame を破棄（全体）');
            emit(error: 'invalid hand_frame (discarded)');
            break;
          }
          _enqueueFrame(frame, receiveMicros);
          break;
        case 'calibration_markers':
          _onCalibration(CalibrationMarkers.fromJson(j));
          break;
        case 'camera_changed':
          _onCameraChanged(CameraChanged.fromJson(j));
          break;
        case 'slide_corners':
          _onSlideCorners(SlideCorners.fromJson(j));
          break;
        case 'heartbeat':
          break; // 受信のみ（生存確認）
        default:
          emit(error: 'unknown messageType: $type');
      }
    } catch (error) {
      // スキーマ不正なJSONでstream callbackを例外終了させず、その接続を
      // hello timeout/次メッセージで回復可能な状態に保つ。
      _log('不正メッセージを受信（無視）: type=$type error=$error');
      emit(error: 'invalid payload: $type');
    }
  }

  void _onHello(TransportConnection source, Hello hello) {
    if (!identical(_connection, source)) return;
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
      // close完了を待たず枠を解放する。遅れて届くこの接続の切断通知は
      // onClosed のidentity guardにより、次の正常セッションを消さない。
      if (identical(_connection, source)) {
        // 確立済みセッションを切り離すときは、切断と同じく入力を即時解除する。
        final established = _sessionId != null;
        _connection = null;
        _clearConnectionState(releaseInput: established);
      }
      unawaited(source.close(4001, 'pairing_code_mismatch'));
      emit(error: 'コード不一致の接続を拒否しました (端末: ${hello.deviceId})');
      return;
    }
    final cameraChangedSinceCalibration =
        engine.isCalibrated &&
        hello.cameraFacing != null &&
        hello.cameraFacing != _calibratedCameraFacing;
    if (cameraChangedSinceCalibration) {
      _log(
        '接続カメラが前回位置合わせと異なるため旧位置合わせを破棄: '
        '${_calibratedCameraFacing ?? "unknown"} -> ${hello.cameraFacing}',
      );
      _invalidateCalibration(notifyClient: false);
    }
    // 同じ接続での hello し直しは session の切り替え。旧 session の入力を
    // 猶予なしで解除し、frameId の基準も新 session 用に初期化する。
    if (_sessionId != null) _releaseSessionInput();
    _clientId = hello.deviceId;
    _helloTimer?.cancel();
    _helloTimer = null;
    _sessionId = 'session-${_randHex(8)}';
    _armInactivityTimeout(source);
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
      acceptedInteractionProfile:
          hello.interactionProfile == kTwoHandInteractionProfile
              ? kTwoHandInteractionProfile
              : null,
    );
    _sendTo(source, ack.toJson());
    engine.mode =
        engine.isCalibrated ? EngineMode.tracking : EngineMode.calibration;
    emit();
    if (cameraChangedSinceCalibration) onCalibrationInvalidated?.call();
  }

  void _onCalibration(CalibrationMarkers markers) {
    if (!acceptCalibrationMessages) {
      emit();
      return;
    }
    if (!engine.config.acceptsAruco) {
      emit(); // 設定で除外中のソースは静かに無視
      return;
    }
    final ok = engine.calibrate(markers);
    if (ok) {
      _calibratedCameraFacing = markers.cameraFacing;
      _log('calibration_markers で位置合わせ成功 → set_mode tracking 送信');
      // 「画面位置合わせ完了」の通知（チームシーケンス図）。Androidはこれで
      // マーカー検出ループを抜けて通常トラッキングへ移る。
      _send(ControlMessage.setMode(_sessionId ?? '', 'tracking').toJson());
    }
    // 安定判定の蓄積中（4マーカー揃いだが未確定）はエラーにしない。
    final invalid = markers.markers.length < 4;
    emit(error: invalid ? 'calibration failed (need 4 markers)' : null);
  }

  void _onCameraChanged(CameraChanged message) {
    if (!message.isValid || message.sessionId != _sessionId) {
      _log('不正または別sessionの camera_changed を無視');
      emit(error: 'invalid camera_changed (ignored)');
      return;
    }
    _log('カメラ切替を受信: facing=${message.cameraFacing} → 再位置合わせ必須');
    _invalidateCalibration(notifyClient: true);
    onCalibrationInvalidated?.call();
  }

  void _invalidateCalibration({required bool notifyClient}) {
    _pending = null;
    final byTrack = engine.resetCalibration();
    _dispatch(byTrack);
    _calibratedCameraFacing = null;
    if (notifyClient && _sessionId != null) {
      _send(ControlMessage.setMode(_sessionId!, 'calibration').toJson());
    }
    emit();
  }

  /// スマホ検出のスライド四隅で位置合わせ（ArUcoなしの経路）。
  void _onSlideCorners(SlideCorners sc) {
    if (!acceptCalibrationMessages) {
      emit();
      return;
    }
    if (!engine.config.acceptsSlideCorners) {
      emit(); // 設定で除外中のソースは静かに無視
      return;
    }
    if (!sc.isValid) {
      emit(error: 'slide_corners requires 4 finite corners');
      return;
    }
    final ok = engine.calibrateFromCorners(sc.corners);
    if (ok) {
      _send(ControlMessage.setMode(_sessionId ?? '', 'tracking').toJson());
    }
    // 安定判定の蓄積中はエラーにしない（退化した四隅だけを報告）。
    final degenerate = Homography.fromCorners(sc.corners) == null;
    emit(
      error:
          degenerate
              ? 'slide_corners calibration failed (degenerate quad)'
              : null,
    );
  }

  void _enqueueFrame(InputFrame f, int receiveMicros) {
    if (_sessionId == null) return; // ハンドシェイク前は無視
    final probe = latencyProbe;
    if (probe != null) {
      final parseMicros = probe.now();
      probe.onReceived(
        receiveMicros: receiveMicros,
        parseMicros: parseMicros,
        handCount: f.tracks.length,
        replacedPending: _pending != null,
      );
      _pendingReceiveMicros = receiveMicros;
      _pendingParseMicros = parseMicros;
    }
    _pending = f; // 最新で置換
    _drain();
  }

  Future<void> _drain() async {
    if (_processing) return;
    _processing = true;
    while (_pending != null) {
      final f = _pending!;
      _pending = null;
      final probe = latencyProbe;
      final receiveMicros = _pendingReceiveMicros;
      final parseMicros = _pendingParseMicros;
      final startMicros = probe?.now() ?? 0;
      // (sessionId, trackId) ごとに分離したエンジンで処理。単調増加でない
      // frameId は onInputFrame が null を返す＝フレーム全体を破棄する。
      final byTrack = engine.onInputFrame(f);
      final engineMicros = probe?.now() ?? 0;
      if (byTrack == null) {
        probe?.onStale();
        _log('失効した hand_frame を破棄（frameId=${f.frameId}）');
        emit(error: 'stale hand_frame (discarded)');
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      _frames++;
      if (_frames == 1) _log('hand_frame 受信開始 (frameId=${f.frameId})');
      _lastFrameId = f.frameId;
      _handDetected = f.hasHands;
      onFrame?.call(f);
      _dispatch(byTrack, probe);
      if (probe != null) {
        probe.onProcessed(
          receiveMicros: receiveMicros,
          parseMicros: parseMicros,
          startMicros: startMicros,
          engineMicros: engineMicros,
          osMicros: byTrack.isEmpty ? engineMicros : _osMicros,
          overlayMicros: byTrack.isEmpty ? engineMicros : _overlayMicros,
        );
      }
      emit();
      _syncLostTrackTimer();
      await Future<void>.delayed(Duration.zero); // 他イベントに譲る
    }
    _processing = false;
  }

  /// 猶予中のトラックがある間だけ周期タイマーを動かし、hand_frame が途絶えても
  /// 時計で猶予切れを判定して解除する。
  void _syncLostTrackTimer() {
    if (!engine.hasLostTracks || _sessionId == null) {
      _lostTrackTimer?.cancel();
      _lostTrackTimer = null;
      return;
    }
    _lostTrackTimer ??= Timer.periodic(lostTrackCheckInterval, (_) {
      if (_sessionId == null) {
        _syncLostTrackTimer();
        return;
      }
      final byTrack = engine.expireLostTracks();
      if (byTrack.isNotEmpty) {
        _log('hand_frame 途絶中に猶予が切れたトラックを解除: ${byTrack.keys.toList()}');
        // 受信フレームの区間ではないので計測（probe）には渡さない。
        _dispatch(byTrack);
        emit();
      }
      _syncLostTrackTimer();
    });
  }

  /// 安定して保持する主トラックのイベントをOS入力へ、全トラックをオーバーレイへ。
  /// [probe] があれば OS 入力とオーバーレイ更新の呼び出し完了時刻を残す。
  void _dispatch(
    Map<int, List<InteractionEvent>> byTrack, [
    LatencyProbe? probe,
  ]) {
    if (byTrack.isEmpty) return;
    final primaryEvents = engine.primaryEventsOf(byTrack);
    if (primaryEvents != null) onEvents(primaryEvents);
    if (probe != null) _osMicros = probe.now();
    onTrackEvents?.call(byTrack);
    if (probe != null) _overlayMicros = probe.now();
  }

  void requestMode(String mode) {
    if (_sessionId == null) return;
    engine.mode =
        mode == 'tracking' ? EngineMode.tracking : EngineMode.calibration;
    _send(ControlMessage.setMode(_sessionId!, mode).toJson());
    emit();
  }

  void _send(Map<String, dynamic> j) => _connection?.send(jsonEncode(j));

  static void _sendTo(TransportConnection c, Map<String, dynamic> j) {
    c.send(jsonEncode(j));
  }

  @override
  void onClosed(TransportConnection connection) {
    // 旧接続の切断通知は非同期で遅れて届く。別の接続が既に確立済みなら、
    // その現行session/client状態には一切触れない。
    if (!identical(_connection, connection)) return;
    _connection = null;
    _clearConnectionState(releaseInput: true);
    emit();
  }

  void _onHelloTimeout(TransportConnection source) {
    if (!identical(_connection, source) || _clientId != null) return;
    _log('hello timeout (${source.label}): 認証メッセージ未受信のため切断');
    _sendTo(
      source,
      const HelloError(
        code: 'hello_timeout',
        message: '接続の初期化が時間切れになりました',
        retryable: true,
      ).toJson(),
    );
    _connection = null;
    _clearConnectionState(releaseInput: false);
    unawaited(source.close(4003, 'hello_timeout'));
    emit(error: 'helloを受信できず接続を終了しました');
  }

  void _armInactivityTimeout(TransportConnection source) {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(
      inactivityTimeout,
      () => _onInactivityTimeout(source),
    );
  }

  void _onInactivityTimeout(TransportConnection source) {
    if (!identical(_connection, source) || _sessionId == null) return;
    _log('受信timeout: heartbeatを含む通信が途絶えたため半開き接続を解放');
    _connection = null;
    _clearConnectionState(releaseInput: true);
    unawaited(source.close(4004, 'inactivity_timeout'));
    emit(error: 'スマホとの通信が途絶えたため再接続を待っています');
  }

  /// 旧 session の入力状態を捨て、全トラックを即時解除する（猶予なし）。
  /// エンジンの releaseAll が frameId の基準も初期化する。
  void _releaseSessionInput() {
    _lostTrackTimer?.cancel();
    _lostTrackTimer = null;
    _frames = 0;
    _lastFrameId = null;
    _handDetected = false;
    _pending = null;
    final byTrack = engine.releaseAll();
    _dispatch(byTrack);
  }

  void _clearConnectionState({required bool releaseInput}) {
    _helloTimer?.cancel();
    _helloTimer = null;
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _lostTrackTimer?.cancel();
    _lostTrackTimer = null;
    _sessionId = null;
    _clientId = null;
    _frames = 0;
    _lastFrameId = null;
    _handDetected = false;
    _pending = null;
    if (!releaseInput) return;
    // 切断・停止では全trackIdを即時解除する。
    final byTrack = engine.releaseAll();
    _dispatch(byTrack);
  }

  /// 停止時に現在の接続を切り離し、状態を消す（接続があれば入力も即時解除）。
  /// 切り離した接続を返す。閉じるのは呼び出し側。
  ///
  /// 切断通知より先にidentityを外すので、停止後に古いsessionIdが状態通知へ残らない。
  TransportConnection? detach() {
    final connection = _connection;
    _connection = null;
    _clearConnectionState(releaseInput: connection != null);
    return connection;
  }

  void emit({bool? listening, String? error}) {
    onStatus(
      ServerStatus(
        listening: listening ?? isListening(),
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
