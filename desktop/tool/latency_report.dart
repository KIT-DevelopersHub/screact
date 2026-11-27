// ScreactPerf ログ（Android の logcat、Desktop の接続ログや標準出力）を集計し、
// 条件ごとの中央値・P95・欠落率の表を Markdown か CSV で出す。
//
// 使い方（desktop/ で実行）:
//   dart run tool/latency_report.dart [オプション] 条件=ログ [条件=ログ ...]
//
//   同じ条件名を複数回書くと、そのログをまとめて 1 条件として集計する
//   （Android と Desktop のログを同じ条件名で渡すと、件数の比較も出る）。
//   `条件=` を省くと、ファイル名を条件名にする。
//
// オプション:
//   --format md|csv      出力形式（既定 md）
//   --out <path>         ファイルへ書く（既定は標準出力）
//   --meta key=value     見出しの計測条件。key は date, android_device, android_os,
//                        android_build, desktop_device, desktop_os, desktop_build,
//                        hands, network, transport, duration, method（それ以外も可）
//   --title <text>       Markdown の見出し
//   --skip-first <n>     各ログの先頭 n 窓を捨てる（起動直後や条件切り替え直後の窓を除く。既定 0）
//
// 例:
//   dart run tool/latency_report.dart --meta date=2026-11-28 --meta network=通常LAN \
//     1手-通常LAN=logs/a1.log 1手-通常LAN=logs/d1.log \
//     2手-通常LAN=logs/a2.log 2手-通常LAN=logs/d2.log
import 'dart:io';

import 'package:thehack_overlay/net/latency_report.dart';

const _usage =
    '使い方: dart run tool/latency_report.dart [--format md|csv] [--out path] '
    '[--meta key=value]... [--title text] [--skip-first n] '
    '条件=ログ [条件=ログ ...]';

Future<void> main(List<String> args) async {
  var format = 'md';
  String? out;
  String? title;
  var skipFirst = 0;
  final meta = <String, String>{};
  final inputs = <(String, String)>[];

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) _fail('$a の値がありません。\n$_usage');
      return args[++i];
    }

    switch (a) {
      case '-h' || '--help':
        stdout.writeln(_usage);
        return;
      case '--format':
        format = next();
        if (format != 'md' && format != 'csv') {
          _fail('--format は md か csv です。');
        }
      case '--out':
        out = next();
      case '--title':
        title = next();
      case '--skip-first':
        final value = next();
        final n = int.tryParse(value);
        if (n == null || n < 0) _fail('--skip-first は 0 以上の整数です: $value');
        skipFirst = n;
      case '--meta':
        final kv = next();
        final eq = kv.indexOf('=');
        if (eq <= 0) _fail('--meta は key=value の形です: $kv');
        meta[kv.substring(0, eq)] = kv.substring(eq + 1);
      default:
        if (a.startsWith('--')) _fail('不明なオプション: $a\n$_usage');
        inputs.add(_splitInput(a));
    }
  }
  if (inputs.isEmpty) _fail(_usage);

  final byCondition = <String, List<PerfRecord>>{};
  var skipped = 0;
  for (final (condition, path) in inputs) {
    final file = File(path);
    if (!file.existsSync()) _fail('ログが見つかりません: $path');
    final log = parsePerfLog(decodeLogBytes(file.readAsBytesSync()));
    if (log.records.isEmpty) {
      stderr.writeln('注意: $path に ScreactPerf の集計行がありません。');
    }
    skipped += log.skippedLines;
    byCondition
        .putIfAbsent(condition, () => [])
        .addAll(log.records.skip(skipFirst));
  }

  final report = buildLatencyReport([
    for (final e in byCondition.entries) ConditionLogs(e.key, e.value),
  ], skippedLines: skipped);
  final text =
      format == 'csv'
          ? renderCsv(report)
          : renderMarkdown(report, meta: meta, title: title ?? '遅延計測レポート');

  if (out == null) {
    stdout.write(text);
  } else {
    File(out).writeAsStringSync(text);
    stderr.writeln('書き出しました: $out');
  }
}

/// `条件=パス` を分ける。`=` が無いか、引数全体が既存ファイルならファイル名を条件にする。
(String, String) _splitInput(String arg) {
  final eq = arg.indexOf('=');
  if (eq <= 0 || File(arg).existsSync()) {
    final name = arg.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return (dot > 0 ? name.substring(0, dot) : name, arg);
  }
  return (arg.substring(0, eq), arg.substring(eq + 1));
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(64);
}
