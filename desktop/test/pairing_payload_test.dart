import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/net/pairing_payload.dart';

void main() {
  group('PairingPayload.toUri', () {
    test('LAN 直結のみ（relay/room 省略）', () {
      const p = PairingPayload(
        pairingToken: '123456',
        lanHost: '192.168.1.23',
        lanPort: 8765,
      );
      final uri = p.toUri();
      expect(uri, startsWith('screact://pair?'));
      final parsed = Uri.parse(uri).queryParameters;
      expect(parsed['v'], '1');
      expect(parsed['t'], '123456');
      expect(parsed['host'], '192.168.1.23');
      expect(parsed['port'], '8765');
      expect(parsed.containsKey('relay'), isFalse);
      expect(parsed.containsKey('room'), isFalse);
    });

    test('LAN + リレーの両方を載せ、relay の wss:// が安全にエンコードされる', () {
      const p = PairingPayload(
        pairingToken: '654321',
        lanHost: '10.0.0.5',
        lanPort: 8765,
        relayUrl: 'wss://relay.example/ws',
        relayRoom: 'K7QP-3F',
      );
      final uri = p.toUri();
      // 生の "://" は query に出さない（エンコードされる）。
      expect(uri.contains('relay=wss://'), isFalse);
      final parsed = Uri.parse(uri).queryParameters;
      expect(parsed['relay'], 'wss://relay.example/ws');
      expect(parsed['room'], 'K7QP-3F');
    });

    test('exp は UNIX 秒で載る', () {
      final p = PairingPayload(
        pairingToken: '111111',
        lanHost: '1.2.3.4',
        lanPort: 8765,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(1723550400 * 1000,
            isUtc: true),
      );
      final parsed = Uri.parse(p.toUri()).queryParameters;
      expect(parsed['exp'], '1723550400');
    });
  });

  group('PairingPayload round-trip (toUri -> tryParse)', () {
    test('LAN のみ', () {
      const p = PairingPayload(
        pairingToken: '246810',
        lanHost: '192.168.0.42',
        lanPort: 8765,
      );
      final back = PairingPayload.tryParse(p.toUri())!;
      expect(back.pairingToken, '246810');
      expect(back.lanHost, '192.168.0.42');
      expect(back.lanPort, 8765);
      expect(back.hasLanDirect, isTrue);
      expect(back.hasRelay, isFalse);
      expect(back.lanWebSocketUrl(), 'ws://192.168.0.42:8765/ws/v1/input');
    });

    test('LAN + リレー', () {
      const p = PairingPayload(
        pairingToken: '135790',
        lanHost: '172.16.5.9',
        lanPort: 9000,
        relayUrl: 'wss://relay.example/ws',
        relayRoom: 'AB12-CD',
      );
      final back = PairingPayload.tryParse(p.toUri())!;
      expect(back.hasLanDirect, isTrue);
      expect(back.hasRelay, isTrue);
      expect(back.relayUrl, 'wss://relay.example/ws');
      expect(back.relayRoom, 'AB12-CD');
    });

    test('リレーのみ（LAN 情報なし）', () {
      const p = PairingPayload(
        pairingToken: '999999',
        relayUrl: 'wss://relay.example/ws',
        relayRoom: 'ROOM-1',
      );
      final back = PairingPayload.tryParse(p.toUri())!;
      expect(back.hasLanDirect, isFalse);
      expect(back.hasRelay, isTrue);
      expect(back.lanWebSocketUrl(), isNull);
    });
  });

  group('PairingPayload.tryParse rejects', () {
    test('スキーム違い', () {
      expect(
        PairingPayload.tryParse('https://pair?v=1&t=123456&host=1.2.3.4&port=8765'),
        isNull,
      );
    });

    test('authority 違い', () {
      expect(
        PairingPayload.tryParse('screact://connect?v=1&t=123456&host=1.2.3.4&port=8765'),
        isNull,
      );
    });

    test('未知版数', () {
      expect(
        PairingPayload.tryParse('screact://pair?v=2&t=123456&host=1.2.3.4&port=8765'),
        isNull,
      );
    });

    test('版数欠落', () {
      expect(
        PairingPayload.tryParse('screact://pair?t=123456&host=1.2.3.4&port=8765'),
        isNull,
      );
    });

    test('トークン不正（6桁でない）', () {
      expect(
        PairingPayload.tryParse('screact://pair?v=1&t=12345&host=1.2.3.4&port=8765'),
        isNull,
      );
      expect(
        PairingPayload.tryParse('screact://pair?v=1&t=abcdef&host=1.2.3.4&port=8765'),
        isNull,
      );
    });

    test('host あり port なし（不整合）', () {
      expect(
        PairingPayload.tryParse('screact://pair?v=1&t=123456&host=1.2.3.4'),
        isNull,
      );
    });

    test('port 範囲外', () {
      expect(
        PairingPayload.tryParse('screact://pair?v=1&t=123456&host=1.2.3.4&port=70000'),
        isNull,
      );
    });

    test('relay あり room なし（不整合）', () {
      expect(
        PairingPayload.tryParse('screact://pair?v=1&t=123456&relay=wss%3A%2F%2Fr%2Fws'),
        isNull,
      );
    });

    test('LAN もリレーも無い（接続先不明）', () {
      expect(PairingPayload.tryParse('screact://pair?v=1&t=123456'), isNull);
    });

    test('壊れた文字列', () {
      expect(PairingPayload.tryParse('not a uri at all'), isNull);
      expect(PairingPayload.tryParse(''), isNull);
    });
  });

  group('PairingPayload.isExpired', () {
    final base = DateTime.fromMillisecondsSinceEpoch(1000 * 1000, isUtc: true);

    test('exp 未設定なら常に false', () {
      const p = PairingPayload(
        pairingToken: '123456',
        lanHost: '1.2.3.4',
        lanPort: 8765,
      );
      expect(p.isExpired(base), isFalse);
    });

    test('exp より前は有効・以降は失効（境界含む）', () {
      final p = PairingPayload(
        pairingToken: '123456',
        lanHost: '1.2.3.4',
        lanPort: 8765,
        expiresAt: base,
      );
      expect(
        p.isExpired(base.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(p.isExpired(base), isTrue); // 境界＝失効
      expect(p.isExpired(base.add(const Duration(seconds: 1))), isTrue);
    });
  });
}
