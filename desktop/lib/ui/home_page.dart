import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/calibration_config.dart';
import '../core/interaction_engine.dart';
import '../core/mock_hand.dart';
import '../core/pointer_state.dart';
import '../net/connection_log.dart';
import '../net/discovery.dart';
import '../net/input_server.dart';
import '../net/wifi_ip.dart';
import '../platform/desktop_bridge.dart';
import '../platform/overlay_window.dart';
import 'calibration_flow.dart';
import 'device_picker.dart';
import 'overlay_canvas.dart';
import 'pairing_controller.dart';

/// 共通の操作面＋オーバーレイのライブプレビュー。macOSではこれ自体がアプリの
/// 出力（アプリ内描画）。Windowsでは同じ状態がネイティブのOS注入/透過窓を駆動する。
class HomePage extends StatefulWidget {
  /// テスト用のポート差し替え（null なら --dart-define=YUBI_PORT / 既定 8765）。
  final int? port;
  const HomePage({super.key, this.port});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// キャリブ調整値。既定は同梱ターゲット画像のマーカー実測位置
  /// （設定パネルから変更可能・エンジンと同一インスタンスを共有）。
  final _calibConfig = CalibrationConfig.forCalibrationTarget();
  late final _engine = InteractionEngine(config: _calibConfig);
  final _overlay = OverlayModel();
  final _bridge = DesktopBridge.forPlatform();
  final _flow = CalibrationFlowController();
  final _connLog = ConnectionLog();

  InputServer? _server;
  ServerStatus _status = const ServerStatus();
  String? _wifiIp; // Wi-Fi(en0等)の実IPv4のみ表示（utun等は除外）
  String? _pairingCode; // サーバ開始時に生成する6桁コード
  bool _enforcePairing = true;
  Timer? _mockTimer;
  int _mockI = 0;

  late final OverlayWindowController _overlayWin;
  bool _overlayOn = false;
  bool _overlayAvailable = false;
  bool _autoFlowFired = false;

  /// ゼロコンフィグ・ペアリング（UDP発見）の進行管理。
  late final PairingController _pairing;

  /// 開発者向け画面（従来の4ステップパネル）。既定は非表示・⌘D か
  /// 右下の隠しボタンで切替。
  bool _devMode = false;

  /// 直前の接続端末ID（null→非null の立ち上がり検出用）。
  String? _prevClientId;

  /// 検証用に --dart-define=YUBI_PORT=8766 等で差し替え可能（既定 8765）。
  int get _port =>
      widget.port ?? const int.fromEnvironment('YUBI_PORT', defaultValue: 8765);

  /// UDP発見の宛先ポート（検証用に --dart-define=YUBI_DISCOVERY_PORT で差替）。
  int get _discoveryPort => const int.fromEnvironment('YUBI_DISCOVERY_PORT',
      defaultValue: kDiscoveryPort);

  /// UDP発見の送信先override（E2E検証用: 例 YUBI_DISCOVERY_BCAST=127.0.0.1）。
  /// 未指定なら null（255.255.255.255＋サブネットブロードキャストを自動選定）。
  static const String _discoveryBcast =
      String.fromEnvironment('YUBI_DISCOVERY_BCAST');
  List<String>? get _discoveryTargets =>
      _discoveryBcast.isEmpty ? null : _discoveryBcast.split(',');

  /// スマホと接続済みか（hello 受領済み）。設置完了ボタン等の活性条件。
  bool get _phoneConnected => _status.clientId != null;

  /// 検証用の自動フロー: 起動時にサーバ開始し、クライアント接続で
  /// 「スマホ設置完了」をウィンドウ内表示で自動実行する（既定 off）。
  static const bool _autoFlow = bool.fromEnvironment('YUBI_AUTOFLOW');

  static const String _targetAsset = 'assets/calibration-target-1920x1080.png';

  @override
  void initState() {
    super.initState();
    _overlayWin = OverlayWindowController(
      onExited: () => setState(() {
        _overlayOn = false;
        _flow.cancel(); // 脱出経路で抜けたらキャリブ表示も中止
      }),
      onEntered: () => setState(() => _overlayOn = true),
    );
    _overlayWin.probe().then((ok) {
      if (mounted) setState(() => _overlayAvailable = ok);
    });
    _flow.addListener(() {
      if (mounted) setState(() {});
    });
    _connLog.init();
    _connLog.addListener(() {
      if (mounted) setState(() {});
    });
    _pairing = PairingController(
      discoveryFactory: () => DesktopDiscovery(
        token: _pairingCode ?? '',
        wsPort: _server?.boundPort ?? _port,
        ip: _wifiIp,
        discoveryPort: _discoveryPort,
        broadcastAddresses: _discoveryTargets,
        onLog: _connLog.add,
      ),
    );
    _pairing.addListener(() {
      if (mounted) setState(() {});
    });
    _refreshWifiIp();
    // 検証用自動フロー: 起動時に「スマホ設置完了」を自動実行する。
    if (_autoFlow) scheduleMicrotask(_startAutoPairing);
  }

