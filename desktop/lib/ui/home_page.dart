import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/calibration_config.dart';
import '../core/interaction_engine.dart';
import '../core/mock_hand.dart';
import '../core/pointer_state.dart';
import '../net/connection_log.dart';
import '../net/input_server.dart';
import '../net/wifi_ip.dart';
import '../platform/desktop_bridge.dart';
import '../platform/overlay_window.dart';
import 'calibration_flow.dart';
import 'overlay_canvas.dart';

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

  /// 検証用に --dart-define=YUBI_PORT=8766 等で差し替え可能（既定 8765）。
  int get _port =>
      widget.port ?? const int.fromEnvironment('YUBI_PORT', defaultValue: 8765);

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
    _refreshWifiIp();
    if (_autoFlow) scheduleMicrotask(_startServer);
  }

  @override
  void dispose() {
    _mockTimer?.cancel();
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
    setState(() => _status = st);
    // 四隅受信→位置合わせ成功なら、キャリブ画像を自動クローズ。
    _flow.onEngineEpoch(_engine.calibrationCount);
    // 検証用自動フロー: クライアント接続後に「スマホ設置完了」を自動実行。
    if (_autoFlow && !_autoFlowFired && st.clientId != null) {
      _autoFlowFired = true;
      _startCalibrationDisplay(intoOverlay: false);
    }
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('YubiBoard Desktop — THE WIN'),
        actions: [
          IconButton(
            tooltip: 'インクを消去',
            onPressed: _overlay.clear,
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
        ],
      ),
      body: Stack(
        children: [
          Row(
            children: [
              SizedBox(width: 300, child: _controls(running)),
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

  Widget _inWindowCalibration() {
    return Stack(
      children: [
        Positioned.fill(child: _calibrationTarget()),
        Positioned(
          left: 0,
          right: 0,
          bottom: 16,
          child: Center(
            child: Card(
              color: Colors.black87,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
        ),
      ],
    );
  }

  String get _displayIp => _wifiIp ?? '(IP取得不可)';

  /// Android側に打ち込む3点セット（Wi-Fi IP・ポート・6桁コード）を
  /// 一目で読める形でまとめたカード。値はコピー可能。
  Widget _connectionInfoCard(bool running) {
    Widget row(String label, String? value, {bool copyable = true}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(
              width: 88,
              child: Text(label,
                  style: const TextStyle(fontSize: 11, color: Colors.black54))),
          Expanded(
            child: SelectableText(
              value ?? '-',
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace'),
            ),
          ),
          if (copyable && value != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              tooltip: 'コピー',
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
              icon: const Icon(Icons.copy),
            ),
        ]),
      );
    }

    return Card(
      color: const Color(0xFFEDF2FA),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Expanded(
                child: Text('Androidに入力する接続情報',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: 'Wi-Fi IPを再取得（テザリング切替時など）',
                onPressed: _refreshWifiIp,
                icon: const Icon(Icons.refresh),
              ),
            ]),
            row('IP (Wi-Fi)', _wifiIp),
            row('ポート', '$_port'),
            row('6桁コード', running ? _pairingCode : null),
            if (!running)
              const Text('コードはサーバ開始時に発行されます',
                  style: TextStyle(fontSize: 10, color: Colors.black54)),
          ],
        ),
      ),
    );
  }

  Widget _controls(bool running) {
    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            SizedBox(width: 96, child: Text(k, style: const TextStyle(color: Colors.black54))),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
        );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('接続', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: running ? _stopServer : _startServer,
          icon: Icon(running ? Icons.stop : Icons.play_arrow),
          label: Text(running ? 'サーバ停止' : 'サーバ開始'),
        ),
        const SizedBox(height: 8),
        _connectionInfoCard(running),
        const SizedBox(height: 8),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('6桁コードを照合する', style: TextStyle(fontSize: 12)),
          subtitle: const Text('オフにするとコード無しでも接続できます',
              style: TextStyle(fontSize: 10, color: Colors.black54)),
          value: _enforcePairing,
          onChanged: (v) => setState(() {
            _enforcePairing = v;
            _server?.enforcePairing = v; // 稼働中サーバへ即反映
          }),
        ),
        kv('待受', running ? 'ws://$_displayIp:$_port/ws/v1/input' : '停止中'),
        kv('セッション', _status.sessionId ?? '-'),
        kv('端末', _status.clientId ?? '-'),
        kv('モード', _status.mode == EngineMode.tracking ? 'tracking' : 'calibration'),
        kv('校正', _engine.isCalibrated ? '済' : '未'),
        kv('受信フレーム', '${_status.frames} (id ${_status.lastFrameId ?? "-"})'),
        kv('手検出', _status.handDetected ? 'あり' : 'なし'),
        kv('OS出力', _bridge.name),
        kv('状態', _stateLabel(running)),
        if (_status.lastError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('※ ${_status.lastError}', style: const TextStyle(color: Colors.red)),
          ),
        const Divider(height: 24),
        const Text('スマホの設置とキャリブレーション',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        FilledButton.icon(
          onPressed: running && _phoneConnected && !_flow.showingTarget
              ? _onPhonePlaced
              : null,
          icon: const Icon(Icons.smartphone),
          label: const Text('スマホ設置完了'),
        ),
        const SizedBox(height: 8),
        Text(
          _calibrationHelpText(running),
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
        _calibrationSettings(),
        const Divider(height: 24),
        const Text('モード切替', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
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
        const Divider(height: 24),
        const Text('スライドに上乗せ', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        FilledButton.icon(
          onPressed: _overlayAvailable ? _enterOverlay : null,
          icon: const Icon(Icons.layers_outlined),
          label: const Text('オーバーレイ表示'),
        ),
        const SizedBox(height: 8),
        Text(
          _overlayAvailable
              ? 'ウィンドウを透過・最前面・クリック透過にして全画面へ広げ、'
                  'スライドの上にインクとポインタだけを重ねます。'
                  '解除は macOS: メニューバーの ✏ アイコン / ⌘⇧O、'
                  'Windows: Ctrl+Shift+O。'
              : 'このビルドではオーバーレイ窓が未接続です（macOS/Windowsネイティブが必要）。',
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
        const Divider(height: 24),
        const Text('動作確認（電話なし）', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        FilledButton.tonalIcon(
          onPressed: _toggleMock,
          icon: Icon(_mockTimer == null ? Icons.gesture : Icons.stop),
          label: Text(_mockTimer == null ? 'モックの手を流す' : 'モック停止'),
        ),
        const SizedBox(height: 8),
        const Text(
          'モックは実プロトコルと同じデータでパイプライン（位置合わせ→変換→平滑化→'
          'ジェスチャー認識→描画）を駆動します。ピンチで線が描かれます。',
          style: TextStyle(fontSize: 11, color: Colors.black54),
        ),
        const Divider(height: 24),
        _connectionLogSection(),
      ],
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
          const Expanded(
            child: Text('接続ログ', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 14,
            tooltip: '全ログをコピー',
            onPressed: entries.isEmpty
                ? null
                : () => Clipboard.setData(ClipboardData(text: _connLog.joined)),
            icon: const Icon(Icons.copy),
          ),
        ]),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2530),
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            entries.isEmpty ? '(サーバ開始後にここへ接続の各段階が出ます)' : recent.join('\n'),
            style: const TextStyle(
                fontSize: 10, color: Color(0xFFB8F5C8), fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'ログファイル: ${_connLog.filePath ?? "(未作成)"}\n'
          '見方: http request が出ない=Androidの通信がMacまで届いていない（ネットワーク層）／'
          'ws upgraded まで出て hello が無い=アプリ層／hello_error=6桁コード不一致。',
          style: const TextStyle(fontSize: 10, color: Colors.black54),
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
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            '内側率(%) = 検知点が画面端からどれだけ内側にあるか。マーカー内側率の'
            '既定はキャリブ画像のマーカー中心位置（X 12.50 / Y 22.22）。'
            '四隅内側率は slide_corners 用の補正（既定 0）。',
            style: TextStyle(fontSize: 11, color: Colors.black54),
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
            style: const TextStyle(fontSize: 12, color: Colors.black87),
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

  Widget _preview() {
    return Container(
      color: const Color(0xFFFAF7F0),
      child: Stack(
        children: [
          Positioned.fill(child: OverlayCanvas(model: _overlay)),
          const Positioned(
            left: 12,
            top: 8,
            child: Text('スライド面プレビュー（正規化0..1）',
                style: TextStyle(color: Colors.black38, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
