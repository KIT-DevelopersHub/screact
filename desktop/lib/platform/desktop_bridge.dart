import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/interaction_engine.dart';

/// OS入力・透過オーバーレイの副作用境界。共通Flutter層はこの抽象だけを見る。
/// 各OSのネイティブ実装（Windows=C++/Win32・macOS=CGEvent）を裏に差し込む。
/// dev/macOSプレビューでは NoopDesktopBridge（アプリ内描画のみ）。
abstract class DesktopBridge {
  String get name;
  bool get isNativeBackend;

  /// 操作イベントをOSへ反映（ポインタ移動・OSクリック/ドラッグ・スクロール等）。
  /// インク描画（draw*）はオーバーレイ専用でOSには注入しない。
  Future<void> applyEvent(InteractionEvent e);

  /// 透過クリックスルーのオーバーレイ窓の表示切替。
  Future<void> setOverlayVisible(bool visible);

  /// OSクリック注入に必要なアクセシビリティ権限を持っているか。
  /// （macOS: AXIsProcessTrusted。未対応OS/Noopでは true 扱い）。
  Future<bool> accessibilityTrusted();

  /// アクセシビリティ権限の許可プロンプトを出す（システム設定の一覧に登録）。
  Future<void> requestAccessibility();

  /// 実行OSに応じたブリッジを返す。ネイティブ未接続時は Noop。
  static DesktopBridge forPlatform() {
    if (Platform.isWindows) return _MethodChannelBridge('windows');
    if (Platform.isMacOS) return _MethodChannelBridge('macos');
    return NoopDesktopBridge();
  }
}

/// OS注入をしない（共通UIのアプリ内描画だけで動作確認する）ブリッジ。
class NoopDesktopBridge implements DesktopBridge {
  @override
  String get name => 'in-app (no OS injection)';
  @override
  bool get isNativeBackend => false;
  @override
  Future<void> applyEvent(InteractionEvent e) async {}
  @override
  Future<void> setOverlayVisible(bool visible) async {}
  @override
  Future<bool> accessibilityTrusted() async => true;
  @override
  Future<void> requestAccessibility() async {}
}

/// 各OSのネイティブプラグインへ MethodChannel で委譲する。
/// ネイティブ側（windows/ runner の C++、macos/ runner の Swift）が未実装なら
/// MissingPluginException を握りつぶし、共通UIは動き続ける（段階実装のため）。
class _MethodChannelBridge implements DesktopBridge {
  final String _os;
  final MethodChannel _ch = const MethodChannel('yubiboard/desktop_input');
  late final Future<void> _probeFuture;
  bool _native = false;

  _MethodChannelBridge(this._os) {
    _probeFuture = _probe();
  }

  Future<void> _probe() async {
    try {
      final ok = await _ch.invokeMethod<bool>('isAvailable');
      _native = ok ?? false;
    } on PlatformException {
      _native = false;
    } on MissingPluginException {
      _native = false;
    }
  }

  @override
  String get name => '$_os native (${_native ? "active" : "not yet wired"})';
  @override
  bool get isNativeBackend => _native;

  /// インク描画はオーバーレイ専用でOSに注入しない（OSへ流すのはポインタ移動・
  /// クリック/ドラッグ・スクロールのみ）。
  static const _overlayOnlyKinds = {
    InteractionKind.drawDown,
    InteractionKind.drawMove,
    InteractionKind.drawUp,
    InteractionKind.pointerExit,
  };

  @override
  Future<void> applyEvent(InteractionEvent e) async {
    await _probeFuture;
    if (!_native) return;
    if (_overlayOnlyKinds.contains(e.kind)) return;
    try {
      await _ch.invokeMethod('applyEvent', {
        'kind': e.kind.name,
        'x': e.screen.x,
        'y': e.screen.y,
        'dx': e.delta.x,
        'dy': e.delta.y,
      });
    } on MissingPluginException {
      _native = false;
    } on PlatformException catch (err) {
      debugPrint('desktop_bridge applyEvent error: ${err.message}');
    }
  }

  @override
  Future<bool> accessibilityTrusted() async {
    await _probeFuture;
    if (!_native) return false;
    try {
      final ok = await _ch.invokeMethod<bool>('accessibilityTrusted');
      return ok ?? false;
    } on MissingPluginException {
      _native = false;
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> requestAccessibility() async {
    await _probeFuture;
    if (!_native) return;
    try {
      await _ch.invokeMethod('requestAccessibility');
    } on MissingPluginException {
      _native = false;
    } on PlatformException catch (_) {}
  }

  @override
  Future<void> setOverlayVisible(bool visible) async {
    await _probeFuture;
    if (!_native) return;
    try {
      await _ch.invokeMethod('setOverlayVisible', {'visible': visible});
    } on MissingPluginException {
      _native = false;
    } on PlatformException catch (_) {}
  }
}
