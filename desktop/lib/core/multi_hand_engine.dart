import 'dart:collection';

import 'calibration_config.dart';
import 'geom.dart';
import 'homography.dart';
import 'interaction_engine.dart';
import '../protocol/input_frame.dart';
import '../protocol/messages.dart';

/// 2人同時操作の処理主体。session単位の位置合わせ（ホモグラフィ）を共有し、
/// `(sessionId, trackId)` ごとに [InteractionEngine] 相当の状態
/// （平滑化・ジェスチャー判定・押下/描画/ドラッグ）を分離して保持する。
///
/// 単一手の既存フローを壊さないためのファサードでもある: 位置合わせ・感度・
/// 平滑化・モードは従来の [InteractionEngine] と同じ形で読み書きできる。
///
/// 手の一時欠落と確定消失を区別する: フレームから消えた trackId は
/// [trackLossGraceMs] のあいだ状態（押下・描画・ドラッグ）を保ったまま保留し、
/// 同じ trackId が戻れば続きとして処理する。猶予を過ぎたら確定消失として
/// 従来どおり安全に解除する。WebSocket切断・停止時の [releaseAll] は猶予なし。
///
/// 猶予切れはフレーム到着時に加えて、[expireLostTracks] で時計からも判定する。
/// hand_frame が途絶えると到着時の判定が走らず、押下・描画が残り続けるため、
/// 呼び出し側（[InputServer]）が猶予中のトラックがある間だけ周期的に呼ぶ。
class MultiHandEngine {
  /// 一時欠落の猶予時間の既定値（ms）。Android `HandTrackAssigner` の
  /// `DEFAULT_RETENTION_MS`（300ms）に合わせた暫定値で、実機で調整する。
  static const int defaultTrackLossGraceMs = 300;

  /// 位置合わせ・設定の基準（フレームは流し込まない）。session共有の正本。
  final InteractionEngine _calib;

  /// trackId → そのトラック専用エンジン。猶予中のトラックも含む。
  /// 確定消失したら解除して取り除く。
  final Map<int, InteractionEngine> _tracks = {};

  /// trackId → 最後にフレームへ現れた時刻（capturedAtMonotonicMs）。
  final Map<int, int> _lastSeenAtMs = {};

  /// trackId → 最後にフレームへ現れた desktop 側の時刻（[_clock] の ms）。
  /// フレームの capturedAtMonotonicMs は Android の時計なので、時計による
  /// 猶予切れ判定（[expireLostTracks]）ではこちらだけを使い、混ぜない。
  final Map<int, int> _lastSeenAtLocalMs = {};

  /// 直近フレームに現れず、猶予中の trackId。
  final Set<int> _lostTracks = {};

  /// desktop 側の単調時計（ms）。テストで差し替えられる。
  final int Function() _clock;

  /// 消えた trackId を確定消失とみなすまでの猶予（ms）。
  /// 時刻はフレームの capturedAtMonotonicMs で測る。0 なら即時解除（従来挙動）。
  final int trackLossGraceMs;

  double _sensitivity;
  bool _smoothing;
  bool _clickEnabled;
  bool _penEnabled;
  bool _eraserEnabled;
  bool _scrollEnabled;

  /// 直近に採用した frameId（単調増加の検証用）。session開始/切断でリセット。
  int? _lastFrameId;

  // OS入力は単一カーソルなので、イベント発生有無とは独立して所有者を保持する。
  int? _primaryTrackId;
  int? _dispatchPrimaryTrackId;
  bool _primaryAcquiredThisFrame = false;
  int? _primaryCandidateTrackId;
  int _primaryCandidateStreak = 0;

  static const int _primaryStableFrames = 2;

  factory MultiHandEngine({
    InteractionEngine? calibrationEngine,
    CalibrationConfig? config,
    EngineMode mode = EngineMode.calibration,
    bool smoothingEnabled = true,
    int trackLossGraceMs = defaultTrackLossGraceMs,
    int Function()? clock,
  }) {
    if (trackLossGraceMs < 0) {
      throw ArgumentError.value(
        trackLossGraceMs,
        'trackLossGraceMs',
        '0以上を指定する',
      );
    }
    final calib =
        calibrationEngine ??
        InteractionEngine(
          config: config,
          mode: mode,
          smoothingEnabled: smoothingEnabled,
        );
    return MultiHandEngine._(
      calib,
      trackLossGraceMs,
      clock ?? _monotonicClock(),
    );
  }

