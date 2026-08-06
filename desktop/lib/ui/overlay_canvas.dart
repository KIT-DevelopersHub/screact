import 'package:flutter/material.dart';

import '../core/geom.dart';
import '../core/pointer_state.dart';

/// オーバーレイ描画: インクストローク＋現在のカーソル。正規化(0..1)座標を
/// 描画サイズへスケールするので、どの解像度/モニタでも同じ見た目になる。
class OverlayCanvas extends StatelessWidget {
  final OverlayModel model;
  const OverlayCanvas({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (_, __) => CustomPaint(
        painter: _OverlayPainter(model),
        size: Size.infinite,
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final OverlayModel model;
  _OverlayPainter(this.model);

  Offset _p(Vec2 v, Size s) => Offset(v.x * s.width, v.y * s.height);

  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()
      ..color = const Color(0xFF2B6CB0)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (final stroke in model.strokes) {
      if (stroke.points.length < 2) continue;
      final first = _p(stroke.points.first, size);
      final path = Path()..moveTo(first.dx, first.dy);
      for (final pt in stroke.points.skip(1)) {
        final o = _p(pt, size);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, ink);
    }

    final c = model.cursor;
    if (c != null) {
      final o = _p(c, size);
      final fill = Paint()
        ..style = PaintingStyle.fill
        ..color = model.pressed ? const Color(0xFFC05621) : const Color(0xFF38A169);
      canvas.drawCircle(o, model.pressed ? 12 : 9, fill);
      canvas.drawCircle(
          o,
          model.pressed ? 12 : 9,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => true;
}
