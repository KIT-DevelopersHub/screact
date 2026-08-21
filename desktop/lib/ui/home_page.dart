import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/calibration_config.dart';
import '../core/geom.dart';
import '../core/interaction_engine.dart';
import '../core/multi_hand_engine.dart';
import '../core/pointer_state.dart';
import '../protocol/input_frame.dart';
import '../net/connection_log.dart';
import '../net/discovery.dart';
import '../net/input_server.dart';
import '../net/pairing_payload.dart';
import '../net/wifi_ip.dart';
import '../platform/desktop_bridge.dart';
import '../platform/overlay_window.dart';
import 'calibration_flow.dart';
import 'calibration_target.dart';
import 'color_palette.dart';
import 'overlay_canvas.dart';
import 'pairing_controller.dart';
import 'pairing_qr_panel.dart';
import 'production_design.dart';

enum DesktopSection { connection, calibration, workspace, settings }

/// PC側の接続・位置合わせ・オーバーレイ・設定を、本番向けの4画面にまとめた操作面。
/// 通信・位置合わせ・透明オーバーレイの既存処理はそのまま共有する。
class HomePage extends StatefulWidget {
  /// テスト用のポート差し替え。nullならYUBI_PORT、未指定時は8765。
  final int? port;

  /// ペアリング状態を決定的に駆動するテスト用差し替え。
  /// 省略時は現在のIP・待受ポート・6桁コードでUDP offerを送る。
  final PairingController? pairingController;

  /// OS入力権限を決定的に駆動するテスト用差し替え。
  final DesktopBridge? desktopBridge;

