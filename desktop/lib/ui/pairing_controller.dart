import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/discovery.dart';

/// UDP offer と Android からの WebSocket 接続を待つ進行状態。
enum PairingPhase { idle, searching, waitingConnect, timeout }

/// Desktopは接続情報をUDP broadcastで広告し、待受を明示的に開始したAndroidが
/// offerを受けてDesktopのWebSocketへ接続する。
///
/// 旧実装はresponseを集約してselectを送り直していたが、現Androidはoffer受信時に
/// 接続を開始するため、その選択UIは接続結果を制御できなかった。ここでは接続方式を
/// offer駆動へ一本化し、複数端末の競合はInputServerのfirst-client-winsで安全に拒否する。
class PairingController extends ChangeNotifier {
  final DesktopDiscovery Function() discoveryFactory;

  final Duration searchTimeout;

  DesktopDiscovery? _discovery;
  PairingPhase _phase = PairingPhase.idle;
  DiscoveredDevice? _selected;
  Timer? _timeoutTimer;

  PairingController({
    required this.discoveryFactory,
    this.searchTimeout = const Duration(seconds: 15),
  });

  PairingPhase get phase => _phase;
  DiscoveredDevice? get selected => _selected;
  List<DiscoveredDevice> get devices => _discovery?.devices ?? const [];
  bool get active => _phase != PairingPhase.idle;

  Future<void> start() async {
    if (_phase == PairingPhase.searching ||
        _phase == PairingPhase.waitingConnect) {
      return;
    }
    _teardown();
    late final DesktopDiscovery discovery;
    try {
      discovery = discoveryFactory();
    } catch (_) {
      _phase = PairingPhase.timeout;
      notifyListeners();
      return;
    }
    _discovery = discovery;
    discovery.addListener(_onDiscoveryChanged);
    _phase = PairingPhase.searching;
    _selected = null;
    notifyListeners();
    try {
      await discovery.start();
    } catch (_) {
      if (!identical(_discovery, discovery)) {
        discovery.stop();
        return;
      }
      _teardown();
      _phase = PairingPhase.timeout;
      notifyListeners();
      return;
    }
    if (!identical(_discovery, discovery)) {
      discovery.stop();
      return;
    }
    _timeoutTimer = Timer(searchTimeout, _onSearchTimeout);
  }

  void _onDiscoveryChanged() {
    final discovery = _discovery;
    if (discovery == null) return;
    if (_phase == PairingPhase.searching && discovery.devices.isNotEmpty) {
      _selected = discovery.devices.first;
      _phase = PairingPhase.waitingConnect;
    } else if (_phase == PairingPhase.waitingConnect &&
        _selected == null &&
        discovery.devices.isNotEmpty) {
      _selected = discovery.devices.first;
    } else if (_phase == PairingPhase.timeout && discovery.devices.isNotEmpty) {
      // タイムアウト後も offer を流し続けているため、遅れて待受を始めたスマホが
      // 現れることがある。その場合は再検索を挟まず接続待ちへ戻す。
      _selected = discovery.devices.first;
      _phase = PairingPhase.waitingConnect;
    }
    notifyListeners();
  }

  void _onSearchTimeout() {
    if (_phase != PairingPhase.searching &&
        _phase != PairingPhase.waitingConnect) {
      return;
    }
    // 発見（offerブロードキャスト）は止めない。15秒はあくまでUIの見切りで、
    // ここで teardown するとスマホが後から待受を始めても offer が届かず永久に
    // つながらない。offer は1秒間隔で流し続け、UIだけ手動/QR案内へ切り替える。
    // 一度きりのタイムアウトタイマーは発火済みなので参照だけ落とす（リークなし）。
    _timeoutTimer = null;
    _phase = PairingPhase.timeout;
    notifyListeners();
  }

  /// WebSocketのhelloが認証された時点でUDP広告を終了する。
  void onConnected() {
    if (_phase == PairingPhase.idle) return;
    _teardown();
    _phase = PairingPhase.idle;
    notifyListeners();
  }

  void cancel() {
    _teardown();
    _phase = PairingPhase.idle;
    _selected = null;
    notifyListeners();
  }

  void _teardown() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    final discovery = _discovery;
    if (discovery != null) {
      discovery.removeListener(_onDiscoveryChanged);
      discovery.stop();
      discovery.dispose();
    }
    _discovery = null;
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
