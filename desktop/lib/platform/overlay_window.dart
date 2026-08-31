import 'dart:async';

import 'package:flutter/services.dart'; // Rect もここから来る。

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
  int _operationEpoch = 0;
  bool get isAvailable => _available;

  OverlayWindowController({this.onExited, this.onEntered}) {
    _activeController = this;
    channel.setMethodCallHandler(_onNativeCall);
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (_disposed) return;
    switch (call.method) {
      case 'overlayExited':
        ++_operationEpoch;
        onExited?.call();
      case 'overlayEntered':
        _available = true;
        ++_operationEpoch;
        onEntered?.call();
    }
  }

  /// ネイティブ実装の有無を調べる（無ければ以後の enter/exit は no-op）。
  Future<bool> probe() async {
    if (_disposed) return false;
    final epoch = _operationEpoch;
    var available = false;
    try {
      available = await channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      available = false;
    } on PlatformException {
      available = false;
    }
    if (_disposed || epoch != _operationEpoch) return false;
    _available = available;
    return _available;
  }

  /// オーバーレイモードへ（透過・最前面・クリック透過・全画面）。
  Future<bool> enter() async {
    if (_disposed || !_available) return false;
    final epoch = ++_operationEpoch;
    var entered = false;
    try {
      entered = await channel.invokeMethod<bool>('enterOverlay') ?? false;
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      entered = false;
    }
    if (_disposed || epoch != _operationEpoch) {
      if (entered) await _invokeNativeExit();
      return false;
    }
    return entered;
  }

  /// 通常ウィンドウへ戻す。
  Future<void> exit() async {
    ++_operationEpoch;
    if (!_available) return;
    await _invokeNativeExit();
  }

  /// クリック透過オーバーレイ窓の中で「マウス入力を拾わせたい」矩形を通知する。
  /// ネイティブ側はカーソルがこの矩形（画面正規化・左上原点）に入っている間だけ
  /// window.ignoresMouseEvents を false にして、色丸のマウスクリックを Flutter の
  /// GestureDetector へ届ける。それ以外は従来どおりクリック透過を維持する。
  Future<void> setInteractiveRect(Rect? normalized) async {
    if (_disposed || !_available) return;
    try {
      await channel.invokeMethod('setInteractiveRect', <String, double>{
        'x': normalized?.left ?? 0,
        'y': normalized?.top ?? 0,
        'w': normalized?.width ?? 0,
        'h': normalized?.height ?? 0,
      });
    } on MissingPluginException {
      // 未対応ビルドでは何もしない（マウスは従来どおり素通り）。
    } on PlatformException {
      // 失敗しても致命ではない。
    }
  }

  Future<void> _invokeNativeExit() async {
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
    ++_operationEpoch;
    if (_available) unawaited(_invokeNativeExit());
    if (identical(_activeController, this)) {
      _activeController = null;
      channel.setMethodCallHandler(null);
    }
  }
}
