import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
import 'package:thehack_overlay/net/input_session.dart';
import 'package:thehack_overlay/net/input_transport.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';

/// 偽の通信路の接続。送信と close を記録するだけ。
class _FakeConnection implements TransportConnection {
  @override
  final String label;
  final List<Map<String, dynamic>> sent = [];
  int? closeCode;
  String? closeReason;
  bool closed = false;

  _FakeConnection(this.label);

  @override
  void send(String message) =>
      sent.add((jsonDecode(message) as Map).cast<String, dynamic>());

  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
    closeCode = code;
    closeReason = reason;
  }

  Iterable<String?> get sentTypes =>
      sent.map((m) => m['messageType'] as String?);
}

Map<String, dynamic> _hello(String deviceId, {String? token}) => {
  'schemaVersion': 1,
  'messageType': 'hello',
  'deviceId': deviceId,
  if (token != null) 'pairingToken': token,
};

Map<String, dynamic> _frame(String sessionId, int frameId, {Vec2? tip}) => {
  'schemaVersion': 1,
  'messageType': 'hand_frame',
  'sessionId': sessionId,
  'frameId': frameId,
  'capturedAtMonotonicMs': frameId * 33,
  'hands': [
    {
      'trackId': 7,
      'landmarks': [
        for (final l
            in MockHand.at(
              frameId: 0,
              tip: tip ?? const Vec2(0.5, 0.5),
              pinch: false,
            ).landmarks)
          [l.x, l.y, l.z],
      ],
    },
  ],
};

class _Harness {
  final MultiHandEngine engine;
  final InputSession session;
  final List<ServerStatus> statuses;
  final List<InputFrame> frames;
  final List<List<InteractionEvent>> osEvents;
  final List<String> logs;

  _Harness._(
    this.engine,
    this.session,
    this.statuses,
    this.frames,
    this.osEvents,
    this.logs,
  );

  factory _Harness({
    String? pairingCode,
    Duration helloTimeout = const Duration(seconds: 5),
    Duration inactivityTimeout = const Duration(seconds: 12),
  }) {
    final engine = MultiHandEngine(calibrationEngine: InteractionEngine());
    engine.calibrate(MockHand.markers());
    final statuses = <ServerStatus>[];
    final frames = <InputFrame>[];
    final osEvents = <List<InteractionEvent>>[];
    final logs = <String>[];
    final session = InputSession(
      engine: engine,
      onEvents: osEvents.add,
      onStatus: statuses.add,
      onFrame: frames.add,
      onLog: logs.add,
      isListening: () => true,
      pairingCode: pairingCode,
      helloTimeout: helloTimeout,
      inactivityTimeout: inactivityTimeout,
    );
    addTearDown(session.detach);
    return _Harness._(engine, session, statuses, frames, osEvents, logs);
  }

  ServerStatus get latest => statuses.last;

  void text(TransportConnection c, Map<String, dynamic> j) =>
      session.onText(c, jsonEncode(j));

  /// 接続して hello し、払い出された sessionId を返す。
  String connect(
    _FakeConnection c, {
    String deviceId = 'dev-a',
    String? token,
  }) {
    expect(session.onOpened(c), isTrue);
    text(c, _hello(deviceId, token: token));
    final ack = c.sent.lastWhere((m) => m['messageType'] == 'hello_ack');
    return ack['sessionId'] as String;
  }
}

