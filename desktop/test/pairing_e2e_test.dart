import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/net/discovery.dart';
import 'package:thehack_overlay/net/input_server.dart';
import 'package:thehack_overlay/ui/pairing_controller.dart';

/// ゼロコンフィグ・ペアリングの loopback E2E（実UDP＋実WSサーバ）。
/// 実機不具合「PCは認識・Androidは待ちのまま」の回帰テスト:
///   offer→response→select(再送)→ACK→WS接続→hello→hello_ack→両側遷移
/// を、実機Android相当のモック（UDP待受＋select受信でWS自動接続）で通す。
void main() {
  test('offer→Android自発WS接続→hello_ack で両側が接続完了へ遷移する', () async {
    // --- PC側: 実サーバ＋実発見（home_page.dart と同じ配線） ---
    final engine = InteractionEngine();
    ServerStatus status = const ServerStatus();
    String? helloAckSessionId;
    late InputServer server;
    late PairingController controller;
    server = InputServer(
      engine: engine,
      port: 0, // 空きポート
      onEvents: (_) {},
      onStatus: (st) {
        // home_page._onServerStatus 相当: hello受領（clientId確定）で発見終了。
        final justConnected = st.clientId != null && status.clientId == null;
        status = st;
        if (justConnected) controller.onConnected();
      },
      pairingCode: '123456',
    );
    await server.start();

    // --- Android側モック: offer受信で自分からWS接続（接続の向きを反転・実機相当） ---
    // PC→Androidのユニキャスト(select)は使わない。offerのip/wsPort/tokenで接続する。
    final phone = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    var phoneConnected = false;
    phone.listen((e) {
      if (e != RawSocketEvent.read) return;
      final dg = phone.receive();
      if (dg == null) return;
      final j = decodeDiscoveryDatagram(dg.data);
      if (j == null) return;
      final offer = DiscoveryOffer.tryParse(j);
      if (offer == null) return;
      // PC表示用にresponseを返す（接続には不要）。
      phone.send(
        utf8.encode(
          jsonEncode(
            const DiscoveryResponse(
              deviceId: 'e2e-phone',
              deviceName: 'E2E Phone',
              model: 'mock',
            ).toJson(),
          ),
        ),
        dg.address,
        dg.port,
      );
      if (phoneConnected) return;
      phoneConnected = true;
      // offer受信で即WS接続（host=offer送信元、wsPort/token=offer）。
      () async {
        final ws = await WebSocket.connect(
          'ws://${dg.address.address}:${offer.wsPort}/ws/v1/input',
        );
        ws.listen((data) {
          final m = jsonDecode(data as String) as Map<String, dynamic>;
          if (m['messageType'] == 'hello_ack') {
            helloAckSessionId = m['sessionId'] as String?;
          }
        });
        ws.add(
          jsonEncode({
            'schemaVersion': 1,
            'messageType': 'hello',
            'deviceId': 'e2e-phone',
            'clientVersion': '0.0.0-e2e',
            'pairingToken': offer.token,
          }),
        );
      }();
    });

    controller = PairingController(
      discoveryFactory:
          () => DesktopDiscovery(
            token: '123456',
            wsPort: server.boundPort!,
            discoveryPort: phone.port,
            broadcastAddresses: ['127.0.0.1'],
            offerInterval: const Duration(milliseconds: 80),
            selectResendInterval: const Duration(milliseconds: 50),
          ),
    );

    Future<void> waitUntil(bool Function() cond) async {
      final sw = Stopwatch()..start();
      while (!cond()) {
        if (sw.elapsed > const Duration(seconds: 8)) {
          fail('条件が時間内に満たされませんでした');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    await controller.start();
    expect(controller.phase, PairingPhase.searching);
    // Android側: offer受信で即WS接続→hello_ack受信＝接続完了（selectを介さない）。
    await waitUntil(() => helloAckSessionId != null);
    // PC側: hello受領で発見終了＝次画面（ArUco表示）へ。phase は idle に戻る。
    await waitUntil(() => controller.phase == PairingPhase.idle);
    expect(status.clientId, 'e2e-phone');
    expect(status.sessionId, helloAckSessionId);

    controller.dispose();
    phone.close();
    await server.stop();
  });
}
