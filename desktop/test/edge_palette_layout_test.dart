import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/ui/edge_palette_layout.dart';
import 'package:thehack_overlay/ui/overlay_canvas.dart';

/// 画面端パレットのレイアウトとヒット判定が、解像度・DPI・縦横比を変えても
/// 見た目の矩形と一致することを確かめる。
void main() {
  // (物理解像度, devicePixelRatio)。論理サイズ = 物理 / DPR。
  const cases = <(Size, double)>[
    (Size(1920, 1080), 1.0),
    (Size(1920, 1080), 1.25),
    (Size(2560, 1440), 1.0),
    (Size(2560, 1440), 1.5),
    (Size(3840, 2160), 1.0),
    (Size(3840, 2160), 2.0),
    (Size(3840, 2160), 1.75),
    (Size(1080, 1920), 1.0), // 縦長
    (Size(1024, 768), 1.0), // 4:3
    (Size(3440, 1440), 1.0), // 21:9
    (Size(2880, 1800), 2.0), // 16:10 Retina
  ];

  for (final (physical, dpr) in cases) {
    final logical = Size(physical.width / dpr, physical.height / dpr);
    final label =
        '${physical.width.toInt()}x${physical.height.toInt()} @${dpr}x';

    group(label, () {
      final layout = EdgePaletteLayout.compute(
        screenSize: logical,
        devicePixelRatio: dpr,
      );
      final screen = Offset.zero & logical;

      test('スウォッチ数と色は既存の色スロットと一致する', () {
        expect(layout.swatches.length, OverlayModel.colorSlotCount);
        for (var i = 0; i < layout.swatches.length; i++) {
          expect(layout.swatches[i].slot, i);
          expect(layout.swatches[i].color, OverlayCanvas.colorForSlot(i));
        }
      });

      test('右端の中央に縦並びで、画面内に収まる', () {
        final panel = layout.panelRect;
        expect(screen.contains(panel.topLeft), isTrue);
        expect(panel.right, lessThanOrEqualTo(logical.width));
        expect(panel.bottom, lessThanOrEqualTo(logical.height));
        // 右端に寄っている（画面の右 1/4 に入る）。
        expect(panel.left, greaterThan(logical.width * 0.75));
        // 縦の中央（物理 1px の丸め誤差まで）。
        expect(
          (panel.center.dy - logical.height / 2).abs(),
          lessThanOrEqualTo(1 / dpr + 1e-9),
        );
        for (var i = 1; i < layout.swatches.length; i++) {
          final a = layout.swatches[i - 1].rect;
          final b = layout.swatches[i].rect;
          expect(b.left, a.left);
          expect(b.top, greaterThan(a.bottom));
          // 隣の判定とは重ならない（接するのは可。浮動小数の誤差は許す）。
          expect(
            layout.swatches[i - 1].hitRect.bottom,
            lessThanOrEqualTo(layout.swatches[i].hitRect.top + 1e-9),
          );
        }
        for (final s in layout.swatches) {
          expect(panel.contains(s.rect.topLeft), isTrue);
          expect(s.rect.right, lessThanOrEqualTo(panel.right));
          expect(s.rect.bottom, lessThanOrEqualTo(panel.bottom));
        }
      });

      test('大きさは最小・最大の範囲で、辺は物理ピクセル格子に揃う', () {
        expect(
          layout.swatchSize,
          inInclusiveRange(
            EdgePaletteLayout.minSwatchSize - 1,
            EdgePaletteLayout.maxSwatchSize + 1,
          ),
        );
        bool onGrid(double v) {
          final p = v * dpr;
          return (p - p.roundToDouble()).abs() < 1e-6;
        }

        for (final s in layout.swatches) {
          final r = layout.toPhysicalRect(s.rect);
          for (final v in [r.left, r.top, r.right, r.bottom]) {
            expect(onGrid(v / dpr), isTrue, reason: '$v が格子外');
          }
        }
      });

      test('正規化座標と論理ピクセルの判定が見た目の矩形と一致する', () {
        for (final s in layout.swatches) {
          final n = layout.toNormalizedRect(s.rect);
          // 中心・四隅の少し内側は、正規化でも論理でもそのスウォッチ。
          final probes = <Offset>[
            s.rect.center,
            s.rect.topLeft + const Offset(0.5, 0.5),
            s.rect.bottomRight - const Offset(0.5, 0.5),
            s.rect.topRight + const Offset(-0.5, 0.5),
            s.rect.bottomLeft + const Offset(0.5, -0.5),
          ];
          for (final p in probes) {
            expect(layout.hitTestLogical(p), EdgePaletteHit.swatch(s.slot));
            final v = Vec2(p.dx / logical.width, p.dy / logical.height);
            expect(layout.hitTestNormalized(v), EdgePaletteHit.swatch(s.slot));
          }
          final c = Vec2(n.center.dx, n.center.dy);
          expect(layout.hitTestNormalized(c), EdgePaletteHit.swatch(s.slot));
        }
      });

      test('見た目より少し外でも当たり、判定の外はパレット外になる', () {
        final slop = layout.swatchSize * EdgePaletteLayout.hitSlopFraction;
        final s = layout.swatches.first;
        // 左側へ余白の半分だけ外れても当たる。
        final nearLeft = Offset(s.rect.left - slop / 2, s.rect.center.dy);
        expect(layout.hitTestLogical(nearLeft), EdgePaletteHit.swatch(0));
        // パレットの判定領域より左は外。
        final outside = Offset(
          layout.panelHitRect.left - 1,
          layout.panelRect.center.dy,
        );
        expect(layout.hitTestLogical(outside), EdgePaletteHit.none);
        expect(
          layout.hitTestNormalized(const Vec2(0.5, 0.5)),
          EdgePaletteHit.none,
        );
        expect(
          layout.hitTestNormalized(const Vec2(0.0, 0.0)),
          EdgePaletteHit.none,
        );
      });

      test('パレットの背景の上（スウォッチの判定の外）は panel になる', () {
        final panel = layout.panelRect;
        // 背景の上端付近。スウォッチの判定は余白分しか広がらないため外れる。
        final p = Offset(panel.center.dx, panel.top + 0.5);
        final slop = layout.swatchSize * EdgePaletteLayout.hitSlopFraction;
        final pad = layout.swatches.first.rect.top - panel.top;
        if (pad > slop + 0.5) {
          expect(layout.hitTestLogical(p), EdgePaletteHit.panel);
        } else {
          expect(layout.hitTestLogical(p).isInsidePalette, isTrue);
        }
        // 背景のすぐ外（余白内）もパレット内として扱う。
        final justAbove = Offset(panel.center.dx, panel.top - 1);
        expect(layout.hitTestLogical(justAbove).isInsidePalette, isTrue);
      });

      test('隣り合うスウォッチの間は中心に近い方を返す', () {
        for (var i = 1; i < layout.swatches.length; i++) {
          final a = layout.swatches[i - 1].rect;
          final b = layout.swatches[i].rect;
          final mid = (a.bottom + b.top) / 2;
          final x = a.center.dx;
          expect(layout.hitTestLogical(Offset(x, mid - 1)).slot, i - 1);
          expect(layout.hitTestLogical(Offset(x, mid + 1)).slot, i);
        }
      });
    });
  }

  test('同じ物理解像度なら DPR が違っても正規化した配置はほぼ同じ', () {
    final a = EdgePaletteLayout.compute(screenSize: const Size(1920, 1080));
    final b = EdgePaletteLayout.compute(
      screenSize: const Size(960, 540),
      devicePixelRatio: 2,
    );
    // b の論理サイズは小さいため最小値が効き得る。最小値が効かない組で比べる。
    final c = EdgePaletteLayout.compute(screenSize: const Size(3840, 2160));
    final d = EdgePaletteLayout.compute(
      screenSize: const Size(1920, 1080),
      devicePixelRatio: 2,
    );
    expect(b.swatchSize, greaterThanOrEqualTo(EdgePaletteLayout.minSwatchSize));
    expect(a.swatches.length, b.swatches.length);
    final nc = c.toNormalizedRect(c.swatches.first.rect);
    final nd = d.toNormalizedRect(d.swatches.first.rect);
    // 3840x2160@1 は最大値で頭打ち、1920x1080@2 は割合どおり（75.6px）。
    // 大きさは違うが、どちらも右端中央の縦並び。
    expect(nc.right, closeTo(nd.right, 0.02));
  });

  test('極端に低い画面でも縦に収まる', () {
    final layout = EdgePaletteLayout.compute(screenSize: const Size(800, 200));
    expect(layout.panelRect.top, greaterThanOrEqualTo(0));
    expect(layout.panelRect.bottom, lessThanOrEqualTo(200));
    for (final s in layout.swatches) {
      expect(
        layout.hitTestLogical(s.rect.center),
        EdgePaletteHit.swatch(s.slot),
      );
    }
  });

  test('不正な入力は拒否する', () {
    expect(
      () => EdgePaletteLayout.compute(screenSize: Size.zero),
      throwsArgumentError,
    );
    expect(
      () => EdgePaletteLayout.compute(
        screenSize: const Size(100, 100),
        devicePixelRatio: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => EdgePaletteLayout.compute(
        screenSize: const Size(100, 100),
        slotCount: 0,
      ),
      throwsArgumentError,
    );
  });
}
