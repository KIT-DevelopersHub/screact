import 'calibration_config.dart';
import 'geom.dart';
import 'homography.dart';
import 'one_euro.dart';
import 'gesture_recognizer.dart';
import '../protocol/messages.dart';

/// チーム確定仕様のジェスチャー分岐:
/// - ポインタ移動/描画/ドラッグ = 人差し指先端（pointerMove/pressDown/pressMove/pressUp）
/// - スクロール = 二本指の移動量（scroll）
/// - ピンチズーム = 二本指間距離の変化（未実装。追加時は zoom kind を足し、
///   onFrame の scrolling 分岐と同列に距離変化の分岐を挿す）
enum InteractionKind {
  pointerMove,
  pressDown, // ピンチ押下（描画/クリック/ドラッグの開始）
  pressMove, // 押下中の移動（ドラッグ/描画）
  pressUp, // 押下解除
  click, // 短いピンチ＝クリック
  scroll,
  release, // トラッキング喪失などで安全解除
}

/// エンジンが1フレームで出す操作イベント。screen は画面正規化(0..1)。
class InteractionEvent {
  final InteractionKind kind;
  final Vec2 screen;
  final Vec2 delta; // scroll 用
  const InteractionEvent(
    this.kind,
    this.screen, {
    this.delta = const Vec2(0, 0),
  });
}

enum EngineMode { calibration, tracking }

/// 受信フレーム→操作イベントへの変換主体（要件の「PCが処理主体」）。
/// ホモグラフィ位置合わせ→座標変換→平滑化→ジェスチャー認識→操作、を担う。
class InteractionEngine {
  final GestureRecognizer _rec;
  final Vec2Filter _screenFilter;
  bool _smoothingEnabled;

  /// キャリブレーションの調整値（インセット補正・安定判定・受付ソース）。
  /// UIの設定パネルから同一インスタンスを書き換えて反映する。
  final CalibrationConfig config;

  Homography? _homography;
  EngineMode mode;

  /// 位置合わせが成功した回数（エポック）。UI はこの増加で
  /// 「四隅受信→キャリブ画像の自動クローズ」を検知する。
  int _calibrationCount = 0;
  int get calibrationCount => _calibrationCount;

  // 連続安定メッセージのカウンタ（ソース別）。
  int _arucoStreak = 0;
  int _cornersStreak = 0;

  // ピンチ状態機械
  bool _pressed = false;
  Vec2? _pressStart;
  int _pressStartMs = 0;
  Vec2? _lastScreen;
  // スクロール状態
  Vec2? _lastScrollAnchor;

  static const int _clickMaxMs = 260;
  static const double _clickMaxMove = 0.02;

  InteractionEngine({
    GestureRecognizer? recognizer,
    this.mode = EngineMode.calibration,
    CalibrationConfig? config,
    bool smoothingEnabled = true,
  }) : _rec = recognizer ?? GestureRecognizer(),
       _screenFilter = Vec2Filter(),
       _smoothingEnabled = smoothingEnabled,
       config = config ?? CalibrationConfig();

  bool get isCalibrated => _homography != null;

  /// ピンチ認識の感度（0..1）。既定0.5は従来の比率ON=0.40/OFF=0.60。
  double get recognitionSensitivity => _rec.recognitionSensitivity;

  set recognitionSensitivity(double value) {
    if (value == _rec.recognitionSensitivity) return;
    _rec.recognitionSensitivity = value;
    _resetRuntimeFilters();
  }

  /// falseでは画面座標をOne-Euroフィルタに通さず、そのまま操作へ使う。
  bool get smoothingEnabled => _smoothingEnabled;

  set smoothingEnabled(bool value) {
    if (value == _smoothingEnabled) return;
    _smoothingEnabled = value;
    _resetRuntimeFilters();
  }

  /// 設定変更前のヒステリシスや平滑化履歴を次フレームへ持ち越さない。
  /// 押下状態自体は保持し、次フレームの新しい設定による判定で安全に
  /// pressMove / pressUpへ遷移させる。
  void _resetRuntimeFilters() {
    _rec.reset();
    _screenFilter.reset();
    _lastScrollAnchor = null;
  }

  /// ArUcoマーカーからホモグラフィを作成（位置合わせ）。
  /// ID 10..13→画面四隅の対応付けとマーカーインセット外挿は config に従う。
  /// config.requiredStableMessages 回連続で妥当なら確定し tracking へ。
  bool calibrate(CalibrationMarkers markers) {
    if (!config.acceptsAruco) return false;
    final h = Homography.fromMarkers(
      markers.markers,
      insetX: config.markerInsetX,
      insetY: config.markerInsetY,
    );
    if (h == null) {
      _arucoStreak = 0;
      return false;
    }
    if (++_arucoStreak < config.requiredStableMessages) return false;
    _applyHomography(h);
    return true;
  }

