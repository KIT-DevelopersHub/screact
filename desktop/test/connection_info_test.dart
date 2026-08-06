import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/net/input_server.dart';
import 'package:thehack_overlay/net/wifi_ip.dart';

void main() {
  group('pickWifiIp（Wi-Fi IPの選択）', () {
    test('en0 を最優先で選ぶ（utunが先に並んでいても）', () {
      final ip = pickWifiIp(const [
        InterfaceAddrs('utun0', ['100.64.0.1']),
        InterfaceAddrs('utun4', ['198.18.0.1']),
        InterfaceAddrs('en0', ['172.20.10.4']),
        InterfaceAddrs('en5', ['192.168.5.2']),
      ]);
      expect(ip, '172.20.10.4');
    });

    test('en0 が無ければ番号の小さい en 系へフォールバック', () {
      final ip = pickWifiIp(const [
        InterfaceAddrs('utun1', ['100.64.0.2']),
        InterfaceAddrs('en8', ['10.0.1.8']),
        InterfaceAddrs('en1', ['10.0.1.1']),
      ]);
      expect(ip, '10.0.1.1');
    });

    test('en 系が無ければ仮想IF以外を選ぶ', () {
      final ip = pickWifiIp(const [
        InterfaceAddrs('utun0', ['100.64.0.1']),
        InterfaceAddrs('bridge0', ['192.168.64.1']),
        InterfaceAddrs('eth0', ['10.1.2.3']),
      ]);
      expect(ip, '10.1.2.3');
    });

    test('IPv4を持つIFが無ければ null', () {
      expect(pickWifiIp(const [InterfaceAddrs('en0', [])]), isNull);
      expect(pickWifiIp(const []), isNull);
    });

    test('仮想IFしか無ければ null（誤ったIPを表示しない）', () {
      expect(
        pickWifiIp(const [
          InterfaceAddrs('utun3', ['100.64.0.9']),
          InterfaceAddrs('awdl0', ['169.254.1.1']),
        ]),
        isNull,
      );
    });
  });

  group('6桁コード', () {
    test('generatePairingCode は6桁の数字', () {
      for (var i = 0; i < 20; i++) {
        final c = InputServer.generatePairingCode();
        expect(RegExp(r'^\d{6}$').hasMatch(c), isTrue, reason: c);
      }
    });
  });

  group('6桁コード照合（実サーバE2E）', () {
    Future<InputServer> startServer({
      required String? code,
      bool enforce = true,
      void Function(ServerStatus)? onStatus,
    }) async {
      final server = InputServer(
        engine: InteractionEngine(),
        port: 0,
        onEvents: (_) {},
        onStatus: onStatus ?? (_) {},
        pairingCode: code,
        enforcePairing: enforce,
      );
      await server.start();
      addTearDown(server.stop);
      return server;
    }

    Future<(WebSocket, Stream<Map<String, dynamic>>)> connect(
        InputServer server) async {
      final ws = await WebSocket.connect(
          'ws://localhost:${server.boundPort}/ws/v1/input');
      final msgs = ws
          .map((d) => (jsonDecode(d as String) as Map).cast<String, dynamic>())
          .asBroadcastStream();
      return (ws, msgs);
    }

    Map<String, dynamic> hello(String? token) => {
          'schemaVersion': 1,
          'messageType': 'hello',
          'deviceId': 'pairing-test',
          if (token != null) 'pairingToken': token,
        };

    test('一致するコードなら hello_ack が返る', () async {
      final server = await startServer(code: '123456');
      final (ws, msgs) = await connect(server);
      addTearDown(ws.close);
      final ack = msgs.firstWhere((m) => m['messageType'] == 'hello_ack');
      ws.add(jsonEncode(hello('123456')));
      final m = await ack.timeout(const Duration(seconds: 5));
      expect(m['sessionId'], isNotNull);
    });

    test('不一致は hello_error(pairing_code_mismatch) で拒否・切断される', () async {
      String? lastError;
      final server = await startServer(
          code: '123456', onStatus: (st) => lastError = st.lastError ?? lastError);
      final (ws, msgs) = await connect(server);
      final events = <Map<String, dynamic>>[];
      final done = Completer<void>();
      msgs.listen(events.add, onDone: done.complete);
      ws.add(jsonEncode(hello('000000')));
      await done.future.timeout(const Duration(seconds: 5)); // サーバ側から切断
      expect(events, hasLength(1));
      expect(events.single['messageType'], 'hello_error');
      expect(events.single['code'], 'pairing_code_mismatch');
      expect(events.single['retryable'], isFalse);
      expect(lastError, contains('コード不一致'));
    });

    test('コード無し(hello に pairingToken 無し)も不一致として拒否', () async {
      final server = await startServer(code: '123456');
      final (ws, msgs) = await connect(server);
      final err = msgs.firstWhere((m) => m['messageType'] == 'hello_error');
      ws.add(jsonEncode(hello(null)));
      final m = await err.timeout(const Duration(seconds: 5));
      expect(m['code'], 'pairing_code_mismatch');
    });

    test('照合オフなら不一致でも hello_ack が返る', () async {
      final server = await startServer(code: '123456', enforce: false);
      final (ws, msgs) = await connect(server);
      addTearDown(ws.close);
      final ack = msgs.firstWhere((m) => m['messageType'] == 'hello_ack');
      ws.add(jsonEncode(hello('999999')));
      final m = await ack.timeout(const Duration(seconds: 5));
      expect(m['messageType'], 'hello_ack');
    });

    test('稼働中に enforcePairing を切り替えられる', () async {
      final server = await startServer(code: '123456');
      server.enforcePairing = false; // UIトグル相当
      final (ws, msgs) = await connect(server);
      addTearDown(ws.close);
      final ack = msgs.firstWhere((m) => m['messageType'] == 'hello_ack');
      ws.add(jsonEncode(hello('999999')));
      await ack.timeout(const Duration(seconds: 5));
    });
  });
}
