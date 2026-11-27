import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
import 'package:thehack_overlay/net/input_server.dart';
import 'package:thehack_overlay/net/latency_probe.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';

import 'fixtures/two_hand_fixtures.dart';

void main() {
  group('IntSampleBuffer', () {
    test('サンプルが無ければ null', () {
      final b = IntSampleBuffer(4);
      expect(b.size, 0);
      expect(b.percentile(0.5), isNull);
      expect(b.percentile(0.95), isNull);
    });

    test('最近傍順位法で中央値とP95を返す（偶数個の中央値は下側）', () {
      final b = IntSampleBuffer(100);
      for (var v = 100; v >= 1; v--) {
        b.add(v);
      }
      expect(b.size, 100);
      expect(b.percentile(0.5), 50);
      expect(b.percentile(0.95), 95);

      final c = IntSampleBuffer(8)
        ..add(40)
        ..add(10)
        ..add(30)
        ..add(20);
      expect(c.percentile(0.5), 20);
      expect(c.percentile(0.95), 40);
    });

    test('満杯なら最古から上書きし、件数は容量で止まる', () {
      final b = IntSampleBuffer(3);
      for (final v in [1000, 1000, 1000, 1, 2, 3]) {
        b.add(v);
      }
      expect(b.size, 3);
      expect(b.percentile(0.95), 3);
      expect(b.percentile(0.5), 2);
    });

    test('clear で空に戻る', () {
      final b = IntSampleBuffer(3)..add(5);
      b.clear();
      expect(b.size, 0);
      expect(b.percentile(0.5), isNull);
    });
  });

  group('LatencyWindow', () {
    test('件数・破棄数・手の数・区間を集計する', () {
      final w = LatencyWindow(capacity: 16);
      // 33ms 間隔で3枚受信。2枚目は未処理の1枚目を上書きした。
      w.onReceived(
        receiveMicros: 1000000,
        parseMicros: 1000200,
        handCount: 1,
        replacedPending: false,
      );
      w.onReceived(
        receiveMicros: 1033000,
        parseMicros: 1033300,
        handCount: 2,
        replacedPending: true,
      );
      w.onProcessed(
        receiveMicros: 1033000,
        parseMicros: 1033300,
        startMicros: 1033400,
        engineMicros: 1034400,
        osMicros: 1034600,
        overlayMicros: 1035000,
      );
      w.onReceived(
        receiveMicros: 1066000,
        parseMicros: 1066100,
        handCount: 5, // 範囲外は2手側へ寄せる
        replacedPending: false,
      );
      w.onStale();

      final s = w.summarize(5000000);
      expect(s.received, 3);
      expect(s.processed, 1);
      expect(s.dropped, 1);
      expect(s.stale, 1);
      expect(s.handCounts, [0, 1, 2]);
      expect(s.frameInterval.samples, 2);
      expect(s.frameInterval.p50Micros, 33000);
      expect(s.receiveToParse.p95Micros, 300);
      expect(s.parseToStart.p50Micros, 100);
      expect(s.startToEngine.p50Micros, 1000);
      expect(s.engineToOs.p50Micros, 200);
      expect(s.osToOverlay.p50Micros, 400);
      expect(s.receiveToOverlay.p50Micros, 2000);

      expect(
        LatencyWindow.format(s),
        'win=5.0s recv=3 done=1 drop=1 stale=1 hands=0/1/2 '
        'interval=33.0/33.0 parse=0.2/0.3 wait=0.1/0.1 engine=1.0/1.0 '
        'os=0.2/0.2 overlay=0.4/0.4 total=2.0/2.0',
      );
    });

    test('長い空白はフレーム間隔に含めず、逆転した区間は捨てる', () {
      final w = LatencyWindow(capacity: 4);
      w.onReceived(
        receiveMicros: 0,
        parseMicros: 10,
        handCount: 0,
        replacedPending: false,
      );
      w.onReceived(
        receiveMicros: 10000000,
        parseMicros: 9999999,
        handCount: 0,
        replacedPending: false,
      );
      final s = w.summarize(1);
      expect(s.frameInterval.samples, 0);
      expect(s.receiveToParse.samples, 1);
    });

    test('サンプルが無い区間は - と出し、reset で集計を消す', () {
      final w = LatencyWindow(capacity: 4);
      w.onReceived(
        receiveMicros: 100,
        parseMicros: 150,
        handCount: 1,
        replacedPending: false,
      );
      w.reset();
      final line = LatencyWindow.format(w.summarize(5000000));
      expect(
        line,
        'win=5.0s recv=0 done=0 drop=0 stale=0 hands=0/0/0 interval=-/- '
        'parse=-/- wait=-/- engine=-/- os=-/- overlay=-/- total=-/-',
      );
      // フレーム間隔の基準時刻は reset 後も残る。
      w.onReceived(
        receiveMicros: 33100,
        parseMicros: 33150,
        handCount: 1,
        replacedPending: false,
      );
      expect(w.summarize(1).frameInterval.p50Micros, 33000);
    });
  });

  group('LatencyProbe', () {
    test('差し替えた時計で、間隔を過ぎた次の受信時に ScreactPerf 行を1つ出す', () {
      var now = 0;
      final lines = <String>[];
      final probe = LatencyProbe(
        sink: lines.add,
        nowMicros: () => now,
        reportIntervalMicros: 5000000,
      );
      expect(probe.now(), 0);

      void receive(int at) {
        probe.onReceived(
          receiveMicros: at,
          parseMicros: at + 100,
          handCount: 1,
          replacedPending: false,
        );
        probe.onProcessed(
          receiveMicros: at,
          parseMicros: at + 100,
          startMicros: at + 100,
          engineMicros: at + 600,
          osMicros: at + 700,
          overlayMicros: at + 900,
        );
      }

      for (var t = 0; t < 5000000; t += 50000) {
        receive(t);
      }
      expect(lines, isEmpty);

      now = 5000000;
      receive(5000000); // 窓を締めてから、このフレームは次の窓へ入る
      expect(lines, hasLength(1));
      expect(
        lines.single,
        'ScreactPerf win=5.0s recv=100 done=100 drop=0 stale=0 hands=0/100/0 '
        'interval=50.0/50.0 parse=0.1/0.1 wait=0.0/0.0 engine=0.5/0.5 '
        'os=0.1/0.1 overlay=0.2/0.2 total=0.9/0.9',
      );
      final next = probe.window.summarize(0);
      expect(next.received, 1);
      expect(next.processed, 1);
    });

    test('既定の時計は単調に進む', () {
      final probe = LatencyProbe(sink: (_) {});
      final a = probe.now();
      final b = probe.now();
      expect(b, greaterThanOrEqualTo(a));
    });
  });

  test('InputServer: 計測ONで受信・処理・失効を記録する', () async {
    var clock = 0;
    final probe = LatencyProbe(
      sink: (_) {},
      nowMicros: () => clock += 100,
      reportIntervalMicros: 1 << 40,
    );
    final frames = <InputFrame>[];
    final engine = MultiHandEngine(calibrationEngine: InteractionEngine());
    engine.calibrate(MockHand.markers());
    final server = InputServer(
      engine: engine,
      port: 0,
      onEvents: (_) {},
      onTrackEvents: (_) {},
      onFrame: frames.add,
      onStatus: (_) {},
      latencyProbe: probe,
    );
    await server.start();
    addTearDown(server.stop);

    final ws = await WebSocket.connect(
      'ws://localhost:${server.boundPort}/ws/v1/input',
    );
    addTearDown(ws.close);
    final ack = Completer<String>();
    ws.listen((data) {
      final j = jsonDecode(data as String) as Map<String, dynamic>;
      if (j['messageType'] == 'hello_ack' && !ack.isCompleted) {
        ack.complete(j['sessionId'] as String);
      }
    });
    ws.add(
      jsonEncode({
        'schemaVersion': 1,
        'messageType': 'hello',
        'deviceId': 'perf-client',
        'interactionProfile': 'two_users_two_active_hands',
        'maxHands': 2,
      }),
    );
    final session = await ack.future.timeout(const Duration(seconds: 5));

    Future<void> sendAndWait(Map<String, dynamic> m, int received) async {
      ws.add(jsonEncode(m));
      for (var i = 0; i < 200; i++) {
        final s = probe.window.summarize(0);
        if (s.received >= received &&
            s.processed + s.dropped + s.stale >= received) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    await sendAndWait(twoHandFrame(frameId: 10, sessionId: session), 1);
    await sendAndWait(oneHandFrame(frameId: 11, sessionId: session), 2);
    await sendAndWait(zeroHandFrame(frameId: 12, sessionId: session), 3);
    // frameId が戻ったフレームはエンジンが失効扱いで破棄する。
    await sendAndWait(oneHandFrame(frameId: 5, sessionId: session), 4);

    final s = probe.window.summarize(0);
    expect(s.received, 4);
    expect(s.handCounts, [1, 2, 1]);
    expect(s.stale, 1);
    expect(s.processed + s.dropped, 3);
    expect(s.processed, frames.length);
    expect(s.receiveToParse.samples, 4);
    expect(s.receiveToOverlay.samples, s.processed);
    // 時計は1回読むごとに100µs進むので、各区間は正の値になる。
    expect(s.startToEngine.p50Micros, greaterThan(0));
    expect(s.receiveToOverlay.p50Micros, greaterThan(0));
  });
}
