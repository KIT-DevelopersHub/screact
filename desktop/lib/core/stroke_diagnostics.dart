import 'dart:io' show Platform;

import 'geom.dart';

/// 描画中ストロークが確定した理由（[OverlayModel] の確定経路と 1 対 1）。
enum StrokeEndReason {
  /// ペン解除（drawUp）。末尾トリムの対象になる唯一の経路。
  drawUp,

  /// トラッキング喪失・切断（release）。
  release,

  /// 手が画面外へ出た（pointerExit）。
  pointerExit,

  /// ポインタ移動や消しゴムへ切り替わった。
  modeSwitch,

  /// drawUp なしで次の drawDown が来た。
  redrawDown,
}

/// [OverlayModel] が 1 本のストロークを確定したときの記録。
/// 時刻は [OverlayModel] の単調時計（ミリ秒）。
class StrokeFinish {
  final int trackId;
  final StrokeEndReason reason;

  /// 最初の drawDown を受けた時刻。
  final int startMs;

  /// 最後に drawDown/drawMove を受けた時刻。継続時間はここまでで測る。
  final int lastSeenMs;

  /// 確定した時刻。[lastSeenMs] との差は、手が消えてから確定までの空白。
  final int finishedMs;

  /// 受けた drawMove の数（点を増やさなかった微小移動も数える）。
  final int drawMoveCount;

  /// 確定時点の点列（間引き後・末尾トリム前）。誤認識の判定はこの点列で行う。
  final List<Vec2> pointsBeforeTrim;

  /// 確定後に残った点数（破棄なら 0）。
  final int pointsAfter;

  /// 誤認識の微小ストロークとして破棄したか。
  final bool discarded;

  const StrokeFinish({
    required this.trackId,
    required this.reason,
    required this.startMs,
    required this.lastSeenMs,
    required this.finishedMs,
    required this.drawMoveCount,
    required this.pointsBeforeTrim,
    required this.pointsAfter,
    required this.discarded,
  });

  int get durationMs => lastSeenMs - startMs;
  int get idleMs => finishedMs - lastSeenMs;

  /// 軌跡長（画面正規化・トリム前の点列）。
  double get pathLength {
    var length = 0.0;
    for (var i = 1; i < pointsBeforeTrim.length; i++) {
      length += pointsBeforeTrim[i - 1].distanceTo(pointsBeforeTrim[i]);
    }
    return length;
  }

  /// 始点と終点の距離（画面正規化・トリム前の点列）。
  double get endpointDistance =>
      pointsBeforeTrim.length < 2
          ? 0
          : pointsBeforeTrim.first.distanceTo(pointsBeforeTrim.last);
}

/// ストロークごとの診断ログ（Issue #26）。微小ストロークの閾値を実機で
/// 調整するための記録で、描画結果には影響しない。
///
/// 1 本ごとに `ScreactStroke` で始まる 1 行を [sink] へ渡す。
class StrokeDiagnostics {
  final void Function(String line) sink;

  StrokeDiagnostics({required this.sink});

  /// `--dart-define=SCREACT_STROKE_LOG=true` または環境変数
  /// `SCREACT_STROKE_LOG=1` で有効。
  static bool enabledByEnvironment() {
    const fromDefine = bool.fromEnvironment('SCREACT_STROKE_LOG');
    if (fromDefine) return true;
    try {
      final v = Platform.environment['SCREACT_STROKE_LOG'];
      return v == '1' || v == 'true';
    } catch (_) {
      return false;
    }
  }

  void record(StrokeFinish f) => sink(format(f));

  static String format(StrokeFinish f) {
    final buf =
        StringBuffer('ScreactStroke')
          ..write(' track=${f.trackId}')
          ..write(' reason=${f.reason.name}')
          ..write(' pts=${f.pointsBeforeTrim.length}/${f.pointsAfter}')
          ..write(' moves=${f.drawMoveCount}')
          ..write(' dur=${f.durationMs}ms')
          ..write(' idle=${f.idleMs}ms')
          ..write(' len=${f.pathLength.toStringAsFixed(4)}')
          ..write(' span=${f.endpointDistance.toStringAsFixed(4)}')
          ..write(' discarded=${f.discarded}');
    return buf.toString();
  }
}