  /// スマホが検出したスライド四隅（順不同・カメラ正規化）から位置合わせ。
  /// 斜め・下から等の歪んだ台形でも射影変換で正確に写す。
  /// 検知点が画面端より内側の場合は config の四隅インセットで外挿する。
  bool calibrateFromCorners(List<Vec2> corners) {
    if (!config.acceptsSlideCorners) return false;
    final h = Homography.fromCorners(
      corners,
      insetX: config.cornerInsetX,
      insetY: config.cornerInsetY,
    );
    if (h == null) {
      _cornersStreak = 0;
      return false;
    }
    if (++_cornersStreak < config.requiredStableMessages) return false;
    _applyHomography(h);
    return true;
  }

  void _applyHomography(Homography h) {
    _homography = h;
    mode = EngineMode.tracking;
    _calibrationCount++;
    _arucoStreak = 0;
    _cornersStreak = 0;
  }

  /// 未校正時は恒等（カメラ座標をそのまま画面座標とみなす）。
  Vec2 _toScreen(Vec2 cam) {
    final s = _homography?.map(cam) ?? cam;
    return Vec2(s.x.clamp(0.0, 1.0), s.y.clamp(0.0, 1.0));
  }

  /// 1フレーム処理。安全解除も含め、UI/OSへ渡すイベント列を返す。
  List<InteractionEvent> onFrame(HandFrame f) {
    if (mode != EngineMode.tracking) return const [];
    if (!f.detected) return _releaseAll();
    final pose = _rec.recognize(f);
    if (pose == null || !f.isValid) return _releaseAll();

    final t = f.capturedAtMonotonicMs;
    final rawScreen = _toScreen(pose.indexTip);
    final screen =
        _smoothingEnabled ? _screenFilter.filter(rawScreen, t) : rawScreen;
    final events = <InteractionEvent>[];

    // スクロール: 人差し指＋中指を立てて動かす（ピンチしていない時）。
    final scrolling =
        !pose.pinching &&
        pose.indexUp &&
        pose.middleUp &&
        pose.extendedFingers >= 2;
    if (scrolling) {
      if (_pressed) events.addAll(_endPress(screen));
      if (_lastScrollAnchor != null) {
        events.add(
          InteractionEvent(
            InteractionKind.scroll,
            screen,
            delta: screen - _lastScrollAnchor!,
          ),
        );
      }
      _lastScrollAnchor = screen;
      _lastScreen = screen;
      return events;
    }
    _lastScrollAnchor = null;

    if (pose.pinching) {
      if (!_pressed) {
        _pressed = true;
        _pressStart = screen;
        _pressStartMs = t;
        events.add(InteractionEvent(InteractionKind.pressDown, screen));
      } else {
        events.add(InteractionEvent(InteractionKind.pressMove, screen));
      }
    } else {
      if (_pressed) {
        events.addAll(_endPress(screen, tMs: t));
      } else {
        events.add(InteractionEvent(InteractionKind.pointerMove, screen));
      }
    }
    _lastScreen = screen;
    return events;
  }

  List<InteractionEvent> _endPress(Vec2 screen, {int? tMs}) {
    final events = <InteractionEvent>[];
    final dur = (tMs ?? _pressStartMs) - _pressStartMs;
    final moved = (_pressStart ?? screen).distanceTo(screen);
    if (dur <= _clickMaxMs && moved <= _clickMaxMove) {
      events.add(InteractionEvent(InteractionKind.click, screen));
    }
    events.add(InteractionEvent(InteractionKind.pressUp, screen));
    _pressed = false;
    _pressStart = null;
    return events;
  }

  List<InteractionEvent> _releaseAll() {
    final events = <InteractionEvent>[];
    if (_pressed) {
      events.add(
        InteractionEvent(
          InteractionKind.pressUp,
          _lastScreen ?? const Vec2(0, 0),
        ),
      );
    }
    events.add(
      InteractionEvent(
        InteractionKind.release,
        _lastScreen ?? const Vec2(0, 0),
      ),
    );
    _pressed = false;
    _pressStart = null;
    _lastScrollAnchor = null;
    _screenFilter.reset();
    _rec.reset();
    return events;
  }
}
