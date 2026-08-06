import 'dart:io';

/// Wi-Fi の IPv4 アドレス取得。
///
/// これまでは全インターフェースの IPv4 を列挙してそのまま表示していたため、
/// utun(VPN) や bridge 等の値が混ざり `ifconfig` の Wi-Fi 実値と一致しなかった。
/// macOS では Wi-Fi は通常 en0（無ければ en1..）なので、en 系を優先して1つ選ぶ。
class InterfaceAddrs {
  final String name;
  final List<String> v4;
  const InterfaceAddrs(this.name, this.v4);
}

/// 仮想/非物理インターフェース（表示すべきでないもの）。
bool _isVirtual(String name) {
  final n = name.toLowerCase();
  const prefixes = [
    'utun',
    'awdl',
    'llw',
    'bridge',
    'vmnet',
    'lo',
    'gif',
    'stf',
    'ap',
  ];
  return prefixes.any(n.startsWith);
}

bool _isWifi(String name) {
  final n = name.toLowerCase();
  return n == 'wi-fi' || n == 'wifi' || n.startsWith('wlan');
}

/// Wi-Fi として表示すべき IPv4 を1つ選ぶ（テスト可能な純関数）。
/// 優先順: en0 → en1..enN（番号順） → Windows Wi-Fi → その他の非仮想IF。
/// 無ければ null。
String? pickWifiIp(List<InterfaceAddrs> interfaces) {
  final withV4 = interfaces.where((i) => i.v4.isNotEmpty).toList();

  int enRank(String name) {
    final m = RegExp(r'^en(\d+)$').firstMatch(name.toLowerCase());
    return m != null ? int.parse(m.group(1)!) : 1 << 20;
  }

  final en =
      withV4.where((i) => enRank(i.name) < (1 << 20)).toList()
        ..sort((a, b) => enRank(a.name).compareTo(enRank(b.name)));
  if (en.isNotEmpty) return en.first.v4.first;

  // WindowsではVirtualBox等のホストオンリーNICがWi-Fiより先に列挙される
  // ことがあるため、実際の無線LANインターフェース名を明示的に優先する。
  for (final i in withV4) {
    if (_isWifi(i.name)) return i.v4.first;
  }

  for (final i in withV4) {
    if (!_isVirtual(i.name)) return i.v4.first;
  }
  return null;
}

/// 現在の Wi-Fi IPv4 を取得（`ipconfig getifaddr en0` 相当・フォールバック付き）。
Future<String?> currentWifiIp() async {
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return pickWifiIp([
      for (final i in ifs)
        InterfaceAddrs(i.name, [
          for (final a in i.addresses)
            if (!a.isLoopback) a.address,
        ]),
    ]);
  } catch (_) {
    return null;
  }
}
