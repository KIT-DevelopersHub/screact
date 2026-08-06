import 'dart:io';

import 'package:flutter/foundation.dart';

/// 接続診断ログ。UI（左パネルの「接続ログ」欄）とファイルの両方へ出す。
/// Android実機から繋がらない時に「どの段階まで届いているか」を切り分けるためのもの。
///
/// 段階の目安:
/// - "listen" のみ → まだ誰も来ていない（ネットワーク層で届いていない）
/// - "http request" あり → TCPはMacまで到達している
/// - "ws upgraded" あり → WebSocket確立済み（以後はプロトコル層）
/// - "hello_error" → 6桁コード不一致
class ConnectionLog extends ChangeNotifier {
  static const int maxEntries = 300;
  final List<String> entries = [];
  IOSink? _sink;
  String? _filePath;

  String? get filePath => _filePath;

  /// ~/Library/Logs/yubiboard/desktop.log を開く（失敗してもUIログは動く）。
  Future<void> init() async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      final dir = Directory('$home/Library/Logs/yubiboard');
      await dir.create(recursive: true);
      final file = File('${dir.path}/desktop.log');
      _sink = file.openWrite(mode: FileMode.append);
      _filePath = file.path;
    } catch (_) {
      _sink = null;
    }
  }

  void add(String message) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final line =
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)} $message';
    entries.add(line);
    if (entries.length > maxEntries) entries.removeAt(0);
    try {
      _sink?.writeln('${now.toIso8601String()} $message');
    } catch (_) {}
    notifyListeners();
  }

  String get joined => entries.join('\n');

  @override
  void dispose() {
    _sink?.close();
    super.dispose();
  }
}
