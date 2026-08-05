import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/interaction_engine.dart';
import '../core/mock_hand.dart';
import '../core/pointer_state.dart';
import '../net/input_server.dart';
import '../platform/desktop_bridge.dart';
import 'overlay_canvas.dart';

/// 共通の操作面＋オーバーレイのライブプレビュー。macOSではこれ自体がアプリの
/// 出力（アプリ内描画）。Windowsでは同じ状態がネイティブのOS注入/透過窓を駆動する。
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _engine = InteractionEngine();
  final _overlay = OverlayModel();
  final _bridge = DesktopBridge.forPlatform();

  InputServer? _server;
  ServerStatus _status = const ServerStatus();
  List<String> _ips = const [];
  Timer? _mockTimer;
  int _mockI = 0;

  static const int _port = 8765;

  @override
  void initState() {
    super.initState();
    _loadIps();
  }

  @override
  void dispose() {
    _mockTimer?.cancel();
    _server?.stop();
    super.dispose();
  }

  Future<void> _loadIps() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      setState(() => _ips = [
            for (final i in ifs)
              for (final a in i.addresses)
                if (!a.isLoopback) a.address
          ]);
    } catch (_) {}
  }

  void _applyEvents(List<InteractionEvent> events) {
    for (final e in events) {
      _overlay.apply(e);
      _bridge.applyEvent(e);
    }
  }

  Future<void> _startServer() async {
    if (_server != null) return;
    final s = InputServer(
      engine: _engine,
      port: _port,
      onEvents: _applyEvents,
      onStatus: (st) => setState(() => _status = st),
    );
    await s.start();
    await _bridge.setOverlayVisible(true);
    setState(() => _server = s);
  }

  Future<void> _stopServer() async {
    await _server?.stop();
    await _bridge.setOverlayVisible(false);
    setState(() => _server = null);
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

  @override
  Widget build(BuildContext context) {
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
      body: Row(
        children: [
          SizedBox(width: 300, child: _controls(running)),
          const VerticalDivider(width: 1),
          Expanded(child: _preview()),
        ],
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
        kv('待受', running ? 'ws://<PC>:$_port/ws/v1/input' : '停止中'),
        kv('PCのIP', _ips.isEmpty ? '(取得中)' : _ips.join(', ')),
        kv('セッション', _status.sessionId ?? '-'),
        kv('端末', _status.clientId ?? '-'),
        kv('モード', _status.mode == EngineMode.tracking ? 'tracking' : 'calibration'),
        kv('校正', _engine.isCalibrated ? '済' : '未'),
        kv('受信フレーム', '${_status.frames} (id ${_status.lastFrameId ?? "-"})'),
        kv('手検出', _status.handDetected ? 'あり' : 'なし'),
        kv('OS出力', _bridge.name),
        if (_status.lastError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('※ ${_status.lastError}', style: const TextStyle(color: Colors.red)),
          ),
        const Divider(height: 24),
        const Text('モード切替', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          OutlinedButton(
            onPressed: running ? () => _server!.requestMode('calibration') : null,
            child: const Text('位置合わせ'),
          ),
          OutlinedButton(
            onPressed: running ? () => _server!.requestMode('tracking') : null,
            child: const Text('トラッキング'),
          ),
        ]),
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
