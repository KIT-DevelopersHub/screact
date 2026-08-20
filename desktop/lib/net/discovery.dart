import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'wifi_ip.dart';

/// Screact のゼロコンフィグ・ペアリング（UDP発見プロトコル）。
///
/// Desktop が「始める」押下から UDP ブロードキャストで offer を投げ、待受を
/// 明示的に開始した Android が response を返したうえで、offer 内の接続情報を
/// 使って既存の WebSocket (/ws/v1/input) へ自動接続する。
///
/// discovery_select/select_ack は旧Androidとのプロトコル互換のため残すが、
/// 現行の接続成立条件には使用しない。
///
/// メッセージは全て UTF-8 JSON・`app:"screact"` を必須マーカーとする。
const String kDiscoveryApp = 'screact';
const int kDiscoveryPort = 8766;
const int kDiscoverySchemaVersion = 1;

bool _isDiscoveryMessage(Map<String, dynamic> json, String messageType) {
  return json['app'] == kDiscoveryApp &&
      json['schemaVersion'] == kDiscoverySchemaVersion &&
      json['messageType'] == messageType;
}

bool _isValidPort(int? port) => port != null && port >= 1 && port <= 65535;
bool _isValidPairingToken(String? token) =>
    token != null && RegExp(r'^\d{6}$').hasMatch(token);

/// Desktop→broadcast: 接続情報の広告。
class DiscoveryOffer {
  final String? ip; // 参考情報（AndroidはUDP送信元アドレスを優先してよい）
  final int wsPort;
  final String token; // WebSocket hello の pairingToken にそのまま使う
  const DiscoveryOffer({this.ip, required this.wsPort, required this.token});

  Map<String, dynamic> toJson() => {
    'app': kDiscoveryApp,
    'schemaVersion': kDiscoverySchemaVersion,
    'messageType': 'discovery_offer',
    if (ip != null) 'ip': ip,
    'wsPort': wsPort,
    'token': token,
  };

  static DiscoveryOffer? tryParse(Map<String, dynamic> j) {
    if (!_isDiscoveryMessage(j, 'discovery_offer')) return null;
    final wsPort = (j['wsPort'] as num?)?.toInt();
    final token = j['token'] as String?;
    if (!_isValidPort(wsPort) || !_isValidPairingToken(token)) return null;
    return DiscoveryOffer(
      ip: j['ip'] as String?,
      wsPort: wsPort!,
      token: token!,
    );
  }
}

/// Android→Desktop(ユニキャスト): 「ここにいます」の応答。
class DiscoveryResponse {
  final String deviceId;
  final String deviceName;
  final String model;
  const DiscoveryResponse({
    required this.deviceId,
    required this.deviceName,
    required this.model,
  });

  Map<String, dynamic> toJson() => {
    'app': kDiscoveryApp,
    'schemaVersion': kDiscoverySchemaVersion,
    'messageType': 'discovery_response',
    'deviceId': deviceId,
    'deviceName': deviceName,
    'model': model,
  };

  static DiscoveryResponse? tryParse(Map<String, dynamic> j) {
    if (!_isDiscoveryMessage(j, 'discovery_response')) return null;
    final id = j['deviceId'] as String?;
    if (id == null || id.trim().isEmpty || id.length > 128) return null;
    return DiscoveryResponse(
      deviceId: id,
      deviceName: (j['deviceName'] as String?) ?? id,
      model: (j['model'] as String?) ?? '',
    );
  }
}

/// 旧Android向けの接続許可メッセージ。現行Androidはoffer駆動で接続する。
class DiscoverySelect {
  final String deviceId;
  final String? ip;
  final int wsPort;
  final String token;
  const DiscoverySelect({
    required this.deviceId,
    this.ip,
    required this.wsPort,
    required this.token,
  });

  Map<String, dynamic> toJson() => {
    'app': kDiscoveryApp,
    'schemaVersion': kDiscoverySchemaVersion,
    'messageType': 'discovery_select',
    'deviceId': deviceId,
    'selected': true,
    if (ip != null) 'ip': ip,
    'wsPort': wsPort,
    'token': token,
  };

  static DiscoverySelect? tryParse(Map<String, dynamic> j) {
    if (!_isDiscoveryMessage(j, 'discovery_select')) return null;
    if (j['selected'] != true) return null;
    final id = j['deviceId'] as String?;
    final wsPort = (j['wsPort'] as num?)?.toInt();
    final token = j['token'] as String?;
    if (id == null ||
        id.trim().isEmpty ||
        id.length > 128 ||
        !_isValidPort(wsPort) ||
        !_isValidPairingToken(token)) {
      return null;
    }
    return DiscoverySelect(
      deviceId: id,
      ip: j['ip'] as String?,
      wsPort: wsPort!,
      token: token!,
    );
  }
}

