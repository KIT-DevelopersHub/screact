import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/protocol/messages.dart';
import 'package:thehack_overlay/ui/overlay_canvas.dart';

import 'slide_corner_drawing_test.dart'
    show tiltedQuad, slideToCam, drawFrameAt;

/// 「斜めから見た四隅＋2本指くっつきで線を引く手」を通した最終描画の検証。
/// 歪み補正された位置に連続した線が描かれることをピクセルで確認し、
/// 証拠PNGを YUBIBOARD_PROOF_DIR（未指定時はシステムtemp）へ保存する。
void main() {
  testWidgets('傾いた四隅＋ピンチの軌跡が補正済みの連続線として描画される',
      (tester) async {
    final engine = InteractionEngine();
    expect(
      engine.calibrateFromCorners(
          [tiltedQuad[2], tiltedQuad[0], tiltedQuad[3], tiltedQuad[1]]),
      isTrue,
    );

    final fwd = slideToCam(tiltedQuad);
    final model = OverlayModel();
    void feed(int i, Vec2 slide, bool drawing) {
      final cam = fwd.map(slide);
      final f = drawing
          ? drawFrameAt(i, cam)
          : MockHand.at(frameId: i, tip: cam, pinch: false);
      for (final e in engine.onFrame(f)) {
        model.apply(e);
      }
    }

    // mock_android --tilted と同じ台本: 水平線→移動→斜め線。
    for (var i = 0; i < 30; i++) {
      feed(i, Vec2(0.05 + 0.10 * i / 29.0, 0.5), false);
    }
    for (var i = 0; i < 60; i++) {
      feed(30 + i, Vec2(0.15 + 0.70 * i / 59.0, 0.5), true);
    }
    for (var i = 0; i < 30; i++) {
      feed(90 + i, Vec2(0.85 - 0.65 * i / 29.0, 0.5 + 0.2 * i / 29.0), false);
    }
    for (var i = 0; i < 60; i++) {
      feed(120 + i, Vec2(0.2 + 0.6 * i / 59.0, 0.7 - 0.4 * i / 59.0), true);
    }
    // トラッキング喪失→カーソル消去（ストロークだけの画にする）
    for (final e in engine.onFrame(
        const HandFrame(frameId: 999, capturedAtMonotonicMs: 0, detected: false))) {
      model.apply(e);
    }

    expect(model.strokes.length, 2, reason: "描画2回=線2本");

    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: Container(
            color: Colors.white,
            child: OverlayCanvas(model: model),
          ),
        ),
      ),
    );
    await tester.pump();

    final proof = await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return (image.width, image.height, png!, raw!);
    });
    final (w, h, png, raw) = proof!;

    Color pixel(double u, double v) {
      final x = (u * (w - 1)).round(), y = (v * (h - 1)).round();
      final o = (y * w + x) * 4;
      return Color.fromARGB(raw.getUint8(o + 3), raw.getUint8(o),
          raw.getUint8(o + 1), raw.getUint8(o + 2));
    }

    bool isInk(Color c) => c.b > c.r && (c.b * 255).round() > 120 && (c.r * 255).round() < 120;
    bool isWhite(Color c) =>
        (c.r * 255).round() > 240 && (c.g * 255).round() > 240 && (c.b * 255).round() > 240;

    // 水平線 v=0.5 上（u=0.3/0.5/0.7）にインクがある＝歪み補正が効いている。
    for (final u in const [0.3, 0.5, 0.7]) {
      expect(isInk(pixel(u, 0.5)), isTrue, reason: '水平線が (u=$u, v=0.5) を通る');
    }
    // 斜め線 (0.2,0.7)→(0.8,0.3) の中点付近。
    expect(isInk(pixel(0.5, 0.5)), isTrue);
    expect(isInk(pixel(0.65, 0.4)), isTrue, reason: '斜め線が乗る');
    // 線から離れた場所は背景のまま＝台形のまま歪んで描かれていない。
    expect(isWhite(pixel(0.5, 0.15)), isTrue);
    expect(isWhite(pixel(0.1, 0.9)), isTrue);

    // 証拠PNGを保存（検証レポート用）。
    final dir = Platform.environment['YUBIBOARD_PROOF_DIR'] ??
        Directory.systemTemp.path;
    final file = File('$dir/tilted_pinch_line_proof.png');
    file.writeAsBytesSync(png.buffer.asUint8List());
    debugPrint('proof png: ${file.path} (${w}x$h)');
  });
}
