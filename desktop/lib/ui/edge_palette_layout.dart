import 'dart:math' as math;
import 'dart:ui' show Color, Offset, Rect, Size;

import '../core/geom.dart';
import '../core/pointer_state.dart';
import 'overlay_canvas.dart';

/// 画面端パレットの 1 スウォッチ分のレイアウト。
///
/// [rect] は見た目の矩形、[hitRect] はヒット判定の矩形（見た目より
/// [EdgePaletteLayout.hitSlopFraction] だけ広い）。どちらも論理ピクセル。
class EdgePaletteSwatch {
  /// 色スロット（[OverlayCanvas.colorForSlot] の引数と同じ）。
  final int slot;
  final Rect rect;
  final Rect hitRect;

  const EdgePaletteSwatch({
    required this.slot,
    required this.rect,
    required this.hitRect,
  });

  /// 表示色。色の正本は [OverlayCanvas.colorForSlot]。
  Color get color => OverlayCanvas.colorForSlot(slot);
}

/// ヒット判定の結果の種類。
enum EdgePaletteHitKind {
  /// パレットの外。
  none,

  /// パレットの領域内だが、どのスウォッチにも入っていない。
  panel,

  /// いずれかのスウォッチに入っている（[EdgePaletteHit.slot] が有効）。
  swatch,
}

/// ヒット判定の結果。
class EdgePaletteHit {
  final EdgePaletteHitKind kind;

  /// [kind] が [EdgePaletteHitKind.swatch] のときの色スロット。それ以外は null。
  final int? slot;

  const EdgePaletteHit._(this.kind, this.slot);
  static const EdgePaletteHit none = EdgePaletteHit._(
    EdgePaletteHitKind.none,
    null,
  );
  static const EdgePaletteHit panel = EdgePaletteHit._(
    EdgePaletteHitKind.panel,
    null,
  );
  const EdgePaletteHit.swatch(int this.slot) : kind = EdgePaletteHitKind.swatch;

  bool get isSwatch => kind == EdgePaletteHitKind.swatch;
  bool get isInsidePalette => kind != EdgePaletteHitKind.none;

  @override
  bool operator ==(Object other) =>
      other is EdgePaletteHit && other.kind == kind && other.slot == slot;

  @override
  int get hashCode => Object.hash(kind, slot);

  @override
  String toString() => 'EdgePaletteHit($kind, slot: $slot)';
}

/// 画面端パレットの配置とヒット判定を計算する（描画には依存しない）。
///
/// 描画（パレットの表示）と入力判定（手の正規化座標がどの色に入ったか）は、
/// どちらもこのクラスが返す矩形だけを使う。両者が別々に計算すると、解像度や
/// DPI によって見た目と判定がずれるため。
///
/// 推奨配置: 画面の右端の中央に、[OverlayModel.colorSlotCount] 色を縦に並べる。
/// 大きさは画面の短辺に対する割合で決め、最小・最大で制限する。
/// 矩形の辺は物理ピクセルの格子に揃える（[devicePixelRatio] を使う）。
///
/// 下の定数はすべて推奨案の初期値で、実機で調整予定。
class EdgePaletteLayout {
  /// スウォッチの一辺 = 画面の短辺 × この割合（実機で調整予定）。
  static const double swatchSizeFraction = 0.07;

  /// スウォッチの一辺の最小値（論理ピクセル）。手の指先で狙える大きさ（実機で調整予定）。
  static const double minSwatchSize = 48;

  /// スウォッチの一辺の最大値（論理ピクセル）。大画面で邪魔にならない大きさ（実機で調整予定）。
  static const double maxSwatchSize = 120;

  /// スウォッチ同士の間隔 = スウォッチの一辺 × この割合（実機で調整予定）。
  static const double spacingFraction = 0.5;

  /// パレットの背景の内側余白 = スウォッチの一辺 × この割合（実機で調整予定）。
  static const double panelPaddingFraction = 0.25;

  /// 画面の右端からパレットの背景までの余白 = スウォッチの一辺 × この割合（実機で調整予定）。
  static const double edgeMarginFraction = 0.25;

  /// ヒット判定を見た目より広げる量 = スウォッチの一辺 × この割合（実機で調整予定）。
  ///
  /// [spacingFraction] の半分以下にして、隣り合うスウォッチの判定が重ならない
  /// ようにする（ちょうど半分なら境界で接する。接した点は中心に近い方を選ぶ）。
  static const double hitSlopFraction = 0.25;

  /// 論理ピクセルでの画面サイズ。
  final Size screenSize;

  /// 論理ピクセル 1 個あたりの物理ピクセル数。
  final double devicePixelRatio;

  /// スウォッチの一辺（論理ピクセル、物理ピクセル格子に揃えた値）。
  final double swatchSize;

  /// パレットの背景の矩形（論理ピクセル）。
  final Rect panelRect;

  /// パレット全体のヒット判定の矩形（論理ピクセル、画面内に切り詰めたもの）。
  final Rect panelHitRect;

  /// 上から順のスウォッチ。index は色スロットと一致する。
  final List<EdgePaletteSwatch> swatches;