/// Android→Desktop(ユニキャスト): select の受領確認。UDPの select は落ちる
/// ことがあるため、Desktop はこの ACK を受信するまで select を再送する
/// （実機テストで「PCは認識・Androidは待ちのまま」となった片方向不達の対策）。
class DiscoverySelectAck {
  final String deviceId;
  const DiscoverySelectAck({required this.deviceId});

  Map<String, dynamic> toJson() => {
    'app': kDiscoveryApp,
    'schemaVersion': kDiscoverySchemaVersion,
    'messageType': 'discovery_select_ack',
    'deviceId': deviceId,
  };

  static DiscoverySelectAck? tryParse(Map<String, dynamic> j) {
    if (!_isDiscoveryMessage(j, 'discovery_select_ack')) return null;
    final id = j['deviceId'] as String?;
    if (id == null || id.trim().isEmpty || id.length > 128) return null;
    return DiscoverySelectAck(deviceId: id);
  }
}

/// 受信データグラムを JSON Map にする（Screact のものだけ通す）。
Map<String, dynamic>? decodeDiscoveryDatagram(List<int> data) {
  try {
    final j = jsonDecode(utf8.decode(data));
    if (j is! Map<String, dynamic>) return null;
    if (j['app'] != kDiscoveryApp) return null;
    return j;
  } catch (_) {
    return null;
  }
}

/// macOSの「ローカルネットワーク」権限プロンプトを能動的に発火させる。
///
/// macOSはアプリが実際にLAN宛て送信を行った時に初めて権限確認を出し、
/// システム設定 > プライバシーとセキュリティ > ローカルネットワーク の
/// 一覧にアプリを登録する。ペアリング開始まで待つとプロンプトが接続失敗の
/// 後に出て分かりにくいため、起動直後に無害な1パケットを送って先に
/// 確認を促す（送信はベストエフォート・失敗してもアプリは継続）。
///
/// パケットは `messageType: "ln_probe"` の Screact JSON。Android/Desktop の
/// 既存パーサはいずれも未知の messageType を無視するため実害はない。
Future<void> triggerLocalNetworkPrompt({
  String? ip,
  int port = kDiscoveryPort,
  List<String>? targets,
  void Function(String)? onLog,
}) async {
  await runZonedGuarded(
    () async {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.broadcastEnabled = true;
      final payload = utf8.encode(
        jsonEncode({
          'app': kDiscoveryApp,
          'schemaVersion': kDiscoverySchemaVersion,
          'messageType': 'ln_probe',
        }),
      );
      final subnet = subnetBroadcastOf(ip);
      final dests = targets ?? ['255.255.255.255', if (subnet != null) subnet];
      for (final t in dests) {
        try {
          s.send(payload, InternetAddress(t), port);
        } catch (_) {}
      }
      onLog?.call(
        '[権限] ローカルネットワークへの送信を試行しました'
        '（初回はmacOSの許可プロンプトが表示されます）',
      );
      // 送信済みデータグラムはclose後もカーネルから送出される。
      // widgetテストでタイマーが残らないよう即時closeする。
      s.close();
    },
    (e, _) {
      onLog?.call('[権限] ローカルネットワーク送信トリガに失敗（継続）: $e');
    },
  );
}

/// サブネットのブロードキャストアドレス（/24 前提の簡易版）。
/// 255.255.255.255 が届かないAP向けの補助として併送する。
String? subnetBroadcastOf(String? ip) {
  if (ip == null) return null;
  final parts = ip.split('.');
  if (parts.length != 4) return null;
  return '${parts[0]}.${parts[1]}.${parts[2]}.255';
}

/// 発見済みのAndroid端末。
class DiscoveredDevice {
  final String deviceId;
  final String deviceName;
  final String model;
  final InternetAddress address;
  final int port;
  DateTime lastSeen;
  DiscoveredDevice({
    required this.deviceId,
    required this.deviceName,
    required this.model,
    required this.address,
    required this.port,
    required this.lastSeen,
  });
}

/// Desktop 側の発見ドライバ。offer の定期ブロードキャスト送信とresponseの
/// 集約（deviceId で重複排除・古い応答の失効）を行う。
class DesktopDiscovery extends ChangeNotifier {
  final String token;
  final int wsPort;
  final String? ip;
  final int discoveryPort;
  final Duration offerInterval;
  final Duration deviceTtl;
  final void Function(String)? onLog;

  /// select の再送間隔と最大送信回数（ACK 受信までリピート）。
  final Duration selectResendInterval;
  final int selectMaxAttempts;

  /// 送信先（null なら 255.255.255.255＋サブネットブロードキャストを自動選定。
  /// テストでは ['127.0.0.1'] 等に差し替える）。
  final List<String>? broadcastAddresses;

