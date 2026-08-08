import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/net/discovery.dart';

/// UDP発見プロトコルの単体テスト（JSONコーデック）と、loopback 実ソケットでの
/// offer→response→select 往復テスト。
void main() {
  group('発見メッセージのJSONコーデック', () {
    test('offer の round trip', () {
      const offer = DiscoveryOffer(ip: '192.168.1.5', wsPort: 8765, token: '123456');
      final j = jsonDecode(jsonEncode(offer.toJson())) as Map<String, dynamic>;
      final parsed = DiscoveryOffer.tryParse(j)!;
      expect(parsed.ip, '192.168.1.5');
      expect(parsed.wsPort, 8765);
      expect(parsed.token, '123456');
      expect(j['app'], 'screact');
      expect(j['messageType'], 'discovery_offer');
    });

    test('response の round trip', () {
      const res = DiscoveryResponse(
          deviceId: 'android-abc', deviceName: 'Pixel 7', model: 'Pixel 7');
      final j = jsonDecode(jsonEncode(res.toJson())) as Map<String, dynamic>;
      final parsed = DiscoveryResponse.tryParse(j)!;
      expect(parsed.deviceId, 'android-abc');
      expect(parsed.deviceName, 'Pixel 7');
    });

    test('select の round trip（selected:true 必須）', () {
      const sel = DiscoverySelect(
          deviceId: 'android-abc', ip: '10.0.0.2', wsPort: 8765, token: '654321');
      final j = jsonDecode(jsonEncode(sel.toJson())) as Map<String, dynamic>;
      expect(j['selected'], isTrue);
      final parsed = DiscoverySelect.tryParse(j)!;
      expect(parsed.deviceId, 'android-abc');
      expect(parsed.token, '654321');
      // selected=false は不許可
      expect(DiscoverySelect.tryParse({...j, 'selected': false}), isNull);
    });

    test('他アプリのJSON・壊れたデータは無視する', () {
      expect(decodeDiscoveryDatagram(utf8.encode('{"app":"other"}')), isNull);
      expect(decodeDiscoveryDatagram(utf8.encode('not json')), isNull);
      expect(decodeDiscoveryDatagram(utf8.encode('[1,2]')), isNull);
      expect(
        DiscoveryOffer.tryParse(
            {'app': 'screact', 'messageType': 'discovery_response'}),
        isNull,
      );
      // 必須フィールド欠落
      expect(
        DiscoveryOffer.tryParse(
            {'app': 'screact', 'messageType': 'discovery_offer'}),
        isNull,
      );
    });

    test('subnetBroadcastOf は /24 のブロードキャストを作る', () {
      expect(subnetBroadcastOf('192.168.1.23'), '192.168.1.255');
      expect(subnetBroadcastOf(null), isNull);
      expect(subnetBroadcastOf('bad'), isNull);
    });
  });

  group('DesktopDiscovery（loopback実ソケット往復）', () {
    /// テスト用のAndroid応答シミュレータ。1ソケットで複数deviceIdを演じられる。
    Future<(RawDatagramSocket, List<Map<String, dynamic>>)> startResponder(
        List<String> deviceIds) async {
      final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = <Map<String, dynamic>>[];
      sock.listen((e) {
        if (e != RawSocketEvent.read) return;
        final dg = sock.receive();
        if (dg == null) return;
        final j = decodeDiscoveryDatagram(dg.data);
        if (j == null) return;
        received.add(j);
        if (DiscoveryOffer.tryParse(j) != null) {
          for (final id in deviceIds) {
            final res = DiscoveryResponse(
                deviceId: id, deviceName: 'name-$id', model: 'model-$id');
            sock.send(
                utf8.encode(jsonEncode(res.toJson())), dg.address, dg.port);
          }
        }
      });
      return (sock, received);
    }

    Future<void> waitUntil(bool Function() cond,
        {Duration timeout = const Duration(seconds: 5)}) async {
      final sw = Stopwatch()..start();
      while (!cond()) {
        if (sw.elapsed > timeout) fail('条件が時間内に満たされませんでした');
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    test('offer に応答した端末が devices に集約される（2台・重複排除）', () async {
      final (responder, _) = await startResponder(['dev-a', 'dev-b']);
      final discovery = DesktopDiscovery(
        token: '111111',
        wsPort: 8765,
        discoveryPort: responder.port,
        broadcastAddresses: ['127.0.0.1'],
        offerInterval: const Duration(milliseconds: 100),
      );
      await discovery.start();
      await waitUntil(() => discovery.devices.length == 2);
      // offer が繰り返されても deviceId で重複排除される
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(discovery.devices.length, 2);
      expect(discovery.devices.map((d) => d.deviceId), containsAll(['dev-a', 'dev-b']));
      expect(discovery.devices.first.deviceName, startsWith('name-'));
      discovery.stop();
      responder.close();
    });

    test('select は選んだ端末のアドレスへユニキャストされ token を含む', () async {
      final (responder, received) = await startResponder(['dev-a']);
      final discovery = DesktopDiscovery(
        token: '222222',
        wsPort: 9999,
        discoveryPort: responder.port,
        broadcastAddresses: ['127.0.0.1'],
        offerInterval: const Duration(milliseconds: 100),
      );
      await discovery.start();
      await waitUntil(() => discovery.devices.length == 1);
      discovery.select(discovery.devices.first);
      await waitUntil(() => received
          .any((j) => DiscoverySelect.tryParse(j)?.deviceId == 'dev-a'));
      final sel = received
          .map(DiscoverySelect.tryParse)
          .whereType<DiscoverySelect>()
          .first;
      expect(sel.token, '222222');
      expect(sel.wsPort, 9999);
      discovery.stop();
      responder.close();
    });

    test('応答が無ければ devices は空のまま', () async {
      // 開いていないポート宛てに送る（応答者なし）
      final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = probe.port;
      probe.close();
      final discovery = DesktopDiscovery(
        token: '333333',
        wsPort: 8765,
        discoveryPort: freePort,
        broadcastAddresses: ['127.0.0.1'],
        offerInterval: const Duration(milliseconds: 80),
      );
      await discovery.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(discovery.devices, isEmpty);
      discovery.stop();
    });
  });
}