  static int Function() _monotonicClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  MultiHandEngine._(this._calib, this.trackLossGraceMs, this._clock)
    : _sensitivity = _calib.recognitionSensitivity,
      _smoothing = _calib.smoothingEnabled,
      _clickEnabled = _calib.clickEnabled,
      _penEnabled = _calib.penEnabled,
      _eraserEnabled = _calib.eraserEnabled,
      _scrollEnabled = _calib.scrollEnabled;

  // ---- 単一手エンジン互換のファサード（UI/サーバはこの形で扱う） ----

  CalibrationConfig get config => _calib.config;
  bool get isCalibrated => _calib.isCalibrated;
  int get calibrationCount => _calib.calibrationCount;
  Homography? get homography => _calib.homography;

  EngineMode get mode => _calib.mode;
  set mode(EngineMode value) {
    _calib.mode = value;
    for (final e in _tracks.values) {
      e.mode = value;
    }
  }

  double get recognitionSensitivity => _sensitivity;
  set recognitionSensitivity(double value) {
    _sensitivity = value;
    _calib.recognitionSensitivity = value;
    for (final e in _tracks.values) {
      e.recognitionSensitivity = value;
    }
  }

  bool get smoothingEnabled => _smoothing;
  set smoothingEnabled(bool value) {
    _smoothing = value;
    _calib.smoothingEnabled = value;
    for (final e in _tracks.values) {
      e.smoothingEnabled = value;
    }
  }

  bool get clickEnabled => _clickEnabled;
  set clickEnabled(bool value) {
    _clickEnabled = value;
    _calib.clickEnabled = value;
    for (final e in _tracks.values) {
      e.clickEnabled = value;
    }
  }

  bool get penEnabled => _penEnabled;
  set penEnabled(bool value) {
    _penEnabled = value;
    _calib.penEnabled = value;
    for (final e in _tracks.values) {
      e.penEnabled = value;
    }
  }

  bool get eraserEnabled => _eraserEnabled;
  set eraserEnabled(bool value) {
    _eraserEnabled = value;
    _calib.eraserEnabled = value;
    for (final e in _tracks.values) {
      e.eraserEnabled = value;
    }
  }

  bool get scrollEnabled => _scrollEnabled;
  set scrollEnabled(bool value) {
    _scrollEnabled = value;
    _calib.scrollEnabled = value;
    for (final e in _tracks.values) {
      e.scrollEnabled = value;
    }
  }

  /// 直近フレームで追跡中のトラック数（0〜2）。猶予中のトラックは含めない。
  int get activeTrackCount => _tracks.length - _lostTracks.length;
  Iterable<int> get activeTrackIds =>
      _tracks.keys.where((id) => !_lostTracks.contains(id));

  /// 一時欠落の猶予中で、状態を保留している trackId。
  Iterable<int> get lostTrackIds => UnmodifiableSetView(_lostTracks);

  /// 猶予中のトラックがあるか（時計による猶予切れ判定が要るか）。
  bool get hasLostTracks => _lostTracks.isNotEmpty;
  int? get primaryTrackId => _primaryTrackId;

  // ---- 位置合わせ（session共有）----

  bool calibrate(CalibrationMarkers markers) {
    final ok = _calib.calibrate(markers);
    if (ok) _propagateCalibration();
    return ok;
  }

  bool calibrateFromCorners(List<Vec2> corners) {
    final ok = _calib.calibrateFromCorners(corners);
    if (ok) _propagateCalibration();
    return ok;
  }

  void _propagateCalibration() {
    for (final e in _tracks.values) {
      e.adoptCalibration(_calib.homography, _calib.mode);
    }
  }

  /// 全入力を解除して、session共有のHomographyを無効化する。
  Map<int, List<InteractionEvent>> resetCalibration() {
    final released = releaseAll();
    _calib.resetCalibration();
    return released;
  }

  /// カメラ正規化座標を未クリップの画面surface座標へ写す。
  /// 骨格は範囲外を保持し、描画Canvas側で画面矩形へクリップする。
  Vec2 mapToSurface(Vec2 camera) => _calib.homography?.map(camera) ?? camera;

  InteractionEngine _engineFor(int trackId) => _tracks.putIfAbsent(trackId, () {
    final e = InteractionEngine(
      config: _calib.config,
      mode: _calib.mode,
      smoothingEnabled: _smoothing,
      clickEnabled: _clickEnabled,
      penEnabled: _penEnabled,
      eraserEnabled: _eraserEnabled,
      scrollEnabled: _scrollEnabled,
    );
    e.recognitionSensitivity = _sensitivity;
    e.adoptCalibration(_calib.homography, _calib.mode);
    return e;
  });