  /// start() 時に列挙した、全物理IFの /24 ディレクテッドブロードキャスト。
  /// offer/select を `_wifiIp` 由来の1サブネットだけでなく全物理IFへ併送し、
  /// 実際にスマホと同じL2にあるIFが `ip` と異なる環境でも到達させる。
  /// broadcastAddresses（テスト差し替え）指定時は使わない。
  List<String> _autoTargets = const [];

  RawDatagramSocket? _socket;
  Timer? _offerTimer;
  Timer? _selectTimer;
  DiscoveredDevice? _selectTarget;
  int _selectAttempts = 0;
  bool _selectAcked = false;
  bool _selectGaveUp = false;
  int _generation = 0;
  final Map<String, DiscoveredDevice> _devices = {};

  DesktopDiscovery({
    required this.token,
    required this.wsPort,
    this.ip,
    this.discoveryPort = kDiscoveryPort,
    this.offerInterval = const Duration(seconds: 1),
    this.deviceTtl = const Duration(seconds: 6),
    this.selectResendInterval = const Duration(milliseconds: 300),
    this.selectMaxAttempts = 20,
    this.broadcastAddresses,
    this.onLog,
  });

  bool get running => _socket != null;

  /// 選択した端末から select の ACK を受信済みか（到達確認）。
  bool get selectAcked => _selectAcked;

  /// これまでに select を送信した回数（テスト/診断用）。
  int get selectAttempts => _selectAttempts;

  /// select を最大回数送っても ACK が得られず打ち切ったか。
  /// true なら select がスマホに届いていない（macOSの「ローカルネットワーク」
  /// 権限拒否・Wi-Fiアイソレーション等）。UI が対処案内を出すためのフラグ。
  bool get selectGaveUp => _selectGaveUp;
  List<DiscoveredDevice> get devices =>
      _devices.values.toList()
        ..sort((a, b) => a.deviceName.compareTo(b.deviceName));

  void _log(String m) => onLog?.call('[発見] $m');

  List<String> get _targets {
    final custom = broadcastAddresses;
    if (custom != null) return custom;
    final subnet = subnetBroadcastOf(ip);
    // 255.255.255.255 を先頭に保ちつつ、サブネット/全物理IFの.255を重複排除で併送。
    return <String>{
      '255.255.255.255',
      if (subnet != null) subnet,
      ..._autoTargets,
    }.toList();
  }

  Future<void> start() async {
    if (_socket != null) return;
    final generation = ++_generation;
    // RawDatagramSocket.send の失敗（macOSのローカルネットワーク権限拒否時の
    // EHOSTUNREACH 等）は同期 try/catch を素通りして zone に上がることがある。
    // 発見はベストエフォートなので、ソケット起因の非同期例外は全てログに落として
    // アプリを落とさない。
    await runZonedGuarded(
      () async {
        final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        if (generation != _generation) {
          s.close();
          return;
        }
        s.broadcastEnabled = true;
        _socket = s;
        // 全物理IFの.255を併送先に加える（ベストエフォート・失敗は無視）。
        // broadcastAddresses 指定時は _targets が無視するのでここでの結果も影響しない。
        try {
          final autoTargets = await localSubnetBroadcasts();
          if (generation == _generation) _autoTargets = autoTargets;
        } catch (_) {
          // 列挙失敗時は 255.255.255.255＋サブネットのみで継続。
        }
        s.listen(_onSocketEvent, onError: (Object e) => _log('受信エラー: $e'));
        _log(
          'UDPブロードキャスト開始 → ${_targets.join(", ")}:$discoveryPort '
          '(wsPort=$wsPort)',
        );
        _sendOffer();
        _offerTimer = Timer.periodic(offerInterval, (_) {
          _sendOffer();
          _expireStale();
        });
      },
      (e, _) {
        _log(
          '発見ソケットエラー（継続）: $e '
          '— macOSの「ローカルネットワーク」権限を確認してください',
        );
      },
    );
  }

