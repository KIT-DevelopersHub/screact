import 'dart:io';

import 'package:flutter/services.dart';

/// Bonjour(mDNS) 広告のDart側ハンドル。ネイティブ macOS の [BonjourAdvertiser]
/// （desktop/macos/Runner/BonjourAdvertiser.swift）へ MethodChannel で委譲し、
/// WebSocket サーバを `_screact._tcp` として同一 Wi-Fi へ広告する。
///
/// iOS は生の UDP ブロードキャストを特別 entitlement 無しに受信できないため、
/// 既存の UDP offer（discovery.dart）だけでは iOS の自動接続が原理的に成立しない。
/// 本器で Bonjour を追加し、iOS 側（NWBrowser/NetServiceBrowser）が entitlement 不要で
/// PC を自動発見・自動接続できるようにする。Android 互換の UDP offer は従来どおり
/// 並行して流し続ける（本器は iOS 向けの追加経路であり、既存経路を置き換えない）。
///
/// 広告は macOS のみ（NSNetService は macOS の network.server entitlement で足りる）。
/// Windows は Bonjour を標準搭載しないため対象外で、Android 向けの UDP 経路のみ動く。
class BonjourAdvertiser {
  BonjourAdvertiser({MethodChannel? channel, this.onLog})
    : _channel = channel ?? const MethodChannel('yubiboard/bonjour') {
    _channel.setMethodCallHandler(_handleNative);
  }

  final MethodChannel _channel;
  final void Function(String message)? onLog;

  /// 本OSでBonjour広告が使えるか（現状 macOS のみ）。
  bool get supported => Platform.isMacOS;

  Future<dynamic> _handleNative(MethodCall call) async {
    // ネイティブからの広告開始/失敗ログを接続診断ログへ流す。
    if (call.method == 'log' && call.arguments is String) {
      onLog?.call(call.arguments as String);
    }
    return null;
  }

  /// `_screact._tcp` の広告を開始する。[token] は6桁ペアリングコードで、TXT レコードに
  /// 載せて iOS がキー入力ゼロで hello.pairingToken に使う。サーバ起動成功後に呼ぶ。
  Future<void> start({required int port, required String token}) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('publish', {'port': port, 'token': token});
      onLog?.call('[Bonjour] _screact._tcp をポート $port で広告要求（iOS自動接続用）');
    } on MissingPluginException catch (e) {
      onLog?.call('[Bonjour] ネイティブ未登録 MissingPluginException: $e');
    } on PlatformException catch (e) {
      onLog?.call('[Bonjour] 広告開始に失敗（UDP経路は継続）: ${e.message}');
    } catch (e) {
      onLog?.call('[Bonjour] start() 予期せぬ例外: $e');
    }
  }

  /// 広告を停止する。サーバ停止・破棄時に呼ぶ。
  Future<void> stop() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('stop');
      onLog?.call('[Bonjour] 広告停止');
    } on MissingPluginException {
      // 何もしない。
    } on PlatformException catch (_) {
      // 停止失敗は致命ではない。
    }
  }
}
