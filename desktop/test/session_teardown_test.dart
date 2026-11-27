import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/net/input_server.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';
import 'package:thehack_overlay/protocol/messages.dart';

/// 切断・無通信タイムアウト・再接続の各場面で、押下／ドラッグ／描画／消しゴム／
/// スクロールが即時に解除され（MultiHandEngine.releaseAll）、旧セッションの
/// hand_frame が拒否されることを、実WebSocketサーバ越しに固定する回帰テスト。
///
/// 片手だけの消失（一時欠落の猶予の対象）は扱わず、接続単位の全解除に絞る。

/// 合成した [HandFrame] を hands[] の1トラック分のJSONへ変換する。
Map<String, dynamic> _track(int trackId, HandFrame f) => {
  'trackId': trackId,
  'landmarks': [
    for (final l in f.landmarks) [l.x, l.y, l.z],
  ],
};

Map<String, dynamic> _frame(
  String sessionId,
  int frameId,
  List<Map<String, dynamic>> hands,
) => {
  'schemaVersion': 1,
  'messageType': 'hand_frame',
  'sessionId': sessionId,
  'frameId': frameId,
  'capturedAtMonotonicMs': frameId * 33,
  'hands': hands,
};

HandFrame _pointer(Vec2 tip) => MockHand.at(frameId: 0, tip: tip, pinch: false);

Map<String, dynamic> _hello(String deviceId, {String? token}) => {
  'schemaVersion': 1,
  'messageType': 'hello',
  'deviceId': deviceId,
  if (token != null) 'pairingToken': token,
};

/// 解除前に作っておく入力状態。各状態は「開始フレーム→継続フレーム」の2枚で作る。
enum _Held { press, drag, draw, erase, scroll }

extension on _Held {
  String get label => switch (this) {
    _Held.press => '押下中',
    _Held.drag => 'ドラッグ中',
    _Held.draw => '描画中',
    _Held.erase => '消しゴム中',
    _Held.scroll => 'スクロール中',
  };

  /// i 枚目（0,1）の手。
  HandFrame hand(int i) => switch (this) {
    _Held.press => MockHand.at(
      frameId: 0,
      tip: const Vec2(0.5, 0.5),
      pinch: true,
    ),
    _Held.drag => MockHand.at(
      frameId: 0,
      tip: Vec2(0.4 + 0.1 * i, 0.5),
      pinch: true,
    ),
    _Held.draw => MockHand.at(
      frameId: 0,
      tip: Vec2(0.4 + 0.1 * i, 0.5),
      pinch: false,
      together: true,
    ),
    _Held.erase => MockHand.fist(frameId: 0, tip: Vec2(0.4 + 0.1 * i, 0.5)),
    _Held.scroll => MockHand.goodSign(frameId: 0),
  };

  /// 状態が保持されていることを示す、継続フレームのイベント。
  InteractionKind get holdingKind => switch (this) {
    _Held.press => InteractionKind.pressMove,
    _Held.drag => InteractionKind.pressMove,
    _Held.draw => InteractionKind.drawMove,
    _Held.erase => InteractionKind.eraseMove,
    _Held.scroll => InteractionKind.scroll,
  };

  /// 解除時に OS 入力側へ届くべき終了イベント（スクロールは保持状態がないので null）。
  InteractionKind? get endKind => switch (this) {
    _Held.press => InteractionKind.pressUp,
    _Held.drag => InteractionKind.pressUp,
    _Held.draw => InteractionKind.drawUp,
    _Held.erase => InteractionKind.eraseUp,
    _Held.scroll => null,
  };
}

/// テスト用の接続端末（hello 済み）。
class _Client {
  final WebSocket ws;
  final Stream<Map<String, dynamic>> messages;
  final String sessionId;
  _Client(this.ws, this.messages, this.sessionId);

  void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));
}

/// 実サーバと、OS入力側・オーバーレイ側の受信記録。
class _Harness {
  final MultiHandEngine engine;
  final InputServer server;
  final OverlayModel overlay;
  final List<List<InteractionEvent>> osEvents;
  final List<Map<int, List<InteractionEvent>>> trackEvents;
  final List<InputFrame> frames;
  final List<ServerStatus> statuses;

