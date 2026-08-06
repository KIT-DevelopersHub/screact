import 'dart:math' as math;

import 'geom.dart';
import '../protocol/messages.dart';

/// 電話なしで結合を確認するためのモック入力（実プロトコルと同じ型）。
/// ArUcoは正規化カメラの 0.1..0.9 の枠を画面 0..1 に対応させる。手はその枠内で
/// 人差し指を円運動させ、周期的にピンチ（描画/クリック）する。
class MockHand {
  /// 位置合わせ用の4マーカー（四隅）。
  static CalibrationMarkers markers() {
    Marker m(int id, double x, double y) => Marker(
          id,
          Vec2(x, y),
          [Vec2(x - .02, y - .02), Vec2(x + .02, y - .02), Vec2(x + .02, y + .02), Vec2(x - .02, y + .02)],
        );
    return CalibrationMarkers(0, [
      m(10, 0.1, 0.1),
      m(11, 0.9, 0.1),
      m(12, 0.9, 0.9),
      m(13, 0.1, 0.9),
    ]);
  }

  /// フレーム i の手（カメラ正規化）。tick=30で1周。i の一定区間でピンチ。
  static HandFrame frame(int i) {
    final t = i / 30.0;
    final cx = 0.5 + 0.28 * math.cos(t);
    final cy = 0.5 + 0.28 * math.sin(t);
    final pinch = (i ~/ 20) % 2 == 1; // 20フレームごとにピンチON/OFF
    final tip = Vec2(cx, cy);
    final wrist = Vec2(cx, cy + 0.25);

    // 21点を初期化（既定は手首位置）してから主要点を設定。
    final lm = List<Landmark>.filled(21, Landmark(wrist.x, wrist.y, 0), growable: false).toList();
    void set(int idx, Vec2 v) => lm[idx] = Landmark(v.x, v.y, 0);

    set(HandFrame.wrist, wrist);
    set(HandFrame.indexMcp, Vec2(cx, cy + 0.12)); // 5
    set(6, Vec2(cx, cy + 0.06)); // index pip
    set(HandFrame.indexTip, tip); // 8 伸展
    // 親指: ピンチ時は人差し指先端付近、非ピンチ時は離す
    set(HandFrame.thumbTip, pinch ? Vec2(cx - 0.02, cy + 0.01) : Vec2(cx - 0.16, cy + 0.10));
    // 中指/薬指/小指は折り畳み（tip を pip より手首側へ）
    set(10, Vec2(cx + 0.03, cy + 0.06));
    set(HandFrame.middleTip, Vec2(cx + 0.03, cy + 0.15));
    set(14, Vec2(cx + 0.06, cy + 0.06));
    set(HandFrame.ringTip, Vec2(cx + 0.06, cy + 0.15));
    set(18, Vec2(cx + 0.09, cy + 0.06));
    set(HandFrame.pinkyTip, Vec2(cx + 0.09, cy + 0.15));

    return HandFrame(
      frameId: i,
      capturedAtMonotonicMs: i * 33, // ~30fps
      detected: true,
      handedness: 'RIGHT',
      landmarks: lm,
    );
  }
}
