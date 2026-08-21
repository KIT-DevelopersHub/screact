/// Screact の QR / ディープリンク接続ペイロード `screact://pair?...` のコーデック。
/// 接続/認証 確定仕様 v1（docs/connection-auth-spec-v1.md の 4.2）に準拠する。
///
/// トランスポート非依存の設計：QR で運んでも UDP offer / 手入力でも、認証は
/// `hello` の `pairingToken`（6桁）1本のまま。このクラスは「接続情報の運び方」
/// だけを担い、新しい秘密を作らない。1個の URI に LAN 直結情報（host/port）と
/// リレー情報（relay/room）の両方を載せられ、スマホは LAN 直結を先に試して
/// ダメならリレーへ落ちる。
class PairingPayload {
  static const String scheme = 'screact';

  /// URI の authority（`screact://pair?...`）。
  static const String authority = 'pair';

  /// 現行ペイロード版数。未知版数の QR は受理しない。
  static const int currentVersion = 1;

  /// ペイロード版数（`v`）。
  final int version;

  /// 初回ペアリング認証コード（`t`・6桁）。`hello.pairingToken` にそのまま使う。
  final String pairingToken;

  /// LAN 直結時の PC の IP（`host`）。
  final String? lanHost;

  /// LAN 直結時の WebSocket ポート（`port`・既定 8765）。
  final int? lanPort;

  /// リレー可時の `wss://` エンドポイント（`relay`）。
  final String? relayUrl;

  /// リレー可時のルーム ID（`room`）。
  final String? relayRoom;

  /// QR の有効期限（`exp`・UNIX 秒）。過ぎたら PC は再生成・スマホは失効表示。
  final DateTime? expiresAt;

  const PairingPayload({
    this.version = currentVersion,
    required this.pairingToken,
    this.lanHost,
    this.lanPort,
    this.relayUrl,
    this.relayRoom,
    this.expiresAt,
  });

  /// LAN 直結の接続先が揃っているか（host と有効な port）。
  bool get hasLanDirect =>
      lanHost != null && lanHost!.isNotEmpty && _isValidPort(lanPort);

  /// リレー経由の接続先が揃っているか（relay と room）。
  bool get hasRelay =>
      relayUrl != null &&
      relayUrl!.isNotEmpty &&
      relayRoom != null &&
      relayRoom!.isNotEmpty;

  /// LAN 直結の WebSocket URL（`ws://host:port/ws/v1/input`）。無ければ null。
  String? lanWebSocketUrl() =>
      hasLanDirect ? 'ws://$lanHost:$lanPort/ws/v1/input' : null;

  /// `exp` を過ぎているか（境界＝失効扱い）。
  bool isExpired(DateTime now) =>
      expiresAt != null && !now.isBefore(expiresAt!);

  /// `screact://pair?v=1&t=..&host=..&port=..&relay=..&room=..&exp=..` を生成。
  /// 値の百分率エンコードは Uri に委ねる（relay の `wss://` も安全に載る）。
  String toUri() {
    final params = <String, String>{
      'v': '$version',
      't': pairingToken,
      if (hasLanDirect) 'host': lanHost!,
      if (hasLanDirect) 'port': '$lanPort',
      if (hasRelay) 'relay': relayUrl!,
      if (hasRelay) 'room': relayRoom!,
      if (expiresAt != null)
        'exp': '${expiresAt!.toUtc().millisecondsSinceEpoch ~/ 1000}',
    };
    return Uri(
      scheme: scheme,
      host: authority,
      queryParameters: params,
    ).toString();
  }

  /// `screact://pair?...` をパースする。不正・未知版数・接続先不明は null。
  static PairingPayload? tryParse(String input) {
    Uri uri;
    try {
      uri = Uri.parse(input.trim());
    } catch (_) {
      return null;
    }
    if (uri.scheme != scheme || uri.host != authority) return null;

    final q = uri.queryParameters;
    final version = int.tryParse(q['v'] ?? '');
    if (version != currentVersion) return null; // 未知/欠落版数は弾く

    final token = q['t'];
    if (token == null || !_isValidToken(token)) return null;

    final host = q['host'];
    final port = int.tryParse(q['port'] ?? '');
    final relay = q['relay'];
    final room = q['room'];

    // host があるなら port も有効でなければ整合しない。
    final hasHost = host != null && host.isNotEmpty;
    if (hasHost && !_isValidPort(port)) return null;
    // relay があるなら room も要る。
    final hasRelay = relay != null && relay.isNotEmpty;
    if (hasRelay && (room == null || room.isEmpty)) return null;

    final lanOk = hasHost && _isValidPort(port);
    final relayOk = hasRelay && room != null && room.isNotEmpty;
    // LAN もリレーも無いなら接続先が無く無効。
    if (!lanOk && !relayOk) return null;

    DateTime? exp;
    final expRaw = int.tryParse(q['exp'] ?? '');
    if (expRaw != null) {
      exp = DateTime.fromMillisecondsSinceEpoch(expRaw * 1000, isUtc: true);
    }

    return PairingPayload(
      version: currentVersion, // 上の版数ゲートで一致を確認済み
      pairingToken: token,
      lanHost: lanOk ? host : null,
      lanPort: lanOk ? port : null,
      relayUrl: relayOk ? relay : null,
      relayRoom: relayOk ? room : null,
      expiresAt: exp,
    );
  }
}

bool _isValidToken(String t) => RegExp(r'^\d{6}$').hasMatch(t);
bool _isValidPort(int? p) => p != null && p >= 1 && p <= 65535;
