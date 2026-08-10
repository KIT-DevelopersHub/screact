import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 位置合わせ用 ArUco ターゲットの「アスペクト比非依存」レイアウト計算。
///
/// 背景（なぜ必要か）:
/// 従来は同梱画像 assets/calibration-target-1920x1080.png を [BoxFit.fill] で
/// 画面いっぱいに引き伸ばして表示していた。この方式だと
///  - 16:9 以外のディスプレイでは各マーカーが正方形でなく長方形に歪む
///    （ArUco検出が不安定になる）、
///  - マーカー中心のインセットが固定比率(0.125 / 0.2222)のままなので、縦横比が
///    違うと4隅が「画面の角」から大きく離れ、外挿誤差が拡大する、
/// という問題があった。
///
/// 本クラスは実際の表示領域 [Size]（論理px）から、各マーカーを
///  - 正方形のまま（歪ませない）、
///  - 画面の4隅に固定マージンで吸着、
///  - サイズは画面短辺にスケール、
/// で配置する矩形と、その中心のインセット（画面正規化）を算出する。
/// インセットはホモグラフィ（[CalibrationConfig.markerInsetX/Y]）へそのまま渡すので、
/// 「描画位置」と「位置合わせが期待する座標系」が常に一致する。
class CalibrationTargetGeometry {
  // --- 同梱画像内のマーカー配置（実測・1920x1080）---
  /// 同梱ターゲット画像の寸法。
  static const double imageWidth = 1920;
  static const double imageHeight = 1080;

  /// 各マーカーの一辺（px）と外余白（px）。中心は各辺から 110+260/2 = 240px 内側。
  static const double _srcMarker = 260;
  static const double _srcMargin = 110;

  /// 画面四隅(TL,TR,BR,BL)＝ArUco ID 10,11,12,13 の順に対応する、
  /// 同梱画像内のソース矩形。スライスして再配置してもID→隅の対応を壊さない。
  static const List<Rect> sourceRects = [
    Rect.fromLTWH(_srcMargin, _srcMargin, _srcMarker, _srcMarker), // TL / id10
    Rect.fromLTWH(imageWidth - _srcMargin - _srcMarker, _srcMargin, _srcMarker,
        _srcMarker), // TR / id11
    Rect.fromLTWH(imageWidth - _srcMargin - _srcMarker,
        imageHeight - _srcMargin - _srcMarker, _srcMarker, _srcMarker), // BR/id12
    Rect.fromLTWH(_srcMargin, imageHeight - _srcMargin - _srcMarker, _srcMarker,
        _srcMarker), // BL / id13
  ];

  // --- 画面側レイアウトのスケール方針（既定値）---
  /// マーカー一辺 = 画面短辺 * [_markerSizeFraction]（[_minMarker].._maxMarker にクランプ）。
  static const double _markerSizeFraction = 0.16;
  static const double _minMarker = 96;
  static const double _maxMarker = 320;

  /// 角からの固定マージン = 画面短辺 * [_marginFraction]（[_minMargin].._maxMargin）。
  static const double _marginFraction = 0.03;
  static const double _minMargin = 16;
  static const double _maxMargin = 56;

  /// 表示領域 [size] に対するマーカー一辺（論理px）。
  static double markerSize(Size size) {
    final shortSide = size.shortestSide;
    var s = (shortSide * _markerSizeFraction).clamp(_minMarker, _maxMarker);
    // 小さいウィンドウで左右/上下のマーカーが重ならないよう上限を抑える。
    final maxByShort = (shortSide - 2 * margin(size)) / 2;
    if (maxByShort > 0 && s > maxByShort) s = maxByShort;
    return s;
  }

  /// 表示領域 [size] に対する角マージン（論理px）。
  static double margin(Size size) =>
      (size.shortestSide * _marginFraction).clamp(_minMargin, _maxMargin);

  /// 画面四隅(TL,TR,BR,BL)へ配置するマーカーの宛先矩形。[sourceRects] と同順。
  static List<Rect> markerRects(Size size) {
    final m = margin(size);
    final k = markerSize(size);
    final w = size.width, h = size.height;
    return [
      Rect.fromLTWH(m, m, k, k), // TL
      Rect.fromLTWH(w - m - k, m, k, k), // TR
      Rect.fromLTWH(w - m - k, h - m - k, k, k), // BR
      Rect.fromLTWH(m, h - m - k, k, k), // BL
    ];
  }

  /// マーカー中心の画面正規化インセット（X, Y）。全辺同一マージンなので対称。
  /// ホモグラフィの insetRect(insetX, insetY) と一致する。
  static (double, double) insets(Size size) {
    final m = margin(size);
    final k = markerSize(size);
    final cx = m + k / 2;
    final cy = m + k / 2;
    return (cx / size.width, cy / size.height);
  }
}

/// 位置合わせ用 ArUco ターゲットを、表示領域の実寸から4隅へ動的配置して描画する。
///
/// [onInsets] は算出したマーカー中心インセット(X,Y)を返す（リサイズ時も追従）。
/// 呼び出し側はこれを [CalibrationConfig.markerInsetX/Y] へ反映し、
/// 描画位置とホモグラフィの座標系を一致させる。
class CalibrationTargetView extends StatefulWidget {
  const CalibrationTargetView({
    super.key,
    this.assetName = 'assets/calibration-target-1920x1080.png',
    required this.onInsets,
  });

  final String assetName;
  final void Function(double insetX, double insetY) onInsets;

  @override
  State<CalibrationTargetView> createState() => _CalibrationTargetViewState();
}

class _CalibrationTargetViewState extends State<CalibrationTargetView> {
  ui.Image? _image;
  double? _lastInsetX, _lastInsetY;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await rootBundle.load(widget.assetName);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => _image = frame.image);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _reportInsets(Size size) {
    final (ix, iy) = CalibrationTargetGeometry.insets(size);
    if (ix == _lastInsetX && iy == _lastInsetY) return;
    _lastInsetX = ix;
    _lastInsetY = iy;
    // build 中に setState を伴わない純粋なコールバック（config のフィールド更新のみ）。
    // 描画とホモグラフィの座標系を常に一致させるため、レイアウト確定時に反映する。
    widget.onInsets(ix, iy);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.isFinite && !size.isEmpty) _reportInsets(size);
        return CustomPaint(
          size: Size.infinite,
          painter: _CalibrationTargetPainter(_image),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

class _CalibrationTargetPainter extends CustomPainter {
  _CalibrationTargetPainter(this.image);

  final ui.Image? image;

  @override
  void paint(Canvas canvas, Size size) {
    // 白背景（各マーカー周囲のクワイエットゾーンを確保しArUco検出を安定させる）。
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    final img = image;
    if (img == null || size.isEmpty) return;

    final dstRects = CalibrationTargetGeometry.markerRects(size);
    final srcRects = CalibrationTargetGeometry.sourceRects;
    final paint = Paint()..filterQuality = FilterQuality.high;
    for (var i = 0; i < dstRects.length; i++) {
      canvas.drawImageRect(img, srcRects[i], dstRects[i], paint);
    }
  }

  @override
  bool shouldRepaint(_CalibrationTargetPainter old) => old.image != image;
}
