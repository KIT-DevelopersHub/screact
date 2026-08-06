import 'dart:math' as math;

import 'geom.dart';
import '../protocol/messages.dart';

/// 4点対応から求めた 3x3 ホモグラフィ行列。カメラ正規化座標（ArUcoで囲まれた
/// 投影面）を画面正規化座標(0..1)へ写す。位置合わせで作成する（要件: ホモグラフィ変換）。
class Homography {
  final List<double> h; // 9要素・行優先
  const Homography(this.h);

  /// src(カメラ正規化)→dst(画面正規化) の4点対応から算出。
  static Homography? fromCorrespondences(List<Vec2> src, List<Vec2> dst) {
    if (src.length != 4 || dst.length != 4) return null;
    // 8x9 の同次連立を作り、h33=1 に固定した 8x8 を解く。
    final a = <List<double>>[];
    final b = <double>[];
    for (var i = 0; i < 4; i++) {
      final x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y;
      a.add([x, y, 1, 0, 0, 0, -u * x, -u * y]);
      b.add(u);
      a.add([0, 0, 0, x, y, 1, -v * x, -v * y]);
      b.add(v);
    }
    final sol = _solve(a, b);
    if (sol == null) return null;
    return Homography([...sol, 1.0]);
  }

  /// キャリブ画像のマーカーID → 画面四隅の対応（TL, TR, BR, BL の順）。
  /// チーム確定仕様:「マーカーIDと画面四隅の対応付け」はPC側の責務。
  static const List<int> cornerMarkerIds = [10, 11, 12, 13];

  /// 4つのArUcoマーカー中心から画面へのホモグラフィ。
  /// ID 10..13 が揃っていれば「ID→四隅の対応付け」で割り当てる（スマホが
  /// 逆さま・横向きでも正しく写る）。揃わない場合は幾何順序（TL,TR,BR,BL）
  /// へ並べ替える従来動作にフォールバックする。
  /// [insetX]/[insetY] はマーカー中心が画面端から内側にある割合
  /// （キャリブ画像の余白ぶんを外挿して画面全域へ写すための補正）。
  static Homography? fromMarkers(List<Marker> markers,
      {double insetX = 0, double insetY = 0}) {
    if (markers.length < 4) return null;
    final byId = {for (final m in markers) m.id: m};
    final List<Vec2> src;
    if (cornerMarkerIds.every(byId.containsKey)) {
      src = [for (final id in cornerMarkerIds) byId[id]!.center];
    } else {
      src = orderQuadCorners(markers.take(4).map((m) => m.center).toList());
    }
    return fromCorrespondences(src, insetRect(insetX, insetY));
  }

  /// スライドの四隅（順不同・カメラ正規化）→ スライド座標(0..1)のホモグラフィ。
  /// 斜め・下から等の台形歪みも full homography（射影変換）で正確に写す。
  /// [insetX]/[insetY] は検知点が実画面端より内側にある場合の外挿補正。
  static Homography? fromCorners(List<Vec2> corners,
      {double insetX = 0, double insetY = 0}) {
    if (corners.length != 4) return null;
    final ordered = orderQuadCorners(corners);
    return fromCorrespondences(ordered, insetRect(insetX, insetY));
  }

  /// 画面端から (ix, iy) だけ内側の矩形の四隅（TL,TR,BR,BL）。
  /// 検知点をここへ対応付けると、外側の画面全域まで外挿されて写る。
  static List<Vec2> insetRect(double ix, double iy) => [
        Vec2(ix, iy),
        Vec2(1 - ix, iy),
        Vec2(1 - ix, 1 - iy),
        Vec2(ix, 1 - iy),
      ];

  /// カメラ正規化点 → 画面正規化点。
  Vec2 map(Vec2 p) {
    final x = p.x, y = p.y;
    final w = h[6] * x + h[7] * y + h[8];
    if (w == 0) return p;
    return Vec2((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w);
  }

  /// TL,TR,BR,BL の順に並べ替え。重心まわりの角度で時計回り（y下向き座標系）に
  /// ソートし、x+y 最小の点を TL として回転させる。象限判定と違い、傾いた台形
  /// （斜め・下から見た四隅）でも空象限が生じず正しく並ぶ。
  static List<Vec2> orderQuadCorners(List<Vec2> pts) {
    assert(pts.length == 4);
    final cx = pts.map((p) => p.x).reduce((a, b) => a + b) / pts.length;
    final cy = pts.map((p) => p.y).reduce((a, b) => a + b) / pts.length;
    final sorted = [...pts]..sort((a, b) => math
        .atan2(a.y - cy, a.x - cx)
        .compareTo(math.atan2(b.y - cy, b.x - cx)));
    var tl = 0;
    for (var i = 1; i < 4; i++) {
      if (sorted[i].x + sorted[i].y < sorted[tl].x + sorted[tl].y) tl = i;
    }
    return [for (var i = 0; i < 4; i++) sorted[(tl + i) % 4]];
  }

  /// ガウスの消去法で A·x=b（正方）を解く。特異なら null。
  static List<double>? _solve(List<List<double>> a, List<double> b) {
    final n = b.length;
    final m = List.generate(n, (i) => [...a[i], b[i]]);
    for (var col = 0; col < n; col++) {
      var piv = col;
      for (var r = col + 1; r < n; r++) {
        if (m[r][col].abs() > m[piv][col].abs()) piv = r;
      }
      if (m[piv][col].abs() < 1e-12) return null;
      final tmp = m[col];
      m[col] = m[piv];
      m[piv] = tmp;
      final d = m[col][col];
      for (var j = col; j <= n; j++) {
        m[col][j] /= d;
      }
      for (var r = 0; r < n; r++) {
        if (r == col) continue;
        final f = m[r][col];
        if (f == 0) continue;
        for (var j = col; j <= n; j++) {
          m[r][j] -= f * m[col][j];
        }
      }
    }
    return List.generate(n, (i) => m[i][n]);
  }
}