  void _onSocketEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    final j = decodeDiscoveryDatagram(dg.data);
    if (j == null) return;
    final ack = DiscoverySelectAck.tryParse(j);
    if (ack != null) {
      _onSelectAck(ack);
      return;
    }
    final res = DiscoveryResponse.tryParse(j);
    if (res == null) return;
    final existing = _devices[res.deviceId];
    _devices[res.deviceId] = DiscoveredDevice(
      deviceId: res.deviceId,
      deviceName: res.deviceName,
      model: res.model,
      address: dg.address,
      port: dg.port,
      lastSeen: DateTime.now(),
    );
    if (existing == null) {
      _log('スマホ発見: ${res.deviceName} (${dg.address.address})');
      notifyListeners();
    }
  }

  void _sendOffer() {
    final s = _socket;
    if (s == null) return;
    final bytes = utf8.encode(
      jsonEncode(DiscoveryOffer(ip: ip, wsPort: wsPort, token: token).toJson()),
    );
    for (final t in _targets) {
      try {
        s.send(bytes, InternetAddress(t), discoveryPort);
      } catch (e) {
        _log('offer送信失敗 ($t): $e');
      }
    }
  }

  void _expireStale() {
    final cutoff = DateTime.now().subtract(deviceTtl);
    final before = _devices.length;
    _devices.removeWhere((_, d) => d.lastSeen.isBefore(cutoff));
    if (_devices.length != before) notifyListeners();
  }

  /// 旧Androidへ接続許可（select）を送信する互換API。
  /// 以後の offer 送信は止める（未選択端末は待機に戻る）。
  ///
  /// UDPの select は落ちうる（実機で「PCは認識・Androidは待ちのまま」と
  /// なった原因経路）ため、Android からの discovery_select_ack を受信する
  /// まで [selectResendInterval] 間隔で最大 [selectMaxAttempts] 回再送する。
  /// WS接続成立（hello受領）で呼び出し側が stop() すれば再送も止まる。
  ///
  /// 送信は「ユニキャスト＋offerと同じブロードキャスト」の併送。実機で
  /// macOSの「ローカルネットワーク」権限が未許可だと LAN 宛てユニキャスト
  /// だけがOSに落とされ（ブロードキャストは通る＝offerは届く非対称）、
  /// select が永遠に届かない事象を確認したため。deviceId 照合により
  /// ブロードキャストでも選択した1台しか反応しない（token は元々 offer で
  /// 全端末に届いている情報なので露出は増えない）。
  void select(DiscoveredDevice device) {
    final s = _socket;
    if (s == null) return;
    _offerTimer?.cancel();
    _offerTimer = null;
    _selectTimer?.cancel();
    _selectTarget = device;
    _selectAttempts = 0;
    _selectAcked = false;
    _selectGaveUp = false;
    _log(
      '接続許可(select)を送信: ${device.deviceName} '
      '(${device.address.address}:${device.port} + ブロードキャスト併送) '
      '— ACK受信まで再送します',
    );
    _sendSelect(device);
    _selectTimer = Timer.periodic(selectResendInterval, (_) {
      if (_selectAcked) {
        _selectTimer?.cancel();
        _selectTimer = null;
        return;
      }
      if (_selectAttempts >= selectMaxAttempts) {
        _selectTimer?.cancel();
        _selectTimer = null;
        _selectGaveUp = true;
        _log(
          'selectのACKなし（$_selectAttempts回送信）— スマホ側に届いていま'
          'せん。macOSの「システム設定 > プライバシーとセキュリティ > '
          'ローカルネットワーク」でこのアプリを許可しているか、Wi-Fiの'
          'アイソレーション設定を確認してください',
        );
        notifyListeners(); // UIに対処案内を出させる
        return;
      }
      _sendSelect(device);
    });
  }

  void _sendSelect(DiscoveredDevice device) {
    final bytes = utf8.encode(
      jsonEncode(
        DiscoverySelect(
          deviceId: device.deviceId,
          ip: ip,
          wsPort: wsPort,
          token: token,
        ).toJson(),
      ),
    );
    var sent = false;
    // 1) 応答の送信元へユニキャスト（本来の宛先）。
    try {
      _socket?.send(bytes, device.address, device.port);
      sent = true;
    } catch (e) {
      _log('select送信失敗(ユニキャスト): $e');
    }
    // 2) offerと同じブロードキャストにも併送（ユニキャストがOS/APに落とされる
    //    環境への到達経路。deviceId照合で選択端末しか反応しない）。
    for (final t in _targets) {
      try {
        _socket?.send(bytes, InternetAddress(t), discoveryPort);
        sent = true;
      } catch (e) {
        _log('select送信失敗($t): $e');
      }
    }
    if (sent) {
      _selectAttempts++;
      // 1回目と以後5回ごとにログ（再送のたびに流れると読みにくい）。
      if (_selectAttempts == 1 || _selectAttempts % 5 == 0) {
        _log(
          'select送信 ($_selectAttempts回目) → '
          '${device.address.address}:${device.port} と ${_targets.join(", ")}'
          ':$discoveryPort',
        );
      }
    }
  }

  void _onSelectAck(DiscoverySelectAck ack) {
    final target = _selectTarget;
    if (target == null || ack.deviceId != target.deviceId) return;
    if (_selectAcked) return;
    _selectAcked = true;
    _selectTimer?.cancel();
    _selectTimer = null;
    _log(
      'selectのACKを受信: ${target.deviceName} — スマホに到達確認。'
      'WebSocket接続を待ちます',
    );
  }

  void stop() {
    _generation++;
    _offerTimer?.cancel();
    _offerTimer = null;
    _selectTimer?.cancel();
    _selectTimer = null;
    _selectTarget = null;
    _socket?.close();
    _socket = null;
    _devices.clear();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
