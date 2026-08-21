import 'calibration_config.dart';
import 'geom.dart';
import 'homography.dart';
import 'one_euro.dart';
import 'gesture_recognizer.dart';
import '../protocol/messages.dart';

/// チーム確定仕様のジェスチャー分岐:
/// - ポインタ移動 = 人差し指先端（pointerMove）※OSカーソルを動かす
/// - インク描画 = 人差し指と中指をくっつける（drawDown/drawMove/drawUp）
///   筆点は人差し指先端。トリガー条件（人差し指＋中指のくっつき）は不変。オーバーレイのインク専用。
/// - OSクリック/ドラッグ = 親指と人差し指のピンチ（pressDown/pressMove/pressUp/click）
///   OSの実マウスイベントとして注入する。
/// - スクロール = グッドサイン（親指だけを立て他4指を折る）で、親指の向きにスクロール
///   （親指が上→上/下→下/右→右/左→左）。scroll を一定量ずつ送出する。
///
/// 各ジェスチャーは設定から個別にON/OFFできる（既定は全てON）。OFFのジェスチャーは
/// 認識・実行せず、その手はポインタ移動として扱う。
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
  pointerExit, // 画面外遷移。カーソルだけ隠し、検出中の骨格は保持する
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

  // ジェスチャー個別の有効/無効（既定は全てON）。OFFのジェスチャーはトリガーを
  // 無視し、その手はポインタ移動として扱う（誤作動の抑制）。
  bool _clickEnabled;
  bool _penEnabled;
  bool _eraserEnabled;
  bool _scrollEnabled;

  /// グッドサインで送るスクロールの1フレームあたりの量（画面正規化）。
  /// ネイティブ側でピクセルへ換算する。実測で調整可能。
  static const double _scrollStepMagnitude = 0.03;

  /// 親指の向きが微小すぎてスクロール方向を確定できない不感帯（画面正規化）。
  static const double _scrollDirDeadzone = 1e-4;

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
  // 画面境界状態
  Vec2? _lastRawSurface;
  bool _outside = false;
  int _insideStreak = 0;
  bool _blockPressUntilNeutral = false;
  bool _primaryNeutral = false;

  static const int _clickMaxMs = 260;
  static const double _clickMaxMove = 0.02;
  static const int _reentryStableFrames = 2;

  InteractionEngine({
    GestureRecognizer? recognizer,
    this.mode = EngineMode.calibration,
    CalibrationConfig? config,
    bool smoothingEnabled = true,
    bool clickEnabled = true,
    bool penEnabled = true,
    bool eraserEnabled = true,
    bool scrollEnabled = true,
  }) : _rec = recognizer ?? GestureRecognizer(),
       _screenFilter = Vec2Filter(),
       _smoothingEnabled = smoothingEnabled,
       _clickEnabled = clickEnabled,
       _penEnabled = penEnabled,
       _eraserEnabled = eraserEnabled,
       _scrollEnabled = scrollEnabled,
       config = config ?? CalibrationConfig();

  bool get isCalibrated => _homography != null;
  Vec2? get lastRawSurfacePoint => _lastRawSurface;
  bool get isPointerInside => !_outside && _lastScreen != null;
  bool get canAcquirePrimary => isPointerInside && _primaryNeutral;

  /// 現在の位置合わせ（ホモグラフィ）。session内の全トラックで共有するため
  /// MultiHandEngine が読み出し、新規トラックのエンジンへ配布する。
  Homography? get homography => _homography;

  /// session単位で確定した位置合わせを、このトラック用エンジンへ取り込む。
  /// ジェスチャー・平滑化の履歴はトラックごとに独立させるためリセットする。
  /// （位置合わせ自体はsession共有・操作状態は手ごと独立、が仕様）。
  void adoptCalibration(Homography? homography, EngineMode mode) {
    _homography = homography;
    this.mode = mode;
    _screenFilter.reset();
    _rec.reset();
  }

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

  /// OSクリック/ドラッグ（ピンチ）を認識するか。
  bool get clickEnabled => _clickEnabled;
  set clickEnabled(bool value) {
    if (value == _clickEnabled) return;
    _clickEnabled = value;
    _resetRuntimeFilters();
  }

  /// インク描画（人差し指＋中指のくっつき）を認識するか。
  bool get penEnabled => _penEnabled;
  set penEnabled(bool value) {
    if (value == _penEnabled) return;
    _penEnabled = value;
    _resetRuntimeFilters();
  }

  /// 消しゴム（グー）を認識するか。消しゴムジェスチャーが有効な構成でのみ効く。
  bool get eraserEnabled => _eraserEnabled;
  set eraserEnabled(bool value) {
    if (value == _eraserEnabled) return;
    _eraserEnabled = value;
    _resetRuntimeFilters();
  }

  /// スクロール（グッドサイン）を認識するか。
  bool get scrollEnabled => _scrollEnabled;
  set scrollEnabled(bool value) {
    if (value == _scrollEnabled) return;
    _scrollEnabled = value;
    _resetRuntimeFilters();
  }

  /// 設定変更前のヒステリシスや平滑化履歴を次フレームへ持ち越さない。
  /// 押下状態自体は保持し、次フレームの新しい設定による判定で安全に
  /// pressMove / pressUpへ遷移させる。
  void _resetRuntimeFilters() {
    _rec.reset();
    _screenFilter.reset();
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
  /// 範囲外を保持し、画面内外判定より前にクリップしない。
  Vec2 _toSurface(Vec2 cam) => _homography?.map(cam) ?? cam;

  Vec2 _filteredScreen(Vec2 surfacePoint, int timestampMs) =>
      _smoothingEnabled
          ? _screenFilter.filter(surfacePoint, timestampMs)
          : surfacePoint;

  static bool _isInside(Vec2 point) =>
      point.x.isFinite &&
      point.y.isFinite &&
      point.x >= 0 &&
      point.x <= 1 &&
      point.y >= 0 &&
      point.y <= 1;

  /// 1フレーム処理。安全解除も含め、UI/OSへ渡すイベント列を返す。
  ///
  /// 優先順位（相互排他）:
  ///   1. スクロール（グッドサイン＝親指だけ立て・親指の向きへ一定量）
  ///   2. インク描画（人差し指＋中指がくっつく・筆点は中間点）
  ///   3. OSクリック/ドラッグ（親指＋人差し指のピンチ）
  ///   4. ポインタ移動（人差し指先端）
  ///
  /// 各ジェスチャーが設定でOFFのときはそのトリガーを無視し、下位分岐へ流す。
  List<InteractionEvent> onFrame(HandFrame f) {
    if (mode != EngineMode.tracking) return const [];
    if (!f.detected) return _releaseAll();
    final pose = _rec.recognize(f);
    if (pose == null || !f.isValid) return _releaseAll();

    final t = f.capturedAtMonotonicMs;
    final events = <InteractionEvent>[];
    final rawIndex = _toSurface(pose.indexTip);
    _lastRawSurface = rawIndex;
    if (!_isInside(rawIndex)) return _onPointerOutside(pose);

    if (_outside) {
      _insideStreak++;
      _primaryNeutral = false;
      if (_insideStreak < _reentryStableFrames) return const [];
      _outside = false;
      _insideStreak = 0;
    }
    if (!pose.pinching) _blockPressUntilNeutral = false;

    // 1) スクロール: グッドサイン（親指だけを立て他4指を折る）で親指の向きへ一定量。
    //    設定でOFFなら無視する。
    // グッドサインは4指を折るため、指先が近づいて fingersTogether を巻き込む
    // ことがある。goodSign を最優先にし、描画へ落とさない。
    final scrolling = _scrollEnabled && pose.goodSign && !pose.pinching;
    _primaryNeutral =
        !pose.pinching && !(pose.fingersTogether && !pose.goodSign) && !scrolling;
    if (scrolling) {
      final screen = _lastScreen ?? _filteredScreen(rawIndex, t);
      if (_drawing) events.addAll(_endDraw(screen));
      if (_pressed) events.addAll(_endPress(screen: screen, tMs: t));
      final step = _scrollStep(f);
      if (step != null) {
        events.add(InteractionEvent(InteractionKind.scroll, screen, delta: step));
      }
      _lastScreen = screen;
      return events;
    }

    // 2) インク描画: 人差し指と中指がくっついている（トリガーは不変） → 人差し指先端で線を引く。
    //    設定でOFFなら描画せず、下位分岐（クリック/移動）へ流す。
    //    グッドサイン（4指折り）は指先が近く together を巻き込むため描画から除外する。
    if (_penEnabled && pose.fingersTogether && !pose.goodSign) {
      if (_pressed) events.addAll(_endPress(screen: null, tMs: t)); // 排他解除
      final rawDraw = _toSurface(pose.indexTip);
      final screen = _filteredScreen(
        _isInside(rawDraw) ? rawDraw : rawIndex,
        t,
      );
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
      final rawDraw = _toSurface(pose.indexTip);
      final endAt = _filteredScreen(_isInside(rawDraw) ? rawDraw : rawIndex, t);
      events.addAll(_endDraw(endAt));
    }

    // 3) OSクリック/ドラッグ（ピンチ）／4) ポインタ移動（人差し指先端）。
    //    クリックが設定でOFFなら、ピンチしていても押下せずポインタ移動のみ。
    final screen = _filteredScreen(rawIndex, t);
    if (_clickEnabled && pose.pinching && !_blockPressUntilNeutral) {
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

  List<InteractionEvent> _onPointerOutside(HandPose pose) {
    final events = <InteractionEvent>[];
    final at = _lastScreen ?? const Vec2(0, 0);
    if (!_outside) {
      if (_drawing) events.addAll(_endDraw(at));
      if (_pressed) {
        events.addAll(_endPress(screen: at, allowClick: false));
      }
      events.add(InteractionEvent(InteractionKind.pointerExit, at));
    }
    _outside = true;
    _insideStreak = 0;
    _blockPressUntilNeutral = pose.pinching;
    _primaryNeutral = false;
    _screenFilter.reset();
    return events;
  }

  /// グッドサインの親指の向きから、1フレーム分のスクロール量（画面正規化）を作る。
  /// 親指先端と付け根(thumbMcp)を画面座標へ写し、優勢な軸へ一定量だけ送る。
  /// 画面座標で判定するのでキャリブレーションのミラー/回転にも追従する。
  /// 親指が上→上/下→下/右→右/左→左（縦は用途上重要・横の極性は実測で調整可能）。
  Vec2? _scrollStep(HandFrame f) {
    final tip = f.at(HandFrame.thumbTip);
    final base = f.at(HandFrame.thumbMcp);
    if (tip == null || base == null) return null;
    final d = _toSurface(tip.xy) - _toSurface(base.xy);
    if (!d.x.isFinite || !d.y.isFinite) return null;
    const k = _scrollStepMagnitude;
    if (d.x.abs() >= d.y.abs()) {
      if (d.x.abs() < _scrollDirDeadzone) return null;
      return Vec2(d.x > 0 ? k : -k, 0); // 右／左
    }
    if (d.y.abs() < _scrollDirDeadzone) return null;
    return Vec2(0, d.y > 0 ? k : -k); // 下／上（画面座標はyが下向き）
  }

  /// 描画（2本指くっつき）の終了。インクを確定する。
  List<InteractionEvent> _endDraw(Vec2 screen) {
    _drawing = false;
    return [InteractionEvent(InteractionKind.drawUp, screen)];
  }

  List<InteractionEvent> _endPress({
    Vec2? screen,
    int? tMs,
    bool allowClick = true,
  }) {
    final at = screen ?? _lastScreen ?? const Vec2(0, 0);
    final events = <InteractionEvent>[];
    final dur = (tMs ?? _pressStartMs) - _pressStartMs;
    final moved = (_pressStart ?? at).distanceTo(at);
    if (allowClick && dur <= _clickMaxMs && moved <= _clickMaxMove) {
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
    _lastRawSurface = null;
    _outside = false;
    _insideStreak = 0;
    _blockPressUntilNeutral = false;
    _primaryNeutral = false;
    _screenFilter.reset();
    _rec.reset();
    return events;
  }
}
