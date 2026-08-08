import 'geom.dart';
import '../protocol/messages.dart';

/// 21点骨格から抽出した1フレームの手のポーズ。座標はカメラ正規化(0..1)。
class HandPose {
  final Vec2 indexTip; // 人差し指先端（ポインタの主座標）
  final bool pinching; // 親指-人差し指の接触（押下=クリック/描画/ドラッグ）
  final bool indexUp;
  final bool middleUp;
  final int extendedFingers;
  const HandPose({
    required this.indexTip,
    required this.pinching,
    required this.indexUp,
    required this.middleUp,
    required this.extendedFingers,
  });
}

/// 手指骨格→ポーズ認識。姿勢のしきい値は手のスケール（手首→人差し指付け根）で
/// 正規化し、カメラ距離に依らず安定させる。
///
/// ピンチ（親指と人差し指の接触＝「線を引く」アクション）はヒステリシス付き:
/// ON は比率 [pinchOnRatio] 未満、OFF は [pinchOffRatio] 超で判定し、
/// 境界付近のチャタリング（線の途切れ・二重判定）を防ぐ。
class GestureRecognizer {
  /// UIで扱う認識感度。0は指同士をより近づけないとピンチにならず、
  /// 1はより離れた状態でもピンチとして認識する。
  ///
  /// 既定値0.5では従来のON=0.40 / OFF=0.60をそのまま使う。
  static const double defaultRecognitionSensitivity = 0.5;

  double _recognitionSensitivity;
  bool _pinched = false;

  GestureRecognizer({
    double recognitionSensitivity = defaultRecognitionSensitivity,
  }) : _recognitionSensitivity = _validateRecognitionSensitivity(
         recognitionSensitivity,
       );

  double get recognitionSensitivity => _recognitionSensitivity;

  set recognitionSensitivity(double value) {
    final validated = _validateRecognitionSensitivity(value);
    if (validated == _recognitionSensitivity) return;
    _recognitionSensitivity = validated;
    reset();
  }

  /// 感度0..1を、幅0.20のヒステリシスを保ったピンチ比率へ写す。
  double get pinchOnRatio => 0.20 + 0.40 * _recognitionSensitivity;
  double get pinchOffRatio => 0.40 + 0.40 * _recognitionSensitivity;

  static double _validateRecognitionSensitivity(double value) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw RangeError.range(value, 0, 1, 'recognitionSensitivity');
    }
    return value;
  }

  /// トラッキング喪失時などに呼び、ピンチ状態を初期化する。
  void reset() => _pinched = false;

  HandPose? recognize(HandFrame f) {
    if (!f.detected || f.landmarks.length != HandFrame.expectedLandmarks) {
      return null;
    }
    final wrist = f.at(HandFrame.wrist)!.xy;
    final indexMcp = f.at(HandFrame.indexMcp)!.xy;
    final thumbTip = f.at(HandFrame.thumbTip)!.xy;
    final indexTip = f.at(HandFrame.indexTip)!.xy;

    final scale = wrist.distanceTo(indexMcp).clamp(1e-3, 1.0);
    final ratio = thumbTip.distanceTo(indexTip) / scale;
    if (_pinched) {
      if (ratio > pinchOffRatio) _pinched = false;
    } else {
      if (ratio < pinchOnRatio) _pinched = true;
    }
    final pinching = _pinched;

    bool up(int tip, int pip) =>
        wrist.distanceTo(f.at(tip)!.xy) >
        wrist.distanceTo(f.at(pip)!.xy) * 1.02;
    final indexUp = up(HandFrame.indexTip, 6);
    final middleUp = up(HandFrame.middleTip, 10);
    final ringUp = up(HandFrame.ringTip, 14);
    final pinkyUp = up(HandFrame.pinkyTip, 18);
    final extended =
        [indexUp, middleUp, ringUp, pinkyUp].where((e) => e).length;

    return HandPose(
      indexTip: indexTip,
      pinching: pinching,
      indexUp: indexUp,
      middleUp: middleUp,
      extendedFingers: extended,
    );
  }
}
