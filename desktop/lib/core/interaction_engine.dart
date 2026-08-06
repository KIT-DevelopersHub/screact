import 'geom.dart';
import 'homography.dart';
import 'one_euro.dart';
import 'gesture_recognizer.dart';
import '../protocol/messages.dart';

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
  const InteractionEvent(this.kind, this.screen, {this.delta = const Vec2(0, 0)});
}

enum EngineMode { calibration, tracking }

/// 受信フレーム→操作イベントへの変換主体（要件の「PCが処理主体」）。
/// ホモグラフィ位置合わせ→座標変換→平滑化→ジェスチャー認識→操作、を担う。
class InteractionEngine {
  final GestureRecognizer _rec;
  final Vec2Filter _screenFilter;
  Homography? _homography;
  EngineMode mode;

  // ピンチ状態機械
  bool _pressed = false;
  Vec2? _pressStart;
  int _pressStartMs = 0;
  Vec2? _lastScreen;
  // スクロール状態
  Vec2? _lastScrollAnchor;

  static const int _clickMaxMs = 260;
  static const double _clickMaxMove = 0.02;

  InteractionEngine({GestureRecognizer? recognizer, this.mode = EngineMode.calibration})
      : _rec = recognizer ?? GestureRecognizer(),
        _screenFilter = Vec2Filter();

  bool get isCalibrated => _homography != null;

  /// ArUcoマーカーからホモグラフィを作成（位置合わせ）。成功で tracking へ。
  bool calibrate(CalibrationMarkers markers) {
    final h = Homography.fromMarkers(markers.markers);
    if (h == null) return false;
    _homography = h;
    mode = EngineMode.tracking;
    return true;
  }

  /// スマホが検出したスライド四隅（順不同・カメラ正規化）から位置合わせ。
  /// 斜め・下から等の歪んだ台形でも射影変換で正確に写す。成功で tracking へ。
  bool calibrateFromCorners(List<Vec2> corners) {
    final h = Homography.fromCorners(corners);
    if (h == null) return false;
    _homography = h;
    mode = EngineMode.tracking;
    return true;
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
    final screen = _screenFilter.filter(_toScreen(pose.indexTip), t);
    final events = <InteractionEvent>[];

    // スクロール: 人差し指＋中指を立てて動かす（ピンチしていない時）。
    final scrolling = !pose.pinching && pose.indexUp && pose.middleUp &&
        pose.extendedFingers >= 2;
    if (scrolling) {
      if (_pressed) events.addAll(_endPress(screen));
      if (_lastScrollAnchor != null) {
        events.add(InteractionEvent(InteractionKind.scroll, screen,
            delta: screen - _lastScrollAnchor!));
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
      events.add(InteractionEvent(
          InteractionKind.pressUp, _lastScreen ?? const Vec2(0, 0)));
    }
    events.add(InteractionEvent(
        InteractionKind.release, _lastScreen ?? const Vec2(0, 0)));
    _pressed = false;
    _pressStart = null;
    _lastScrollAnchor = null;
    _screenFilter.reset();
    _rec.reset();
    return events;
  }
}
