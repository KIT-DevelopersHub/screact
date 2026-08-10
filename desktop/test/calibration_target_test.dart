import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/ui/calibration_target.dart';

/// マーカー中心（宛先矩形の中心）を画面正規化したもの。
(double, double) centerNormalized(Rect r, Size s) =>
    ((r.left + r.width / 2) / s.width, (r.top + r.height / 2) / s.height);

void main() {
  group('CalibrationTargetGeometry: アスペクト比非依存の4隅配置', () {
    const sizes = [
      Size(1920, 1080), // 16:9
      Size(2560, 1080), // 21:9 ウルトラワイド
      Size(1080, 1920), // 縦向き
      Size(1440, 900), // 16:10
      Size(1024, 768), // 4:3
    ];

    test('マーカーは常に正方形（歪まない）', () {
      for (final s in sizes) {
        for (final r in CalibrationTargetGeometry.markerRects(s)) {
          expect(r.width, closeTo(r.height, 1e-9), reason: '$s');
          expect(r.width, greaterThan(0), reason: '$s');
        }
      }
    });

    test('4つのマーカーは画面内に完全に収まり四隅へ吸着する', () {
      for (final s in sizes) {
        final m = CalibrationTargetGeometry.margin(s);
        final rects = CalibrationTargetGeometry.markerRects(s);
        for (final r in rects) {
          expect(r.left, greaterThanOrEqualTo(-1e-6), reason: '$s');
          expect(r.top, greaterThanOrEqualTo(-1e-6), reason: '$s');
          expect(r.right, lessThanOrEqualTo(s.width + 1e-6), reason: '$s');
          expect(r.bottom, lessThanOrEqualTo(s.height + 1e-6), reason: '$s');
        }
        // TL/TR/BR/BL の順で、各マーカーが正しい角に固定マージンで吸着。
        final tl = rects[0], tr = rects[1], br = rects[2], bl = rects[3];
        expect(tl.left, closeTo(m, 1e-9), reason: '$s TL.left');
        expect(tl.top, closeTo(m, 1e-9), reason: '$s TL.top');
        expect(tr.right, closeTo(s.width - m, 1e-9), reason: '$s TR.right');
        expect(br.bottom, closeTo(s.height - m, 1e-9), reason: '$s BR.bottom');
        expect(bl.left, closeTo(m, 1e-9), reason: '$s BL.left');
      }
    });

    test('insets() は markerRects の中心と一致する', () {
      for (final s in sizes) {
        final (ix, iy) = CalibrationTargetGeometry.insets(s);
        final rects = CalibrationTargetGeometry.markerRects(s);
        // TL の中心が (insetX, insetY)、BR の中心が (1-insetX, 1-insetY)。
        final (tlx, tly) = centerNormalized(rects[0], s);
        final (brx, bry) = centerNormalized(rects[2], s);
        expect(tlx, closeTo(ix, 1e-9), reason: '$s');
        expect(tly, closeTo(iy, 1e-9), reason: '$s');
        expect(brx, closeTo(1 - ix, 1e-9), reason: '$s');
        expect(bry, closeTo(1 - iy, 1e-9), reason: '$s');
        // 妥当な範囲（画面内の内側）。
        expect(ix, inInclusiveRange(0.0, 0.45), reason: '$s');
        expect(iy, inInclusiveRange(0.0, 0.45), reason: '$s');
      }
    });

    test('マーカーサイズ/マージンは短辺のみに依存（縦横入れ替えで不変）', () {
      const wide = Size(2560, 1080);
      const tall = Size(1080, 2560);
      expect(CalibrationTargetGeometry.markerSize(wide),
          closeTo(CalibrationTargetGeometry.markerSize(tall), 1e-9));
      expect(CalibrationTargetGeometry.margin(wide),
          closeTo(CalibrationTargetGeometry.margin(tall), 1e-9));
    });

    test('小さいウィンドウでも左右/上下のマーカーが重ならない', () {
      const small = Size(420, 320);
      final rects = CalibrationTargetGeometry.markerRects(small);
      final tl = rects[0], tr = rects[1], bl = rects[3];
      expect(tl.right, lessThan(tr.left), reason: '左右が重ならない');
      expect(tl.bottom, lessThan(bl.top), reason: '上下が重ならない');
    });

    test('ソース矩形は4隅ぶん・すべて画像内の正方形', () {
      final src = CalibrationTargetGeometry.sourceRects;
      expect(src.length, 4);
      for (final r in src) {
        expect(r.width, closeTo(r.height, 1e-9));
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.top, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(CalibrationTargetGeometry.imageWidth));
        expect(
            r.bottom, lessThanOrEqualTo(CalibrationTargetGeometry.imageHeight));
      }
    });
  });
}
