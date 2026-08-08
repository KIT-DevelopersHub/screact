import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/discovery.dart';

/// ゼロコンフィグ・ペアリングの進行状態。
enum PairingPhase {
  /// 何もしていない（「スマホ設置完了」待ち）。
  idle,

  /// offer をブロードキャスト中・応答待ち。
  searching,

  /// 2台以上が応答: AirDrop 風の選択UIを表示中。
  selecting,

  /// select 送信済み: 選択した端末の WebSocket 接続待ち。
  waitingConnect,

  /// 応答ゼロのままタイムアウト（再試行/手動接続への誘導）。
  timeout,
}

/// 「スマホ設置完了」→ UDP発見 → 1台なら自動選択・複数なら選択UI →
/// select 送信 → WS接続待ち、の状態遷移だけを持つコントローラ。
/// UIから分離してテスト可能にする（UDP実体は factory 経由で注入）。
class PairingController extends ChangeNotifier {
  /// 発見ドライバの生成（本番は DesktopDiscovery をそのまま・テストは
  /// loopback 宛てに差し替えた個体を返す）。
  final DesktopDiscovery Function() discoveryFactory;

  /// 最初の応答から追加応答を待つ集約ウィンドウ。閉じた時点で
  /// 1台なら自動選択・複数なら選択UIへ。
  final Duration selectionWindow;

  /// 応答ゼロで諦めるまでの時間。
  final Duration searchTimeout;

  DesktopDiscovery? _discovery;
  PairingPhase _phase = PairingPhase.idle;
  DiscoveredDevice? _selected;
  Timer? _windowTimer;
  Timer? _timeoutTimer;

  PairingController({
    required this.discoveryFactory,
    this.selectionWindow = const Duration(seconds: 2),
    this.searchTimeout = const Duration(seconds: 15),
  });

  PairingPhase get phase => _phase;
  DiscoveredDevice? get selected => _selected;
  List<DiscoveredDevice> get devices => _discovery?.devices ?? const [];
  bool get active => _phase != PairingPhase.idle;

  /// select のACKが得られず打ち切った（スマホに届いていない）。
  /// waitingConnect 画面で権限/ネットワークの対処案内を出すために使う。
  bool get selectDeliveryStalled => _discovery?.selectGaveUp ?? false;

  /// 発見を開始する（「スマホ設置完了」押下）。
  Future<void> start() async {
    if (_phase == PairingPhase.searching || _phase == PairingPhase.selecting) {
      return;
    }
    _teardown();
    final d = discoveryFactory();
    _discovery = d;
    d.addListener(_onDiscoveryChanged);
    _phase = PairingPhase.searching;
    _selected = null;
    notifyListeners();
    await d.start();
    _timeoutTimer = Timer(searchTimeout, _onSearchTimeout);
  }

  void _onDiscoveryChanged() {
    final d = _discovery;
    if (d == null) return;
    if (_phase == PairingPhase.searching && d.devices.isNotEmpty) {
      // 最初の応答: 追加応答の集約ウィンドウを開く（AirDrop的な猶予）。
      _timeoutTimer?.cancel();
      _windowTimer ??= Timer(selectionWindow, _onWindowClosed);
    }
    notifyListeners(); // 選択UI表示中のカード増減にも追従
  }

  void _onWindowClosed() {
    _windowTimer = null;
    final d = _discovery;
    if (d == null || _phase != PairingPhase.searching) return;
    final found = d.devices;
    if (found.length == 1) {
      selectDevice(found.first); // 1台だけなら自動選択
    } else if (found.length > 1) {
      _phase = PairingPhase.selecting;
      notifyListeners();
    }
  }

  void _onSearchTimeout() {
    if (_phase != PairingPhase.searching) return;
    if (devices.isNotEmpty) return; // 応答があればウィンドウ側に任せる
    _discovery?.stop();
    _phase = PairingPhase.timeout;
    notifyListeners();
  }

  /// 端末を選択して接続許可を送る（選択UI/自動選択の双方から呼ぶ）。
  void selectDevice(DiscoveredDevice device) {
    final d = _discovery;
    if (d == null) return;
    _selected = device;
    d.select(device);
    _phase = PairingPhase.waitingConnect;
    notifyListeners();
  }

  /// WebSocket 接続（hello 受領）で発見フェーズを終了する。
  void onConnected() {
    if (_phase == PairingPhase.idle) return;
    _teardown();
    _phase = PairingPhase.idle;
    notifyListeners();
  }

  /// キャンセル/中止（発見のみ止める。サーバは呼び出し側の管轄）。
  void cancel() {
    _teardown();
    _phase = PairingPhase.idle;
    _selected = null;
    notifyListeners();
  }

  void _teardown() {
    _windowTimer?.cancel();
    _windowTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    final d = _discovery;
    if (d != null) {
      d.removeListener(_onDiscoveryChanged);
      d.stop();
      d.dispose();
    }
    _discovery = null;
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
