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
  final bool fist; // グー（全指を折り畳む）＝消しゴム
  final bool thumbExtended; // 親指だけを立てているか（グッドサイン判定用）
  final bool goodSign; // グッドサイン＝親指を立て、他4指を折り曲げた状態（スクロール）
  const HandPose({
    required this.indexTip,
    required this.middleTip,
    required this.pinching,
    required this.fingersTogether,
    required this.indexUp,
    required this.middleUp,
    required this.extendedFingers,
    this.fist = false,
    required this.thumbExtended,
    required this.goodSign,
  });

  /// 描画の筆点＝人差し指先端と中指先端の中間点。
  Vec2 get drawPoint =>
      Vec2((indexTip.x + middleTip.x) / 2, (indexTip.y + middleTip.y) / 2);

  /// 消しゴムの代表点＝人差し指先端と中指先端の中間点（グー時は掌付近に集まる）。
  Vec2 get erasePoint => drawPoint;
}

/// 手指骨格→ポーズ認識。姿勢のしきい値は手のスケール（手首→人差し指付け根）で
/// 正規化し、カメラ距離に依らず安定させる。
///
/// 2つの接触ジェスチャーをヒステリシス付きで判定する（境界のチャタリング
/// ＝線の途切れ・二重判定を防ぐ。ON は比率 onRatio 未満、OFF は offRatio 超）:
/// - pinch（親指-人差し指の接触）= OSの実クリック/ドラッグ
/// - fingersTogether（人差し指-中指の接触）= インク描画（中間点を筆点にする）
class GestureRecognizer {
  /// UIで扱う認識感度。0は指同士をより近づけないとピンチにならず、
  /// 1はより離れた状態でも接触として認識する。
  ///
  /// 既定値0.5ではピンチON/OFF=0.40/0.60、2本指接触
  /// ON/OFF=0.35/0.55をそのまま使う。
  static const double defaultRecognitionSensitivity = 0.5;

  double _recognitionSensitivity;
  double? _customPinchOnRatio;
  double? _customPinchOffRatio;
  double? _customTogetherOnRatio;
  double? _customTogetherOffRatio;
  bool _pinched = false;
  bool _together = false;
  bool _fist = false;

  GestureRecognizer({
    double recognitionSensitivity = defaultRecognitionSensitivity,
    double? pinchOnRatio,
    double? pinchOffRatio,
    double? togetherOnRatio,
    double? togetherOffRatio,
  }) : _recognitionSensitivity = _validateRecognitionSensitivity(
         recognitionSensitivity,
       ),
       _customPinchOnRatio = pinchOnRatio,
       _customPinchOffRatio = pinchOffRatio,
       _customTogetherOnRatio = togetherOnRatio,
       _customTogetherOffRatio = togetherOffRatio,
       assert(
         pinchOnRatio == null ||
             pinchOffRatio == null ||
             pinchOnRatio < pinchOffRatio,
       ),
       assert(
         togetherOnRatio == null ||
             togetherOffRatio == null ||
             togetherOnRatio < togetherOffRatio,
       );

  double get recognitionSensitivity => _recognitionSensitivity;

  set recognitionSensitivity(double value) {
    final validated = _validateRecognitionSensitivity(value);
    if (validated == _recognitionSensitivity) return;
    _recognitionSensitivity = validated;
    _customPinchOnRatio = null;
    _customPinchOffRatio = null;
    _customTogetherOnRatio = null;
    _customTogetherOffRatio = null;
    reset();
  }

  /// 感度0..1を、幅0.20のヒステリシスを保ったピンチ比率へ写す。
  double get pinchOnRatio =>
      _customPinchOnRatio ?? 0.20 + 0.40 * _recognitionSensitivity;
  double get pinchOffRatio =>
      _customPinchOffRatio ?? 0.40 + 0.40 * _recognitionSensitivity;

  /// 描画用の人差し指-中指接触も同じ感度へ連動させる。
  double get togetherOnRatio =>
      _customTogetherOnRatio ?? 0.15 + 0.40 * _recognitionSensitivity;
  double get togetherOffRatio =>
      _customTogetherOffRatio ?? 0.35 + 0.40 * _recognitionSensitivity;

  static double _validateRecognitionSensitivity(double value) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw RangeError.range(value, 0, 1, 'recognitionSensitivity');
    }
    return value;
  }

  /// トラッキング喪失時などに呼び、接触状態を初期化する。
  void reset() {
    _pinched = false;
    _together = false;
    _fist = false;
  }

  HandPose? recognize(HandFrame f) {
    if (!f.detected || f.landmarks.length != HandFrame.expectedLandmarks) {
      return null;
    }
    final wrist = f.at(HandFrame.wrist)!.xy;
    final indexMcp = f.at(HandFrame.indexMcp)!.xy;
    final thumbMcp = f.at(HandFrame.thumbMcp)!.xy;
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
        wrist.distanceTo(f.at(tip)!.xy) >
        wrist.distanceTo(f.at(pip)!.xy) * 1.02;
    final indexUp = up(HandFrame.indexTip, 6);
    final middleUp = up(HandFrame.middleTip, 10);
    final ringUp = up(HandFrame.ringTip, 14);
    final pinkyUp = up(HandFrame.pinkyTip, 18);
    final extended =
        [indexUp, middleUp, ringUp, pinkyUp].where((e) => e).length;

    // グー（消しゴム）判定。境界のチャタリングを防ぐため、伸びた指の本数に
    // ヒステリシス（不感帯 extended==1）を設ける: 0本で確実に握った時だけON、
    // 2本以上伸ばして明確に開いた時だけOFF。1本の中間状態は直前を保持する。
    if (_fist) {
      if (extended >= 2) _fist = false;
    } else {
      if (extended == 0) _fist = true;
    }

    // 親指の伸展: 親指先端が付け根(thumbMcp)から手のスケール比で十分伸びているか。
    // 親指は上下左右どの向きにも立つため、手首からの距離ではなく親指自身の長さで
    // 判定する（向きに依存せずグッドサインを検出できる）。
    final thumbExtended = thumbTip.distanceTo(thumbMcp) > scale * 0.8;
    // グッドサイン: 親指だけ立て、人差し指〜小指の4本は折り曲げている。
    final goodSign = thumbExtended && extended == 0;

    return HandPose(
      indexTip: indexTip,
      middleTip: middleTip,
      pinching: _pinched,
      fingersTogether: _together,
      indexUp: indexUp,
      middleUp: middleUp,
      extendedFingers: extended,
      fist: _fist,
      thumbExtended: thumbExtended,
      goodSign: goodSign,
    );
  }
}
