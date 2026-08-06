import 'dart:math' as math;

/// 2D vector used across the pure-Dart core so it stays testable without a
/// Flutter binding. UI code converts to `Offset` at the edge.
class Vec2 {
  final double x, y;
  const Vec2(this.x, this.y);

  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);

  double distanceTo(Vec2 o) => math.sqrt(_sq(x - o.x) + _sq(y - o.y));
  double get length => math.sqrt(_sq(x) + _sq(y));

  static double _sq(double v) => v * v;

  @override
  String toString() => 'Vec2(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})';
}
