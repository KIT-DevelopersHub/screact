import 'package:flutter/material.dart';

import '../core/pointer_state.dart';

/// オーバーレイ右下の「大きな色丸」。実機で確実に狙えるよう大きく（直径 [diameter]px）、
/// 1回押すたびに描画色が 赤 → 黄 → 緑 → 青 → 赤 … と循環する（初期表示は青）。
/// 丸に表示中の色が、以後のペン描画色になる（[OverlayModel.penColor] と連動）。
///
/// クリックはこの丸の領域だけで受ける（透過オーバーレイの他操作と競合しない）。
/// マウスクリックはネイティブ側が色丸の矩形に入った時だけ窓の ignoresMouseEvents を
/// 外して届ける。ピンチ（手）クリックは [OverlayModel.colorButtonRect] とのヒット
/// テストで色送りに配線する。
class ColorPalette extends StatelessWidget {
  final OverlayModel model;
  const ColorPalette({super.key, required this.model});

  /// 色丸の直径（論理px）。カーソルの丸（[OverlayCanvas.cursorDiameter]=18）とは独立に
  /// 大きくして、実機のマウス/ピンチで確実に狙えるようにする（消しゴムの丸は不変）。
  static const double diameter = 168;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final color = model.penColor;
        return Semantics(
          button: true,
          label: 'ペンの色を変える（押すたびに 赤・黄・緑・青 と切り替わります）',
          // 円形にヒットテストを限定し、四隅の余白ではクリックを拾わない。
          child: ClipOval(
            child: SizedBox(
              width: diameter,
              height: diameter,
              child: GestureDetector(
                key: const ValueKey('pen-color-cycle'),
                behavior: HitTestBehavior.opaque,
                onTap: model.cyclePenColor,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      const BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                      BoxShadow(
                        color: color.withValues(alpha: 0.5),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
