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

  /// 4つのArUcoマーカー中心から、画面の四隅(0,0)(1,0)(1,1)(0,1)へのホモグラフィ。
  /// マーカーIDの割当に依存しないよう、重心まわりの角度で TL,TR,BR,BL に並べ替える。
  static Homography? fromMarkers(List<Marker> markers) {
    if (markers.length < 4) return null;
    final pts = markers.take(4).map((m) => m.center).toList();
    final ordered = _orderCorners(pts);
    final dst = const [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)];
    return fromCorrespondences(ordered, dst);
  }

  /// カメラ正規化点 → 画面正規化点。
  Vec2 map(Vec2 p) {
    final x = p.x, y = p.y;
    final w = h[6] * x + h[7] * y + h[8];
    if (w == 0) return p;
    return Vec2((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w);
  }

  /// TL,TR,BR,BL の順に並べ替え（重心からの象限で判定）。
  static List<Vec2> _orderCorners(List<Vec2> pts) {
    final cx = pts.map((p) => p.x).reduce((a, b) => a + b) / pts.length;
    final cy = pts.map((p) => p.y).reduce((a, b) => a + b) / pts.length;
    Vec2? tl, tr, br, bl;
    for (final p in pts) {
      final left = p.x < cx;
      final top = p.y < cy;
      if (left && top) {
        tl = p;
      } else if (!left && top) {
        tr = p;
      } else if (!left && !top) {
        br = p;
      } else {
        bl = p;
      }
    }
    // 退避: 象限に空きがあれば元順で埋める（歪んだ配置でも落ちないように）。
    final ordered = [tl, tr, br, bl];
    var k = 0;
    for (var i = 0; i < 4; i++) {
      ordered[i] ??= pts[k++ % pts.length];
    }
    return ordered.map((e) => e!).toList();
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
