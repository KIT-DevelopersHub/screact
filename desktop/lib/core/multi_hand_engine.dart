import 'dart:math' as math;

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

  /// 直近に採用した frameId（単調増加の検証用）。session開始/切断でリセット。
  int? _lastFrameId;

  factory MultiHandEngine({
    InteractionEngine? calibrationEngine,
    CalibrationConfig? config,
    EngineMode mode = EngineMode.calibration,
    bool smoothingEnabled = true,
  }) {
    final calib = calibrationEngine ??
        InteractionEngine(
          config: config,
          mode: mode,
          smoothingEnabled: smoothingEnabled,
        );
    return MultiHandEngine._(calib);
  }

  MultiHandEngine._(this._calib)
      : _sensitivity = _calib.recognitionSensitivity,
        _smoothing = _calib.smoothingEnabled;

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

  /// 現在追跡中のトラック数（0〜2）。
  int get activeTrackCount => _tracks.length;
  Iterable<int> get activeTrackIds => _tracks.keys;

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

  /// カメラ正規化座標を画面正規化座標へ（未校正時は恒等・0..1にクランプ）。
  /// 骨格をカーソルと同じ座標系で重ねるために使う。
  Vec2 mapToScreen(Vec2 camera) {
    final s = _calib.homography?.map(camera) ?? camera;
    return Vec2(s.x.clamp(0.0, 1.0), s.y.clamp(0.0, 1.0));
  }

  InteractionEngine _engineFor(int trackId) => _tracks.putIfAbsent(trackId, () {
        final e = InteractionEngine(
          config: _calib.config,
          mode: _calib.mode,
          smoothingEnabled: _smoothing,
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

    final result = <int, List<InteractionEvent>>{};
    final seen = <int>{};
    for (final track in frame.tracks) {
      seen.add(track.trackId);
      final events = _engineFor(track.trackId).onFrame(
        track.toHandFrame(frame.frameId, frame.capturedAtMonotonicMs),
      );
      if (events.isNotEmpty) result[track.trackId] = events;
    }

    // 消えた trackId は個別に解除（押下/描画/ドラッグを閉じる）→ 破棄。
    final vanished =
        _tracks.keys.where((id) => !seen.contains(id)).toList(growable: false);
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
    return result;
  }

  /// 全トラックを即時解除（WebSocket切断・停止時）。trackId→解除イベント列を返す。
  Map<int, List<InteractionEvent>> releaseAll() {
    final result = <int, List<InteractionEvent>>{};
    for (final entry in _tracks.entries) {
      final events = entry.value.onFrame(
        const HandFrame(frameId: -1, capturedAtMonotonicMs: 0, detected: false),
      );
      if (events.isNotEmpty) result[entry.key] = events;
    }
    _tracks.clear();
    _lastFrameId = null;
    return result;
  }

  /// OS入力（単一カーソル）へ流す主トラック＝最小 trackId。無ければ null。
  int? primaryTrackIdOf(Map<int, List<InteractionEvent>> byTrack) {
    if (byTrack.isEmpty) return null;
    return byTrack.keys.reduce(math.min);
  }
}