  _Harness._(
    this.engine,
    this.server,
    this.overlay,
    this.osEvents,
    this.trackEvents,
    this.frames,
    this.statuses,
  );

  static Future<_Harness> start({
    Duration inactivityTimeout = const Duration(seconds: 12),
    String? pairingCode,
  }) async {
    final engine = MultiHandEngine(calibrationEngine: InteractionEngine());
    // 位置合わせ済みにしておき、hello で通常追跡へ入れる。
    engine.calibrate(MockHand.markers());
    final overlay = OverlayModel();
    final osEvents = <List<InteractionEvent>>[];
    final trackEvents = <Map<int, List<InteractionEvent>>>[];
    final frames = <InputFrame>[];
    final statuses = <ServerStatus>[];
    final server = InputServer(
      engine: engine,
      port: 0,
      onEvents: osEvents.add,
      onTrackEvents: (byTrack) {
        trackEvents.add(byTrack);
        // アプリ本体（home_page）と同じくオーバーレイへ反映する。
        overlay.applyTrackEvents(byTrack);
      },
      onFrame: frames.add,
      onStatus: statuses.add,
      inactivityTimeout: inactivityTimeout,
      pairingCode: pairingCode,
    );
    await server.start();
    addTearDown(server.stop);
    return _Harness._(
      engine,
      server,
      overlay,
      osEvents,
      trackEvents,
      frames,
      statuses,
    );
  }

  ServerStatus get latest => statuses.last;

  Future<WebSocket> _open() async {
    final ws = await WebSocket.connect(
      'ws://localhost:${server.boundPort}/ws/v1/input',
    );
    addTearDown(() => ws.close());
    return ws;
  }

  /// 新しいソケットで hello し、払い出された sessionId を持つ端末を返す。
  Future<_Client> connect(String deviceId, {String? token}) async {
    final ws = await _open();
    final messages =
        ws
            .map(
              (d) => (jsonDecode(d as String) as Map).cast<String, dynamic>(),
            )
            .asBroadcastStream();
    final ack = messages.firstWhere((m) => m['messageType'] == 'hello_ack');
    ws.add(jsonEncode(_hello(deviceId, token: token)));
    final j = await ack.timeout(const Duration(seconds: 5));
    return _Client(ws, messages, j['sessionId'] as String);
  }

  /// 処理済みフレーム数が [n] に達するまで待つ。
  Future<void> waitFrames(int n) =>
      waitUntil(() => frames.length >= n, 'frames>=$n');

  Future<void> waitUntil(bool Function() cond, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('待機がタイムアウトしました: $what');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// 旧データが届かないことを確かめるための短い待機。
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 150));

  /// trackId 7 を主トラックにしてから [held] の状態を作る。frameId は 1〜4 を使う。
  Future<void> hold(_Client c, _Held held, {int trackId = 7}) async {
    final base = frames.length;
    // ポインタ2枚で主トラック（OS入力の所有者）を確定させる。
    c.send(
      _frame(c.sessionId, 1, [_track(trackId, _pointer(const Vec2(0.5, 0.5)))]),
    );
    c.send(
      _frame(c.sessionId, 2, [_track(trackId, _pointer(const Vec2(0.5, 0.5)))]),
    );
    await waitFrames(base + 2);
    expect(engine.primaryTrackId, trackId, reason: '主トラックが確定している');
    c.send(_frame(c.sessionId, 3, [_track(trackId, held.hand(0))]));
    await waitFrames(base + 3);
    c.send(_frame(c.sessionId, 4, [_track(trackId, held.hand(1))]));
    await waitFrames(base + 4);
    expect(
      osEvents.last.map((e) => e.kind),
      contains(held.holdingKind),
      reason: '${held.label} の状態が OS 入力側で継続している',
    );
  }

  /// 解除の直前位置を記録しておき、解除イベントの到着を待つ。
  Future<List<InteractionEvent>> waitRelease(int osBefore) async {
    await waitUntil(
      () => osEvents
          .skip(osBefore)
          .expand((e) => e)
          .any((e) => e.kind == InteractionKind.release),
      'OS入力側への release',
    );
    return osEvents.skip(osBefore).expand((e) => e).toList();
  }
}

