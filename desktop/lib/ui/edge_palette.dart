import 'package:flutter/material.dart';

import '../core/pointer_state.dart';
import 'edge_palette_layout.dart';
import 'overlay_canvas.dart';

/// 全画面オーバーレイの描画（[OverlayCanvas]）に、画面端パレットを重ねたもの。
///
/// [showEdgePalette] が false のときは [OverlayCanvas] だけを描く。
class OverlayWithEdgePalette extends StatelessWidget {
  final OverlayModel model;
  final bool showEdgePalette;

  /// パレットの描画に使ったレイアウトを受け取る（[EdgePaletteOverlay.onLayout]）。
  final ValueChanged<EdgePaletteLayout>? onPaletteLayout;

  const OverlayWithEdgePalette({
    super.key,
    required this.model,
    required this.showEdgePalette,
    this.onPaletteLayout,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // パレットは下に敷き、手のカーソル・骨格・インクを上に描く
        // （スウォッチの上でもカーソルが隠れないように）。
        if (showEdgePalette)
          EdgePaletteOverlay(
            key: const ValueKey('overlay-edge-palette'),
            model: model,
            onLayout: onPaletteLayout,
          ),
        OverlayCanvas(model: model),
      ],
    );
  }
}

/// 画面端パレットの表示（見た目だけ）。
///
/// 配置は [EdgePaletteLayout] が返す矩形をそのまま使う。入力側のヒット判定も
/// 同じレイアウトを使うので、見た目と判定はずれない。
/// オーバーレイはクリックを透過するため、Flutter のタップには頼らない
/// （[IgnorePointer] で包む）。パレットへの手の入力は、OS 入力へ渡す前に
/// `PaletteInputRouter` が [onLayout] で受け取った同じレイアウトで判定する。
class EdgePaletteOverlay extends StatelessWidget {
  final OverlayModel model;

  /// 描画に使ったレイアウトを、計算のたびに知らせる（入力のヒット判定用）。
  /// build 中に呼ぶので、受け取り側は setState しないこと。
  final ValueChanged<EdgePaletteLayout>? onLayout;

  const EdgePaletteOverlay({super.key, required this.model, this.onLayout});

  /// 手のカーソルが上にあるスウォッチの色スロット（消しゴム中の手は除く）。
  static Set<int> hoveredSlots(OverlayModel model, EdgePaletteLayout layout) {
    final slots = <int>{};
    for (final id in model.trackIds) {
      final v = model.track(id);
      final c = v?.cursor;
      if (v == null || c == null || v.erasing) continue;
      final hit = layout.hitTestNormalized(c);
      if (hit.isSwatch) slots.add(hit.slot!);
    }
    return slots;
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (!(size.width > 0 && size.height > 0) || !size.isFinite) {
            return const SizedBox.shrink();
          }
          final layout = EdgePaletteLayout.compute(
            screenSize: size,
            devicePixelRatio: dpr,
          );
          onLayout?.call(layout);
          return AnimatedBuilder(
            animation: model,
            builder:
                (_, __) => CustomPaint(
                  size: size,
                  painter: EdgePalettePainter(
                    layout: layout,
                    selectedSlot: model.selectedColorSlot,
                    hoveredSlots: hoveredSlots(model, layout),
                  ),
                ),
          );
        },
      ),
    );
  }
}

/// [paintEdgePalette] を呼ぶだけの painter。
class EdgePalettePainter extends CustomPainter {
  final EdgePaletteLayout layout;
  final int? selectedSlot;
  final Set<int> hoveredSlots;

  const EdgePalettePainter({
    required this.layout,
    this.selectedSlot,
    this.hoveredSlots = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    paintEdgePalette(
      canvas,
      layout,
      selectedSlot: selectedSlot,
      hoveredSlots: hoveredSlots,
    );
  }

  @override
  bool shouldRepaint(covariant EdgePalettePainter old) =>
      old.selectedSlot != selectedSlot ||
      !identical(old.layout, layout) ||
      old.hoveredSlots.length != hoveredSlots.length ||
      !old.hoveredSlots.containsAll(hoveredSlots);
}

/// 画面端パレットを [layout] の矩形どおりに描く。
///
/// - パレットの背景: 半透明の白の角丸（画面を隠しすぎないよう薄め）。
/// - スウォッチ: 各矩形に内接する円。色は [EdgePaletteSwatch.color]。
/// - 選択中（[selectedSlot]）: 白い縁＋外側の濃い輪。既存の `ColorPalette` の
///   「白いリング」にそろえつつ、白い背景の上でも分かるよう外側に輪を足す。
/// - 手のカーソルが上にある（[hoveredSlots]）: スウォッチの色の淡い後光。
void paintEdgePalette(
  Canvas canvas,
  EdgePaletteLayout layout, {
  int? selectedSlot,
  Set<int> hoveredSlots = const {},
}) {
  final s = layout.swatchSize;
  final panel = RRect.fromRectAndRadius(
    layout.panelRect,
    Radius.circular(layout.panelRect.width / 2),
  );
  canvas.drawRRect(
    panel.shift(Offset(0, s * 0.04)),
    Paint()
      ..color = const Color(0x33000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.12),
  );
  canvas.drawRRect(panel, Paint()..color = const Color(0xDBFFFFFF));

  for (final swatch in layout.swatches) {
    final center = swatch.rect.center;
    final r = swatch.rect.shortestSide / 2;
    final color = swatch.color;
    final selected = swatch.slot == selectedSlot;

    if (hoveredSlots.contains(swatch.slot)) {
      canvas.drawCircle(
        center,
        r + s * 0.2,
        Paint()..color = color.withValues(alpha: 0.35),
      );
    }
    canvas.drawCircle(center, r, Paint()..color = color);
    if (selected) {
      final ring = (s * 0.08).clamp(3.0, 6.0);
      canvas.drawCircle(
        center,
        r - ring / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ring
          ..color = Colors.white,
      );
      canvas.drawCircle(
        center,
        r + s * 0.1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ring * 0.75
          ..color = const Color(0xFF222222),
      );
    } else {
      canvas.drawCircle(
        center,
        r - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0x55000000),
      );
    }
  }
}
