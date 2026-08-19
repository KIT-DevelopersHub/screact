import 'package:flutter/material.dart';

import '../core/geom.dart';
import '../core/hand_skeleton.dart';
import '../core/pointer_state.dart';

/// オーバーレイ描画: 各トラックの骨格＋カーソル＋インクストローク。
/// 正規化(0..1)座標を描画サイズへスケールするので、どの解像度/モニタでも同じ
/// 見た目になる。最大2トラックを別色で同時に描く。
class OverlayCanvas extends StatelessWidget {
  final OverlayModel model;
  const OverlayCanvas({super.key, required this.model});

  /// 表示モデルが割り当てた色スロット→表示色。
  static Color colorForSlot(int colorSlot) =>
      _palette[colorSlot % _palette.length];

  static const List<Color> _palette = [
    Color(0xFF2B6CB0), // 青
    Color(0xFFD53F8C), // マゼンタ
    Color(0xFF2F855A), // 緑（保険）
    Color(0xFFB7791F), // 琥珀（保険）
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder:
          (_, __) =>
              CustomPaint(painter: _OverlayPainter(model), size: Size.infinite),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final OverlayModel model;
  _OverlayPainter(this.model);

  Offset _p(Vec2 v, Size s) => Offset(v.x * s.width, v.y * s.height);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // インク（トラック別の色）。
    for (final stroke in model.strokes) {
      final color = OverlayCanvas.colorForSlot(stroke.colorSlot);
      final ink =
          Paint()
            ..color = color
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke;
      final pts = stroke.points;
      if (pts.isEmpty) continue;
      if (pts.length == 1) {
        canvas.drawCircle(
          _p(pts.first, size),
          ink.strokeWidth / 2,
          Paint()..color = color,
        );
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
        path.quadraticBezierTo(
          c.dx,
          c.dy,
          (c.dx + n.dx) / 2,
          (c.dy + n.dy) / 2,
        );
      }
      final last = _p(pts.last, size);
      path.lineTo(last.dx, last.dy);
      canvas.drawPath(path, ink);
    }

    // トラックごとの骨格＋カーソル。
    for (final id in model.trackIds) {
      final v = model.track(id);
      if (v == null) continue;
      final color = OverlayCanvas.colorForSlot(v.colorSlot);
      final skeleton = v.skeleton;
      if (skeleton != null && skeleton.length == 21) {
        _paintSkeleton(canvas, size, skeleton, color);
      }
      final c = v.cursor;
      if (c != null) {
        final o = _p(c, size);
        canvas.drawCircle(
          o,
          v.pressed ? 12 : 9,
          Paint()
            ..style = PaintingStyle.fill
            ..color = v.pressed ? _darken(color) : color,
        );
        canvas.drawCircle(
          o,
          v.pressed ? 12 : 9,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white,
        );
      }
    }
    canvas.restore();
  }

  void _paintSkeleton(Canvas canvas, Size size, List<Vec2> lm, Color color) {
    final bone =
        Paint()
          ..color = color.withValues(alpha: 0.85)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke;
    for (final c in HandSkeleton.connections) {
      canvas.drawLine(_p(lm[c[0]], size), _p(lm[c[1]], size), bone);
    }
    final joint =
        Paint()
          ..color = color
          ..style = PaintingStyle.fill;
    for (final p in lm) {
      canvas.drawCircle(_p(p, size), 3, joint);
    }
  }

  Color _darken(Color c) => Color.alphaBlend(const Color(0x66000000), c);

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => true;
}