  /// フレーム処理。返り値は trackId→操作イベント列。
  /// null は「不正/失効フレーム＝全体破棄」（イベントを一切出さない）。
  ///
  /// 前フレームから消えた trackId は猶予中として状態を保ち、イベントを出さない
  /// （カーソルは最後の位置のまま）。猶予内に同じ trackId が戻れば続きとして
  /// 処理し、猶予を過ぎたらそのトラックだけを解除してから取り除く。
  Map<int, List<InteractionEvent>>? onInputFrame(InputFrame frame) {
    // 単調増加でない frameId（重複・巻き戻り）は全体破棄。
    if (_lastFrameId != null && frame.frameId <= _lastFrameId!) return null;
    _lastFrameId = frame.frameId;

    final now = frame.capturedAtMonotonicMs;
    final localNow = _clock();
    final previousPrimary = _primaryTrackId;
    _dispatchPrimaryTrackId = null;
    _primaryAcquiredThisFrame = false;
    final result = <int, List<InteractionEvent>>{};
    final seen = <int>{};
    for (final track in frame.tracks) {
      seen.add(track.trackId);
      _lostTracks.remove(track.trackId);
      _lastSeenAtMs[track.trackId] = now;
      _lastSeenAtLocalMs[track.trackId] = localNow;
      final events = _engineFor(
        track.trackId,
      ).onFrame(track.toHandFrame(frame.frameId, now));
      if (events.isNotEmpty) result[track.trackId] = events;
    }

    // 消えた trackId: 猶予内なら保留、猶予を過ぎたら個別に解除
    // （押下/描画/ドラッグを閉じる）→ 破棄。
    final missing = _tracks.keys
        .where((id) => !seen.contains(id))
        .toList(growable: false);
    for (final id in missing) {
      if (!_graceExpired(id, now)) {
        _lostTracks.add(id);
        continue;
      }
      final events = _tracks[id]!.onFrame(
        HandFrame(
          frameId: frame.frameId,
          capturedAtMonotonicMs: now,
          detected: false,
        ),
      );
      if (events.isNotEmpty) result[id] = events;
      _forget(id);
    }

    if (previousPrimary != null) {
      if (_tracks.containsKey(previousPrimary)) {
        // 画面外・イベントなし・一時欠落の猶予中でも所有権は維持する。
        // 猶予中は他トラックへ移さない（移すと、戻ってきた旧所有者の押下中
        // 状態と新所有者の入力がOSの単一カーソル上で混ざるため）。
        _dispatchPrimaryTrackId = previousPrimary;
      } else {
        // このフレームは旧所有者の解除だけをOSへ送り、引き継がない。
        _dispatchPrimaryTrackId = previousPrimary;
        _primaryTrackId = null;
        _resetPrimaryCandidate();
      }
    } else {
      _advancePrimaryCandidate();
    }
    return result;
  }

  /// 猶予を過ぎたか。capturedAtMonotonicMs が進んでいない（欠落・巻き戻り）
  /// フレームでは経過時間を測れないため、固着を避けて確定消失として扱う。
  bool _graceExpired(int id, int now) {
    final lastSeen = _lastSeenAtMs[id];
    if (lastSeen == null) return true;
    final elapsed = now - lastSeen;
    return elapsed <= 0 || elapsed >= trackLossGraceMs;
  }

  /// フレーム到着とは別に、desktop 側の時計で猶予切れを判定して解除する。
  ///
  /// hand_frame が途絶えた（Android のバックグラウンド移行・カメラ停止など）
  /// ときに、押下・描画を残さないための手段。猶予中のトラックのうち、
  /// 最後にフレームへ現れた desktop 時刻から [trackLossGraceMs] 以上経った
  /// ものを解除して取り除き、trackId→解除イベント列を返す。
  /// 主トラックを解除した場合は、その解除だけを [primaryEventsOf] で OS へ流す。
  /// [nowMs] は desktop 側の時計（省略時は [_clock]）。
  Map<int, List<InteractionEvent>> expireLostTracks([int? nowMs]) {
    final now = nowMs ?? _clock();
    _dispatchPrimaryTrackId = null;
    _primaryAcquiredThisFrame = false;
    final result = <int, List<InteractionEvent>>{};
    final expired = _lostTracks
        .where((id) {
          final lastSeen = _lastSeenAtLocalMs[id];
          return lastSeen == null || now - lastSeen >= trackLossGraceMs;
        })
        .toList(growable: false);
    for (final id in expired) {
      final events = _tracks[id]!.onFrame(
        HandFrame(
          frameId: _lastFrameId ?? -1,
          capturedAtMonotonicMs: _lastSeenAtMs[id] ?? 0,
          detected: false,
        ),
      );
      if (events.isNotEmpty) result[id] = events;
      _forget(id);
      if (id == _primaryTrackId) {
        // 旧所有者の解除だけを OS へ送り、引き継ぎは次フレーム以降に行う。
        _dispatchPrimaryTrackId = id;
        _primaryTrackId = null;
        _resetPrimaryCandidate();
      }
    }
    return result;
  }