  const EdgePaletteLayout._({
    required this.screenSize,
    required this.devicePixelRatio,
    required this.swatchSize,
    required this.panelRect,
    required this.panelHitRect,
    required this.swatches,
  });

  /// 画面サイズ（論理ピクセル）と DPI からレイアウトを計算する。
  factory EdgePaletteLayout.compute({
    required Size screenSize,
    double devicePixelRatio = 1.0,
    int slotCount = OverlayModel.colorSlotCount,
  }) {
    if (!(screenSize.width > 0 && screenSize.height > 0)) {
      throw ArgumentError.value(screenSize, 'screenSize', '幅と高さは正の値');
    }
    if (!(devicePixelRatio > 0) || !devicePixelRatio.isFinite) {
      throw ArgumentError.value(devicePixelRatio, 'devicePixelRatio', '正の値');
    }
    if (slotCount <= 0) {
      throw ArgumentError.value(slotCount, 'slotCount', '1 以上');
    }

    double snap(double v) =>
        (v * devicePixelRatio).roundToDouble() / devicePixelRatio;

    final shortSide = math.min(screenSize.width, screenSize.height);
    var size = (shortSide * swatchSizeFraction).clamp(
      minSwatchSize,
      maxSwatchSize,
    );
    double spacingOf(double s) => s * spacingFraction;
    double paddingOf(double s) => s * panelPaddingFraction;
    double marginOf(double s) => s * edgeMarginFraction;
    double columnHeight(double s) =>
        slotCount * s + (slotCount - 1) * spacingOf(s) + 2 * paddingOf(s);
    // 極端に低い画面では、縦に収まるまで縮める（最小値より優先して画面内に収める）。
    final maxColumn = screenSize.height - 2 * marginOf(size);
    if (columnHeight(size) > maxColumn) {
      final perUnit = columnHeight(1.0) + 2 * edgeMarginFraction;
      size = screenSize.height / perUnit;
    }
    size = math.max(snap(size), 1 / devicePixelRatio);

    final spacing = snap(spacingOf(size));
    final padding = snap(paddingOf(size));
    final margin = snap(marginOf(size));
    // 隣同士の判定が重ならないよう、間隔の半分を上限にする。
    final slop = math.min(snap(size * hitSlopFraction), spacing / 2);

    final panelWidth = size + 2 * padding;
    final panelHeight =
        slotCount * size + (slotCount - 1) * spacing + 2 * padding;
    final panelRight = screenSize.width - margin;
    final panelLeft = snap(panelRight - panelWidth);
    final panelTop = snap((screenSize.height - panelHeight) / 2);
    final panelRect = Rect.fromLTWH(
      panelLeft,
      panelTop,
      panelWidth,
      panelHeight,
    );
    final screenRect = Offset.zero & screenSize;

    final swatches = <EdgePaletteSwatch>[
      for (var slot = 0; slot < slotCount; slot++)
        () {
          final rect = Rect.fromLTWH(
            panelLeft + padding,
            panelTop + padding + slot * (size + spacing),
            size,
            size,
          );
          return EdgePaletteSwatch(
            slot: slot,
            rect: rect,
            hitRect: rect.inflate(slop).intersect(screenRect),
          );
        }(),
    ];

    return EdgePaletteLayout._(
      screenSize: screenSize,
      devicePixelRatio: devicePixelRatio,
      swatchSize: size,
      panelRect: panelRect,
      panelHitRect: panelRect.inflate(slop).intersect(screenRect),
      swatches: List.unmodifiable(swatches),
    );
  }

  /// 論理ピクセルの矩形を正規化座標（0..1）の矩形へ変換する。
  Rect toNormalizedRect(Rect logical) => Rect.fromLTRB(
    logical.left / screenSize.width,
    logical.top / screenSize.height,
    logical.right / screenSize.width,
    logical.bottom / screenSize.height,
  );

  /// 論理ピクセルの矩形を物理ピクセルの矩形へ変換する。
  Rect toPhysicalRect(Rect logical) => Rect.fromLTRB(
    logical.left * devicePixelRatio,
    logical.top * devicePixelRatio,
    logical.right * devicePixelRatio,
    logical.bottom * devicePixelRatio,
  );

  /// 正規化座標（0..1）を論理ピクセルへ変換する。
  Offset normalizedToLogical(Vec2 p) =>
      Offset(p.x * screenSize.width, p.y * screenSize.height);

  /// 論理ピクセルの点でヒット判定する。
  EdgePaletteHit hitTestLogical(Offset p) {
    if (!panelHitRect.contains(p)) return EdgePaletteHit.none;
    EdgePaletteSwatch? best;
    var bestDist = double.infinity;
    for (final s in swatches) {
      if (!s.hitRect.contains(p)) continue;
      final d = (s.rect.center - p).distanceSquared;
      if (d < bestDist) {
        best = s;
        bestDist = d;
      }
    }
    return best == null
        ? EdgePaletteHit.panel
        : EdgePaletteHit.swatch(best.slot);
  }

  /// 手の正規化座標（0..1）でヒット判定する。
  EdgePaletteHit hitTestNormalized(Vec2 p) =>
      hitTestLogical(normalizedToLogical(p));
}