  @override
  void dispose() {
    _mockTimer?.cancel();
    _pairing.dispose();
    _server?.stop();
    _flow.dispose();
    _connLog.dispose();
    super.dispose();
  }

  /// Wi-Fi IPを再取得（テザリング切替等でネットワークが変わっても更新できる）。
  Future<void> _refreshWifiIp() async {
    final ip = await currentWifiIp();
    if (mounted) setState(() => _wifiIp = ip);
  }

  void _applyEvents(List<InteractionEvent> events) {
    for (final e in events) {
      _overlay.apply(e);
      _bridge.applyEvent(e);
    }
  }

  Future<void> _startServer() async {
    if (_server != null) return;
    _pairingCode = InputServer.generatePairingCode();
    final s = InputServer(
      engine: _engine,
      port: _port,
      onEvents: _applyEvents,
      onStatus: _onServerStatus,
      pairingCode: _pairingCode,
      enforcePairing: _enforcePairing,
      onLog: _connLog.add,
    );
    await s.start();
    await _bridge.setOverlayVisible(true);
    await _refreshWifiIp(); // 開始時点の実IPを表示（テザリング切替に追従）
    setState(() => _server = s);
  }

  Future<void> _stopServer() async {
    await _server?.stop();
    await _bridge.setOverlayVisible(false);
    _flow.cancel();
    setState(() => _server = null);
  }

  void _onServerStatus(ServerStatus st) {
    if (!mounted) return;
    final justConnected = st.clientId != null && _prevClientId == null;
    _prevClientId = st.clientId;
    setState(() => _status = st);
    // 四隅受信→位置合わせ成功なら、キャリブ画像を自動クローズ。
    _flow.onEngineEpoch(_engine.calibrationCount);
    if (!justConnected) return;
    // ゼロコンフィグ・フロー: スマホ接続（hello受領）で発見を終了し、
    // そのままArUco表示（画面認識）へ自動遷移する。
    if (_pairing.active) {
      _pairing.onConnected();
      scheduleMicrotask(() => _startCalibrationDisplay(
          intoOverlay: _overlayAvailable && !_autoFlow));
      return;
    }
    // 検証用自動フロー（発見を介さない直接WS接続でも位置合わせを自動開始）。
    if (_autoFlow && !_autoFlowFired) {
      _autoFlowFired = true;
      _startCalibrationDisplay(intoOverlay: false);
    }
  }

  /// 「スマホ設置完了」（ゼロコンフィグの1ボタン）: サーバを起動し、
  /// UDPブロードキャストで待受中のAndroidを探す。1台なら自動選択・複数なら
  /// AirDrop風の選択UI。選択端末がWS接続してきたらArUco表示→位置合わせ→
  /// 自動でオーバーレイ開始。
  Future<void> _startAutoPairing() async {
    await _startServer();
    // 既にスマホが接続済み（再キャリブ等）なら発見をスキップして
    // そのまま画面認識へ。
    if (_phoneConnected) {
      await _startCalibrationDisplay(
          intoOverlay: _overlayAvailable && !_autoFlow);
      return;
    }
    await _pairing.start();
  }

  /// 発見の中止（検索中のキャンセル）。サーバも止めて初期状態に戻す。
  Future<void> _cancelAutoPairing() async {
    _pairing.cancel();
    await _stopServer();
  }

  /// 「スマホ設置完了」: キャリブ画像を最前面（オーバーレイ）に全画面表示し、
  /// スマホをマーカー検出（calibration）モードへ切り替える。四隅を受信して
  /// 位置合わせが完了すると画像は自動で閉じ、従来フロー（描画）へ進む。
  Future<void> _onPhonePlaced() =>
      _startCalibrationDisplay(intoOverlay: _overlayAvailable);

  Future<void> _startCalibrationDisplay({required bool intoOverlay}) async {
    final server = _server;
    if (server == null || !_phoneConnected) return; // 未接続時は開始しない
    server.requestMode('calibration');
    _flow.start(_engine.calibrationCount);
    if (intoOverlay && !_overlayOn) await _enterOverlay();
    if (mounted) setState(() {});
  }