  const HomePage({
    super.key,
    this.port,
    this.pairingController,
    this.desktopBridge,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int _environmentPort = int.fromEnvironment(
    'YUBI_PORT',
    defaultValue: 8765,
  );
  static const bool _autoFlow = bool.fromEnvironment('YUBI_AUTOFLOW');
  static const String _targetAsset = 'assets/calibration-target-1920x1080.png';

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _calibConfig = CalibrationConfig.forCalibrationTarget();
  late final _engine = MultiHandEngine(config: _calibConfig);
  final _overlay = OverlayModel();
  late final DesktopBridge _bridge;
  final _flow = CalibrationFlowController();
  final _connLog = ConnectionLog();

  late final TextEditingController _ipController;
  late final TextEditingController _portController;
  late final OverlayWindowController _overlayWin;
  late final PairingController _pairing;

  InputServer? _server;
  InputServer? _startingServerInstance;
  InputServer? _stoppingServerInstance;
  ServerStatus _status = const ServerStatus();
  DesktopSection _section = DesktopSection.connection;

  String? _wifiIp;
  String? _pairingCode;
  String? _serverError;
  late int _configuredPort;
  bool _enforcePairing = true;
  // 手の骨格（ランドマーク）をオーバーレイに描画するか。既定OFF・永続化する。
  bool _showSkeleton = false;
  bool _startingServer = false;
  // UDPで自動接続できない環境向けの手動接続情報（IP/ポート）を開いているか。
  // 既定は非表示で1ボタンに集中させ、リンク押下かUDPタイムアウト時だけ開く。
  bool _showManualConnect = false;
  bool _overlayOn = false;
  bool _enteringOverlay = false;
  String? _overlayError;
  int _overlayAttempt = 0;
  bool? _accessibilityTrusted;
  bool _checkingAccessibility = false;
  bool _autoFlowFired = false;
  bool _disposed = false;
  late double _draftSensitivity;
  late bool _draftSmoothing;
  late double _draftMarkerInsetX;
  late double _draftMarkerInsetY;
  late double _draftCornerInsetX;
  late double _draftCornerInsetY;
  late int _draftStableMessages;
  late CalibrationSource _draftCalibrationSource;
  bool _calibrationHadTracking = false;

  bool get _running => _server != null;
  bool get _phoneConnected => _status.clientId != null;
  bool get _overlayPlatformSupported => Platform.isMacOS || Platform.isWindows;
  bool get _overlayReady =>
      _overlayPlatformSupported &&
      _running &&
      _phoneConnected &&
      _engine.isCalibrated &&
      !_flow.showingTarget &&
      !_enteringOverlay;
  String get _overlayExitHint =>
      Platform.isWindows
          ? '操作画面を閉じるには Ctrl+Shift+O を押してください'
          : '操作画面を閉じるには、メニューバーの ✏ か ⌘⇧O を押してください';
  int get _port => _configuredPort;
  int get _displayPort => _server?.boundPort ?? _configuredPort;
  String get _displayIp => _wifiIp ?? '(IPを取得できません)';

  /// UDP 自動発見が使えない環境向けの QR フォールバック用 URI。
  /// LAN 直結情報（IP/ポート）と 6桁トークンが揃ったときだけ生成する
  /// （リレー構成は後段で relay/room を相乗せする）。認証は hello の
  /// pairingToken 1本のまま（QR は配達手段）。
  String? get _pairingUri {
    final token = _pairingCode;
    final host = _wifiIp;
    if (token == null || host == null || host.isEmpty) return null;
    return PairingPayload(
      pairingToken: token,
      lanHost: host,
      lanPort: _displayPort,
    ).toUri();
  }

  @override
  void initState() {
    super.initState();
    _configuredPort = widget.port ?? _environmentPort;
    _bridge = widget.desktopBridge ?? DesktopBridge.forPlatform();
    _ipController = TextEditingController();
    _portController = TextEditingController(text: '$_configuredPort');
    _draftSensitivity = _engine.recognitionSensitivity;
    _draftSmoothing = _engine.smoothingEnabled;
    _syncCalibrationDraftFromConfig();
    _loadShowSkeleton();

    _pairing =
        widget.pairingController ??
        PairingController(discoveryFactory: _createDiscovery);
    _pairing.addListener(_handlePairingChanged);

    _overlayWin = OverlayWindowController(
      onExited: _handleOverlayExited,
      onEntered: () {
        if (_disposed || !mounted) return;
        // ネイティブのホットキー突入は、進行中のprobe/enterより優先する。
        // これで古い非同期応答がDart側だけを通常画面へ戻す競合を防ぐ。
        _overlayAttempt++;
        if (!_running ||
            !_phoneConnected ||
            (!_engine.isCalibrated && !_flow.showingTarget)) {
          setState(() => _enteringOverlay = false);
          unawaited(_overlayWin.exit());
          return;
        }
        setState(() {
          _overlayOn = true;
          _enteringOverlay = false;
          _overlayError = null;
        });
      },
    );
    _flow.addListener(_handleFlowChanged);
    _connLog.addListener(_handleLogChanged);
    _connLog.init();
    _refreshWifiIp();
    if (Platform.isMacOS) {
      unawaited(_refreshAccessibility());
      // 起動直後にLAN宛て送信を1回行い、macOSの「ローカルネットワーク」権限
      // プロンプトを先出しする（許可が遅れると offer/select が黙って落ち、
      // 「PCは検索中・スマホは待ちのまま」になる）。_wifiIp は init時点で未取得
      // でも良い（その場合は 255.255.255.255 宛てに送られる）。ベストエフォート。
      unawaited(
        triggerLocalNetworkPrompt(ip: _wifiIp, onLog: _handleServerLog),
      );
    }
    if (_autoFlow) scheduleMicrotask(_startPairing);
  }

  @override
  void dispose() {
    _disposed = true;
    _overlayAttempt++;
    _pairing.removeListener(_handlePairingChanged);
    _pairing.dispose();
    _flow.removeListener(_handleFlowChanged);
    _connLog.removeListener(_handleLogChanged);
    final server =
        _server ?? _startingServerInstance ?? _stoppingServerInstance;
    _server = null;
    _startingServerInstance = null;
    _stoppingServerInstance = null;
    if (server == null) {
      _connLog.dispose();
    } else {
      unawaited(_shutdownServer(server).whenComplete(_connLog.dispose));
    }
    _ipController.dispose();
    _portController.dispose();
    _overlayWin.dispose();
    _flow.dispose();
    super.dispose();
  }

  void _handleFlowChanged() {
    if (!_disposed && mounted) setState(() {});
  }

  void _handleLogChanged() {
    if (!_disposed && mounted) setState(() {});
  }

  void _handlePairingChanged() {
    if (_disposed || !mounted) return;
    // UDP検索がタイムアウトしたら、手動接続の逃げ道（IP/ポート）を自動で開く。
    if (_pairing.phase == PairingPhase.timeout) _showManualConnect = true;
    setState(() {});
  }

  void _handleServerLog(String message) {
    if (!_disposed) _connLog.add(message);
  }

  void _handleServerEvents(List<InteractionEvent> events) {
    // MultiHandEngineが安定して保持する主トラックだけをOS入力へ流す。
    if (_disposed) return;
    for (final event in events) {
      _bridge.applyEvent(event);
    }
  }

  void _handleTrackEvents(Map<int, List<InteractionEvent>> byTrack) {
    // 各トラックのカーソル/描画をオーバーレイへ（最大2手を別色で表示）。
    if (!_disposed) _overlay.applyTrackEvents(byTrack);
  }

  void _handleFrame(InputFrame frame) {
    if (_disposed) return;
    // カメラ正規化の骨格を、カーソルと同じ画面座標へ写して重ねる。
    final byTrack = <int, List<Vec2>>{};
    for (final track in frame.tracks) {
      byTrack[track.trackId] = [
        for (final lm in track.landmarks) _engine.mapToSurface(lm.xy),
      ];
    }
    // 骨格表示がONのときだけ描画する。OFFなら空を渡して既存の骨格も消す。
    _overlay.showSkeletons(_showSkeleton ? byTrack : const {});
  }

  DesktopDiscovery _createDiscovery() {
    final code = _pairingCode;
    final wsPort = _server?.boundPort;
    if (code == null || wsPort == null) {
      throw StateError('接続情報の準備前に検索を開始しようとしました');
    }
    return DesktopDiscovery(
      token: code,
      wsPort: wsPort,
      ip: _wifiIp,
      onLog: _handleServerLog,
    );
  }

  void _handleOverlayExited() {
    if (_disposed || !mounted) return;
    _overlayAttempt++;
    if (_flow.showingTarget) {
      _cancelCalibration(overlayAlreadyExited: true);
      return;
    }
    setState(() {
      _overlayOn = false;
      _enteringOverlay = false;
      _section =
          _phoneConnected
              ? DesktopSection.workspace
              : DesktopSection.connection;
    });
  }

  Future<void> _refreshWifiIp() async {
    final ip = await currentWifiIp();
    if (_disposed || !mounted) return;
    setState(() {
      _wifiIp = ip;
      _ipController.text = ip ?? '';
    });
  }

  Future<void> _refreshAccessibility() async {
    if (_checkingAccessibility) return;
    _checkingAccessibility = true;
    final trusted = await _bridge.accessibilityTrusted();
    if (_disposed || !mounted) return;
    setState(() {
      _accessibilityTrusted = trusted;
      _checkingAccessibility = false;
    });
  }

  Future<void> _requestAccessibility() async {
    if (_checkingAccessibility) return;
    setState(() => _checkingAccessibility = true);
    await _bridge.requestAccessibility();
    final trusted = await _bridge.accessibilityTrusted();
    if (_disposed || !mounted) return;
    setState(() {
      _accessibilityTrusted = trusted;
      _checkingAccessibility = false;
    });
  }

  /// WebSocket待受の成功後だけUDP offerを広告する。
  /// 待受失敗時に検索だけが残る状態を作らない。
  Future<void> _startPairing() async {
    await _startServer();
    if (_disposed || !mounted || !_running || _phoneConnected) return;
    await _pairing.start();
  }

  Future<void> _retryPairing() async {
    if (_disposed || !mounted || !_running || _phoneConnected) return;
    setState(() => _serverError = null);
    await _pairing.start();
  }

  Future<void> _startServer() async {
    if (_server != null || _startingServer) return;
    setState(() {
      _startingServer = true;
      _serverError = null;
      _pairingCode = InputServer.generatePairingCode();
    });
    final server = InputServer(
      engine: _engine,
      port: _port,
      onEvents: _handleServerEvents,
      onTrackEvents: _handleTrackEvents,
      onFrame: _handleFrame,
      onStatus: _onServerStatus,
      onCalibrationInvalidated: () {
        if (_disposed || !mounted) return;
        unawaited(
          _startCalibrationDisplay(intoOverlay: _overlayPlatformSupported),
        );
      },
      pairingCode: _pairingCode,
      enforcePairing: _enforcePairing,
      acceptCalibrationMessages: false,
      onLog: _handleServerLog,
    );
    _startingServerInstance = server;
    try {
      await server.start();
      if (_disposed || !mounted) {
        await _shutdownServer(server);
        return;
      }
      await _bridge.setOverlayVisible(true);
      await _refreshWifiIp();
      if (_disposed || !mounted) {
        await _shutdownServer(server);
        return;
      }
      setState(() {
        _server = server;
        _startingServer = false;
      });
    } catch (error) {
      await _shutdownServer(server);
      if (_disposed || !mounted) return;
      setState(() {
        _startingServer = false;
        _pairingCode = null;
        _serverError =
            '接続を開始できませんでした。'
            'ポート番号が他のアプリで使われていないか確認して、'
            'もう一度お試しください。（詳細: $error）';
      });
    } finally {
      if (identical(_startingServerInstance, server)) {
        _startingServerInstance = null;
      }
    }
  }

  Future<void> _stopServer() async {
    // UDPタイマー/ソケットを先に止め、古いofferからの再接続を防ぐ。
    _pairing.cancel();
    final server = _server;
    if (server == null) return;
    _overlayAttempt++;
    unawaited(_overlayWin.exit());
    _stoppingServerInstance = server;
    setState(() {
      _server = null;
      _pairingCode = null;
      _status = const ServerStatus();
      _overlayOn = false;
      _enteringOverlay = false;
      _overlayError = null;
      _section = DesktopSection.connection;
    });
    await _shutdownServer(server);
    if (identical(_stoppingServerInstance, server)) {
      _stoppingServerInstance = null;
    }
    if (_disposed || !mounted) return;
    _cancelCalibration(sectionOverride: DesktopSection.connection);
  }

  Future<void> _shutdownServer(InputServer server) async {
    try {
      await server.stop();
    } catch (error) {
      _handleServerLog('サーバ停止エラー: $error');
    }
    try {
      await _bridge.setOverlayVisible(false);
    } catch (_) {
      // ネイティブ側が既に終了していても、Dart側の停止は完了扱いにする。
    }
  }

  void _onServerStatus(ServerStatus status) {
    if (_disposed || !mounted) return;
    final wasConnected = _phoneConnected;
    final wasCalibrating = _flow.showingTarget;
    final justConnected = !wasConnected && status.clientId != null;
    setState(() {
      _status = status;
      if (justConnected) {
        _section =
            _engine.isCalibrated
                ? DesktopSection.workspace
                : DesktopSection.calibration;
      }
    });
    if (justConnected) {
      // helloの認証完了を接続確定とし、UDP広告はここで終了する。
      _pairing.onConnected();
      if (_engine.isCalibrated && _overlayPlatformSupported) {
        // 既存の位置合わせを再利用できる場合は、白いアプリ内キャンバスを
        // 経由せず標準の透明オーバーレイへ直接入る。
        unawaited(_enterOverlay());
      } else if (!_engine.isCalibrated) {
        // 未校正なら手動ボタンを待たず、そのまま位置合わせ（ArUco表示）へ
        // 自動遷移する。接続後に「位置合わせ開始」を押させる2クリックを廃止。
        unawaited(
          _startCalibrationDisplay(intoOverlay: _overlayPlatformSupported),
        );
      }
    }
    _flow.onEngineEpoch(_engine.calibrationCount);
    if (wasCalibrating && !_flow.showingTarget && _engine.isCalibrated) {
      _server?.acceptCalibrationMessages = false;
      setState(() => _section = DesktopSection.workspace);
      if (!_overlayOn && _overlayPlatformSupported) {
        unawaited(_enterOverlay());
      }
    } else if (wasConnected && status.clientId == null) {
      // 実機側から切断された時も、全画面の位置合わせ／描画オーバーレイを
      // 必ず閉じる。これを行わないと透明な操作窓だけが残り、再検索ボタンへ
      // 戻れなくなる。
      if (_flow.showingTarget) {
        _cancelCalibration(sectionOverride: DesktopSection.connection);
      } else {
        _overlayAttempt++;
        setState(() {
          _overlayOn = false;
          _enteringOverlay = false;
          _overlayError = null;
          _section = DesktopSection.connection;
        });
        // enterOverlayの応答待ちも無効化するため、表示中かどうかに関係なく
        // exitを送る。遅れてenterが成功してもController側が再度閉じる。
        unawaited(_overlayWin.exit());
      }
    }
    if (_autoFlow && !_autoFlowFired && status.clientId != null) {
      _autoFlowFired = true;
      _startCalibrationDisplay(intoOverlay: _overlayPlatformSupported);
    }
  }

  Future<void> _startCalibrationDisplay({required bool intoOverlay}) async {
    final server = _server;
    if (server == null || !_phoneConnected) return;
    // 既に位置合わせターゲットを表示中なら二重起動しない
    // （接続時の自動遷移と旧AUTOFLOW/再入の競合を防ぐ）。
    if (_flow.showingTarget) return;
    setState(() {
      _calibrationHadTracking =
          _engine.isCalibrated && _engine.mode == EngineMode.tracking;
      _section = DesktopSection.calibration;
    });
    server.acceptCalibrationMessages = true;
    server.requestMode('calibration');
    _flow.start(_engine.calibrationCount);
    if (intoOverlay && !_overlayOn) await _enterOverlay();
  }

  Future<void> _onPhonePlaced() =>
      _startCalibrationDisplay(intoOverlay: _overlayPlatformSupported);

  Future<void> _enterOverlay() async {
    if (_disposed || !mounted || _enteringOverlay) return;
    if (!_running || !_phoneConnected) {
      setState(() => _overlayError = 'スマホを接続すると、操作画面を表示できます。');
      return;
    }
    if (!_engine.isCalibrated && !_flow.showingTarget) {
      setState(() {
        _section = DesktopSection.calibration;
        _overlayError = '先に「位置合わせ」を終わらせてください。';
      });
      return;
    }
    if (!_overlayPlatformSupported) {
      setState(() => _overlayError = 'この環境では透明オーバーレイを利用できません。');
      return;
    }

    final attempt = ++_overlayAttempt;
    if (!_flow.showingTarget) {
      setState(() {
        _section = DesktopSection.workspace;
        _enteringOverlay = true;
        _overlayError = null;
      });
    } else {
      setState(() {
        _enteringOverlay = true;
        _overlayError = null;
      });
    }
    final available = await _overlayWin.probe();
    final ok = available && await _overlayWin.enter();
    if (_disposed || !mounted || attempt != _overlayAttempt) {
      if (ok) await _overlayWin.exit();
      return;
    }
    if (!_running || !_phoneConnected) {
      if (ok) await _overlayWin.exit();
      setState(() {
        _enteringOverlay = false;
        _overlayOn = false;
        _section = DesktopSection.connection;
      });
      return;
    }
    setState(() {
      _enteringOverlay = false;
      _overlayOn = ok;
      _overlayError =
          ok
              ? null
              : available
              ? 'オーバーレイを表示できませんでした。macOSのフルスクリーンを解除して再試行してください。'
              : 'ネイティブ版で起動してください。Web版ではオーバーレイを利用できません。';
    });
  }

  void _cancelCalibration({
    bool overlayAlreadyExited = false,
    DesktopSection? sectionOverride,
  }) {
    if (_disposed || !mounted) return;
    final wasShowing = _flow.showingTarget;
    final restoreTracking = _calibrationHadTracking && _engine.isCalibrated;
    _overlayAttempt++;
    final shouldExitOverlay =
        (_overlayOn || _enteringOverlay) && !overlayAlreadyExited;
    _server?.acceptCalibrationMessages = false;
    setState(() {
      _overlayOn = false;
      _enteringOverlay = false;
      _section =
          sectionOverride ??
          (restoreTracking
              ? DesktopSection.workspace
              : DesktopSection.calibration);
      _calibrationHadTracking = false;
    });
    if (wasShowing) _flow.cancel();
    if (restoreTracking) {
      _engine.mode = EngineMode.tracking;
      if (_phoneConnected) _server?.requestMode('tracking');
    }
    if (shouldExitOverlay) unawaited(_overlayWin.exit());
  }

  /// キャリブ用 ArUco ターゲットの全画面表示。
  ///
  /// 従来は画像を [BoxFit.fill] で引き伸ばしていたため、16:9 以外のディスプレイでは
  /// マーカーが歪み・4隅が画面の角から離れてズレていた。現在は実際の表示領域から
  /// 各マーカーを正方形のまま4隅へ固定マージンで吸着配置し、算出したマーカー中心
  /// インセットを [CalibrationConfig] へ反映して、描画位置と位置合わせの座標系を
  /// アスペクト比に依存せず常に一致させる（リサイズにも追従）。
  Widget _calibrationTarget() {
    return CalibrationTargetView(
      key: const ValueKey('calibration-target-image'),
      assetName: _targetAsset,
      onInsets: (insetX, insetY) {
        _calibConfig
          ..markerInsetX = insetX
          ..markerInsetY = insetY;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_overlayOn) {
      if (_flow.showingTarget) {
        return Material(child: _calibrationTarget());
      }
      return Material(
        type: MaterialType.transparency,
        child: SizedBox.expand(child: OverlayCanvas(model: _overlay)),
      );
    }

    // ネイティブ全画面オーバーレイへ入れない環境でも、位置合わせ中は
    // ヘッダーを含むFlutter描画領域全体をターゲットへ差し替える。
    if (_flow.showingTarget) {
      return Material(child: _inWindowCalibration());
    }

    return Scaffold(
      key: _scaffoldKey,
      appBar: ProductionHeader(
        onMenu: () => _scaffoldKey.currentState?.openDrawer(),
        onSettings: () => _goTo(DesktopSection.settings),
      ),
      drawer: _navigationDrawer(),
      body: WatercolorBackground(child: _currentScreen()),
    );
  }

  void _goTo(DesktopSection section) {
    setState(() => _section = section);
    _scaffoldKey.currentState?.closeDrawer();
    if (section == DesktopSection.settings && Platform.isMacOS) {
      unawaited(_refreshAccessibility());
    }
  }

  Widget _currentScreen() {
    return switch (_section) {
      DesktopSection.connection => _connectionScreen(),
      DesktopSection.calibration => _calibrationScreen(),
      DesktopSection.workspace => _workspaceScreen(),
      DesktopSection.settings => _settingsScreen(),
    };
  }

  Widget _designCanvas({required Key key, required List<Widget> children}) {
    return SizedBox.expand(
      key: key,
      child: Center(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: 1600,
            height: 900,
            child: Stack(children: children),
          ),
        ),
      ),
    );
  }

  Widget _connectionScreen() {
    final code = _running ? _pairingCode : null;
    final pairingPhase = _pairing.phase;
    final canRestartSearch =
        _running &&
        !_phoneConnected &&
        (pairingPhase == PairingPhase.idle ||
            pairingPhase == PairingPhase.timeout);
    final retrying = pairingPhase == PairingPhase.timeout && canRestartSearch;
    final primaryLabel = switch (pairingPhase) {
      _ when _startingServer => '準備中…',
      PairingPhase.searching => '検索中…',
      PairingPhase.waitingConnect => '接続中…',
      PairingPhase.timeout when canRestartSearch => 'もう一度さがす',
      PairingPhase.idle when canRestartSearch => 'もう一度さがす',
      _ => 'はじめる',
    };
    final VoidCallback? primaryAction =
        _startingServer ||
                _phoneConnected ||
                pairingPhase == PairingPhase.searching ||
                pairingPhase == PairingPhase.waitingConnect
            ? null
            : canRestartSearch
            ? _retryPairing
            : _running
            ? null
            : _startPairing;
    return _designCanvas(
      key: const ValueKey('connection-page'),
      children: [
        const Positioned(
          top: 96,
          left: 0,
          right: 0,
          child: Text(
            'ようこそ',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 62,
              fontWeight: FontWeight.w800,
              color: Colors.black,
            ),
          ),
        ),
        // 既定ではIP/ポートを中央に常時表示しない（1ボタンに集中させる）。
        // UDPで自動接続できない環境向けに、控えめなリンクから手動接続情報を開ける。
        Positioned(
          top: 210,
          left: 330,
          width: 940,
          child: Column(
            children: [
              TextButton.icon(
                key: const ValueKey('manual-connect-toggle'),
                onPressed:
                    () => setState(
                      () => _showManualConnect = !_showManualConnect,
                    ),
                icon: Icon(
                  _showManualConnect
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 30,
                ),
                label: Text(
                  _showManualConnect ? '手動接続の情報を隠す' : 'つながらないときは手動で接続',
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF686666),
                  ),
                ),
              ),
              if (_showManualConnect) ...[
                const SizedBox(height: 8),
                ProductionPanel(
                  key: const ValueKey('connection-info'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 52,
                    vertical: 18,
                  ),
                  borderColor: const Color(0xFFB8B8B8),
                  child: Column(
                    children: [
                      // UDP不可環境向けフォールバック: QRは固定配置のボタン群に
                      // 隠れないよう、インライン表示ではなくダイアログで開く。
                      // 読み取れない場合の手入力用にIP/ポートも下に併記する。
                      if (_pairingUri != null) ...[
                        ProductionButton(
                          key: const ValueKey('show-qr'),
                          width: 520,
                          height: 64,
                          label: 'QRコードを表示',
                          icon: Icons.qr_code_2_rounded,
                          onPressed: _showPairingQr,
                          textStyle: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Divider(height: 24, thickness: 1.5),
                      ],
                      const Text(
                        'スマホのアプリに次の値を入力してください',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF686666),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _connectionValueRow('IPアドレス', _displayIp),
                      const Divider(height: 18, thickness: 1.5),
                      _connectionValueRow('IPポート', '$_displayPort'),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        Positioned(
          top: 472,
          left: 330,
          child: KeyedSubtree(
            key: retrying ? const ValueKey('pairing-retry') : null,
            child: ProductionButton(
              key: const ValueKey('server-toggle'),
              width: 430,
              height: 78,
              label: primaryLabel,
              icon: retrying ? Icons.refresh_rounded : Icons.edit_outlined,
              onPressed: primaryAction,
              textStyle: const TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        Positioned(
          top: 472,
          left: 840,
          child: ProductionButton(
            key: const ValueKey('server-stop'),
            width: 430,
            height: 78,
            label: '接続を止める',
            onPressed: _running ? _stopServer : null,
            textStyle: const TextStyle(
              fontSize: 38,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Positioned(
          top: 592,
          left: 250,
          right: 250,
          child: Column(
            children: [
              Text(
                _connectionStatusLabel(),
                key: const ValueKey('pairing-status'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  color: Colors.black,
                ),
              ),
              if (code != null) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      '6桁コード ',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SelectableText(
                      code,
                      key: const ValueKey('pairing-code'),
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 5,
                        fontFamily: 'monospace',
                      ),
                    ),
                    IconButton(
                      tooltip: '6桁コードをコピー',
                      onPressed:
                          () => Clipboard.setData(ClipboardData(text: code)),
                      icon: const Icon(Icons.copy_rounded),
                    ),
                  ],
                ),
              ],
              if (_serverError != null)
                Text(
                  _serverError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF9B3E3A),
                  ),
                ),
            ],
          ),
        ),
        const Positioned(
          bottom: -150,
          left: 0,
          right: 0,
          child: Center(
            child: CharacterMascot(
              key: ValueKey('connection-character'),
              size: 500,
              semanticLabel: 'YubiBoardキャラクター',
            ),
          ),
        ),
      ],
    );
  }

  Widget _connectionValueRow(String label, String value) {
    return SizedBox(
      height: 58,
      child: Row(
        children: [
          SizedBox(
            width: 310,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.w800,
                color: Color(0xFF555555),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 31,
                fontWeight: FontWeight.w700,
                color: Color(0xFF555555),
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _connectionStatusLabel() {
    if (_startingServer) return '接続を準備しています…';
    if (!_running) return '「はじめる」を押して接続をはじめてください';
    if (!_phoneConnected) {
      return switch (_pairing.phase) {
        PairingPhase.searching => 'スマホを検索しています…（スマホ側のアプリを開いてください）',
        PairingPhase.waitingConnect => 'スマホが見つかりました。接続しています…',
        PairingPhase.timeout =>
          'スマホが見つかりません。同じWi-Fiにつないで「もう一度さがす」を押してください'
              '${Platform.isMacOS ? '\n\nつながらないときは、システム設定 > プライバシーとセキュリティ > ローカルネットワーク でこのアプリの通信を許可してください。' : ''}',
        PairingPhase.idle => 'スマホからの接続を待っています…',
      };
    }
    if (_engine.isCalibrated && _status.mode == EngineMode.tracking) {
      return '準備完了！指でスライドを操作できます';
    }
    return 'スマホと接続しました。「位置合わせ」にすすんでください';
  }

  Widget _calibrationScreen() {
    return _designCanvas(
      key: const ValueKey('calibration-page'),
      children: [
        Positioned(
          left: 105,
          top: 18,
          width: 1390,
          height: 650,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFFD8D8D8),
              border: Border.all(color: const Color(0xFFB8B8B8), width: 2),
            ),
            child: _calibrationPreview(),
          ),
        ),
        Positioned(
          top: 680,
          left: 250,
          width: 1100,
          child: Text(
            '位置合わせが終わると、自動で操作画面に切り替わります。$_overlayExitHint',
            key: const ValueKey('overlay-exit-hint'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ProductionDesign.textColor,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Positioned(
          top: 720,
          left: 590,
          child: ProductionButton(
            key: const ValueKey('calibration-start'),
            width: 420,
            height: 82,
            label: '位置合わせをはじめる',
            onPressed:
                _running && _phoneConnected && !_flow.showingTarget
                    ? _onPhonePlaced
                    : null,
            textStyle: const TextStyle(
              fontSize: 38,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Positioned(
          top: 818,
          left: 470,
          width: 660,
          child: Text(
            _calibrationStatusLabel(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              color: Colors.black,
            ),
          ),
        ),
        const Positioned(
          right: 40,
          bottom: -10,
          child: CharacterMascot(
            key: ValueKey('calibration-character'),
            size: 195,
            semanticLabel: '検出を見守るキャラクター',
          ),
        ),
      ],
    );
  }

  /// 案内画面用の非検出プレビュー。本物のArUcoターゲットをここへ縮小表示すると、
  /// Androidが開始ボタンより先に読み取り、全画面前提と異なる座標で校正してしまう。
  Widget _calibrationPreview() {
    const markerSize = 132.0;
    const markerColor = Color(0xFF5A5A5A);
    Widget marker() => const ColoredBox(color: markerColor);
    return Semantics(
      key: const ValueKey('calibration-preview'),
      label: '位置合わせプレビュー',
      image: true,
      child: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Color(0xFFD8D8D8))),
          Positioned(
            left: 0,
            top: 0,
            width: markerSize,
            height: markerSize,
            child: marker(),
          ),
          Positioned(
            right: 0,
            top: 0,
            width: markerSize,
            height: markerSize,
            child: marker(),
          ),
          Positioned(
            left: 0,
            bottom: 0,
            width: markerSize,
            height: markerSize,
            child: marker(),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            width: markerSize,
            height: markerSize,
            child: marker(),
          ),
        ],
      ),
    );
  }

  String _calibrationStatusLabel() {
    if (!_running) return 'まず「接続」画面で接続をはじめてください';
    if (!_phoneConnected) return 'スマホの接続を待っています…';
    if (_flow.showingTarget) return '読み取り中…';
    if (_engine.isCalibrated) return '位置合わせ完了';
    return '準備ができました。「位置合わせをはじめる」を押してください';
  }

  Widget _workspaceScreen() {
    final title = switch ((_running, _phoneConnected, _engine.isCalibrated)) {
      (false, _, _) => 'まず接続をはじめてください',
      (true, false, _) => 'スマホの接続を待っています',
      (true, true, false) => '位置合わせが必要です',
      _ when _enteringOverlay => '操作画面を準備しています',
      _ => '操作画面は表示していません',
    };
    final description = switch ((
      _running,
      _phoneConnected,
      _engine.isCalibrated,
    )) {
      (false, _, _) => '「接続」画面で「はじめる」を押すと、スマホの接続をはじめます。',
      (true, false, _) => '接続すると、位置合わせ済みの場合はスライド上へ自動で表示します。',
      (true, true, false) => '位置合わせを終えると、スライド上へ自動で表示します。',
      _ when _enteringOverlay => '透明な操作画面へ切り替えています…',
      _ => '下のボタンで、透明な操作画面をもう一度表示できます。',
    };
    return _designCanvas(
      key: const ValueKey('workspace-page'),
      children: [
        const Positioned(
          top: 62,
          left: 0,
          right: 0,
          child: Text(
            'オーバーレイ操作',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: ProductionDesign.textColor,
              fontSize: 58,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        Positioned(
          left: 280,
          top: 180,
          width: 1040,
          child: ProductionPanel(
            key: const ValueKey('overlay-status-panel'),
            padding: const EdgeInsets.fromLTRB(54, 42, 54, 38),
            child: Column(
              children: [
                const Icon(
                  Icons.layers_outlined,
                  size: 78,
                  color: ProductionDesign.textColor,
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  key: const ValueKey('overlay-status-title'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: ProductionDesign.textColor,
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF686666),
                    fontSize: 23,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_overlayError != null) ...[
                  const SizedBox(height: 15),
                  Text(
                    _overlayError!,
                    key: const ValueKey('overlay-error'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF9B3E3A),
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
                const SizedBox(height: 30),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      '描画色',
                      style: TextStyle(
                        color: ProductionDesign.textColor,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 24),
                    ColorPalette(model: _overlay),
                    const SizedBox(width: 40),
                    const Text(
                      '骨格表示',
                      style: TextStyle(
                        color: ProductionDesign.textColor,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Switch(
                      key: const ValueKey('workspace-show-skeleton'),
                      value: _showSkeleton,
                      onChanged: _setShowSkeleton,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ProductionButton(
                      key: const ValueKey('overlay-enter'),
                      width: 420,
                      height: 72,
                      label: _enteringOverlay ? '表示しています…' : 'オーバーレイを再表示',
                      icon: Icons.layers_outlined,
                      onPressed: _overlayReady ? _enterOverlay : null,
                      textStyle: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 24),
                    ProductionButton(
                      key: const ValueKey('overlay-clear'),
                      width: 300,
                      height: 72,
                      label: '書いた線を消す',
                      icon: Icons.cleaning_services_outlined,
                      outlined: true,
                      onPressed: _overlay.clear,
                      textStyle: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 96,
          child: Text(
            _overlayExitHint,
            key: const ValueKey('overlay-exit-hint'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ProductionDesign.textColor,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const Positioned(
          right: 36,
          bottom: 16,
          child: CharacterMascot(
            key: ValueKey('workspace-character'),
            size: 210,
            semanticLabel: 'YubiBoardキャラクター',
          ),
        ),
      ],
    );
  }

  Widget _settingsScreen() {
    return _designCanvas(
      key: const ValueKey('settings-page'),
      children: [
        const Positioned(
          left: 90,
          top: 55,
          child: Row(
            children: [
              CharacterMascot(size: 150, semanticLabel: '設定キャラクター'),
              SizedBox(width: 20),
              Text(
                '設定',
                style: TextStyle(
                  fontSize: 70,
                  fontWeight: FontWeight.w900,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: 150,
          top: 78,
          child: ProductionButton(
            key: const ValueKey('settings-reset'),
            width: 290,
            height: 82,
            label: '初期化',
            outlined: true,
            onPressed: _resetSettings,
            textStyle: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Positioned(
          left: 270,
          top: 225,
          width: 1060,
          child: _settingsTextRow(
            'IPアドレス',
            _ipController,
            false,
            readOnly: true,
          ),
        ),
        Positioned(
          left: 270,
          top: 340,
          width: 1060,
          child: _settingsTextRow('ポート番号', _portController, true),
        ),
        Positioned(
          left: 255,
          top: 480,
          width: 1090,
          child: ProductionPanel(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 22),
            borderRadius: 14,
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '認識感度',
                        style: TextStyle(
                          fontSize: 38,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 500,
                      child: Slider(
                        key: const ValueKey('settings-sensitivity'),
                        value: _draftSensitivity,
                        onChanged:
                            (value) =>
                                setState(() => _draftSensitivity = value),
                      ),
                    ),
                    Container(
                      width: 110,
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1EBF5),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Text(
                        '${(_draftSensitivity * 100).round()}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(thickness: 1.5),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '手ブレ補正',
                        style: TextStyle(
                          fontSize: 38,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Text(
                      _draftSmoothing ? 'ON' : 'OFF',
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Transform.scale(
                      scale: 1.35,
                      child: Switch(
                        key: const ValueKey('settings-smoothing'),
                        value: _draftSmoothing,
                        onChanged:
                            (value) => setState(() => _draftSmoothing = value),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _showCalibrationSettings,
                      child: const Text('詳細設定', style: TextStyle(fontSize: 20)),
                    ),
                  ],
                ),
                if (Platform.isMacOS && _accessibilityTrusted == false) ...[
                  const Divider(thickness: 1.5),
                  Row(
                    key: const ValueKey('accessibility-warning'),
                    children: [
                      const Icon(
                        Icons.accessibility_new_rounded,
                        size: 40,
                        color: ProductionDesign.textColor,
                      ),
                      const SizedBox(width: 18),
                      const Expanded(
                        child: Text(
                          'PCを指で操作するには、macOSの'
                          'アクセシビリティ許可が必要です。',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 18),
                      ProductionButton(
                        key: const ValueKey('accessibility-request'),
                        width: 330,
                        height: 58,
                        label:
                            _checkingAccessibility ? '確認中...' : 'アクセシビリティを許可',
                        onPressed:
                            _checkingAccessibility
                                ? null
                                : _requestAccessibility,
                        textStyle: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        Positioned(
          top: 790,
          left: 665,
          child: ProductionButton(
            key: const ValueKey('settings-save'),
            width: 270,
            height: 76,
            label: '保存',
            onPressed: _saveSettings,
            textStyle: const TextStyle(
              fontSize: 37,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  Widget _settingsTextRow(
    String label,
    TextEditingController controller,
    bool numbersOnly, {
    bool readOnly = false,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 290,
          child: Text(
            label,
            style: const TextStyle(fontSize: 37, fontWeight: FontWeight.w900),
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            readOnly: readOnly,
            keyboardType:
                numbersOnly ? TextInputType.number : TextInputType.text,
            inputFormatters:
                numbersOnly
                    ? [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(5),
                    ]
                    : null,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              suffixIcon:
                  readOnly
                      ? IconButton(
                        tooltip: 'Wi-Fi IPを再取得',
                        onPressed: _refreshWifiIp,
                        icon: const Icon(Icons.refresh_rounded),
                      )
                      : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 18,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(
                  color: Color(0xFF575454),
                  width: 1.5,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 骨格表示トグルの永続化先（プラグイン不要のプレーンファイル。connection_log と同流儀）。
  File? _showSkeletonPrefsFile() {
    if (Platform.isWindows) {
      final appData =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) return null;
      return File('$appData\\yubiboard\\show_skeleton');
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    if (Platform.isMacOS) {
      return File('$home/Library/Application Support/yubiboard/show_skeleton');
    }
    final configHome = Platform.environment['XDG_CONFIG_HOME'];
    return File('${configHome ?? '$home/.config'}/yubiboard/show_skeleton');
  }

  void _loadShowSkeleton() {
    try {
      final f = _showSkeletonPrefsFile();
      if (f != null && f.existsSync()) {
        _showSkeleton = f.readAsStringSync().trim() == '1';
      }
    } catch (_) {
      // 読めなければ既定OFFのまま。
    }
  }

  void _setShowSkeleton(bool value) {
    setState(() => _showSkeleton = value);
    // OFFにした瞬間、既に描かれている骨格も消す。
    if (!value) _overlay.showSkeletons(const {});
    try {
      final f = _showSkeletonPrefsFile();
      if (f != null) {
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(value ? '1' : '0', flush: true);
      }
    } catch (_) {
      // 永続化に失敗しても致命ではない（次回起動は既定OFF）。
    }
  }

  void _saveSettings() {
    final parsedPort = int.tryParse(_portController.text);
    if (parsedPort == null || parsedPort < 1 || parsedPort > 65535) {
      _showMessage('ポート番号は1〜65535で入力してください');
      return;
    }
    setState(() {
      _configuredPort = parsedPort;
      _engine.recognitionSensitivity = _draftSensitivity;
      _engine.smoothingEnabled = _draftSmoothing;
      _calibConfig
        ..markerInsetX = _draftMarkerInsetX
        ..markerInsetY = _draftMarkerInsetY
        ..cornerInsetX = _draftCornerInsetX
        ..cornerInsetY = _draftCornerInsetY
        ..requiredStableMessages = _draftStableMessages
        ..source = _draftCalibrationSource;
    });
    _showMessage(_running ? '保存しました。ポートは次回接続から反映されます' : '保存しました');
  }

  void _resetSettings() {
    final defaults = CalibrationConfig.forCalibrationTarget();
    setState(() {
      _configuredPort = widget.port ?? _environmentPort;
      _ipController.text = _wifiIp ?? '';
      _portController.text = '$_configuredPort';
      _draftSensitivity = 0.5;
      _draftSmoothing = true;
      _engine.recognitionSensitivity = _draftSensitivity;
      _engine.smoothingEnabled = _draftSmoothing;
      _calibConfig
        ..markerInsetX = defaults.markerInsetX
        ..markerInsetY = defaults.markerInsetY
        ..cornerInsetX = defaults.cornerInsetX
        ..cornerInsetY = defaults.cornerInsetY
        ..requiredStableMessages = defaults.requiredStableMessages
        ..source = defaults.source;
      _syncCalibrationDraftFromConfig();
    });
    _showMessage('設定を初期化しました');
  }

  void _syncCalibrationDraftFromConfig() {
    _draftMarkerInsetX = _calibConfig.markerInsetX;
    _draftMarkerInsetY = _calibConfig.markerInsetY;
    _draftCornerInsetX = _calibConfig.cornerInsetX;
    _draftCornerInsetY = _calibConfig.cornerInsetY;
    _draftStableMessages = _calibConfig.requiredStableMessages;
    _draftCalibrationSource = _calibConfig.source;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _navigationDrawer() {
    return Drawer(
      width: 330,
      child: WatercolorBackground(
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 28, 24, 20),
                  child: Row(
                    children: [
                      CharacterMascot(size: 76),
                      SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'YubiBoard',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _drawerItem(
                  key: const ValueKey('nav-connection'),
                  icon: Icons.link_rounded,
                  label: '接続',
                  section: DesktopSection.connection,
                ),
                _drawerItem(
                  key: const ValueKey('nav-calibration'),
                  icon: Icons.center_focus_strong_rounded,
                  label: '位置合わせ',
                  section: DesktopSection.calibration,
                ),
                _drawerItem(
                  key: const ValueKey('nav-workspace'),
                  icon: Icons.layers_outlined,
                  label: 'オーバーレイ',
                  section: DesktopSection.workspace,
                ),
                _drawerItem(
                  key: const ValueKey('nav-settings'),
                  icon: Icons.settings_outlined,
                  label: '設定',
                  section: DesktopSection.settings,
                ),
                const Divider(height: 28),
                ListTile(
                  key: const ValueKey('nav-diagnostics'),
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text(
                    '接続情報',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  onTap: () {
                    _scaffoldKey.currentState?.closeDrawer();
                    _showDiagnostics();
                  },
                ),
                ListTile(
                  key: const ValueKey('nav-overlay-enter'),
                  enabled: _overlayReady,
                  leading: const Icon(Icons.layers_outlined),
                  title: const Text(
                    'オーバーレイを再表示',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  onTap:
                      _overlayReady
                          ? () {
                            _scaffoldKey.currentState?.closeDrawer();
                            _enterOverlay();
                          }
                          : null,
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _connectionStatusLabel(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF686666),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _drawerItem({
    required Key key,
    required IconData icon,
    required String label,
    required DesktopSection section,
  }) {
    return ListTile(
      key: key,
      selected: _section == section,
      selectedTileColor: ProductionDesign.headerColor.withValues(alpha: 0.55),
      leading: Icon(icon),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      onTap: () => _goTo(section),
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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '位置合わせ中: スマホのカメラで画面全体を映してください',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  const SizedBox(width: 14),
                  TextButton(
                    key: const ValueKey('calibration-cancel'),
                    onPressed: _cancelCalibration,
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

  /// QRを固定ボタン群に隠さないよう、ダイアログで前面に表示する。
  /// スマホのカメラで `screact://pair?...` を読み取らせ、読めない場合の
  /// 手入力用に IP/ポートも併記する（認証は hello の pairingToken 1本のまま）。
  Future<void> _showPairingQr() async {
    final uri = _pairingUri;
    if (uri == null) return;
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('QRコードで接続'),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PairingQrPanel(uri: uri),
                    const Divider(height: 24, thickness: 1.5),
                    const Text(
                      '読み取れないときは、次の値を手で入力してください',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    _diagnosticRow('IPアドレス', _displayIp),
                    _diagnosticRow('ポート', '$_displayPort'),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('閉じる'),
              ),
            ],
          ),
    );
  }

  Future<void> _showDiagnostics() async {
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) {
              final entries = _connLog.entries;
              final recent =
                  entries.length > 12
                      ? entries.sublist(entries.length - 12)
                      : entries;
              return AlertDialog(
                title: const Text('接続情報'),
                content: SizedBox(
                  width: 680,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _diagnosticRow('IPアドレス', _displayIp),
                        _diagnosticRow('ポート', '$_displayPort'),
                        _diagnosticRow('6桁コード', _pairingCode ?? '-'),
                        _diagnosticRow('端末', _status.clientId ?? '-'),
                        _diagnosticRow('受信フレーム', '${_status.frames}'),
                        _diagnosticRow(
                          '手検出',
                          _status.handDetected ? 'あり' : 'なし',
                        ),
                        _diagnosticRow('OS出力', _bridge.name),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('6桁コードを照合する'),
                          value: _enforcePairing,
                          onChanged: (value) {
                            setState(() {
                              _enforcePairing = value;
                              _server?.enforcePairing = value;
                            });
                            setDialogState(() {});
                          },
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('骨格を表示'),
                          subtitle: const Text('手のランドマーク（骨格）をオーバーレイに重ねる'),
                          value: _showSkeleton,
                          onChanged: (value) {
                            _setShowSkeleton(value);
                            setDialogState(() {});
                          },
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed:
                                  _running && _phoneConnected
                                      ? () {
                                        Navigator.of(dialogContext).pop();
                                        _startCalibrationDisplay(
                                          intoOverlay:
                                              _overlayPlatformSupported,
                                        );
                                      }
                                      : null,
                              child: const Text('位置合わせ'),
                            ),
                            OutlinedButton(
                              onPressed:
                                  _running && _phoneConnected
                                      ? () => _server?.requestMode('tracking')
                                      : null,
                              child: const Text('トラッキング'),
                            ),
                            OutlinedButton.icon(
                              onPressed:
                                  _overlayReady
                                      ? () {
                                        Navigator.of(dialogContext).pop();
                                        _enterOverlay();
                                      }
                                      : null,
                              icon: const Icon(Icons.layers_outlined),
                              label: const Text('オーバーレイ表示'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _overlay.clear,
                              icon: const Icon(
                                Icons.cleaning_services_outlined,
                              ),
                              label: const Text('書いた線を消す'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '接続ログ',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                            IconButton(
                              tooltip: 'ログをコピー',
                              onPressed:
                                  entries.isEmpty
                                      ? null
                                      : () => Clipboard.setData(
                                        ClipboardData(text: _connLog.joined),
                                      ),
                              icon: const Icon(Icons.copy),
                            ),
                          ],
                        ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E2530),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SelectableText(
                            entries.isEmpty
                                ? '(接続を開始するとログが表示されます)'
                                : recent.join('\n'),
                            style: const TextStyle(
                              color: Color(0xFFB8F5C8),
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('閉じる'),
                  ),
                ],
              );
            },
          ),
    );
  }

  Widget _diagnosticRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: const TextStyle(color: Colors.black54)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCalibrationSettings() async {
    String pct(double value) => (value * 100).toStringAsFixed(2);
    var markerInsetX = _draftMarkerInsetX;
    var markerInsetY = _draftMarkerInsetY;
    var cornerInsetX = _draftCornerInsetX;
    var cornerInsetY = _draftCornerInsetY;
    var stableMessages = _draftStableMessages;
    var source = _draftCalibrationSource;
    final applied = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('位置合わせ詳細設定'),
                  content: SizedBox(
                    width: 580,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              _calibrationNumberField(
                                label: 'マーカー内側率X %',
                                initial: pct(markerInsetX),
                                onValue: (value) => markerInsetX = value / 100,
                              ),
                              _calibrationNumberField(
                                label: 'マーカー内側率Y %',
                                initial: pct(markerInsetY),
                                onValue: (value) => markerInsetY = value / 100,
                              ),
                              _calibrationNumberField(
                                label: '四隅内側率X %',
                                initial: pct(cornerInsetX),
                                onValue: (value) => cornerInsetX = value / 100,
                              ),
                              _calibrationNumberField(
                                label: '四隅内側率Y %',
                                initial: pct(cornerInsetY),
                                onValue: (value) => cornerInsetY = value / 100,
                              ),
                              _calibrationNumberField(
                                label: '安定メッセージ数',
                                initial: '$stableMessages',
                                min: 1,
                                max: 30,
                                onValue:
                                    (value) => stableMessages = value.round(),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              const Text(
                                '使用メッセージ',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(width: 16),
                              DropdownButton<CalibrationSource>(
                                value: source,
                                items: const [
                                  DropdownMenuItem(
                                    value: CalibrationSource.any,
                                    child: Text('両方'),
                                  ),
                                  DropdownMenuItem(
                                    value: CalibrationSource.arucoOnly,
                                    child: Text('ArUcoのみ'),
                                  ),
                                  DropdownMenuItem(
                                    value: CalibrationSource.slideCornersOnly,
                                    child: Text('四隅のみ'),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setDialogState(() => source = value);
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: const Text('キャンセル'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      child: const Text('設定に反映'),
                    ),
                  ],
                ),
          ),
    );
    if (applied != true || _disposed || !mounted) return;
    setState(() {
      _draftMarkerInsetX = markerInsetX;
      _draftMarkerInsetY = markerInsetY;
      _draftCornerInsetX = cornerInsetX;
      _draftCornerInsetY = cornerInsetY;
      _draftStableMessages = stableMessages;
      _draftCalibrationSource = source;
    });
  }

  Widget _calibrationNumberField({
    required String label,
    required String initial,
    required void Function(double) onValue,
    double min = 0,
    double max = 45,
  }) {
    return SizedBox(
      width: 250,
      child: TextFormField(
        initialValue: initial,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        onChanged: (text) {
          final value = double.tryParse(text);
          if (value != null && value >= min && value <= max) onValue(value);
        },
      ),
    );
  }
}