/// 全解除後の共通確認: OS入力・エンジン・オーバーレイに保持状態が残らない。
void _expectReleased(
  _Harness h,
  _Held held,
  List<InteractionEvent> released, {
  int trackId = 7,
}) {
  final kinds = released.map((e) => e.kind).toList();
  final end = held.endKind;
  if (end != null) {
    expect(kinds, contains(end), reason: '${held.label} の終了イベントが OS 入力側へ届く');
    expect(
      kinds.indexOf(end),
      lessThan(kinds.indexOf(InteractionKind.release)),
      reason: '終了イベントは release より前に届く',
    );
  }
  expect(kinds, contains(InteractionKind.release));
  expect(
    kinds,
    isNot(contains(InteractionKind.scroll)),
    reason: '解除時にスクロールを送らない',
  );
  expect(h.engine.activeTrackCount, 0, reason: 'エンジンのトラック状態を破棄');
  expect(h.engine.primaryTrackId, isNull, reason: '主トラックを破棄');

  // オーバーレイ: そのトラックのカーソル/押下表示が消え、描画中ストロークが残らない。
  expect(h.overlay.track(trackId), isNull);
  expect(h.overlay.pressed, isFalse);
  final pointsBefore = [for (final s in h.overlay.strokes) s.points.length];
  // 描画中ストロークが残っていれば、同じ trackId の drawMove で点が伸びてしまう。
  h.overlay.applyTrack(
    trackId,
    const InteractionEvent(InteractionKind.drawMove, Vec2(0.9, 0.9)),
  );
  expect(
    [for (final s in h.overlay.strokes) s.points.length],
    pointsBefore,
    reason: '描画中のストロークが残っていない',
  );
}