Future<void> _yield() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  test('hello で sessionId を払い出し、hello_ack を送る', () {
    final h = _Harness();
    final c = _FakeConnection('fake-1');
    final sessionId = h.connect(c, deviceId: 'dev-a');
    expect(sessionId, startsWith('session-'));
    expect(h.latest.sessionId, sessionId);
    expect(h.latest.clientId, 'dev-a');
    expect(h.latest.listening, isTrue);
    expect(h.engine.mode, EngineMode.tracking);
    expect(identical(h.session.connection, c), isTrue);
  });

  test('後着接続は server_busy で拒否し、既存の接続とセッションを保つ', () {
    final h = _Harness();
    final a = _FakeConnection('a');
    final sessionId = h.connect(a);
    final b = _FakeConnection('b');
    expect(h.session.onOpened(b), isFalse);
    expect(b.sentTypes, ['hello_error']);
    expect(b.sent.single['code'], 'server_busy');
    expect(b.closeCode, 4002);
    expect(identical(h.session.connection, a), isTrue);
    expect(h.latest.sessionId, sessionId);
  });

  test('コード不一致の hello は拒否して閉じ、枠を空ける', () {
    final h = _Harness(pairingCode: '123456');
    final c = _FakeConnection('c');
    expect(h.session.onOpened(c), isTrue);
    h.text(c, _hello('dev-x', token: '000000'));
    expect(c.sentTypes, ['hello_error']);
    expect(c.sent.single['code'], 'pairing_code_mismatch');
    expect(c.closeCode, 4001);
    expect(h.session.connection, isNull);
    expect(h.latest.sessionId, isNull);

    // 枠が空いているので次の接続は受け入れられ、正しいコードで hello できる。
    final d = _FakeConnection('d');
    final sessionId = h.connect(d, token: '123456');
    expect(h.latest.sessionId, sessionId);

    // 拒否済み接続の遅れた切断通知は、現行セッションを消さない。
    h.session.onClosed(c);
    expect(h.latest.sessionId, sessionId);
    expect(identical(h.session.connection, d), isTrue);
  });

  test('hello 前の hand_frame は処理しない', () async {
    final h = _Harness();
    final c = _FakeConnection('c');
    expect(h.session.onOpened(c), isTrue);
    h.text(c, _frame('session-unknown', 1));
    await _yield();
    expect(h.frames, isEmpty);
    expect(h.osEvents, isEmpty);
  });

  test('処理中に届いた hand_frame は最新の1枚だけ処理する', () async {
    final h = _Harness();
    final c = _FakeConnection('c');
    final sessionId = h.connect(c);
    // 1枚目は即座に処理が始まり、処理が譲っている間に届いた 2〜4 枚目は
    // 最新の 4 枚目で置換される。
    h.text(c, _frame(sessionId, 1));
    h.text(c, _frame(sessionId, 2));
    h.text(c, _frame(sessionId, 3));
    h.text(c, _frame(sessionId, 4));
    await _yield();
    expect(h.frames.map((f) => f.frameId), [1, 4]);
    expect(h.latest.lastFrameId, 4);
    expect(h.latest.frames, 2);
  });

  test('frameId が戻った hand_frame は失効として破棄する', () async {
    final h = _Harness();
    final c = _FakeConnection('c');
    final sessionId = h.connect(c);
    h.text(c, _frame(sessionId, 5));
    await _yield();
    h.text(c, _frame(sessionId, 3));
    await _yield();
    expect(h.frames.map((f) => f.frameId), [5]);
    expect(
      h.statuses.map((s) => s.lastError),
      contains('stale hand_frame (discarded)'),
    );
  });

  test('別 session の hand_frame は破棄する', () async {
    final h = _Harness();
    final c = _FakeConnection('c');
    h.connect(c);
    h.text(c, _frame('session-other', 1));
    await _yield();
    expect(h.frames, isEmpty);
    expect(h.latest.lastError, 'invalid hand_frame (discarded)');
  });

  test('現在の接続が切れたら全トラックを即時解除し、状態を消す', () async {
    final h = _Harness();
    final c = _FakeConnection('c');
    final sessionId = h.connect(c);
    // 2枚で主トラック（OS入力の所有者）を確定させる。
    h.text(c, _frame(sessionId, 1));
    await _yield();
    h.text(c, _frame(sessionId, 2));
    await _yield();
    expect(h.engine.activeTrackCount, 1);
    expect(h.engine.primaryTrackId, 7);

    h.session.onClosed(c);
    expect(h.engine.activeTrackCount, 0);
    expect(
      h.osEvents.expand((e) => e).map((e) => e.kind),
      contains(InteractionKind.release),
    );
    expect(h.session.connection, isNull);
    expect(h.latest.sessionId, isNull);
    expect(h.latest.clientId, isNull);
  });

  test('切り離した接続からの受信と切断通知は無視する', () async {
    final h = _Harness();
    final a = _FakeConnection('a');
    final oldSession = h.connect(a);
    h.session.onClosed(a);
    final b = _FakeConnection('b');
    final sessionId = h.connect(b, deviceId: 'dev-b');

    h.text(a, _frame(oldSession, 1));
    h.text(a, _hello('dev-a'));
    h.session.onClosed(a);
    await _yield();
    expect(h.frames, isEmpty);
    expect(h.latest.sessionId, sessionId);
    expect(h.latest.clientId, 'dev-b');
    expect(identical(h.session.connection, b), isTrue);
  });

  test('バイナリの受信は不正JSONとして無視する（バイナリ形式は未接続）', () {
    final h = _Harness();
    final c = _FakeConnection('c');
    final sessionId = h.connect(c);
    h.session.onBinary(c, Uint8List.fromList([1, 2, 3]));
    expect(h.latest.lastError, 'invalid json');
    expect(h.latest.sessionId, sessionId);
    expect(identical(h.session.connection, c), isTrue);
  });

  test('不正JSON・未知の messageType ではセッションを保つ', () {
    final h = _Harness();
    final c = _FakeConnection('c');
    final sessionId = h.connect(c);
    h.session.onText(c, '{not json');
    expect(h.latest.lastError, 'invalid json');
    h.text(c, {'messageType': 'unknown_type'});
    expect(h.latest.lastError, 'unknown messageType: unknown_type');
    expect(h.latest.sessionId, sessionId);
  });

  test('hello を送らない接続は hello_timeout で閉じて枠を空ける', () async {
    final h = _Harness(helloTimeout: const Duration(milliseconds: 20));
    final c = _FakeConnection('c');
    expect(h.session.onOpened(c), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(c.sentTypes, ['hello_error']);
    expect(c.sent.single['code'], 'hello_timeout');
    expect(c.closeCode, 4003);
    expect(h.session.connection, isNull);
    expect(h.session.onOpened(_FakeConnection('d')), isTrue);
  });

  test('認証後に無通信が続くと inactivity_timeout で閉じる', () async {
    final h = _Harness(inactivityTimeout: const Duration(milliseconds: 40));
    final c = _FakeConnection('c');
    h.connect(c);
    // heartbeat が届いている間は保つ。
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      h.text(c, {'messageType': 'heartbeat'});
    }
    expect(c.closed, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(c.closeCode, 4004);
    expect(h.session.connection, isNull);
    expect(h.latest.sessionId, isNull);
  });

  test('requestMode は現在の接続へ set_mode を送る', () {
    final h = _Harness();
    final c = _FakeConnection('c');
    final sessionId = h.connect(c);
    h.session.requestMode('calibration');
    final last = c.sent.last;
    expect(last['sessionId'], sessionId);
    expect(h.engine.mode, EngineMode.calibration);
  });

  test('detach は接続を返して状態を消し、以後の切断通知を無視する', () async {
    final h = _Harness();
    final c = _FakeConnection('c');
    final sessionId = h.connect(c);
    h.text(c, _frame(sessionId, 1));
    await _yield();
    final detached = h.session.detach();
    expect(identical(detached, c), isTrue);
    expect(h.engine.activeTrackCount, 0);
    expect(h.session.connection, isNull);
    final before = h.statuses.length;
    h.session.onClosed(c);
    expect(h.statuses.length, before);
  });
}
