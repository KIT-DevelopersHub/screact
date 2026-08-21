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
class MultiHandEngine {
  /// 位置合わせ・設定の基準（フレームは流し込まない）。session共有の正本。
  final InteractionEngine _calib;

  /// trackId → そのトラック専用エンジン。手が消えたら解除して取り除く。
  final Map<int, InteractionEngine> _tracks = {};

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
  int? _primaryCandidateTrackId;
  int _primaryCandidateStreak = 0;

  static const int _primaryStableFrames = 2;

  factory MultiHandEngine({
    InteractionEngine? calibrationEngine,
    CalibrationConfig? config,
    EngineMode mode = EngineMode.calibration,
    bool smoothingEnabled = true,
  }) {
    final calib =
        calibrationEngine ??
        InteractionEngine(
          config: config,
          mode: mode,
          smoothingEnabled: smoothingEnabled,
        );
    return MultiHandEngine._(calib);
  }

  MultiHandEngine._(this._calib)
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

  /// 現在追跡中のトラック数（0〜2）。
  int get activeTrackCount => _tracks.length;
  Iterable<int> get activeTrackIds => _tracks.keys;
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
  /// 前フレームから消えた trackId は、そのトラックだけを即時解除してから取り除く。
  Map<int, List<InteractionEvent>>? onInputFrame(InputFrame frame) {
    // 単調増加でない frameId（重複・巻き戻り）は全体破棄。
    if (_lastFrameId != null && frame.frameId <= _lastFrameId!) return null;
    _lastFrameId = frame.frameId;

    final previousPrimary = _primaryTrackId;
    _dispatchPrimaryTrackId = null;
    final result = <int, List<InteractionEvent>>{};
    final seen = <int>{};
    for (final track in frame.tracks) {
      seen.add(track.trackId);
      final events = _engineFor(
        track.trackId,
      ).onFrame(track.toHandFrame(frame.frameId, frame.capturedAtMonotonicMs));
      if (events.isNotEmpty) result[track.trackId] = events;
    }

    // 消えた trackId は個別に解除（押下/描画/ドラッグを閉じる）→ 破棄。
    final vanished = _tracks.keys
        .where((id) => !seen.contains(id))
        .toList(growable: false);
    for (final id in vanished) {
      final events = _tracks[id]!.onFrame(
        HandFrame(
          frameId: frame.frameId,
          capturedAtMonotonicMs: frame.capturedAtMonotonicMs,
          detected: false,
        ),
      );
      if (events.isNotEmpty) result[id] = events;
      _tracks.remove(id);
    }

    if (previousPrimary != null) {
      if (seen.contains(previousPrimary)) {
        // 画面外やイベントなしでも所有権は維持する。
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

  void _advancePrimaryCandidate() {
    final candidates = _tracks.entries
      .where((entry) => entry.value.canAcquirePrimary)
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
    _resetPrimaryCandidate();
  }

  void _resetPrimaryCandidate() {
    _primaryCandidateTrackId = null;
    _primaryCandidateStreak = 0;
  }

  /// 全トラックを即時解除（WebSocket切断・停止時）。trackId→解除イベント列を返す。
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
}
