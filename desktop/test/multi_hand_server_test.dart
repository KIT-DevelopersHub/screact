import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
import 'package:thehack_overlay/net/input_server.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';

import 'fixtures/two_hand_fixtures.dart';

/// 統合シートの実通信fixture（trackId 7/12）を、実際のWebSocketサーバへ流し、
/// Android未完でもPCが2骨格分の受信・状態分離・片手消失時の個別解除を行えることを
/// end-to-end で確認する。
void main() {
  test('sheet fixture: 2手受信→骨格2件→片手を隠すと他方は継続・消えた手だけ解除',
      () async {
    final frames = <InputFrame>[];
    final trackEvents = <Map<int, List<InteractionEvent>>>[];
    final engine = MultiHandEngine(calibrationEngine: InteractionEngine());
    // 位置合わせ（骨格を画面座標へ写せる状態にしてから通常追跡へ）。
    engine.calibrate(MockHand.markers());

    final server = InputServer(
      engine: engine,
      port: 0,
      onEvents: (_) {},
      onTrackEvents: trackEvents.add,
      onFrame: frames.add,
      onStatus: (_) {},
    );
    await server.start();
    addTearDown(server.stop);

    final ws = await WebSocket.connect(
      'ws://localhost:${server.boundPort}/ws/v1/input',
    );
    addTearDown(ws.close);

    final ackSession = Completer<String>();
    ws.listen((data) {
      final j = jsonDecode(data as String) as Map<String, dynamic>;
      if (j['messageType'] == 'hello_ack' && !ackSession.isCompleted) {
        ackSession.complete(j['sessionId'] as String);
      }
    });

    void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));
    send({
      'schemaVersion': 1,
      'messageType': 'hello',
      'deviceId': 'fixture-client',
      'interactionProfile': 'two_users_two_active_hands',
      'maxHands': 2,
    });
    // 実Androidと同じく、サーバが払い出した sessionId をフレームへ載せる。
    final session = await ackSession.future.timeout(const Duration(seconds: 5));

    Future<void> waitFrames(int n) async {
      for (var i = 0; i < 100 && frames.length < n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    // 2手フレーム。
    send(twoHandFrame(frameId: 1842, sessionId: session));
    await waitFrames(1);
    expect(frames.last.tracks.map((t) => t.trackId), [7, 12]);
    expect(frames.last.tracks.every((t) => t.landmarks.length == 21), isTrue);
    expect(engine.activeTrackCount, 2, reason: '2骨格分の状態を分離保持');

    // 片手（12）を隠す → hands=[7]。
    send(oneHandFrame(frameId: 1843, sessionId: session));
    await waitFrames(2);
    expect(frames.last.tracks.map((t) => t.trackId), [7]);
    expect(engine.activeTrackCount, 1, reason: '12 は解除され 7 は継続');
    expect(engine.activeTrackIds, [7]);

    // 12 の解除イベントがオーバーレイ側へ通知される。
    final released = trackEvents
        .expand((m) => m.entries)
        .where((e) => e.key == 12)
        .expand((e) => e.value)
        .any((ev) => ev.kind == InteractionKind.release);
    expect(released, isTrue, reason: '消えた 12 だけを即時解除');

    // 0手 → 全解除。
    send(zeroHandFrame(frameId: 1844, sessionId: session));
    await waitFrames(3);
    expect(engine.activeTrackCount, 0);
  });

  test('session不一致の hand_frame は全体破棄される', () async {
    final frames = <InputFrame>[];
    final engine = MultiHandEngine(calibrationEngine: InteractionEngine());
    engine.calibrate(MockHand.markers());
    final server = InputServer(
      engine: engine,
      port: 0,
      onEvents: (_) {},
      onFrame: frames.add,
      onStatus: (_) {},
    );
    await server.start();
    addTearDown(server.stop);

    final ws = await WebSocket.connect(
      'ws://localhost:${server.boundPort}/ws/v1/input',
    );
    addTearDown(ws.close);
    final ack = Completer<void>();
    ws.listen((data) {
      final j = jsonDecode(data as String) as Map<String, dynamic>;
      if (j['messageType'] == 'hello_ack' && !ack.isCompleted) ack.complete();
    });
    ws.add(jsonEncode({
      'schemaVersion': 1,
      'messageType': 'hello',
      'deviceId': 'x',
    }));
    await ack.future.timeout(const Duration(seconds: 5));

    // わざと別 session を載せる → 破棄され onFrame は呼ばれない。
    ws.add(jsonEncode(twoHandFrame(frameId: 5, sessionId: 'session-WRONG')));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(frames, isEmpty);
    expect(engine.activeTrackCount, 0);
  });
}