  /// キャリブ画像の全画面表示（白背景＋ArUcoターゲットを画面いっぱいに引き伸ばす。
  /// マーカー中心位置の比率が設定のインセット既定値と一致する）。
  Widget _calibrationTarget() {
    return Container(
      color: Colors.white,
      alignment: Alignment.center,
      child: SizedBox.expand(
        child: Image.asset(_targetAsset, fit: BoxFit.fill),
      ),
    );
  }

  /// 電話なしの結合確認: モックの位置合わせ＋手フレームをエンジンへ直接流す。
  void _toggleMock() {
    if (_mockTimer != null) {
      _mockTimer!.cancel();
      setState(() => _mockTimer = null);
      return;
    }
    _engine.calibrate(MockHand.markers());
    _engine.mode = EngineMode.tracking;
    _mockI = 0;
    _mockTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _applyEvents(_engine.onFrame(MockHand.frame(_mockI++)));
    });
    setState(() {});
  }

  /// スライドの上にインクを重ねるオーバーレイモードへ。
  /// 解除はメニューバーのアイコン or Cmd+Shift+O（ネイティブ側の脱出経路）。
  Future<void> _enterOverlay() async {
    final ok = await _overlayWin.enter();
    if (ok && mounted) setState(() => _overlayOn = true);
  }

  // ---------------------------------------------------------------------------
  // 表示状態（セットアップの進行ステップ）
  // ---------------------------------------------------------------------------

  /// 0:サーバ未開始 1:スマホ接続待ち 2:接続済み(設置待ち) 3:位置合わせ中 4:操作可能
  int get _step {
    if (_server == null) return 0;
    if (!_phoneConnected) return 1;
    if (_flow.showingTarget) return 3;
    if (_engine.isCalibrated && _status.mode == EngineMode.tracking) return 4;
    return 2;
  }

  (Color, IconData, String) _stepBadge() {
    switch (_step) {
      case 0:
        return (const Color(0xFF8A94A6), Icons.power_settings_new, '未接続');
      case 1:
        return (const Color(0xFFDD8A0C), Icons.wifi_tethering, 'スマホの接続待ち');
      case 2:
        return (const Color(0xFF2B6CB0), Icons.smartphone, '接続済み');
      case 3:
        return (const Color(0xFF7C5CD6), Icons.center_focus_strong, '位置合わせ中');
      default:
        return (const Color(0xFF2F9E63), Icons.gesture, '操作可能');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_overlayOn) {
      // オーバーレイモード。キャリブ表示中はArUcoターゲットを最前面に出し、
      // 四隅の受信で自動的にインク描画（透過）へ切り替わる。
      if (_flow.showingTarget) {
        return Material(child: _calibrationTarget());
      }
      // 背景を完全透過にし、インクとポインタだけ描画する。
      // 窓はネイティブ側でクリック透過になっているため操作UIは出さない。
      return Material(
        type: MaterialType.transparency,
        child: SizedBox.expand(child: OverlayCanvas(model: _overlay)),
      );
    }
    final running = _server != null;
    // ⌘D で開発者向け画面（従来の4ステップパネル）と1ボタン画面を切替。
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true):
            _toggleDevMode,
      },
      child: Focus(
        autofocus: true,
        child: _devMode ? _devScaffold(running) : _simpleScaffold(),
      ),
    );
  }

  void _toggleDevMode() => setState(() => _devMode = !_devMode);

  /// 開発者向け画面（従来UI: 4ステップパネル＋接続情報カード＋プレビュー）。
  Widget _devScaffold(bool running) {
    return Scaffold(
      appBar: _header(),
      body: Stack(
        children: [
          Row(
            children: [
              SizedBox(width: 332, child: _controls(running)),
              const VerticalDivider(width: 1),
              Expanded(child: _preview()),
            ],
          ),
          // オーバーレイ窓が使えない環境（未接続ビルド・検証時）は
          // ウィンドウ内いっぱいにキャリブ画像を表示する。
          if (_flow.showingTarget && !_overlayOn)
            Positioned.fill(child: _inWindowCalibration()),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // ゼロコンフィグの1ボタン画面（既定のホーム）
  // ---------------------------------------------------------------------------

  Widget _simpleScaffold() {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: Center(child: _pairingBody())),
          // ブランド（左上・控えめ）
          Positioned(
            left: 20,
            top: 16,
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [cs.primary, const Color(0xFF4C8DD8)],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.gesture, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              const Text('Screact',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            ]),
          ),
          // 開発者向けへの隠し導線（右下・薄表示。⌘D でも切替可能）
          Positioned(
            right: 10,
            bottom: 10,
            child: Opacity(
              opacity: 0.35,
              child: IconButton(
                tooltip: '開発者向け（⌘D）',
                onPressed: _toggleDevMode,
                icon: const Icon(Icons.tune, size: 18),
              ),
            ),
          ),
          if (_flow.showingTarget && !_overlayOn)
            Positioned.fill(child: _inWindowCalibration()),
        ],
      ),
    );
  }

  /// フェーズごとの中央コンテンツ。
  Widget _pairingBody() {
    // 位置合わせ完了後（オーバーレイから戻った時など）は操作状態を表示。
    if (_step == 4) return _readyBody();
    switch (_pairing.phase) {
      case PairingPhase.searching:
        return _searchingBody();
      case PairingPhase.selecting:
        return _selectingBody();
      case PairingPhase.waitingConnect:
        return _waitingConnectBody();
      case PairingPhase.timeout:
        return _timeoutBody();
      case PairingPhase.idle:
        // 接続済みでキャリブ表示待ちの一瞬も idle になる。ターゲット表示中は
        // _inWindowCalibration / オーバーレイが最前面に出るのでここは初期画面。
        return _idleBody();
    }
  }

  Widget _heroColumn(List<Widget> children) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _bigCaption(String text) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
          fontSize: 13,
          height: 1.7,
          color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  /// 初期画面: 「スマホ設置完了」ボタンのみ。
  Widget _idleBody() {
    final cs = Theme.of(context).colorScheme;
    return _heroColumn([
      Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primary, const Color(0xFF4C8DD8)],
          ),
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Icon(Icons.smartphone, color: Colors.white, size: 42),
      ),
      const SizedBox(height: 26),
      const Text('スマホを設置したら、はじめましょう',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),
      _bigCaption('画面全体と手元が映る位置にスマホを固定して、下のボタンを押してください。\n'
          'スマホは自動で見つかります（スマホ側で「画面認識開始」を押しておく）。'),
      const SizedBox(height: 28),
      FilledButton.icon(
        onPressed: _startAutoPairing,
        style: FilledButton.styleFrom(
          minimumSize: const Size(280, 58),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        icon: const Icon(Icons.smartphone),
        label: const Text('スマホ設置完了'),
      ),
    ]);
  }

  /// 検索中: ブロードキャストで応答待ち。
  Widget _searchingBody() {
    return _heroColumn([
      const SizedBox(
          width: 52, height: 52, child: CircularProgressIndicator(strokeWidth: 3)),
      const SizedBox(height: 26),
      const Text('スマホを探しています…',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),
      _bigCaption('同じWi-Fiに接続したスマホで「画面認識開始」を押してください。'),
      const SizedBox(height: 22),
      TextButton(onPressed: _cancelAutoPairing, child: const Text('キャンセル')),
    ]);
  }

  /// 複数台検出: AirDrop風の選択UI。
  Widget _selectingBody() {
    return _heroColumn([
      const Text('スマホが複数見つかりました',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      _bigCaption('画面認識に使うスマホを1台選んでください。'),
      const SizedBox(height: 24),
      DevicePickerGrid(
        devices: _pairing.devices,
        onSelect: _pairing.selectDevice,
      ),
      const SizedBox(height: 20),
      TextButton(onPressed: _cancelAutoPairing, child: const Text('キャンセル')),
    ]);
  }

  /// 選択済み: WebSocket 接続待ち。
  Widget _waitingConnectBody() {
    final name = _pairing.selected?.deviceName ?? 'スマホ';
    final cs = Theme.of(context).colorScheme;
    return _heroColumn([
      const SizedBox(
          width: 52, height: 52, child: CircularProgressIndicator(strokeWidth: 3)),
      const SizedBox(height: 26),
      Text('「$name」と接続しています…',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),
      _bigCaption('接続でき次第、画面認識（位置合わせ）へ自動で進みます。'),
      // select が届いていない（ACK不達で打ち切り）: 実機で確認済みの
      // macOSローカルネットワーク権限拒否への対処を案内する。
      if (_pairing.selectDeliveryStalled) ...[
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.errorContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.error.withValues(alpha: 0.4)),
          ),
          child: Row(children: [
            Icon(Icons.warning_amber_rounded, color: cs.error, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'スマホへの接続指示が届いていません。\n'
                'システム設定 > プライバシーとセキュリティ > ローカルネットワーク'
                ' で「Screact」を許可してから、もう一度お試しください。',
                style: TextStyle(fontSize: 12, height: 1.6, color: cs.onSurface),
              ),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 22),
      TextButton(onPressed: _cancelAutoPairing, child: const Text('キャンセル')),
    ]);
  }

  /// 応答ゼロのタイムアウト: 再試行＋手動接続への逃げ道。
  Widget _timeoutBody() {
    final cs = Theme.of(context).colorScheme;
    return _heroColumn([
      Icon(Icons.wifi_off, size: 52, color: cs.onSurfaceVariant),
      const SizedBox(height: 22),
      const Text('スマホが見つかりませんでした',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),
      _bigCaption('スマホがPCと同じWi-Fiにいるか・スマホ側で「画面認識開始」を'
          '押しているかを確認してください。\n'
          'テザリング等で自動検出が使えない場合は手動接続もできます。'),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: _startAutoPairing,
        style: FilledButton.styleFrom(minimumSize: const Size(220, 50)),
        icon: const Icon(Icons.refresh),
        label: const Text('もう一度探す'),
      ),
      const SizedBox(height: 10),
      TextButton(
        onPressed: () => setState(() => _devMode = true),
        child: const Text('手動で接続する（IP・6桁コード）'),
      ),
    ]);
  }

  /// 位置合わせ完了・操作可能（オーバーレイから戻った時の待機画面）。
  Widget _readyBody() {
    return _heroColumn([
      const Icon(Icons.gesture, size: 52, color: Color(0xFF2F9E63)),
      const SizedBox(height: 22),
      const Text('操作できます',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),
      _bigCaption('ピンチ（親指と人差し指をつまむ）でスライドに描画できます。\n'
          'オーバーレイの解除は macOS: ✏ / ⌘⇧O。'),
      const SizedBox(height: 24),
      if (_overlayAvailable)
        FilledButton.icon(
          onPressed: _enterOverlay,
          style: FilledButton.styleFrom(minimumSize: const Size(220, 50)),
          icon: const Icon(Icons.layers_outlined),
          label: const Text('オーバーレイ表示'),
        ),
      const SizedBox(height: 10),
      TextButton(
        onPressed: () async {
          await _stopServer();
          setState(() {});
        },
        child: const Text('最初からやり直す'),
      ),
    ]);
  }

  // ---------------------------------------------------------------------------
  // ヘッダー（ブランド＋状態バッジ）
  // ---------------------------------------------------------------------------

  PreferredSizeWidget _header() {
    final cs = Theme.of(context).colorScheme;
    final (color, icon, label) = _stepBadge();
    return AppBar(
      titleSpacing: 20,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [cs.primary, const Color(0xFF4C8DD8)],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.gesture, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          const Text('Screact',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(width: 12),
          Text('スライドを、指先で。',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: cs.onSurfaceVariant)),
        ],
      ),
      actions: [
        // 1ボタン画面へ戻る（このヘッダーは開発者向け画面でのみ使う）
        TextButton.icon(
          onPressed: _toggleDevMode,
          icon: const Icon(Icons.arrow_back, size: 14),
          label: const Text('かんたん画面へ戻る'),
        ),
        const SizedBox(width: 8),
        // 現在の状態バッジ（未接続→接続待ち→接続済み→位置合わせ中→操作可能）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: color)),
          ]),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'インクを消去',
          onPressed: _overlay.clear,
          icon: const Icon(Icons.cleaning_services_outlined),
        ),
        const SizedBox(width: 12),
      ],
    );
  }

  Widget _inWindowCalibration() {
    return Stack(
      children: [
        Positioned.fill(child: _calibrationTarget()),
        Positioned(
          left: 0,
          right: 0,
          bottom: 20,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xE6202632),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.center_focus_strong,
                      color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  const Text(
                    'キャリブレーション中: スマホのカメラでこの画面全体を映してください',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: _flow.cancel,
                    child: const Text('中止'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String get _displayIp => _wifiIp ?? '(IP取得不可)';

  // ---------------------------------------------------------------------------
  // 左パネル: ガイド付き4ステップ
  // ---------------------------------------------------------------------------

  Widget _controls(bool running) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _stepRow(
          index: 1,
          done: running,
          current: _step == 0,
          title: 'サーバを開始する',
          child: _serverButton(running),
        ),
        _stepRow(
          index: 2,
          done: _phoneConnected,
          current: _step == 1,
          title: 'スマホに接続情報を入力',
          child: _connectionInfoCard(running),
        ),
        _stepRow(
          index: 3,
          done: _engine.isCalibrated,
          current: _step == 2 || _step == 3,
          title: 'スマホを設置して位置合わせ',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _primaryButton(
                emphasized: _step == 2,
                onPressed: running && _phoneConnected && !_flow.showingTarget
                    ? _onPhonePlaced
                    : null,
                icon: Icons.smartphone,
                label: 'スマホ設置完了',
              ),
              const SizedBox(height: 6),
              _caption(_calibrationHelpText(running)),
            ],
          ),
        ),
        _stepRow(
          index: 4,
          done: false,
          current: _step == 4,
          title: 'スライドに重ねて操作',
          last: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _primaryButton(
                emphasized: _step == 4,
                onPressed: _overlayAvailable ? _enterOverlay : null,
                icon: Icons.layers_outlined,
                label: 'オーバーレイ表示',
              ),
              const SizedBox(height: 6),
              _caption(
                _overlayAvailable
                    ? 'スライドの最前面にインクとポインタだけを重ねます。'
                        '解除は macOS: メニューバーの ✏ / ⌘⇧O、Windows: Ctrl+Shift+O。'
                    : 'このビルドではオーバーレイ窓が未接続です'
                        '（macOS/Windowsネイティブが必要）。',
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _detailsSection(running),
      ],
    );
  }

  /// ステップ行: 番号サークル＋縦の接続線＋本文。
  /// done=チェック / current=強調 / それ以外=薄表示。
  Widget _stepRow({
    required int index,
    required bool done,
    required bool current,
    required String title,
    required Widget child,
    bool last = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final Color circleBg = done
        ? const Color(0xFF2F9E63)
        : current
            ? cs.primary
            : cs.surfaceContainerHighest;
    final Color circleFg =
        done || current ? Colors.white : cs.onSurfaceVariant;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: circleBg, shape: BoxShape.circle),
              child: done
                  ? const Icon(Icons.check, size: 15, color: Colors.white)
                  : Text('$index',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: circleFg)),
            ),
            if (!last)
              Expanded(
                child: Container(
                  width: 2,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: done
                        ? const Color(0xFF2F9E63).withValues(alpha: 0.45)
                        : cs.outlineVariant,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: current || done ? cs.onSurface : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  child,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 現在のステップだけ Filled で強調し、それ以外は tonal に落とす。
  Widget _primaryButton({
    required bool emphasized,
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
  }) {
    return emphasized
        ? FilledButton.icon(
            onPressed: onPressed, icon: Icon(icon, size: 18), label: Text(label))
        : FilledButton.tonalIcon(
            onPressed: onPressed, icon: Icon(icon, size: 18), label: Text(label));
  }

  Widget _serverButton(bool running) {
    return _primaryButton(
      emphasized: _step == 0,
      onPressed: running ? _stopServer : _startServer,
      icon: running ? Icons.stop_circle_outlined : Icons.play_arrow_rounded,
      label: running ? 'サーバ停止' : 'サーバ開始',
    );
  }

  Widget _caption(String text) {
    return Text(
      text,
      style: TextStyle(
          fontSize: 11,
          height: 1.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  /// Android側に打ち込む3点セット（Wi-Fi IP・ポート・6桁コード）。
  /// デモの主役カード: 大きく読める・その場でコピーできる。
  Widget _connectionInfoCard(bool running) {
    final cs = Theme.of(context).colorScheme;

    Widget copyButton(String? value) => IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 15,
          tooltip: 'コピー',
          onPressed: value == null
              ? null
              : () => Clipboard.setData(ClipboardData(text: value)),
          icon: const Icon(Icons.copy_rounded),
        );

    Widget row(String label, String? value, {double fontSize = 15}) {
      return Row(children: [
        SizedBox(
          width: 64,
          child: Text(label,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            // IPが長くても1行に収める（折返しさせない）
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SelectableText(
                value ?? '—',
                maxLines: 1,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Menlo',
                  color: value == null ? cs.onSurfaceVariant : cs.onSurface,
                ),
              ),
            ),
          ),
        ),
        copyButton(value),
      ]);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.smartphone, size: 14, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Androidに入力する接続情報',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: cs.primary)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              tooltip: 'Wi-Fi IPを再取得（テザリング切替時など）',
              onPressed: _refreshWifiIp,
              icon: const Icon(Icons.refresh),
            ),
          ]),
          const SizedBox(height: 6),
          row('IP (Wi-Fi)', _wifiIp),
          const SizedBox(height: 2),
          row('ポート', '$_port'),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(height: 1),
          ),
          Row(children: [
            SizedBox(
              width: 64,
              child: Text('6桁コード',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: SelectableText(
                running ? (_pairingCode ?? '—') : '——————',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'Menlo',
                  letterSpacing: 5,
                  color: running ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ),
            copyButton(running ? _pairingCode : null),
          ]),
          if (!running)
            Text('コードはサーバ開始時に発行されます',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 開発者向け詳細（折りたたみ）
  // ---------------------------------------------------------------------------

  Widget _detailsSection(bool running) {
    final cs = Theme.of(context).colorScheme;
    return Theme(
      // ExpansionTile の区切り線を消してカード風にまとめる。
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: Icon(Icons.tune, size: 18, color: cs.onSurfaceVariant),
          title: Text('開発者向け設定',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurfaceVariant)),
          children: [
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('6桁コードを照合する', style: TextStyle(fontSize: 12)),
              subtitle: Text('オフにするとコード無しでも接続できます',
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
              value: _enforcePairing,
              onChanged: (v) => setState(() {
                _enforcePairing = v;
                _server?.enforcePairing = v; // 稼働中サーバへ即反映
              }),
            ),
            _statusDetails(running),
            const SizedBox(height: 12),
            _sectionLabel('モード切替'),
            Wrap(spacing: 8, children: [
              OutlinedButton(
                onPressed: running && _phoneConnected
                    ? () => _server!.requestMode('calibration')
                    : null,
                child: const Text('位置合わせ'),
              ),
              OutlinedButton(
                onPressed: running && _phoneConnected
                    ? () => _server!.requestMode('tracking')
                    : null,
                child: const Text('トラッキング'),
              ),
            ]),
            const SizedBox(height: 4),
            _calibrationSettings(),
            _sectionLabel('動作確認（電話なし）'),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _toggleMock,
                icon: Icon(_mockTimer == null ? Icons.gesture : Icons.stop,
                    size: 18),
                label: Text(_mockTimer == null ? 'モックの手を流す' : 'モック停止'),
              ),
            ),
            const SizedBox(height: 6),
            _caption(
              'モックは実プロトコルと同じデータでパイプライン（位置合わせ→変換→平滑化→'
              'ジェスチャー認識→描画）を駆動します。ピンチで線が描かれます。',
            ),
            const SizedBox(height: 12),
            _connectionLogSection(),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }

  /// 接続の内部状態（セッション・フレーム数など）の一覧。
  Widget _statusDetails(bool running) {
    final cs = Theme.of(context).colorScheme;
    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            SizedBox(
                width: 96,
                child: Text(k,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant))),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600))),
          ]),
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          kv('待受', running ? 'ws://$_displayIp:$_port/ws/v1/input' : '停止中'),
          kv('セッション', _status.sessionId ?? '-'),
          kv('端末', _status.clientId ?? '-'),
          kv('モード',
              _status.mode == EngineMode.tracking ? 'tracking' : 'calibration'),
          kv('校正', _engine.isCalibrated ? '済' : '未'),
          kv('受信フレーム', '${_status.frames} (id ${_status.lastFrameId ?? "-"})'),
          kv('手検出', _status.handDetected ? 'あり' : 'なし'),
          kv('OS出力', _bridge.name),
          kv('状態', _stateLabel(running)),
          if (_status.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('※ ${_status.lastError}',
                  style: TextStyle(fontSize: 11, color: cs.error)),
            ),
        ],
      ),
    );
  }

  /// 接続ログ欄: Androidから繋がらない時に「どの段階まで届いているか」を
  /// その場で確認できる。全文コピー可・同じ内容をログファイルにも書く。
  Widget _connectionLogSection() {
    final entries = _connLog.entries;
    final recent =
        entries.length > 12 ? entries.sublist(entries.length - 12) : entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: _sectionLabel('接続ログ')),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 14,
            tooltip: '全ログをコピー',
            onPressed: entries.isEmpty
                ? null
                : () => Clipboard.setData(ClipboardData(text: _connLog.joined)),
            icon: const Icon(Icons.copy_rounded),
          ),
        ]),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2530),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            entries.isEmpty ? '(サーバ開始後にここへ接続の各段階が出ます)' : recent.join('\n'),
            style: const TextStyle(
                fontSize: 10, color: Color(0xFFB8F5C8), fontFamily: 'Menlo'),
          ),
        ),
        const SizedBox(height: 4),
        _caption(
          'ログファイル: ${_connLog.filePath ?? "(未作成)"}\n'
          '見方: http request が出ない=Androidの通信がMacまで届いていない'
          '（システム設定>プライバシーとセキュリティ>ローカルネットワークの許可・'
          'Nortonファイアウォールの受信許可・テザリングの子機間通信を確認）／'
          'ws upgraded まで出て hello が無い=アプリ層／hello_error=6桁コード不一致。',
        ),
      ],
    );
  }

  String _stateLabel(bool running) {
    if (!running) return '停止中';
    if (!_phoneConnected) return 'スマホの接続待ち';
    if (_flow.showingTarget) return 'キャリブレーション中';
    if (_engine.isCalibrated && _status.mode == EngineMode.tracking) {
      return '操作可能（ピンチで描画）';
    }
    return '位置合わせ待ち';
  }

  String _calibrationHelpText(bool running) {
    if (_flow.showingTarget) {
      return 'キャリブ画像を表示中。スマホのカメラで画面全体を映すと、'
          '四隅の検知が終わり次第自動で閉じます。'
          '中止は macOS: ✏ / ⌘⇧O、Windows: Ctrl+Shift+O。';
    }
    if (!running) {
      return 'サーバ開始後、スマホが接続されると押せるようになります。';
    }
    if (!_phoneConnected) {
      return 'スマホ未接続です。スマホ側で「PCへ接続」を完了すると押せます。';
    }
    return 'スマホを設置してから押してください。画面の最前面に四隅判定用の'
        'マーカー画像を全画面表示し、スマホが四隅を検知して送ってくると'
        '自動で閉じて操作可能になります。';
  }

  /// キャリブレーションの調整値パネル。値はエンジンと共有する
  /// CalibrationConfig をその場で書き換えて即時反映する。
  Widget _calibrationSettings() {
    Widget numField({
      required String label,
      required String initial,
      required void Function(double) onValue,
      double min = 0,
      double max = 45,
    }) {
      return SizedBox(
        width: 126,
        child: TextFormField(
          initialValue: initial,
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 12),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (t) {
            final v = double.tryParse(t);
            if (v != null && v >= min && v <= max) onValue(v);
          },
        ),
      );
    }

    String pct(double v) => (v * 100).toStringAsFixed(2);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('キャリブレーション設定',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _caption(
            '内側率(%) = 検知点が画面端からどれだけ内側にあるか。マーカー内側率の'
            '既定はキャリブ画像のマーカー中心位置（X 12.50 / Y 22.22）。'
            '四隅内側率は slide_corners 用の補正（既定 0）。',
          ),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          numField(
            label: 'マーカー内側率X %',
            initial: pct(_calibConfig.markerInsetX),
            onValue: (v) => _calibConfig.markerInsetX = v / 100,
          ),
          numField(
            label: 'マーカー内側率Y %',
            initial: pct(_calibConfig.markerInsetY),
            onValue: (v) => _calibConfig.markerInsetY = v / 100,
          ),
          numField(
            label: '四隅内側率X %',
            initial: pct(_calibConfig.cornerInsetX),
            onValue: (v) => _calibConfig.cornerInsetX = v / 100,
          ),
          numField(
            label: '四隅内側率Y %',
            initial: pct(_calibConfig.cornerInsetY),
            onValue: (v) => _calibConfig.cornerInsetY = v / 100,
          ),
          numField(
            label: '安定メッセージ数',
            initial: '${_calibConfig.requiredStableMessages}',
            min: 1,
            max: 30,
            onValue: (v) => _calibConfig.requiredStableMessages = v.round(),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          const Text('使用メッセージ', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 8),
          DropdownButton<CalibrationSource>(
            value: _calibConfig.source,
            isDense: true,
            style: TextStyle(
                fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
            items: const [
              DropdownMenuItem(
                  value: CalibrationSource.any, child: Text('両方')),
              DropdownMenuItem(
                  value: CalibrationSource.arucoOnly,
                  child: Text('ArUcoのみ')),
              DropdownMenuItem(
                  value: CalibrationSource.slideCornersOnly,
                  child: Text('四隅のみ')),
            ],
            onChanged: (v) =>
                setState(() => _calibConfig.source = v ?? _calibConfig.source),
          ),
        ]),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 右側: ライブプレビュー
  // ---------------------------------------------------------------------------

  Widget _preview() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: const Color(0xFFF4F6FA),
      child: Stack(
        children: [
          // 薄いドットグリッド（描画面であることを示す）
          const Positioned.fill(
            child: CustomPaint(painter: _DotGridPainter(Color(0xFFD6DDE8))),
          ),
          Positioned.fill(child: OverlayCanvas(model: _overlay)),
          // 空状態のヒント（描画が始まると消える）
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _overlay,
              builder: (_, __) {
                if (_overlay.strokes.isNotEmpty || _overlay.cursor != null) {
                  return const SizedBox.shrink();
                }
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.gesture,
                          size: 44, color: cs.outlineVariant),
                      const SizedBox(height: 10),
                      Text(
                        _step == 4
                            ? 'ピンチ（親指と人差し指をつまむ）で描画できます'
                            : '接続と位置合わせが完了すると、指先の動きがここに映ります',
                        style: TextStyle(
                            fontSize: 13, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          // 左上のバッジ
          Positioned(
            left: 14,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: _step == 4
                        ? const Color(0xFF2F9E63)
                        : cs.outline,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text('ライブプレビュー',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// プレビュー背景の薄いドットグリッド。
class _DotGridPainter extends CustomPainter {
  final Color color;
  const _DotGridPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 28.0;
    final paint = Paint()..color = color;
    for (var x = gap; x < size.width; x += gap) {
      for (var y = gap; y < size.height; y += gap) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter old) => old.color != color;
}