void main() {
  group('WebSocket 切断で全解除', () {
    for (final held in _Held.values) {
      test('${held.label}に切断すると即時解除される', () async {
        final h = await _Harness.start();
        final c = await h.connect('client-a');
        await h.hold(c, held);

        final before = h.osEvents.length;
        await c.ws.close();
        final released = await h.waitRelease(before);
        _expectReleased(h, held, released);
        await h.waitUntil(() => h.latest.sessionId == null, 'session 破棄');
      });
    }

    test('2手（押下中と描画中）を同時に保持していても両方を解除する', () async {
      final h = await _Harness.start();
      final c = await h.connect('client-a');
      Map<String, dynamic> two(int id, HandFrame f7, HandFrame f12) =>
          _frame(c.sessionId, id, [_track(7, f7), _track(12, f12)]);
      final p7 = _pointer(const Vec2(0.3, 0.5));
      final p12 = _pointer(const Vec2(0.7, 0.5));
      c.send(two(1, p7, p12));
      c.send(two(2, p7, p12));
      await h.waitFrames(2);
      HandFrame pinch(double x) =>
          MockHand.at(frameId: 0, tip: Vec2(x, 0.5), pinch: true);
      HandFrame draw(double x) => MockHand.at(
        frameId: 0,
        tip: Vec2(x, 0.5),
        pinch: false,
        together: true,
      );
      c.send(two(3, pinch(0.3), draw(0.7)));
      c.send(two(4, pinch(0.32), draw(0.72)));
      await h.waitFrames(4);
      expect(h.engine.activeTrackCount, 2);

      final before = h.trackEvents.length;
      await c.ws.close();
      await h.waitUntil(() => h.engine.activeTrackCount == 0, '全トラック解除');
      await h.waitUntil(() => h.trackEvents.length > before, 'オーバーレイへの解除通知');
      final byTrack = <int, List<InteractionKind>>{};
      for (final m in h.trackEvents.skip(before)) {
        m.forEach((id, evs) {
          byTrack.putIfAbsent(id, () => []).addAll(evs.map((e) => e.kind));
        });
      }
      expect(
        byTrack[7],
        containsAll([InteractionKind.pressUp, InteractionKind.release]),
      );
      expect(
        byTrack[12],
        containsAll([InteractionKind.drawUp, InteractionKind.release]),
      );
      expect(h.overlay.trackIds, isEmpty);
      expect(h.overlay.pressed, isFalse);
    });
  });

  group('無通信タイムアウトで全解除', () {
    for (final held in _Held.values) {
      test('${held.label}に通信が途絶えると即時解除される', () async {
        final h = await _Harness.start(
          inactivityTimeout: const Duration(milliseconds: 400),
        );
        final c = await h.connect('client-a');
        await h.hold(c, held);

        // 以後何も送らない（半開き接続）。ソケットはクライアント側では開いたまま。
        final before = h.osEvents.length;
        final released = await h.waitRelease(before);
        _expectReleased(h, held, released);
        await h.waitUntil(() => h.latest.sessionId == null, 'session 破棄');

        // タイムアウトで切り離されたソケットからの送信は、もう処理されない。
        final framesBefore = h.frames.length;
        final osBefore = h.osEvents.length;
        try {
          c.send(_frame(c.sessionId, 5, [_track(7, held.hand(1))]));
        } catch (_) {
          // サーバ側の close が先に届いていれば送信自体が失敗してよい。
        }
        await h.settle();
        expect(h.frames.length, framesBefore);
        expect(h.osEvents.length, osBefore);
        expect(h.engine.activeTrackCount, 0);
      });
    }
  });

  group('再接続（新しい sessionId）', () {
    for (final held in _Held.values) {
      test('${held.label}に切断→新しい hello で再接続すると解除済みで始まる', () async {
        final h = await _Harness.start();
        final old = await h.connect('client-a');
        await h.hold(old, held);

        final before = h.osEvents.length;
        await old.ws.close();
        final released = await h.waitRelease(before);
        _expectReleased(h, held, released);

        final next = await h.connect('client-a');
        expect(next.sessionId, isNot(old.sessionId));
        expect(h.engine.activeTrackCount, 0, reason: '新セッションは保持状態なしで始まる');

        // 新しいソケットに旧 sessionId のフレームが載ってきても拒否する。
        final framesBefore = h.frames.length;
        final osBefore = h.osEvents.length;
        next.send(_frame(old.sessionId, 100, [_track(7, held.hand(1))]));
        await h.settle();
        expect(h.frames.length, framesBefore, reason: '旧 session のフレームは破棄');
        expect(h.osEvents.length, osBefore);
        expect(h.engine.activeTrackCount, 0);

        // 新 session では frameId が 1 からやり直しても受理される（前 session の
        // frameId に引きずられない）。
        next.send(
          _frame(next.sessionId, 1, [
            _track(7, _pointer(const Vec2(0.5, 0.5))),
          ]),
        );
        await h.waitFrames(framesBefore + 1);
        expect(h.engine.activeTrackCount, 1);
      });
    }

    test('無通信タイムアウト後の再接続でも旧 sessionId のフレームを拒否する', () async {
      final h = await _Harness.start(
        inactivityTimeout: const Duration(milliseconds: 400),
      );
      final old = await h.connect('client-a');
      await h.hold(old, _Held.drag);
      final before = h.osEvents.length;
      _expectReleased(h, _Held.drag, await h.waitRelease(before));

      final next = await h.connect('client-a');
      expect(next.sessionId, isNot(old.sessionId));
      final framesBefore = h.frames.length;
      next.send(_frame(old.sessionId, 100, [_track(7, _Held.drag.hand(1))]));
      await h.settle();
      expect(h.frames.length, framesBefore);
      expect(h.engine.activeTrackCount, 0);
    });

    test('半開きの旧接続が残っている間の再接続は server_busy で拒否され、旧状態を壊さない', () async {
      final h = await _Harness.start();
      final old = await h.connect('client-a');
      await h.hold(old, _Held.drag);

      final ws = await h._open();
      final busy = ws
          .map((d) => (jsonDecode(d as String) as Map).cast<String, dynamic>())
          .firstWhere((m) => m['messageType'] == 'hello_error');
      expect(
        (await busy.timeout(const Duration(seconds: 5)))['code'],
        'server_busy',
      );
      expect(h.latest.sessionId, old.sessionId);
      expect(h.engine.activeTrackCount, 1, reason: '拒否された後着接続は旧状態に触れない');
    });

    for (final held in _Held.values) {
      test(
        '${held.label}に同じソケットで hello し直すと解除され、新 session の frameId=1 を受理する',
        () async {
          final h = await _Harness.start();
          final c = await h.connect('client-a');
          await h.hold(c, held);

          final before = h.osEvents.length;
          final ack = c.messages.firstWhere(
            (m) => m['messageType'] == 'hello_ack',
          );
          c.send(_hello('client-a'));
          final newSession =
              (await ack.timeout(const Duration(seconds: 5)))['sessionId']
                  as String;
          expect(newSession, isNot(c.sessionId));

          final released = await h.waitRelease(before);
          _expectReleased(h, held, released);

          final framesBefore = h.frames.length;
          c.send(
            _frame(newSession, 1, [_track(7, _pointer(const Vec2(0.5, 0.5)))]),
          );
          await h.waitFrames(framesBefore + 1);
        },
      );
    }

    test('押下中に同じソケットで 6桁コード不一致の hello が来て切断しても解除される', () async {
      final h = await _Harness.start(pairingCode: '123456');
      final c = await h.connect('client-a', token: '123456');
      await h.hold(c, _Held.drag);

      final before = h.osEvents.length;
      final rejected = c.messages.firstWhere(
        (m) => m['messageType'] == 'hello_error',
      );
      c.send(_hello('client-a', token: '000000'));
      expect(
        (await rejected.timeout(const Duration(seconds: 5)))['code'],
        'pairing_code_mismatch',
      );
      final released = await h.waitRelease(before);
      _expectReleased(h, _Held.drag, released);
    });

    test('同じソケットで hello し直した後、旧 sessionId のフレームは拒否する', () async {
      final h = await _Harness.start();
      final c = await h.connect('client-a');
      final ack = c.messages.firstWhere((m) => m['messageType'] == 'hello_ack');
      c.send(_hello('client-a'));
      final newSession =
          (await ack.timeout(const Duration(seconds: 5)))['sessionId']
              as String;
      expect(newSession, isNot(c.sessionId));

      final framesBefore = h.frames.length;
      c.send(
        _frame(c.sessionId, 50, [_track(7, _pointer(const Vec2(0.5, 0.5)))]),
      );
      await h.settle();
      expect(h.frames.length, framesBefore);
      expect(h.engine.activeTrackCount, 0);
    });
  });

  group('同一 session 内の frameId', () {
    test('重複・巻き戻った frameId は全体破棄され、操作を生まない', () async {
      final h = await _Harness.start();
      final c = await h.connect('client-a');
      await h.hold(c, _Held.drag); // frameId 1〜4

      final framesBefore = h.frames.length;
      final osBefore = h.osEvents.length;
      // 押下を離す姿勢の古いフレームが遅れて届いても、押下を解除しない。
      final up = _track(7, _pointer(const Vec2(0.5, 0.5)));
      c.send(_frame(c.sessionId, 4, [up])); // 重複
      c.send(_frame(c.sessionId, 2, [up])); // 巻き戻り
      c.send(_frame(c.sessionId, 4, const [])); // 0手でも巻き戻りは破棄
      await h.settle();
      expect(h.frames.length, framesBefore);
      expect(h.osEvents.length, osBefore);
      expect(h.engine.activeTrackCount, 1, reason: 'ドラッグは継続');

      // 前進したフレームは受理され、押下が継続している。
      c.send(_frame(c.sessionId, 5, [_track(7, _Held.drag.hand(1))]));
      await h.waitFrames(framesBefore + 1);
      expect(
        h.osEvents.last.map((e) => e.kind),
        contains(InteractionKind.pressMove),
      );
    });
  });
}
