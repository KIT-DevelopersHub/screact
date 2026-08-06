import 'dart:math' as math;

import 'geom.dart';

/// One-Euro フィルタ（座標平滑化）。低速時はジッタを強く抑え、速い動きでは
/// 遅延を抑える。手指骨格・画面座標どちらの平滑化にも使う（要件5.x）。
class _OneEuro {
  final double minCutoff;
  final double beta;
  static const double dCutoff = 1.0; // 速度推定のカットオフ（固定）
  double? _xPrev;
  double? _dxPrev;
  int? _tPrevMs;

  _OneEuro({this.minCutoff = 1.0, this.beta = 0.02});

  static double _alpha(double cutoff, double dt) {
    final tau = 1.0 / (2 * math.pi * cutoff);
    return 1.0 / (1.0 + tau / dt);
  }

  double filter(double x, int tMs) {
    if (_xPrev == null || _tPrevMs == null) {
      _xPrev = x;
      _dxPrev = 0;
      _tPrevMs = tMs;
      return x;
    }
    var dt = (tMs - _tPrevMs!) / 1000.0;
    if (dt <= 0) dt = 1 / 60.0;
    final dx = (x - _xPrev!) / dt;
    final aD = _alpha(dCutoff, dt);
    final dxHat = aD * dx + (1 - aD) * (_dxPrev ?? 0);
    final cutoff = minCutoff + beta * dxHat.abs();
    final a = _alpha(cutoff, dt);
    final xHat = a * x + (1 - a) * _xPrev!;
    _xPrev = xHat;
    _dxPrev = dxHat;
    _tPrevMs = tMs;
    return xHat;
  }

  void reset() {
    _xPrev = null;
    _dxPrev = null;
    _tPrevMs = null;
  }
}

/// 2D 版（x/y 独立にフィルタ）。
class Vec2Filter {
  final _OneEuro _fx;
  final _OneEuro _fy;
  Vec2Filter({double minCutoff = 1.2, double beta = 0.03})
      : _fx = _OneEuro(minCutoff: minCutoff, beta: beta),
        _fy = _OneEuro(minCutoff: minCutoff, beta: beta);

  Vec2 filter(Vec2 p, int tMs) => Vec2(_fx.filter(p.x, tMs), _fy.filter(p.y, tMs));

  void reset() {
    _fx.reset();
    _fy.reset();
  }
}
