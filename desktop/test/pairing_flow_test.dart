import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/net/discovery.dart';
import 'package:thehack_overlay/ui/pairing_controller.dart';

/// ペアリング状態遷移のテスト（loopback 実ソケットで駆動）。
/// - 1台応答 → 集約ウィンドウ後に自動選択（waitingConnect）
/// - 2台応答 → 選択UI（selecting）→ 手動選択で waitingConnect
/// - 応答ゼロ → timeout
void main() {
  Future<(RawDatagramSocket, List<DiscoverySelect>)> startResponder(
      List<String> deviceIds) async {
    final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final selects = <DiscoverySelect>[];
    sock.listen((e) {
      if (e != RawSocketEvent.read) return;
      final dg = sock.receive();
      if (dg == null) return;
      final j = decodeDiscoveryDatagram(dg.data);
      if (j == null) return;
      final sel = DiscoverySelect.tryParse(j);
      if (sel != null) {
        selects.add(sel);
        // 実機Android同様、select には毎回 ACK を返す（PCの再送が止まる）。
        sock.send(
          utf8.encode(jsonEncode(
              DiscoverySelectAck(deviceId: sel.deviceId).toJson())),
          dg.address,
          dg.port,
        );
        return;
      }
      if (DiscoveryOffer.tryParse(j) != null) {
        for (final id in deviceIds) {
          sock.send(
            utf8.encode(jsonEncode(DiscoveryResponse(
                    deviceId: id, deviceName: 'name-$id', model: 'm')
                .toJson())),
            dg.address,
            dg.port,
          );
        }
      }
    });
    return (sock, selects);
  }

  PairingController makeController(int port,
      {Duration window = const Duration(milliseconds: 250),
      Duration timeout = const Duration(milliseconds: 600)}) {
    return PairingController(
      discoveryFactory: () => DesktopDiscovery(
        token: '123456',
        wsPort: 8765,
        discoveryPort: port,
        broadcastAddresses: ['127.0.0.1'],
        offerInterval: const Duration(milliseconds: 80),
      ),
      selectionWindow: window,
      searchTimeout: timeout,
    );
  }

  Future<void> waitUntil(bool Function() cond,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final sw = Stopwatch()..start();
    while (!cond()) {
      if (sw.elapsed > timeout) fail('条件が時間内に満たされませんでした');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  test('1台だけ応答 → ウィンドウ後に自動選択され select が届く', () async {
    final (responder, selects) = await startResponder(['solo']);
    final c = makeController(responder.port);
    await c.start();
    expect(c.phase, PairingPhase.searching);
    await waitUntil(() => c.phase == PairingPhase.waitingConnect);
    expect(c.selected?.deviceId, 'solo');
    await waitUntil(() => selects.any((s) => s.deviceId == 'solo'));
    c.onConnected();
    expect(c.phase, PairingPhase.idle);
    responder.close();
  });

  test('2台応答 → selecting（選択UI）→ 手動選択で waitingConnect', () async {
    final (responder, selects) = await startResponder(['dev-a', 'dev-b']);
    final c = makeController(responder.port);
    await c.start();
    await waitUntil(() => c.phase == PairingPhase.selecting);
    expect(c.devices.length, 2);
    final target = c.devices.firstWhere((d) => d.deviceId == 'dev-b');
    c.selectDevice(target);
    expect(c.phase, PairingPhase.waitingConnect);
    expect(c.selected?.deviceId, 'dev-b');
    await waitUntil(() => selects.any((s) => s.deviceId == 'dev-b'));
    // 選ばれなかった端末宛ての select は送られていない
    expect(selects.where((s) => s.deviceId == 'dev-a'), isEmpty);
    c.cancel();
    responder.close();
  });

  test('応答ゼロ → timeout（再試行で searching に戻れる）', () async {
    final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final freePort = probe.port;
    probe.close();
    final c = makeController(freePort, timeout: const Duration(milliseconds: 250));
    await c.start();
    await waitUntil(() => c.phase == PairingPhase.timeout);
    // 再試行
    await c.start();
    expect(c.phase, PairingPhase.searching);
    c.cancel();
    expect(c.phase, PairingPhase.idle);
  });

  test('キャンセルで発見が止まり idle に戻る', () async {
    final (responder, _) = await startResponder(['dev-a']);
    final c = makeController(responder.port,
        window: const Duration(seconds: 30)); // 自動選択させない
    await c.start();
    await waitUntil(() => c.devices.isNotEmpty);
    c.cancel();
    expect(c.phase, PairingPhase.idle);
    expect(c.devices, isEmpty);
    responder.close();
  });
}
