import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Screact のゼロコンフィグ・ペアリング（UDP発見プロトコル）。
///
/// Desktop が「スマホ設置完了」押下から UDP ブロードキャストで offer を投げ、
/// 待受中の Android がユニキャストで response を返す。Desktop は応答を集約し、
/// 1台なら自動選択・複数なら AirDrop 風UIで選択して select をユニキャスト送信。
/// select を受けた Android だけが既存の WebSocket (/ws/v1/input) へ自動接続する
/// （pairingToken は offer/select の token を使う＝手入力廃止）。
///
/// メッセージは全て UTF-8 JSON・`app:"screact"` を必須マーカーとする。
const String kDiscoveryApp = 'screact';
const int kDiscoveryPort = 8766;
const int kDiscoverySchemaVersion = 1;

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
    if (j['app'] != kDiscoveryApp) return null;
    if (j['messageType'] != 'discovery_offer') return null;
    final wsPort = (j['wsPort'] as num?)?.toInt();
    final token = j['token'] as String?;
    if (wsPort == null || token == null) return null;
    return DiscoveryOffer(ip: j['ip'] as String?, wsPort: wsPort, token: token);
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
    if (j['app'] != kDiscoveryApp) return null;
    if (j['messageType'] != 'discovery_response') return null;
    final id = j['deviceId'] as String?;
    if (id == null || id.isEmpty) return null;
    return DiscoveryResponse(
      deviceId: id,
      deviceName: (j['deviceName'] as String?) ?? id,
      model: (j['model'] as String?) ?? '',
    );
  }
}

/// Desktop→選択したAndroid(ユニキャスト): 接続許可。これを受けた端末だけが
/// WebSocket へ接続する。deviceId 照合で他端末への誤配送を無視できる。
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
    if (j['app'] != kDiscoveryApp) return null;
    if (j['messageType'] != 'discovery_select') return null;
    if (j['selected'] != true) return null;
    final id = j['deviceId'] as String?;
    final wsPort = (j['wsPort'] as num?)?.toInt();
    final token = j['token'] as String?;
    if (id == null || wsPort == null || token == null) return null;
    return DiscoverySelect(deviceId: id, ip: j['ip'] as String?, wsPort: wsPort, token: token);
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

/// Desktop 側の発見ドライバ。offer の定期ブロードキャスト送信と
/// response の集約（deviceId で重複排除・古い応答の失効）を行う。
class DesktopDiscovery extends ChangeNotifier {
  final String token;
  final int wsPort;
  final String? ip;
  final int discoveryPort;
  final Duration offerInterval;
  final Duration deviceTtl;
  final void Function(String)? onLog;

  /// 送信先（null なら 255.255.255.255＋サブネットブロードキャストを自動選定。
  /// テストでは ['127.0.0.1'] 等に差し替える）。
  final List<String>? broadcastAddresses;

  RawDatagramSocket? _socket;
  Timer? _offerTimer;
  final Map<String, DiscoveredDevice> _devices = {};

  DesktopDiscovery({
    required this.token,
    required this.wsPort,
    this.ip,
    this.discoveryPort = kDiscoveryPort,
    this.offerInterval = const Duration(seconds: 1),
    this.deviceTtl = const Duration(seconds: 6),
    this.broadcastAddresses,
    this.onLog,
  });

  bool get running => _socket != null;
  List<DiscoveredDevice> get devices => _devices.values.toList()
    ..sort((a, b) => a.deviceName.compareTo(b.deviceName));

  void _log(String m) => onLog?.call('[発見] $m');

  List<String> get _targets {
    final custom = broadcastAddresses;
    if (custom != null) return custom;
    final subnet = subnetBroadcastOf(ip);
    return ['255.255.255.255', if (subnet != null) subnet];
  }

  Future<void> start() async {
    if (_socket != null) return;
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    s.broadcastEnabled = true;
    _socket = s;
    s.listen(_onSocketEvent);
    _log('UDPブロードキャスト開始 → ${_targets.join(", ")}:$discoveryPort '
        '(wsPort=$wsPort)');
    _sendOffer();
    _offerTimer = Timer.periodic(offerInterval, (_) {
      _sendOffer();
      _expireStale();
    });
  }

  void _onSocketEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    final j = decodeDiscoveryDatagram(dg.data);
    if (j == null) return;
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
        jsonEncode(DiscoveryOffer(ip: ip, wsPort: wsPort, token: token).toJson()));
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

  /// 選択した端末へ接続許可をユニキャスト送信（UDPなので少数回リピート）。
  /// 以後の offer 送信は止める（未選択端末は待機に戻る）。
  void select(DiscoveredDevice device) {
    final s = _socket;
    if (s == null) return;
    _offerTimer?.cancel();
    _offerTimer = null;
    final bytes = utf8.encode(jsonEncode(DiscoverySelect(
      deviceId: device.deviceId,
      ip: ip,
      wsPort: wsPort,
      token: token,
    ).toJson()));
    _log('接続許可を送信: ${device.deviceName} (${device.address.address}:${device.port})');
    for (var i = 0; i < 3; i++) {
      Timer(Duration(milliseconds: 120 * i), () {
        try {
          _socket?.send(bytes, device.address, device.port);
        } catch (e) {
          _log('select送信失敗: $e');
        }
      });
    }
  }

  void stop() {
    _offerTimer?.cancel();
    _offerTimer = null;
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
