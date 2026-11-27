import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';

import 'multi_hand_test.dart' show multiHandFrame, pointerTrack;

/// 誤認識ストロークの確定時破棄（#38 / Issue #5）と、手の一時欠落の猶予
/// （#39 / Issue #4）を実際のエンジン出力でつないで確かめる。
/// 猶予を経て drawUp/release が届いても、一瞬の点は破棄され、
/// 長押しの点は残ることを、フレーム到着と時計の両方の解除経路で見る。
void main() {
  const frameMs = 33;
  const graceMs = MultiHandEngine.defaultTrackLossGraceMs;

  // エンジンとオーバーレイで desktop 側の時計を共有する。
  late int clock;
  late MultiHandEngine engine;
  late OverlayModel model;
  var frameId = 0;

  InputFrame frame(List<Map<String, dynamic>> hands) {
    frameId++;
    return InputFrame.parse(
      multiHandFrame(frameId, hands, capturedAtMs: clock),
    )!;
  }

  Map<String, dynamic> drawing(double x) =>
      pointerTrack(7, Vec2(x, 0.5), together: true);

  /// 1フレーム進めてエンジンへ流し、出たイベントをオーバーレイへ反映する。
  Map<int, List<InteractionEvent>> step(List<Map<String, dynamic>> hands) {
    clock += frameMs;
    final out = engine.onInputFrame(frame(hands))!;
    model.applyTrackEvents(out);
    return out;
  }

  /// drawDown が出るまで描画姿勢のフレームを流す。
  void startDrawing(double x) {
    for (var i = 0; i < 10; i++) {
      final out = step([drawing(x)]);
      final kinds = (out[7] ?? const []).map((e) => e.kind);
      if (kinds.contains(InteractionKind.drawDown)) return;
    }
    fail('描画が始まらない');
  }

  setUp(() {
    clock = 1000;
    frameId = 0;
    engine = MultiHandEngine(clock: () => clock);
    expect(engine.calibrate(MockHand.markers()), isTrue);
    model = OverlayModel(nowMs: () => clock);
  });

  test('drawDown の直後に手が消え、猶予後のフレームで確定しても一瞬の点は破棄される', () {
    startDrawing(0.4);
    expect(model.strokes, hasLength(1), reason: '描画中は即時表示する');

    // 手が消えたフレームが続く。猶予内はイベントを出さず、点は残ったまま。
    Map<int, List<InteractionEvent>> out = const {};
    var elapsed = 0;
    while (elapsed < graceMs) {
      out = step(const []);
      elapsed += frameMs;
    }
    final kinds = (out[7] ?? const []).map((e) => e.kind);
    expect(kinds, contains(InteractionKind.drawUp), reason: '猶予切れで確定する');
    expect(engine.lostTrackIds, isEmpty);
    expect(model.strokes, isEmpty, reason: '猶予ぶんの時間で誤認識の判定がずれない');
  });

  test('hand_frame が途絶え、時計による猶予切れで確定しても一瞬の点は破棄される', () {
    startDrawing(0.4);
    step(const []); // 手が消えたフレームを最後に途絶える。
    expect(engine.lostTrackIds, [7]);
    expect(model.strokes, hasLength(1));

    clock += graceMs;
    final expired = engine.expireLostTracks();
    expect(
      (expired[7] ?? const []).map((e) => e.kind),
      contains(InteractionKind.release),
    );
    model.applyTrackEvents(expired);
    expect(model.strokes, isEmpty);
  });

  test('静止した長押しの点は、時計による猶予切れで確定しても残る', () {
    startDrawing(0.4);
    for (var i = 0; i < 8; i++) {
      step([drawing(0.4)]);
    }
    step(const []);
    clock += graceMs;
    model.applyTrackEvents(engine.expireLostTracks());
    expect(model.strokes, hasLength(1), reason: '意図した点は消さない');
  });
}
