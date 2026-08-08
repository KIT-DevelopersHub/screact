import 'package:flutter/services.dart';

/// ネイティブの「オーバーレイ窓」（透過・最前面・クリック透過）との境界。
/// スライドの上にインクを重ねるモードの入退場を担う。
/// 実装は macOS(Swift: OverlayModeController) / Windows(Win32:
/// overlay_mode_controller.cpp) が同じチャネル契約で提供する。
/// ネイティブ未接続（他OS・旧ビルド）では isAvailable=false のまま劣化動作し、
/// 共通UIは通常モードだけで動き続ける。
class OverlayWindowController {
  static const MethodChannel channel = MethodChannel(
    'yubiboard/overlay_window',
  );
  static OverlayWindowController? _activeController;

  /// ネイティブ側の脱出経路（メニューバー/ホットキー）で解除された時に呼ばれる。
  final VoidCallback? onExited;

  /// ネイティブ側のホットキーでオーバーレイに入った時に呼ばれる。
  final VoidCallback? onEntered;

  bool _available = false;
  bool _disposed = false;
  bool get isAvailable => _available;

  OverlayWindowController({this.onExited, this.onEntered}) {
    _activeController = this;
    channel.setMethodCallHandler(_onNativeCall);
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (_disposed) return;
    switch (call.method) {
      case 'overlayExited':
        onExited?.call();
      case 'overlayEntered':
        onEntered?.call();
    }
  }

  /// ネイティブ実装の有無を調べる（無ければ以後の enter/exit は no-op）。
  Future<bool> probe() async {
    if (_disposed) return false;
    try {
      _available = await channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      _available = false;
    }
    return _available;
  }

  /// オーバーレイモードへ（透過・最前面・クリック透過・全画面）。
  Future<bool> enter() async {
    if (_disposed || !_available) return false;
    try {
      return await channel.invokeMethod<bool>('enterOverlay') ?? false;
    } on MissingPluginException {
      _available = false;
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 通常ウィンドウへ戻す。
  Future<void> exit() async {
    if (_disposed || !_available) return;
    try {
      await channel.invokeMethod('exitOverlay');
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      // 失敗してもUI側は通常モードへ戻す（ネイティブ側の脱出経路が別にある）
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(_activeController, this)) {
      _activeController = null;
      channel.setMethodCallHandler(null);
    }
  }
}
