import 'geom.dart';
import '../protocol/messages.dart';

/// 21点骨格から抽出した1フレームの手のポーズ。座標はカメラ正規化(0..1)。
class HandPose {
  final Vec2 indexTip; // 人差し指先端
  final Vec2 middleTip; // 中指先端
  final bool pinching; // 親指-人差し指の接触（＝OSクリック/ドラッグ）
  final bool fingersTogether; // 人差し指-中指の接触（＝インク描画）
  final bool indexUp;
  final bool middleUp;
  final int extendedFingers;
  const HandPose({
    required this.indexTip,
    required this.middleTip,
    required this.pinching,
    required this.fingersTogether,
    required this.indexUp,
    required this.middleUp,
    required this.extendedFingers,
  });

  /// 描画の筆点＝人差し指先端と中指先端の中間点。
  Vec2 get drawPoint => Vec2(
        (indexTip.x + middleTip.x) / 2,
        (indexTip.y + middleTip.y) / 2,
      );
}

/// 手指骨格→ポーズ認識。姿勢のしきい値は手のスケール（手首→人差し指付け根）で
/// 正規化し、カメラ距離に依らず安定させる。
///
/// 2つの接触ジェスチャーをヒステリシス付きで判定する（境界のチャタリング
/// ＝線の途切れ・二重判定を防ぐ。ON は比率 onRatio 未満、OFF は offRatio 超）:
/// - pinch（親指-人差し指の接触）= OSの実クリック/ドラッグ
/// - fingersTogether（人差し指-中指の接触）= インク描画（中間点を筆点にする）
class GestureRecognizer {
  final double pinchOnRatio;
  final double pinchOffRatio;
  final double togetherOnRatio;
  final double togetherOffRatio;
  bool _pinched = false;
  bool _together = false;

  GestureRecognizer({
    this.pinchOnRatio = 0.40,
    this.pinchOffRatio = 0.60,
    this.togetherOnRatio = 0.35,
    this.togetherOffRatio = 0.55,
  })  : assert(pinchOnRatio < pinchOffRatio),
        assert(togetherOnRatio < togetherOffRatio);

  /// トラッキング喪失時などに呼び、接触状態を初期化する。
  void reset() {
    _pinched = false;
    _together = false;
  }

  HandPose? recognize(HandFrame f) {
    if (!f.detected || f.landmarks.length != HandFrame.expectedLandmarks) {
      return null;
    }
    final wrist = f.at(HandFrame.wrist)!.xy;
    final indexMcp = f.at(HandFrame.indexMcp)!.xy;
    final thumbTip = f.at(HandFrame.thumbTip)!.xy;
    final indexTip = f.at(HandFrame.indexTip)!.xy;
    final middleTip = f.at(HandFrame.middleTip)!.xy;

    final scale = wrist.distanceTo(indexMcp).clamp(1e-3, 1.0);

    // 親指-人差し指の接触（OSクリック）。
    final pinchRatio = thumbTip.distanceTo(indexTip) / scale;
    if (_pinched) {
      if (pinchRatio > pinchOffRatio) _pinched = false;
    } else {
      if (pinchRatio < pinchOnRatio) _pinched = true;
    }

    // 人差し指-中指の接触（インク描画）。
    final togetherRatio = indexTip.distanceTo(middleTip) / scale;
    if (_together) {
      if (togetherRatio > togetherOffRatio) _together = false;
    } else {
      if (togetherRatio < togetherOnRatio) _together = true;
    }

    bool up(int tip, int pip) =>
        wrist.distanceTo(f.at(tip)!.xy) > wrist.distanceTo(f.at(pip)!.xy) * 1.02;
    final indexUp = up(HandFrame.indexTip, 6);
    final middleUp = up(HandFrame.middleTip, 10);
    final ringUp = up(HandFrame.ringTip, 14);
    final pinkyUp = up(HandFrame.pinkyTip, 18);
    final extended =
        [indexUp, middleUp, ringUp, pinkyUp].where((e) => e).length;

    return HandPose(
      indexTip: indexTip,
      middleTip: middleTip,
      pinching: _pinched,
      fingersTogether: _together,
      indexUp: indexUp,
      middleUp: middleUp,
      extendedFingers: extended,
    );
  }
}
