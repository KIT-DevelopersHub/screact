import 'package:flutter/material.dart';

import '../core/pointer_state.dart';
import 'overlay_canvas.dart';

/// オーバーレイ右下の描画色パレット。スウォッチをタップすると、以後の新規
/// ストロークへその色を適用する（ユーザー選択優先）。選択中はリングと拡大で
/// ハイライトし、同じ色をもう一度押すとトラック別自動色へ戻す。
///
/// 色は [OverlayCanvas.colorForSlot]（インク描画と同じ正本）から引く。
class ColorPalette extends StatelessWidget {
  final OverlayModel model;
  const ColorPalette({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final selected = model.selectedColorSlot;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(30),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 12,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var slot = 0; slot < OverlayModel.colorSlotCount; slot++) ...[
                if (slot > 0) const SizedBox(width: 12),
                _Swatch(
                  slot: slot,
                  selected: selected == slot,
                  onTap: () => model.selectColorSlot(slot),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  final int slot;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch({
    required this.slot,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = OverlayCanvas.colorForSlot(slot);
    return Semantics(
      button: true,
      selected: selected,
      label: '描画色 ${slot + 1}',
      child: GestureDetector(
        key: ValueKey('color-swatch-$slot'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: selected ? 46 : 38,
          height: selected ? 46 : 38,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.white : const Color(0x55000000),
              width: selected ? 4 : 2,
            ),
            boxShadow:
                selected
                    ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.6),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                    : null,
          ),
        ),
      ),
    );
  }
}
