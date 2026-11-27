import 'dart:math' as math;

import '../core/interaction_engine.dart';
import '../core/multi_hand_engine.dart';
import '../protocol/input_frame.dart';
import 'input_session.dart';
import 'latency_probe.dart';
import 'websocket_input_transport.dart';

export 'input_session.dart' show ServerStatus;

/// PC側のWebSocketサーバ。`ws://<PCのIP>:<port>/ws/v1/input` で待受け、
/// Androidの hello/hand_frame/calibration_markers/heartbeat を捌く（protocol v1）。
/// hand_frame は「常に最新の1枚だけ処理」= 未処理の古いフレームは新着で置換する。
///
/// 通信路（[WebSocketInputTransport]）と、経路に依存しないセッション処理
/// （[InputSession]）を組み合わせる薄い層。
class InputServer {
  final MultiHandEngine engine;

  /// OS入力（単一カーソル）へ流す主トラック（最小trackId）の操作イベント。
  /// 単一手では従来どおり、その手のイベント全てが渡る。
  final void Function(List<InteractionEvent>) onEvents;

  /// 各トラックの操作イベント（オーバーレイの2カーソル/2色描画用）。任意。
  final void Function(Map<int, List<InteractionEvent>>)? onTrackEvents;

  final void Function(ServerStatus) onStatus;

  /// カメラ切替で位置合わせが失効した時、UIへ再位置合わせ表示を要求する。
  final void Function()? onCalibrationInvalidated;

  /// 受信フレーム全体（0〜2トラックの骨格・骨格表示/状態用）。任意。
  final void Function(InputFrame)? onFrame;
  final int port;

  /// WebSocket確立後、helloを送らない接続が単一クライアント枠を占有できる時間。
  final Duration helloTimeout;

  /// 認証後にメッセージを受信しない接続を半開きとみなすまでの時間。
  /// Androidは5秒ごとにheartbeatを送るため、2回分を超える猶予を持たせる。
  final Duration inactivityTimeout;

  /// 6桁ペアリングコード（null なら照合しない）。UIがサーバ開始時に生成して表示する。
  final String? pairingCode;

  /// 接続診断ログ（UI/ファイルへ流す。null なら無効）。
  final void Function(String)? onLog;

  /// 一時欠落の猶予中のトラックがある間、時計で猶予切れを確かめる周期。
  /// hand_frame が途絶えても押下・描画を猶予後に解除するため。
  final Duration lostTrackCheckInterval;

  /// hand_frame の区間計測（null なら計測しない＝既定OFF）。
  final LatencyProbe? latencyProbe;

  late final InputSession _session;
  late final WebSocketInputTransport _transport;
  bool _listening = false;

  InputServer({
    required this.engine,
    required this.onEvents,
    required this.onStatus,
    this.onCalibrationInvalidated,
    this.onTrackEvents,
    this.onFrame,
    this.port = 8765,
    this.helloTimeout = const Duration(seconds: 5),
    this.inactivityTimeout = const Duration(seconds: 12),
    this.pairingCode,
    bool enforcePairing = true,
    bool acceptCalibrationMessages = true,
    this.onLog,
    this.lostTrackCheckInterval = const Duration(milliseconds: 100),
    this.latencyProbe,
  }) {
    _session = InputSession(
      engine: engine,
      onEvents: onEvents,
      onStatus: onStatus,
      isListening: () => _listening,
      onCalibrationInvalidated: onCalibrationInvalidated,
      onTrackEvents: onTrackEvents,
      onFrame: onFrame,
      helloTimeout: helloTimeout,
      inactivityTimeout: inactivityTimeout,
      pairingCode: pairingCode,
      enforcePairing: enforcePairing,
      acceptCalibrationMessages: acceptCalibrationMessages,
      onLog: onLog,
      lostTrackCheckInterval: lostTrackCheckInterval,
      latencyProbe: latencyProbe,
    );
    _transport = WebSocketInputTransport(port: port, onLog: onLog);
  }

  /// コード照合を行うか（UIのトグルで切替可能・既定ON）。
  bool get enforcePairing => _session.enforcePairing;
  set enforcePairing(bool value) => _session.enforcePairing = value;

  /// UIが全画面ターゲットを表示している間だけ位置合わせ入力を受け付ける。
  /// 既定trueは既存の直接利用・テストとの互換性を保つ。
  bool get acceptCalibrationMessages => _session.acceptCalibrationMessages;
  set acceptCalibrationMessages(bool value) =>
      _session.acceptCalibrationMessages = value;

  void _log(String m) => onLog?.call(m);

  /// 6桁コードの生成（サーバ開始時にUIが呼ぶ）。
  static String generatePairingCode() {
    final r = math.Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  /// バインド済みポート（port=0 指定時のテスト用）。未起動なら null。
  int? get boundPort => _transport.boundPort;

  Future<void> start() async {
    await _transport.start(_session);
    _listening = true;
    _log(
      'listen 開始: ${_transport.endpoint} '
      '(全インターフェースで待受・コード照合=${enforcePairing ? "ON" : "OFF"})',
    );
    if (pairingCode != null) _log('6桁コード: $pairingCode');
    _session.emit(listening: true);
  }

  void requestMode(String mode) => _session.requestMode(mode);

  Future<void> stop() async {
    _log('サーバ停止');
    // 切断通知より先にidentityを外して状態を消す。これにより
    // stop完了時に古いsessionIdがstatusへ残らない。
    _listening = false;
    final connection = _session.detach();
    await connection?.close();
    await _transport.stop();
    _session.emit(listening: false);
  }
}
