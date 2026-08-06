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
      final pts = stroke.points;
      if (pts.isEmpty) continue;
      if (pts.length == 1) {
        // 1点だけのストローク（タップ）は点として残す。
        canvas.drawCircle(
            _p(pts.first, size), ink.strokeWidth / 2, Paint()..color = ink.color);
        continue;
      }
      // 中点スムージング: 各点を制御点に、隣接中点を終点にした2次ベジェで
      // 連続した滑らかな線にする（折れ線のカクつきを除去）。
      final path = Path();
      final first = _p(pts.first, size);
      path.moveTo(first.dx, first.dy);
      for (var i = 1; i < pts.length - 1; i++) {
        final c = _p(pts[i], size);
        final n = _p(pts[i + 1], size);
        path.quadraticBezierTo(c.dx, c.dy, (c.dx + n.dx) / 2, (c.dy + n.dy) / 2);
      }
      final last = _p(pts.last, size);
      path.lineTo(last.dx, last.dy);
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
