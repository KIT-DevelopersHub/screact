import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/net/discovery.dart';

/// UDP発見プロトコルの単体テスト（JSONコーデック）と、loopback 実ソケットでの
/// offer→response→select 往復テスト。
void main() {
  group('発見メッセージのJSONコーデック', () {
    test('offer の round trip', () {
      const offer = DiscoveryOffer(
        ip: '192.168.1.5',
        wsPort: 8765,
        token: '123456',
      );
      final j = jsonDecode(jsonEncode(offer.toJson())) as Map<String, dynamic>;
      final parsed = DiscoveryOffer.tryParse(j)!;
      expect(parsed.ip, '192.168.1.5');
      expect(parsed.wsPort, 8765);
      expect(parsed.token, '123456');
      expect(j['app'], 'screact');
      expect(j['messageType'], 'discovery_offer');
    });

    test('schemaVersion が不一致または欠落したメッセージは拒否する', () {
      final messages = <Map<String, dynamic>>[
        const DiscoveryOffer(wsPort: 8765, token: '123456').toJson(),
        const DiscoveryResponse(
          deviceId: 'android-abc',
          deviceName: 'Pixel 7',
          model: 'Pixel 7',
        ).toJson(),
        const DiscoverySelect(
          deviceId: 'android-abc',
          wsPort: 8765,
          token: '123456',
        ).toJson(),
        const DiscoverySelectAck(deviceId: 'android-abc').toJson(),
      ];

      Object? parse(Map<String, dynamic> message) =>
          DiscoveryOffer.tryParse(message) ??
          DiscoveryResponse.tryParse(message) ??
          DiscoverySelect.tryParse(message) ??
          DiscoverySelectAck.tryParse(message);

      for (final message in messages) {
        expect(parse({...message, 'schemaVersion': 2}), isNull);
        final withoutSchema = Map<String, dynamic>.from(message)
          ..remove('schemaVersion');
        expect(parse(withoutSchema), isNull);
      }
    });

    test('offer/select は範囲外portと6桁数字でないtokenを拒否する', () {
      final offer =
          const DiscoveryOffer(wsPort: 8765, token: '123456').toJson();
      final select =
          const DiscoverySelect(
            deviceId: 'android-abc',
            wsPort: 8765,
            token: '123456',
          ).toJson();

      for (final invalidPort in [-1, 0, 65536]) {
        expect(
          DiscoveryOffer.tryParse({...offer, 'wsPort': invalidPort}),
          isNull,
        );
        expect(
          DiscoverySelect.tryParse({...select, 'wsPort': invalidPort}),
          isNull,
        );
      }
      for (final invalidToken in ['', '12345', '1234567', 'abcdef', '１２３４５６']) {
        expect(
          DiscoveryOffer.tryParse({...offer, 'token': invalidToken}),
          isNull,
        );
        expect(
          DiscoverySelect.tryParse({...select, 'token': invalidToken}),
          isNull,
        );
      }
    });

    test('response の round trip', () {
      const res = DiscoveryResponse(
        deviceId: 'android-abc',
        deviceName: 'Pixel 7',
        model: 'Pixel 7',
      );
      final j = jsonDecode(jsonEncode(res.toJson())) as Map<String, dynamic>;
      final parsed = DiscoveryResponse.tryParse(j)!;
      expect(parsed.deviceId, 'android-abc');
      expect(parsed.deviceName, 'Pixel 7');
    });

    test('select の round trip（selected:true 必須）', () {
      const sel = DiscoverySelect(
        deviceId: 'android-abc',
        ip: '10.0.0.2',
        wsPort: 8765,
        token: '654321',
      );
      final j = jsonDecode(jsonEncode(sel.toJson())) as Map<String, dynamic>;
      expect(j['selected'], isTrue);
      final parsed = DiscoverySelect.tryParse(j)!;
      expect(parsed.deviceId, 'android-abc');
      expect(parsed.token, '654321');
      // selected=false は不許可
      expect(DiscoverySelect.tryParse({...j, 'selected': false}), isNull);
    });

    test('select_ack の round trip（Android側と同じフィールド構成）', () {
      const ack = DiscoverySelectAck(deviceId: 'android-abc');
      final j = jsonDecode(jsonEncode(ack.toJson())) as Map<String, dynamic>;
      expect(j['app'], 'screact');
      expect(j['messageType'], 'discovery_select_ack');
      expect(DiscoverySelectAck.tryParse(j)!.deviceId, 'android-abc');
      // Android(kotlinx.serialization)がencodeDefaultsで出す形をそのまま受ける
      final kotlinShape =
          jsonDecode(
                '{"app":"screact","schemaVersion":1,'
                '"messageType":"discovery_select_ack","deviceId":"android-abc"}',
              )
              as Map<String, dynamic>;
      expect(DiscoverySelectAck.tryParse(kotlinShape)!.deviceId, 'android-abc');
      // deviceId 欠落は不許可
      expect(
        DiscoverySelectAck.tryParse({
          'app': 'screact',
          'messageType': 'discovery_select_ack',
        }),
        isNull,
      );
    });

    test('他アプリのJSON・壊れたデータは無視する', () {
      expect(decodeDiscoveryDatagram(utf8.encode('{"app":"other"}')), isNull);
      expect(decodeDiscoveryDatagram(utf8.encode('not json')), isNull);
      expect(decodeDiscoveryDatagram(utf8.encode('[1,2]')), isNull);
      expect(
        DiscoveryOffer.tryParse({
          'app': 'screact',
          'messageType': 'discovery_response',
        }),
        isNull,
      );
      // 必須フィールド欠落
      expect(
        DiscoveryOffer.tryParse({
          'app': 'screact',
          'messageType': 'discovery_offer',
        }),
        isNull,
      );
    });

    test('subnetBroadcastOf は /24 のブロードキャストを作る', () {
      expect(subnetBroadcastOf('192.168.1.23'), '192.168.1.255');
      expect(subnetBroadcastOf(null), isNull);
      expect(subnetBroadcastOf('bad'), isNull);
    });

    test('ln_probe（権限トリガ）は既存パーサに無視され例外も出さない', () async {
      // 受け側: probe が届いても発見メッセージとしては解釈されない
      final sock = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final parsed = <Object?>[];
      sock.listen((e) {
        if (e != RawSocketEvent.read) return;
        final dg = sock.receive();
        if (dg == null) return;
        final j = decodeDiscoveryDatagram(dg.data);
        if (j == null) return;
        parsed.add(
          DiscoveryOffer.tryParse(j) ??
              DiscoveryResponse.tryParse(j) ??
              DiscoverySelect.tryParse(j) ??
              DiscoverySelectAck.tryParse(j),
        );
      });
      final logs = <String>[];
      await triggerLocalNetworkPrompt(
        port: sock.port,
        targets: ['127.0.0.1'],
        onLog: logs.add,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(parsed.whereType<Object>(), isEmpty); // 全パーサでnull＝無視
      expect(logs, isNotEmpty);
      sock.close();
    });
  });

  group('DesktopDiscovery（loopback実ソケット往復）', () {
    test('IF列挙中に停止してもsocketとofferタイマーが復活しない', () async {
      final providerStarted = Completer<void>();
      final providerResult = Completer<List<String>>();
      var logCount = 0;
      final discovery = DesktopDiscovery(
        token: '123456',
        wsPort: 8765,
        subnetBroadcastsProvider: () {
          providerStarted.complete();
          return providerResult.future;
        },
        onLog: (_) => logCount++,
      );

      final starting = discovery.start();
      await providerStarted.future;
      discovery.stop();
      providerResult.complete(const ['192.168.1.255']);
      await starting;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(discovery.running, isFalse);
      expect(logCount, 0);
      discovery.dispose();
    });

    /// テスト用のAndroid応答シミュレータ。1ソケットで複数deviceIdを演じられる。
    Future<(RawDatagramSocket, List<Map<String, dynamic>>)> startResponder(
      List<String> deviceIds,
    ) async {
      final sock = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
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
              deviceId: id,
              deviceName: 'name-$id',
              model: 'model-$id',
            );
            sock.send(
              utf8.encode(jsonEncode(res.toJson())),
              dg.address,
              dg.port,
            );
          }
        }
      });
      return (sock, received);
    }

    Future<void> waitUntil(
      bool Function() cond, {
      Duration timeout = const Duration(seconds: 5),
    }) async {
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
      expect(
        discovery.devices.map((d) => d.deviceId),
        containsAll(['dev-a', 'dev-b']),
      );
      expect(discovery.devices.first.deviceName, startsWith('name-'));
      discovery.stop();
      responder.close();
    });

    test('start待機中のstop→start競合で古いbindが新しい世代を上書きしない', () async {
      final (responder, received) = await startResponder(['dev-restarted']);
      final discovery = DesktopDiscovery(
        token: '777777',
        wsPort: 8765,
        discoveryPort: responder.port,
        broadcastAddresses: ['127.0.0.1'],
        offerInterval: const Duration(milliseconds: 80),
      );

      // 1回目のbind完了を待たずに停止し、直ちに新しい世代を開始する。
      // 古いstartが遅れて完了しても、新しいsocketを閉じたり上書きしたりしない。
      final staleStart = discovery.start();
      discovery.stop();
      final currentStart = discovery.start();
      await Future.wait([staleStart, currentStart]);

      await waitUntil(
        () => received.any((j) => DiscoveryOffer.tryParse(j) != null),
      );
      await waitUntil(
        () => discovery.devices.any((d) => d.deviceId == 'dev-restarted'),
      );
      expect(discovery.running, isTrue);

      discovery.stop();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(discovery.running, isFalse);
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
      await waitUntil(
        () => received.any(
          (j) => DiscoverySelect.tryParse(j)?.deviceId == 'dev-a',
        ),
      );
      final sel =
          received
              .map(DiscoverySelect.tryParse)
              .whereType<DiscoverySelect>()
              .first;
      expect(sel.token, '222222');
      expect(sel.wsPort, 9999);
      discovery.stop();
      responder.close();
    });

    test('select は ACK を受信するまで再送し、ACK で再送が止まる', () async {
      // 3回目の select で初めて ACK を返す応答者（1〜2回目のロストを模擬）。
      const ackAfter = 3;
      var selectCount = 0;
      final received = <Map<String, dynamic>>[];
      final sock = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      sock.listen((e) {
        if (e != RawSocketEvent.read) return;
        final dg = sock.receive();
        if (dg == null) return;
        final j = decodeDiscoveryDatagram(dg.data);
        if (j == null) return;
        received.add(j);
        if (DiscoveryOffer.tryParse(j) != null) {
          sock.send(
            utf8.encode(
              jsonEncode(
                const DiscoveryResponse(
                  deviceId: 'dev-a',
                  deviceName: 'name-a',
                  model: 'm',
                ).toJson(),
              ),
            ),
            dg.address,
            dg.port,
          );
        }
        final sel = DiscoverySelect.tryParse(j);
        if (sel != null) {
          selectCount++;
          // 併送(ユニキャスト+ブロードキャスト)で1試行=2受信になるため、
          // ackAfter試行分(=2*ackAfter受信)を無視してからACKを返す。
          if (selectCount > ackAfter * 2) {
            sock.send(
              utf8.encode(
                jsonEncode(DiscoverySelectAck(deviceId: sel.deviceId).toJson()),
              ),
              dg.address,
              dg.port,
            );
          }
        }
      });
      final discovery = DesktopDiscovery(
        token: '444444',
        wsPort: 8765,
        discoveryPort: sock.port,
        broadcastAddresses: ['127.0.0.1'],
        offerInterval: const Duration(milliseconds: 80),
        selectResendInterval: const Duration(milliseconds: 40),
        selectMaxAttempts: 30,
      );
      await discovery.start();
      await waitUntil(() => discovery.devices.length == 1);
      discovery.select(discovery.devices.first);
      await waitUntil(() => discovery.selectAcked);
      // 最初のackAfter試行分はACKされず再送している
      expect(discovery.selectAttempts, greaterThan(ackAfter));
      // ACK 後は再送が止まる（回数が増えない）。
      final attemptsAtAck = discovery.selectAttempts;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(discovery.selectAttempts, attemptsAtAck);
      expect(discovery.selectAttempts, lessThan(30));
      expect(discovery.selectGaveUp, isFalse);
      discovery.stop();
      sock.close();
    });

    test('ユニキャストが届かなくても select はブロードキャスト併送で到達し ACK される', () async {
      // 実機で確認した事象の再現: macOSのローカルネットワーク権限拒否等で
      // 「応答の送信元へのユニキャスト」だけが落ちる環境でも、offerと同じ
      // ブロードキャスト経路(127.0.0.1:discoveryPort)で select が届くこと。
      final listenSock = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      ); // B
      final replySock = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      ); // A
      final selectsAtListen = <DiscoverySelect>[];
      listenSock.listen((e) {
        if (e != RawSocketEvent.read) return;
        final dg = listenSock.receive();
        if (dg == null) return;
        final j = decodeDiscoveryDatagram(dg.data);
        if (j == null) return;
        if (DiscoveryOffer.tryParse(j) != null) {
          // 別ソケットAから応答 → desktopはdevice.port=Aのポートを記録する
          // （A閉鎖後に遅延配送されたofferが来ても無視する）
          try {
            replySock.send(
              utf8.encode(
                jsonEncode(
                  const DiscoveryResponse(
                    deviceId: 'dev-bc',
                    deviceName: 'name-bc',
                    model: 'm',
                  ).toJson(),
                ),
              ),
              dg.address,
              dg.port,
            );
          } catch (_) {}
        }
        final sel = DiscoverySelect.tryParse(j);
        if (sel != null && sel.deviceId == 'dev-bc') {
          selectsAtListen.add(sel);
          listenSock.send(
            utf8.encode(
              jsonEncode(const DiscoverySelectAck(deviceId: 'dev-bc').toJson()),
            ),
            dg.address,
            dg.port,
          );
        }
      });
      final discovery = DesktopDiscovery(
        token: '666666',
        wsPort: 8765,
        discoveryPort: listenSock.port,
        broadcastAddresses: ['127.0.0.1'],
        offerInterval: const Duration(milliseconds: 80),
        selectResendInterval: const Duration(milliseconds: 50),
      );
      await discovery.start();
      await waitUntil(() => discovery.devices.length == 1);
      final device = discovery.devices.first;
      expect(device.port, replySock.port); // ユニキャスト宛先はAのポート
      replySock.close(); // ユニキャスト経路を殺す（届かない環境の再現）
      discovery.select(device);
      // ブロードキャスト経路(listenSock)にselectが届き、ACKで再送が止まる
      await waitUntil(() => discovery.selectAcked);
      expect(selectsAtListen, isNotEmpty);
      expect(discovery.selectGaveUp, isFalse);
      discovery.stop();
      listenSock.close();
    });

    test('ACK が無ければ最大回数まで再送して打ち切る', () async {
      final (responder, received) = await startResponder(['dev-a']);
      final discovery = DesktopDiscovery(
        token: '555555',
        wsPort: 8765,
        discoveryPort: responder.port,
        broadcastAddresses: ['127.0.0.1'],
        offerInterval: const Duration(milliseconds: 80),
        selectResendInterval: const Duration(milliseconds: 30),
        selectMaxAttempts: 4,
      );
      await discovery.start();
      await waitUntil(() => discovery.devices.length == 1);
      discovery.select(discovery.devices.first);
      // 打ち切り（最大4回）まで待つ。
      await waitUntil(() => discovery.selectAttempts >= 4);
      await waitUntil(() => discovery.selectGaveUp);
      expect(discovery.selectAttempts, 4);
      expect(discovery.selectAcked, isFalse);
      // 併送のため1試行=2受信（ユニキャスト+ブロードキャスト・宛先は同一）
      final selects =
          received
              .map(DiscoverySelect.tryParse)
              .whereType<DiscoverySelect>()
              .length;
      expect(selects, greaterThanOrEqualTo(4));
      discovery.stop();
      responder.close();
    });

    test('応答が無ければ devices は空のまま', () async {
      // 開いていないポート宛てに送る（応答者なし）
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
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
