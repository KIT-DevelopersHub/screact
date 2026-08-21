import 'dart:math' as math;

import 'geom.dart';
import '../protocol/messages.dart';

/// 電話なしで結合を確認するためのモック入力（実プロトコルと同じ型）。
/// ArUcoは正規化カメラの 0.1..0.9 の枠を画面 0..1 に対応させる。手はその枠内で
/// 人差し指を円運動させ、周期的にピンチ（描画/クリック）する。
class MockHand {
  /// 位置合わせ用の4マーカー（四隅）。
  static CalibrationMarkers markers() {
    Marker m(int id, double x, double y) => Marker(id, Vec2(x, y), [
      Vec2(x - .02, y - .02),
      Vec2(x + .02, y - .02),
      Vec2(x + .02, y + .02),
      Vec2(x - .02, y + .02),
    ]);
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
    return at(frameId: i, tip: Vec2(cx, cy), pinch: pinch);
  }

  /// 人差し指先端 [tip]（カメラ正規化）とピンチ有無から21点の手を合成する。
  /// 任意の軌跡（傾いた四隅での線引き等）のテスト・モックに使う。
  ///
  /// [together]=true で人差し指と中指の先端をくっつける（＝インク描画）。
  /// この時、中指先端は人差し指先端のすぐ隣（描画は両者の中間点が筆点）。
  static HandFrame at({
    required int frameId,
    required Vec2 tip,
    required bool pinch,
    bool together = false,
  }) {
    final cx = tip.x, cy = tip.y;
    final wrist = Vec2(cx, cy + 0.25);

    // 21点を初期化（既定は手首位置）してから主要点を設定。
    final lm =
        List<Landmark>.filled(
          21,
          Landmark(wrist.x, wrist.y, 0),
          growable: false,
        ).toList();
    void set(int idx, Vec2 v) => lm[idx] = Landmark(v.x, v.y, 0);

    set(HandFrame.wrist, wrist);
    set(HandFrame.indexMcp, Vec2(cx, cy + 0.12)); // 5
    set(6, Vec2(cx, cy + 0.06)); // index pip
    set(HandFrame.indexTip, tip); // 8 伸展
    // 親指: ピンチ時は人差し指先端付近、非ピンチ時は離す
    set(
      HandFrame.thumbTip,
      pinch ? Vec2(cx - 0.02, cy + 0.01) : Vec2(cx - 0.16, cy + 0.10),
    );
    if (together) {
      // 中指を立てて人差し指先端のすぐ隣へ（くっつき＝描画）。
      set(10, Vec2(cx + 0.01, cy + 0.06));
      set(HandFrame.middleTip, Vec2(cx + 0.02, cy)); // index tip の至近
    } else {
      // 中指は折り畳み（tip を pip より手首側へ）＝離れている。
      set(10, Vec2(cx + 0.03, cy + 0.06));
      set(HandFrame.middleTip, Vec2(cx + 0.03, cy + 0.15));
    }
    set(14, Vec2(cx + 0.06, cy + 0.06));
    set(HandFrame.ringTip, Vec2(cx + 0.06, cy + 0.15));
    set(18, Vec2(cx + 0.09, cy + 0.06));
    set(HandFrame.pinkyTip, Vec2(cx + 0.09, cy + 0.15));

    return HandFrame(
      frameId: frameId,
      capturedAtMonotonicMs: frameId * 33, // ~30fps
      detected: true,
      handedness: 'RIGHT',
      landmarks: lm,
    );
  }

  /// グー（全指を折り畳んだ握り拳）の手を合成する（＝消しゴム）。
  /// 4本の指先を各PIPより手首側へ置き、[GestureRecognizer] の伸展判定で
  /// extendedFingers==0（＝fist）になるようにする。[tip] は手の代表位置。
  static HandFrame fist({required int frameId, required Vec2 tip}) {
    final cx = tip.x, cy = tip.y;
    final wrist = Vec2(cx, cy + 0.25);
    final lm =
        List<Landmark>.filled(
          21,
          Landmark(wrist.x, wrist.y, 0),
          growable: false,
        ).toList();
    void set(int idx, Vec2 v) => lm[idx] = Landmark(v.x, v.y, 0);

    set(HandFrame.wrist, wrist);
    set(HandFrame.indexMcp, Vec2(cx, cy + 0.12)); // 5（scale基準）
    // 各指: PIP は cy+0.06、TIP は cy+0.10（PIPより手首側＝折り畳み）。
    set(6, Vec2(cx, cy + 0.06));
    set(HandFrame.indexTip, Vec2(cx, cy + 0.10));
    set(10, Vec2(cx + 0.01, cy + 0.06));
    set(HandFrame.middleTip, Vec2(cx + 0.01, cy + 0.10));
    set(14, Vec2(cx + 0.06, cy + 0.06));
    set(HandFrame.ringTip, Vec2(cx + 0.06, cy + 0.10));
    set(18, Vec2(cx + 0.09, cy + 0.06));
    set(HandFrame.pinkyTip, Vec2(cx + 0.09, cy + 0.10));
    // 親指は掌側へ折り、グッドサイン判定もしない距離にする。
    set(HandFrame.thumbMcp, Vec2(cx - 0.08, cy + 0.10));
    set(HandFrame.thumbTip, Vec2(cx - 0.12, cy + 0.12));

    return HandFrame(
      frameId: frameId,
      capturedAtMonotonicMs: frameId * 33,
      detected: true,
      handedness: 'RIGHT',
      landmarks: lm,
    );
  }

  /// グッドサイン（親指だけを立て、他4指を折り曲げた手）を合成する。
  /// [center] は手の中心（＝画面内外判定に使う人差し指先端の近傍）、
  /// [thumbDir] は親指の向き（例: 上=Vec2(0,-1)）。
  static HandFrame goodSign({
    required int frameId,
    Vec2 center = const Vec2(0.5, 0.5),
    Vec2 thumbDir = const Vec2(0, -1),
  }) {
    final cx = center.x, cy = center.y;
    final wrist = Vec2(cx, cy + 0.22);
    final lm =
        List<Landmark>.filled(
          21,
          Landmark(wrist.x, wrist.y, 0),
          growable: false,
        ).toList();
    void set(int idx, Vec2 v) => lm[idx] = Landmark(v.x, v.y, 0);

    set(HandFrame.wrist, wrist);
    set(HandFrame.indexMcp, Vec2(cx, cy + 0.12)); // 手スケール基準
    // 4本の指を折り曲げる: 先端(tip)を pip より手首側に置き up()=false にする。
    void fold(int pip, int tip, double dx) {
      set(pip, Vec2(cx + dx, cy - 0.02)); // 突き出た第2関節
      set(tip, Vec2(cx + dx, cy + 0.05)); // 折り込んだ先端（手首寄り）
    }

    fold(6, HandFrame.indexTip, 0.0);
    fold(10, HandFrame.middleTip, 0.03);
    fold(14, HandFrame.ringTip, 0.06);
    fold(18, HandFrame.pinkyTip, 0.09);

    // 親指: 付け根(thumbMcp)から thumbDir 方向へ十分伸ばす。
    final base = Vec2(cx - 0.05, cy + 0.06);
    final len = thumbDir.length;
    final unit = len == 0 ? const Vec2(0, -1) : thumbDir * (1 / len);
    set(HandFrame.thumbMcp, base);
    set(HandFrame.thumbTip, base + unit * 0.18);

    return HandFrame(
      frameId: frameId,
      capturedAtMonotonicMs: frameId * 33,
      detected: true,
      handedness: 'RIGHT',
      landmarks: lm,
    );
  }
}
