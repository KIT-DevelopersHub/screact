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
///
/// ファイルは1行ごとに同期書き込み＋flush（アプリがクラッシュしても直前まで残る）。
class ConnectionLog extends ChangeNotifier {
  static const int maxEntries = 300;
  final List<String> entries = [];
  File? _file;
  String? _filePath;

  String? get filePath => _filePath;

  /// ~/Library/Logs/yubiboard/desktop.log を開く（失敗してもUIログは動く）。
  Future<void> init() async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      final dir = Directory('$home/Library/Logs/yubiboard');
      await dir.create(recursive: true);
      _file = File('${dir.path}/desktop.log');
      _filePath = _file!.path;
      // init 完了前に記録されたぶん（起動直後の listen ログ等）も書き出す。
      if (entries.isNotEmpty) {
        _file!.writeAsStringSync('${entries.join('\n')}\n',
            mode: FileMode.append, flush: true);
      }
    } catch (_) {
      _file = null;
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
      _file?.writeAsStringSync('${now.toIso8601String()} $message\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
    notifyListeners();
  }

  String get joined => entries.join('\n');
}