  void _forget(int id) {
    _tracks.remove(id);
    _lastSeenAtMs.remove(id);
    _lastSeenAtLocalMs.remove(id);
    _lostTracks.remove(id);
  }

  void _advancePrimaryCandidate() {
    final candidates = _tracks.entries
      // 猶予中のトラックは画面に見えていないので所有者候補にしない。
      .where((entry) => !_lostTracks.contains(entry.key))
      // 実機では画面へ入った最初の姿勢がscroll/pinch/drawと判定されることが
      // ある。neutral限定では主トラックが永久に選ばれず、OS入力が全停止する。
      // 画面内に安定して存在するtrackIdを所有者にし、ジェスチャー途中の安全は
      // primaryEventsOf側で補う。
      .where((entry) => entry.value.isPointerInside)
      .map((entry) => entry.key)
      .toList(growable: false)..sort();
    if (candidates.isEmpty) {
      _resetPrimaryCandidate();
      return;
    }

    final candidate = candidates.first;
    if (_primaryCandidateTrackId == candidate) {
      _primaryCandidateStreak++;
    } else {
      _primaryCandidateTrackId = candidate;
      _primaryCandidateStreak = 1;
    }
    if (_primaryCandidateStreak < _primaryStableFrames) return;

    _primaryTrackId = candidate;
    _dispatchPrimaryTrackId = candidate;
    _primaryAcquiredThisFrame = true;
    _resetPrimaryCandidate();
  }

  void _resetPrimaryCandidate() {
    _primaryCandidateTrackId = null;
    _primaryCandidateStreak = 0;
  }

  /// 全トラックを即時解除（WebSocket切断・停止時）。猶予中のトラックも猶予なしで
  /// 解除する。trackId→解除イベント列を返す。
  Map<int, List<InteractionEvent>> releaseAll() {
    _dispatchPrimaryTrackId = _primaryTrackId;
    final result = <int, List<InteractionEvent>>{};
    for (final entry in _tracks.entries) {
      final events = entry.value.onFrame(
        const HandFrame(frameId: -1, capturedAtMonotonicMs: 0, detected: false),
      );
      if (events.isNotEmpty) result[entry.key] = events;
    }
    _tracks.clear();
    _lastSeenAtMs.clear();
    _lastSeenAtLocalMs.clear();
    _lostTracks.clear();
    _lastFrameId = null;
    _primaryTrackId = null;
    _resetPrimaryCandidate();
    return result;
  }

  /// OS入力（単一カーソル）へ流す、このフレームの明示的な主トラック。
  int? primaryTrackIdOf(Map<int, List<InteractionEvent>> byTrack) {
    final id = _dispatchPrimaryTrackId;
    return id != null && byTrack.containsKey(id) ? id : null;
  }

  /// OS単一カーソルへ流すイベント。主トラックの安定選出がピンチ開始後に
  /// 完了した場合は、pressMoveだけを送って押下なしドラッグにしないよう
  /// 現在位置でpressDownを補完する。
  List<InteractionEvent>? primaryEventsOf(
    Map<int, List<InteractionEvent>> byTrack,
  ) {
    final id = primaryTrackIdOf(byTrack);
    if (id == null) return null;
    final events = byTrack[id]!;
    if (!_primaryAcquiredThisFrame ||
        !events.any((event) => event.kind == InteractionKind.pressMove)) {
      return events;
    }
    final move = events.firstWhere(
      (event) => event.kind == InteractionKind.pressMove,
    );
    return [
      InteractionEvent(InteractionKind.pressDown, move.screen),
      ...events,
    ];
  }
}
