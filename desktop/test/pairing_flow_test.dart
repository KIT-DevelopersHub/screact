import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/net/discovery.dart';
import 'package:thehack_overlay/ui/pairing_controller.dart';

/// offer駆動ペアリングの状態遷移をloopback実ソケットで検証する。
void main() {
  Future<(RawDatagramSocket, List<Map<String, dynamic>>)> startResponder(
    List<String> deviceIds,
  ) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final received = <Map<String, dynamic>>[];
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final json = decodeDiscoveryDatagram(datagram.data);
      if (json == null) return;
      received.add(json);
      if (DiscoveryOffer.tryParse(json) == null) return;
      for (final id in deviceIds) {
        socket.send(
          utf8.encode(
            jsonEncode(
              DiscoveryResponse(
                deviceId: id,
                deviceName: 'name-$id',
                model: 'm',
              ).toJson(),
            ),
          ),
          datagram.address,
          datagram.port,
        );
      }
    });
    return (socket, received);
  }

  PairingController makeController(
    int port, {
    Duration timeout = const Duration(milliseconds: 600),
  }) {
    return PairingController(
      discoveryFactory:
          () => DesktopDiscovery(
            token: '123456',
            wsPort: 8765,
            discoveryPort: port,
            broadcastAddresses: const ['127.0.0.1'],
            offerInterval: const Duration(milliseconds: 80),
          ),
      searchTimeout: timeout,
    );
  }

  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final stopwatch = Stopwatch()..start();
    while (!condition()) {
      if (stopwatch.elapsed > timeout) {
        fail('条件が時間内に満たされませんでした');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  test('応答を受けるとofferを止めずWebSocket接続待ちになる', () async {
    final (responder, received) = await startResponder(['solo']);
    final controller = makeController(responder.port);
    await controller.start();
    await waitUntil(() => controller.phase == PairingPhase.waitingConnect);
    expect(controller.selected?.deviceId, 'solo');

    final offersAtDiscovery =
        received.where((json) => DiscoveryOffer.tryParse(json) != null).length;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final offersWhileWaiting =
        received.where((json) => DiscoveryOffer.tryParse(json) != null).length;
    expect(offersWhileWaiting, greaterThan(offersAtDiscovery));
    expect(
      received.any((json) => DiscoverySelect.tryParse(json) != null),
      false,
    );

    controller.onConnected();
    expect(controller.phase, PairingPhase.idle);
    controller.dispose();
    responder.close();
  });

  test('複数応答でも見せかけの端末選択へ遷移せず最初の接続を待つ', () async {
    final (responder, received) = await startResponder(['dev-a', 'dev-b']);
    final controller = makeController(responder.port);
    await controller.start();
    await waitUntil(() => controller.devices.length == 2);
    expect(controller.phase, PairingPhase.waitingConnect);
    expect(controller.selected, isNotNull);
    expect(
      received.any((json) => DiscoverySelect.tryParse(json) != null),
      false,
    );
    controller.cancel();
    controller.dispose();
    responder.close();
  });

  test('応答後もWebSocketが来なければtimeoutになり再試行できる', () async {
    final (responder, _) = await startResponder(['silent-phone']);
    final controller = makeController(
      responder.port,
      timeout: const Duration(milliseconds: 250),
    );
    await controller.start();
    await waitUntil(() => controller.phase == PairingPhase.waitingConnect);
    await waitUntil(() => controller.phase == PairingPhase.timeout);
    await controller.start();
    expect(controller.phase, PairingPhase.searching);
    controller.cancel();
    expect(controller.phase, PairingPhase.idle);
    controller.dispose();
    responder.close();
  });

  test('キャンセルでUDP socketと端末一覧を破棄する', () async {
    final (responder, _) = await startResponder(['dev-a']);
    final controller = makeController(responder.port);
    await controller.start();
    await waitUntil(() => controller.devices.isNotEmpty);
    controller.cancel();
    expect(controller.phase, PairingPhase.idle);
    expect(controller.devices, isEmpty);
    controller.dispose();
    responder.close();
  });
}
