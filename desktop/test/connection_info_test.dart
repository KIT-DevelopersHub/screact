import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
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

    test('Windowsでは仮想EthernetよりWi-Fiを優先する', () {
      final ip = pickWifiIp(const [
        InterfaceAddrs('イーサネット 7', ['192.168.204.1']),
        InterfaceAddrs('イーサネット 10', ['192.168.56.1']),
        InterfaceAddrs('Wi-Fi', ['172.20.10.3']),
      ]);
      expect(ip, '172.20.10.3');
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

  group('directedBroadcastsOf（UDP offerの併送先）', () {
    test('物理IFの/24宛先を重複排除し、仮想IFと不正IPv4を除外する', () {
      expect(
        directedBroadcastsOf(const [
          InterfaceAddrs('Wi-Fi', ['192.168.10.42']),
          InterfaceAddrs('Ethernet', ['10.2.3.4', '192.168.10.5']),
          InterfaceAddrs('VirtualBox Host-Only Network', ['192.168.56.1']),
          InterfaceAddrs('utun4', ['100.64.0.1']),
          InterfaceAddrs('Ethernet 2', ['999.1.2.3', 'not-an-ip']),
        ]),
        ['192.168.10.255', '10.2.3.255'],
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
      Duration helloTimeout = const Duration(seconds: 5),
      Duration inactivityTimeout = const Duration(seconds: 12),
      void Function(ServerStatus)? onStatus,
    }) async {
      final server = InputServer(
        engine: MultiHandEngine(),
        port: 0,
        onEvents: (_) {},
        onStatus: onStatus ?? (_) {},
        pairingCode: code,
        enforcePairing: enforce,
        helloTimeout: helloTimeout,
        inactivityTimeout: inactivityTimeout,
      );
      await server.start();
      addTearDown(server.stop);
      return server;
    }

    Future<(WebSocket, Stream<Map<String, dynamic>>)> connect(
      InputServer server,
    ) async {
      final ws = await WebSocket.connect(
        'ws://localhost:${server.boundPort}/ws/v1/input',
      );
      final msgs =
          ws
              .map(
                (d) => (jsonDecode(d as String) as Map).cast<String, dynamic>(),
              )
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
        code: '123456',
        onStatus: (st) => lastError = st.lastError ?? lastError,
      );
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

    test('後着ソケットは server_busy で拒否され、先着セッションは維持される', () async {
      ServerStatus latest = const ServerStatus();
      final server = await startServer(
        code: '123456',
        onStatus: (status) => latest = status,
      );
      final (first, firstMessages) = await connect(server);
      addTearDown(first.close);
      final firstAck = firstMessages.firstWhere(
        (m) => m['messageType'] == 'hello_ack',
      );
      first.add(jsonEncode(hello('123456')));
      final ack = await firstAck.timeout(const Duration(seconds: 5));
      final firstSession = ack['sessionId'];
      expect(latest.clientId, 'pairing-test');

      final (late, lateMessages) = await connect(server);
      final lateEvents = <Map<String, dynamic>>[];
      final lateDone = Completer<void>();
      lateMessages.listen(lateEvents.add, onDone: lateDone.complete);
      await lateDone.future.timeout(const Duration(seconds: 5));

      expect(lateEvents, hasLength(1));
      expect(lateEvents.single['messageType'], 'hello_error');
      expect(lateEvents.single['code'], 'server_busy');
      expect(lateEvents.single['retryable'], isTrue);
      expect(latest.clientId, 'pairing-test');
      expect(latest.sessionId, firstSession);

      // 拒否側のonDone後も、現行ソケットへの送信が生きていることを確認する。
      final control = firstMessages.firstWhere(
        (m) => m['messageType'] == 'control_message',
      );
      server.requestMode('tracking');
      expect(
        (await control.timeout(const Duration(seconds: 5)))['mode'],
        'tracking',
      );
    });

    test('helloを送らない接続はtimeout後に枠を解放する', () async {
      final server = await startServer(
        code: '123456',
        helloTimeout: const Duration(milliseconds: 80),
      );
      final (stalled, stalledMessages) = await connect(server);
      addTearDown(stalled.close);
      final timeoutError = stalledMessages.firstWhere(
        (message) => message['messageType'] == 'hello_error',
      );
      expect(
        (await timeoutError.timeout(const Duration(seconds: 5)))['code'],
        'hello_timeout',
      );

      final (next, nextMessages) = await connect(server);
      addTearDown(next.close);
      final ack = nextMessages.firstWhere(
        (message) => message['messageType'] == 'hello_ack',
      );
      next.add(jsonEncode(hello('123456')));
      expect(
        (await ack.timeout(const Duration(seconds: 5)))['sessionId'],
        isNotNull,
      );
    });

    test('heartbeatが途絶えた半開き接続を解放し次の接続を受理する', () async {
      ServerStatus latest = const ServerStatus();
      final server = await startServer(
        code: '123456',
        inactivityTimeout: const Duration(milliseconds: 120),
        onStatus: (status) => latest = status,
      );
      final (stale, staleMessages) = await connect(server);
      addTearDown(stale.close);
      final firstAck = staleMessages.firstWhere(
        (message) => message['messageType'] == 'hello_ack',
      );
      stale.add(jsonEncode(hello('123456')));
      await firstAck.timeout(const Duration(seconds: 5));
      expect(latest.sessionId, isNotNull);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (latest.sessionId != null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(latest.sessionId, isNull);

      final (next, nextMessages) = await connect(server);
      addTearDown(next.close);
      final nextAck = nextMessages.firstWhere(
        (message) => message['messageType'] == 'hello_ack',
      );
      next.add(jsonEncode(hello('123456')));
      expect(
        (await nextAck.timeout(const Duration(seconds: 5)))['sessionId'],
        isNotNull,
      );
    });

    test('heartbeat受信で半開き判定の期限を延長する', () async {
      ServerStatus latest = const ServerStatus();
      final server = await startServer(
        code: '123456',
        inactivityTimeout: const Duration(milliseconds: 250),
        onStatus: (status) => latest = status,
      );
      final (ws, messages) = await connect(server);
      addTearDown(ws.close);
      final ack = messages.firstWhere(
        (message) => message['messageType'] == 'hello_ack',
      );
      ws.add(jsonEncode(hello('123456')));
      await ack.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      ws.add(jsonEncode({'messageType': 'heartbeat'}));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(latest.sessionId, isNotNull);
    });

    test('拒否済み旧ソケットの遅延onDoneが新しいセッションを消さない', () async {
      ServerStatus latest = const ServerStatus();
      final server = await startServer(
        code: '123456',
        onStatus: (status) => latest = status,
      );

      final (rejected, rejectedMessages) = await connect(server);
      final rejection = rejectedMessages.firstWhere(
        (m) => m['messageType'] == 'hello_error',
      );
      rejected.add(jsonEncode(hello('000000')));
      expect(
        (await rejection.timeout(const Duration(seconds: 5)))['code'],
        'pairing_code_mismatch',
      );

      // サーバはclose完了前に旧枠を解放する。直ちに正常接続を確立することで、
      // 後から来る旧onDoneのidentity guardを回帰検証する。
      final (current, currentMessages) = await connect(server);
      addTearDown(current.close);
      final currentAck = currentMessages.firstWhere(
        (m) => m['messageType'] == 'hello_ack',
      );
      current.add(jsonEncode(hello('123456')));
      final session =
          (await currentAck.timeout(const Duration(seconds: 5)))['sessionId'];
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(latest.clientId, 'pairing-test');
      expect(latest.sessionId, session);
    });

    test('現行ソケットのcloseとserver stopでsession状態を確実に消す', () async {
      ServerStatus latest = const ServerStatus();
      final server = await startServer(
        code: '123456',
        onStatus: (status) => latest = status,
      );
      final (ws, messages) = await connect(server);
      final ack = messages.firstWhere((m) => m['messageType'] == 'hello_ack');
      ws.add(jsonEncode(hello('123456')));
      await ack.timeout(const Duration(seconds: 5));
      expect(latest.sessionId, isNotNull);

      await ws.close();
      final sw = Stopwatch()..start();
      while (latest.sessionId != null &&
          sw.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(latest.clientId, isNull);
      expect(latest.sessionId, isNull);

      await server.stop();
      expect(latest.listening, isFalse);
      expect(latest.clientId, isNull);
      expect(latest.sessionId, isNull);
    });

    test('LAN側IP宛でも接続できる（0.0.0.0バインドの回帰）', () async {
      final lanIp = await currentWifiIp();
      if (lanIp == null) return; // ネットワークが無い環境ではスキップ
      final server = await startServer(code: '123456');
      final ws = await WebSocket.connect(
        'ws://$lanIp:${server.boundPort}/ws/v1/input',
      );
      addTearDown(ws.close);
      final ack = ws
          .map((d) => (jsonDecode(d as String) as Map).cast<String, dynamic>())
          .firstWhere((m) => m['messageType'] == 'hello_ack');
      ws.add(jsonEncode(hello('123456')));
      await ack.timeout(const Duration(seconds: 5));
    });

    test('接続ログに段階（listen→request→upgrade→hello→hello_error）が残る', () async {
      final logs = <String>[];
      final server = InputServer(
        engine: MultiHandEngine(),
        port: 0,
        onEvents: (_) {},
        onStatus: (_) {},
        pairingCode: '123456',
        onLog: logs.add,
      );
      await server.start();
      addTearDown(server.stop);

      final ws = await WebSocket.connect(
        'ws://localhost:${server.boundPort}/ws/v1/input',
      );
      final done = Completer<void>();
      ws.listen((_) {}, onDone: done.complete);
      ws.add(jsonEncode(hello('999999')));
      await done.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      String stage(String kw) =>
          logs.firstWhere((l) => l.contains(kw), orElse: () => '');
      expect(stage('listen 開始'), contains('0.0.0.0'));
      expect(stage('6桁コード'), contains('123456'));
      expect(stage('http request'), contains('WS upgrade要求'));
      expect(stage('ws upgraded'), isNotEmpty);
      expect(stage('hello 受信'), contains('pairing-test'));
      expect(stage('hello_error'), contains('コード不一致'));
    });

    test('WS応答に Sec-WebSocket-Extensions を含めない（OkHttp互換・1010切断の回帰）', () async {
      // AndroidのOkHttpは permessage-deflate; client_max_window_bits を含む
      // 応答を拒否して closeCode=1010 で切断する（実機で発生）。
      // 生ソケットで圧縮拡張を提示し、応答ヘッダに拡張が無いことを確認する。
      final server = await startServer(code: '123456');
      final socket = await Socket.connect('localhost', server.boundPort!);
      addTearDown(socket.destroy);
      socket.write(
        'GET /ws/v1/input HTTP/1.1\r\n'
        'Host: localhost\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n'
        '\r\n',
      );
      final buf = StringBuffer();
      await for (final chunk in socket) {
        buf.write(String.fromCharCodes(chunk));
        if (buf.toString().contains('\r\n\r\n')) break;
      }
      final headers = buf.toString().toLowerCase();
      expect(headers, contains('101'));
      expect(headers, contains('upgrade'));
      expect(
        headers,
        isNot(contains('sec-websocket-extensions')),
        reason: '拡張応答があるとOkHttpが1010で切断する',
      );
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
