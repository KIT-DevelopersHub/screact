/// 位置合わせ（キャリブレーション）に使うメッセージ種別の選択。
enum CalibrationSource {
  /// calibration_markers / slide_corners のどちらでも受け付ける（既定）。
  any,

  /// ArUco の calibration_markers だけを受け付ける。
  arucoOnly,

  /// slide_corners だけを受け付ける。
  slideCornersOnly,
}

/// キャリブレーションの調整可能な設定値（要件: データ形式の細部や検出点の
/// ズレに現場で追従できるよう、数値をUIから変更できる）。
///
/// - インセット（内側率）: スマホが検知する4点が「画面の端」ではなく
///   少し内側にある場合の外挿補正。検知点を画面の (inset, inset)..(1-inset, 1-inset)
///   の矩形に対応付けてホモグラフィを作るので、画面の端まで正しく写る。
/// - 既定値はすべて 0 / 1 / any（従来挙動そのまま）。同梱キャリブ画像を
///   表示するフローでは [CalibrationConfig.forCalibrationTarget] を使う。
class CalibrationConfig {
  /// ArUco経路: マーカー中心が画面端から内側にある割合（X方向, 0..0.45）。
  double markerInsetX;

  /// ArUco経路: マーカー中心が画面端から内側にある割合（Y方向, 0..0.45）。
  double markerInsetY;

  /// slide_corners経路: 検知された四隅が実画面より内側にある割合（X方向）。
  double cornerInsetX;

  /// slide_corners経路: 検知された四隅が実画面より内側にある割合（Y方向）。
  double cornerInsetY;

  /// この回数だけ「連続して」妥当な位置合わせメッセージを受けたら確定する。
  /// Android側でも5フレーム安定判定をしているため既定は1。
  int requiredStableMessages;

  /// 位置合わせに使うメッセージ種別。
  CalibrationSource source;

  CalibrationConfig({
    this.markerInsetX = 0,
    this.markerInsetY = 0,
    this.cornerInsetX = 0,
    this.cornerInsetY = 0,
    this.requiredStableMessages = 1,
    this.source = CalibrationSource.any,
  });

  /// 同梱キャリブ画像 assets/calibration-target-1920x1080.png の実測値。
  /// マーカー（260px角）は全辺 110px 余白 → 中心は各辺から 240px 内側。
  static const double targetMarkerInsetX = 240 / 1920; // 0.125
  static const double targetMarkerInsetY = 240 / 1080; // 0.2222

  /// 「スマホ設置完了」フロー用の既定値: 同梱キャリブ画像を全画面表示した時の
  /// マーカー中心位置に合わせたインセット。
  factory CalibrationConfig.forCalibrationTarget() => CalibrationConfig(
        markerInsetX: targetMarkerInsetX,
        markerInsetY: targetMarkerInsetY,
      );

  bool get acceptsAruco => source != CalibrationSource.slideCornersOnly;
  bool get acceptsSlideCorners => source != CalibrationSource.arucoOnly;
}
