import 'package:flutter/foundation.dart';

/// キャリブレーション表示フローの状態。
enum CalibrationFlowState {
  /// 何も表示していない（通常状態）。
  idle,

  /// 「スマホ設置完了」後: キャリブ画像（ArUcoターゲット）を最前面表示中。
  showingTarget,

  /// 四隅を受信して位置合わせが完了し、画像を自動クローズした。
  done,
}

/// 「スマホ設置完了」ボタン → キャリブ画像表示 → 四隅受信 → 自動クローズ、
/// の状態遷移だけを持つ小さなコントローラ（UIから分離してテスト可能に）。
///
/// 完了検知はエンジンの calibrationCount（位置合わせ成功エポック）の増加で行う。
/// 既に校正済みでも「開始時点より増えたか」で判定するので再キャリブにも使える。
class CalibrationFlowController extends ChangeNotifier {
  CalibrationFlowState _state = CalibrationFlowState.idle;
  int _epochAtStart = 0;

  CalibrationFlowState get state => _state;
  bool get showingTarget => _state == CalibrationFlowState.showingTarget;

  /// キャリブ画像の表示を開始する。[currentEpoch] は開始時点の
  /// InteractionEngine.calibrationCount。
  void start(int currentEpoch) {
    _epochAtStart = currentEpoch;
    _state = CalibrationFlowState.showingTarget;
    notifyListeners();
  }

  /// エンジンの状態が更新されるたびに呼ぶ。表示開始後に位置合わせが
  /// 成功していたら画像を自動クローズ（done へ遷移）する。
  void onEngineEpoch(int epoch) {
    if (_state == CalibrationFlowState.showingTarget && epoch > _epochAtStart) {
      _state = CalibrationFlowState.done;
      notifyListeners();
    }
  }

  /// 手動キャンセル（オーバーレイの脱出経路・中止ボタン）。
  void cancel() {
    if (_state != CalibrationFlowState.showingTarget) return;
    _state = CalibrationFlowState.idle;
    notifyListeners();
  }
}
