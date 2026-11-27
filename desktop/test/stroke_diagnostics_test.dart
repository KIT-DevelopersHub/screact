import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/core/stroke_diagnostics.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';

import 'multi_hand_test.dart' show multiHandFrame, pointerTrack;

/// ストロークごとの診断ログ（Issue #26）。
void main() {
  late int clock;
  late OverlayModel model;
  late List<StrokeFinish> finished;

  InteractionEvent ev(InteractionKind kind, double x, [double y = 0.5]) =>
      InteractionEvent(kind, Vec2(x, y));

  void apply(int trackId, InteractionEvent e, {int advanceMs = 0}) {
    clock += advanceMs;
    model.applyTrack(trackId, e);
  }

  /// x=0.1 から 0.02 刻みで [moves] 回動かす（各 33ms）。
  void drawLine(int trackId, int moves) {
    apply(trackId, ev(InteractionKind.drawDown, 0.1));
    for (var i = 1; i <= moves; i++) {
      apply(
        trackId,
        ev(InteractionKind.drawMove, 0.1 + 0.02 * i),
        advanceMs: 33,
      );
    }
  }

  setUp(() {
    clock = 1000;
    model = OverlayModel(nowMs: () => clock);
    finished = [];
    model.onStrokeFinished = finished.add;
  });

  test('drawUp で確定すると、トリム前後の点数・時間・軌跡長を記録する', () {
    drawLine(3, 10);
    apply(3, ev(InteractionKind.drawUp, 0.3), advanceMs: 40);

    expect(finished, hasLength(1));
    final f = finished.single;
    expect(f.trackId, 3);
    expect(f.reason, StrokeEndReason.drawUp);
    expect(f.pointsBeforeTrim, hasLength(11));
    expect(f.pointsAfter, 11 - model.penReleaseTrimPoints);
    expect(f.pointsAfter, model.strokes.single.points.length);
    expect(f.drawMoveCount, 10);
    expect(f.durationMs, 330);
    expect(f.idleMs, 40);
    expect(f.pathLength, closeTo(0.2, 1e-9));
    expect(f.endpointDistance, closeTo(0.2, 1e-9));
    expect(f.discarded, isFalse);
  });

  test('誤認識の微小ストロークは破棄として記録し、残り点数は 0', () {
    apply(1, ev(InteractionKind.drawDown, 0.5));
    apply(1, ev(InteractionKind.drawMove, 0.5), advanceMs: 33);
    apply(1, ev(InteractionKind.drawUp, 0.5), advanceMs: 33);

    expect(model.strokes, isEmpty);
    final f = finished.single;
    expect(f.discarded, isTrue);
    expect(f.pointsBeforeTrim, hasLength(1));
    expect(f.pointsAfter, 0);
    expect(f.drawMoveCount, 1, reason: '点を増やさない drawMove も数える');
    expect(f.pathLength, 0);
    expect(f.endpointDistance, 0);
  });

  test('終了理由を確定経路ごとに区別する', () {
    final cases = <InteractionKind, StrokeEndReason>{
      InteractionKind.drawUp: StrokeEndReason.drawUp,
      InteractionKind.release: StrokeEndReason.release,
      InteractionKind.pointerExit: StrokeEndReason.pointerExit,
      InteractionKind.pointerMove: StrokeEndReason.modeSwitch,
      InteractionKind.eraseDown: StrokeEndReason.modeSwitch,
      InteractionKind.drawDown: StrokeEndReason.redrawDown,
    };
    cases.forEach((kind, reason) {
      finished.clear();
      drawLine(5, 6);
      apply(5, ev(kind, 0.9), advanceMs: 33);
      expect(finished.map((f) => f.reason), [reason], reason: '$kind');
      expect(finished.single.trackId, 5);
      // 再 drawDown で始まった次のストロークを片付ける。
      model.applyTrack(5, ev(InteractionKind.release, 0.9));
    });
  });

  test('トリムは drawUp だけで、強制終了では点数が変わらない', () {
    drawLine(2, 8);
    apply(2, ev(InteractionKind.release, 0.3), advanceMs: 33);
    final f = finished.single;
    expect(f.pointsAfter, f.pointsBeforeTrim.length);
  });

  test('描画中でなければ記録しない・2手は別々に記録する', () {
    apply(1, ev(InteractionKind.pointerMove, 0.2));
    apply(1, ev(InteractionKind.release, 0.2));
    expect(finished, isEmpty);

    drawLine(1, 5);
    drawLine(2, 7);
    apply(1, ev(InteractionKind.drawUp, 0.2));
    expect(finished.map((f) => f.trackId), [1]);
    apply(2, ev(InteractionKind.pointerExit, 0.2));
    expect(finished.map((f) => f.trackId), [1, 2]);
    expect(finished.last.drawMoveCount, 7);
  });

  test('診断の ON/OFF で描画結果は変わらない', () {
    List<List<List<double>>> run({required bool diagnostics}) {
      clock = 1000;
      model = OverlayModel(nowMs: () => clock);
      if (diagnostics) model.onStrokeFinished = (_) {};
      drawLine(1, 10);
      apply(1, ev(InteractionKind.drawUp, 0.3), advanceMs: 33);
      apply(1, ev(InteractionKind.drawDown, 0.5));
      apply(1, ev(InteractionKind.drawUp, 0.5), advanceMs: 33); // 破棄される
      drawLine(1, 4);
      apply(1, ev(InteractionKind.pointerExit, 0.3), advanceMs: 33);
      return [
        for (final s in model.strokes)
          [
            for (final p in s.points) [p.x, p.y],
          ],
      ];
    }

    final off = run(diagnostics: false);
    final on = run(diagnostics: true);
    expect(on, off);
    expect(off, hasLength(2));
  });

  test('1行の書式', () {
    final f = StrokeFinish(
      trackId: 7,
      reason: StrokeEndReason.drawUp,
      startMs: 1000,
      lastSeenMs: 1420,
      finishedMs: 1453,
      drawMoveCount: 15,
      pointsBeforeTrim: const [Vec2(0.1, 0.5), Vec2(0.2, 0.5), Vec2(0.2, 0.6)],
      pointsAfter: 2,
      discarded: false,
    );
    final lines = <String>[];
    StrokeDiagnostics(sink: lines.add).record(f);
    expect(
      lines.single,
      'ScreactStroke track=7 reason=drawUp pts=3/2 moves=15 dur=420ms '
      'idle=33ms len=0.2000 span=0.1414 discarded=false',
    );
  });

  test('mock の手で描くと、エンジン経由でストロークごとの行が出る', () {
    var frameId = 0;
    final engine = MultiHandEngine(clock: () => clock);
    expect(engine.calibrate(MockHand.markers()), isTrue);
    final lines = <String>[];
    model.onStrokeFinished = StrokeDiagnostics(sink: lines.add).record;

    void step(List<Map<String, dynamic>> hands) {
      clock += 33;
      frameId++;
      final frame =
          InputFrame.parse(
            multiHandFrame(frameId, hands, capturedAtMs: clock),
          )!;
      model.applyTrackEvents(engine.onInputFrame(frame)!);
    }

    for (var i = 0; i < 30; i++) {
      step([pointerTrack(7, Vec2(0.3 + 0.01 * i, 0.5), together: true)]);
    }
    for (var i = 0; i < 10; i++) {
      step([pointerTrack(7, Vec2(0.6, 0.5))]);
    }

    expect(lines, hasLength(1));
    expect(lines.single, startsWith('ScreactStroke track=7 reason=drawUp '));
    expect(lines.single, contains('discarded=false'));
    expect(model.strokes, hasLength(1));
  });
}
