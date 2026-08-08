import 'calibration_config.dart';
import 'geom.dart';
import 'homography.dart';
import 'one_euro.dart';
import 'gesture_recognizer.dart';
import '../protocol/messages.dart';

/// チーム確定仕様のジェスチャー分岐:
/// - ポインタ移動 = 人差し指先端（pointerMove）※OSカーソルを動かす
/// - インク描画 = 人差し指と中指をくっつける（drawDown/drawMove/drawUp）
///   筆点は人差し指先端と中指先端の「中間点」。オーバーレイのインク専用。
/// - OSクリック/ドラッグ = 親指と人差し指のピンチ（pressDown/pressMove/pressUp/click）
///   OSの実マウスイベントとして注入する。
/// - スクロール = 二本指を立てて動かす（scroll）
enum InteractionKind {
  pointerMove,
  drawDown, // 2本指くっつき開始（インク描画の開始）
  drawMove, // くっつき中の移動（インク線）
  drawUp, // くっつき解除（インク確定）
  pressDown, // ピンチ押下（OSクリック/ドラッグの開始）
  pressMove, // 押下中の移動（OSドラッグ）
  pressUp, // 押下解除
  click, // 短いピンチ＝クリック（オーバーレイ表示用・OS側は down/up で表現）
  scroll,
  release, // トラッキング喪失などで安全解除
}

/// エンジンが1フレームで出す操作イベント。screen は画面正規化(0..1)。
class InteractionEvent {
  final InteractionKind kind;
  final Vec2 screen;
  final Vec2 delta; // scroll 用
  const InteractionEvent(this.kind, this.screen, {this.delta = const Vec2(0, 0)});
}

enum EngineMode { calibration, tracking }

/// 受信フレーム→操作イベントへの変換主体（要件の「PCが処理主体」）。
/// ホモグラフィ位置合わせ→座標変換→平滑化→ジェスチャー認識→操作、を担う。
class InteractionEngine {
  final GestureRecognizer _rec;
  final Vec2Filter _screenFilter;

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

  // ピンチ状態機械（OSクリック/ドラッグ）
  bool _pressed = false;
  Vec2? _pressStart;
  int _pressStartMs = 0;
  // 2本指くっつき状態機械（インク描画）
  bool _drawing = false;
  Vec2? _lastScreen;
  // スクロール状態
  Vec2? _lastScrollAnchor;

  static const int _clickMaxMs = 260;
  static const double _clickMaxMove = 0.02;

  InteractionEngine({
    GestureRecognizer? recognizer,
    this.mode = EngineMode.calibration,
    CalibrationConfig? config,
  })  : _rec = recognizer ?? GestureRecognizer(),
        _screenFilter = Vec2Filter(),
        config = config ?? CalibrationConfig();

  bool get isCalibrated => _homography != null;

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
  ///
  /// 優先順位（相互排他）:
  ///   1. スクロール（2本指を立てて移動・くっつき/ピンチなし）
  ///   2. インク描画（人差し指＋中指がくっつく・筆点は中間点）
  ///   3. OSクリック/ドラッグ（親指＋人差し指のピンチ）
  ///   4. ポインタ移動（人差し指先端）
  List<InteractionEvent> onFrame(HandFrame f) {
    if (mode != EngineMode.tracking) return const [];
    if (!f.detected) return _releaseAll();
    final pose = _rec.recognize(f);
    if (pose == null || !f.isValid) return _releaseAll();

    final t = f.capturedAtMonotonicMs;
    final events = <InteractionEvent>[];

    // 1) スクロール: 人差し指＋中指を立てて動かす（くっつき/ピンチしていない時）。
    final scrolling = !pose.fingersTogether && !pose.pinching &&
        pose.indexUp && pose.middleUp && pose.extendedFingers >= 2;
    if (scrolling) {
      final screen = _screenFilter.filter(_toScreen(pose.indexTip), t);
      if (_drawing) events.addAll(_endDraw(screen));
      if (_pressed) events.addAll(_endPress(screen: screen, tMs: t));
      if (_lastScrollAnchor != null) {
        events.add(InteractionEvent(InteractionKind.scroll, screen,
            delta: screen - _lastScrollAnchor!));
      }
      _lastScrollAnchor = screen;
      _lastScreen = screen;
      return events;
    }
    _lastScrollAnchor = null;

    // 2) インク描画: 人差し指と中指がくっついている → 中間点で線を引く。
    if (pose.fingersTogether) {
      if (_pressed) events.addAll(_endPress(screen: null, tMs: t)); // 排他解除
      final screen = _screenFilter.filter(_toScreen(pose.drawPoint), t);
      if (!_drawing) {
        _drawing = true;
        events.add(InteractionEvent(InteractionKind.drawDown, screen));
      } else {
        events.add(InteractionEvent(InteractionKind.drawMove, screen));
      }
      _lastScreen = screen;
      return events;
    } else if (_drawing) {
      // くっつきが解けた: インクを確定（drawUp）。同フレームで下の分岐も評価する。
      final endAt = _screenFilter.filter(_toScreen(pose.drawPoint), t);
      events.addAll(_endDraw(endAt));
    }

    // 3) OSクリック/ドラッグ（ピンチ）／4) ポインタ移動（人差し指先端）。
    final screen = _screenFilter.filter(_toScreen(pose.indexTip), t);
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
        events.addAll(_endPress(screen: screen, tMs: t));
      } else {
        events.add(InteractionEvent(InteractionKind.pointerMove, screen));
      }
    }
    _lastScreen = screen;
    return events;
  }

  /// 描画（2本指くっつき）の終了。インクを確定する。
  List<InteractionEvent> _endDraw(Vec2 screen) {
    _drawing = false;
    return [InteractionEvent(InteractionKind.drawUp, screen)];
  }

  List<InteractionEvent> _endPress({Vec2? screen, int? tMs}) {
    final at = screen ?? _lastScreen ?? const Vec2(0, 0);
    final events = <InteractionEvent>[];
    final dur = (tMs ?? _pressStartMs) - _pressStartMs;
    final moved = (_pressStart ?? at).distanceTo(at);
    if (dur <= _clickMaxMs && moved <= _clickMaxMove) {
      events.add(InteractionEvent(InteractionKind.click, at));
    }
    events.add(InteractionEvent(InteractionKind.pressUp, at));
    _pressed = false;
    _pressStart = null;
    return events;
  }

  List<InteractionEvent> _releaseAll() {
    final events = <InteractionEvent>[];
    final at = _lastScreen ?? const Vec2(0, 0);
    if (_drawing) {
      events.add(InteractionEvent(InteractionKind.drawUp, at));
    }
    if (_pressed) {
      events.add(InteractionEvent(InteractionKind.pressUp, at));
    }
    events.add(InteractionEvent(InteractionKind.release, at));
    _pressed = false;
    _pressStart = null;
    _drawing = false;
    _lastScrollAnchor = null;
    _screenFilter.reset();
    _rec.reset();
    return events;
  }
}
