import 'dart:convert';
import 'dart:typed_data';

/// ScreactPerf ログ（Android の logcat と Desktop の接続ログ）を集計し、
/// 条件ごとの表（Markdown / CSV）にする。`tool/latency_report.dart` から使う。
///
/// どちらのログも 5 秒窓ごとに「中央値/P95」（ミリ秒）を 1 行で出すため、
/// 生のサンプルは残っていない。そこで窓をまたいだ値は次のように定める。
/// - 中央値: 各窓の中央値の中央値
/// - P95: 各窓の P95 の中央値
/// - 最悪P95: 各窓の P95 の最大値
///
/// 端末をまたいで時刻を引き算することはしない。両端末をまたぐのは件数の比較だけ。

/// ログの出どころ。
enum PerfSource { android, desktop }

/// ScreactPerf の 1 行（1 窓）。
class PerfRecord {
  final PerfSource source;
  final double windowSeconds;

  /// Android の設定手数（maxHands）。Desktop の行には無い。
  final int? maxHands;

  /// `recv` や `cap` などの件数。
  final Map<String, int> counts;

  /// 手が 0／1／2 本だったフレーム数。
  final List<int> handCounts;

  /// 区間名 → （中央値, P95）ミリ秒。サンプルが無い窓は null。
  final Map<String, (double?, double?)> segments;

  const PerfRecord({
    required this.source,
    required this.windowSeconds,
    required this.maxHands,
    required this.counts,
    required this.handCounts,
    required this.segments,
  });
}

/// 出力に並べる区間の順序と説明。
const Map<PerfSource, List<(String, String)>> perfSegments = {
  PerfSource.android: [
    ('interval', 'カメラフレーム間隔'),
    ('capInf', '受け取り→MediaPipe結果'),
    ('infEnq', 'MediaPipe結果→送信キュー'),
    ('enqSend', '送信キュー→送信要求受理'),
    ('capSend', '受け取り→送信要求受理'),
  ],
  PerfSource.desktop: [
    ('interval', 'hand_frame受信間隔'),
    ('parse', '受信→解析完了'),
    ('wait', '解析完了→処理開始'),
    ('engine', 'エンジン処理'),
    ('os', 'エンジン完了→OS入力'),
    ('overlay', 'OS入力→オーバーレイ'),
    ('total', '受信→オーバーレイ'),
  ],
};

const Map<PerfSource, List<String>> _countKeys = {
  PerfSource.android: [
    'maxHands',
    'cap',
    'inf',
    'enq',
    'sent',
    'dropQ',
    'dropInf',
  ],
  PerfSource.desktop: ['recv', 'done', 'drop', 'stale'],
};

final RegExp _winToken = RegExp(r'(?:^|[\s:])win=');
final RegExp _pair = RegExp(r'(\w+)=(\S+)');

/// 1 行を解析する。ScreactPerf の集計行でなければ null。
/// logcat の前置き（日時・PID・タグ）や Desktop の時刻の前置きは読み飛ばす。
PerfRecord? parsePerfLine(String line) {
  final tag = line.indexOf('ScreactPerf');
  if (tag < 0) return null;
  final rest = line.substring(tag + 'ScreactPerf'.length);
  final win = _winToken.firstMatch(rest);
  if (win == null) return null;
  final body = rest.substring(win.start);
  final fields = <String, String>{
    for (final m in _pair.allMatches(body)) m.group(1)!: m.group(2)!,
  };

  final PerfSource source;
  if (fields.containsKey('cap') && fields.containsKey('sent')) {
    source = PerfSource.android;
  } else if (fields.containsKey('recv') && fields.containsKey('done')) {
    source = PerfSource.desktop;
  } else {
    return null;
  }

  final winText = fields['win']!;
  final seconds = double.tryParse(
    winText.endsWith('s') ? winText.substring(0, winText.length - 1) : winText,
  );
  if (seconds == null || seconds <= 0) return null;

  final counts = <String, int>{};
  for (final key in _countKeys[source]!) {
    final value = int.tryParse(fields[key] ?? '');
    if (value == null) return null;
    counts[key] = value;
  }

  final hands = (fields['hands'] ?? '').split('/').map(int.tryParse).toList();
  if (hands.length != 3 || hands.contains(null)) return null;

  final segments = <String, (double?, double?)>{};
  for (final (name, _) in perfSegments[source]!) {
    final raw = fields[name];
    if (raw == null) return null;
    final parts = raw.split('/');
    if (parts.length != 2) return null;
    segments[name] = (_millis(parts[0]), _millis(parts[1]));
  }

  return PerfRecord(
    source: source,
    windowSeconds: seconds,
    maxHands: source == PerfSource.android ? counts['maxHands'] : null,
    counts: counts,
    handCounts: hands.cast<int>(),
    segments: segments,
  );
}

double? _millis(String text) => text == '-' ? null : double.tryParse(text);

/// ログ全体の解析結果。
class PerfLog {
  final List<PerfRecord> records;

  /// `ScreactPerf` を含むのに集計行として読めなかった行の数。
  final int skippedLines;

  const PerfLog(this.records, this.skippedLines);
}

PerfLog parsePerfLog(String text) {
  final records = <PerfRecord>[];
  var skipped = 0;
  for (final line in const LineSplitter().convert(text)) {
    if (!line.contains('ScreactPerf')) continue;
    final record = parsePerfLine(line);
    if (record == null) {
      skipped++;
    } else {
      records.add(record);
    }
  }
  return PerfLog(records, skipped);
}

/// ログファイルのバイト列を文字列にする。
/// Windows PowerShell 5 の `>` は UTF-16LE（BOM 付き）で書くため、BOM を見て切り替える。
String decodeLogBytes(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _utf16(bytes, 2, Endian.little);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _utf16(bytes, 2, Endian.big);
  }
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3;
  }
  return utf8.decode(bytes.sublist(start), allowMalformed: true);
}

String _utf16(List<int> bytes, int start, Endian endian) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(data.getUint16(i, endian));
  }
  return String.fromCharCodes(units);
}

/// 最近傍順位法の百分位数（latency_probe と同じ定義。偶数個の中央値は下側）。
double? nearestRank(List<double> values, double fraction) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final rank = (fraction * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

/// 区間 1 つの窓またぎの集計。
class SegmentStat {
  final String name;
  final String description;

  /// 値のあった窓の数。
  final int windows;
  final double? p50Ms;
  final double? p95Ms;
  final double? worstP95Ms;

  const SegmentStat({
    required this.name,
    required this.description,
    required this.windows,
    required this.p50Ms,
    required this.p95Ms,
    required this.worstP95Ms,
  });
}

/// 条件 × 出どころ × 手数 の 1 グループ。
class PerfGroup {
  final String condition;
  final PerfSource source;
  final int? maxHands;
  final int windows;
  final double seconds;
  final Map<String, int> totals;
  final List<int> handTotals;
  final List<SegmentStat> segments;

  const PerfGroup({
    required this.condition,
    required this.source,
    required this.maxHands,
    required this.windows,
    required this.seconds,
    required this.totals,
    required this.handTotals,
    required this.segments,
  });

  double? _ratio(String num, String den) {
    final d = totals[den] ?? 0;
    return d == 0 ? null : (totals[num] ?? 0) / d;
  }

  double? _rate(String key) =>
      seconds == 0 ? null : (totals[key] ?? 0) / seconds;

  /// Android: 解析に届いたフレームの毎秒数。Desktop: 受信した hand_frame の毎秒数。
  double? get inputFps => _rate(source == PerfSource.android ? 'cap' : 'recv');

  /// Android: 送信数の毎秒数。Desktop: 処理完了数の毎秒数。
  double? get outputFps =>
      _rate(source == PerfSource.android ? 'sent' : 'done');

  /// Android: 送信キューで上書きされた割合（dropQ / enq）。
  /// Desktop: 処理前に上書きされた割合（drop / recv）。
  double? get queueDropRate =>
      source == PerfSource.android
          ? _ratio('dropQ', 'enq')
          : _ratio('drop', 'recv');

  /// Android: 推論結果が返らなかった割合（dropInf / cap）。
  /// Desktop: frameId 逆転で破棄した割合（stale / recv）。
  double? get secondaryDropRate =>
      source == PerfSource.android
          ? _ratio('dropInf', 'cap')
          : _ratio('stale', 'recv');

  /// 入力のうち出力まで届かなかった割合。
  /// Android: 1 - sent / cap。Desktop: 1 - done / recv。
  double? get lossRate {
    final r =
        source == PerfSource.android
            ? _ratio('sent', 'cap')
            : _ratio('done', 'recv');
    return r == null ? null : (1 - r).clamp(0.0, 1.0);
  }
}

/// 条件 1 つ分の入力（ラベルと、その条件で取ったログ）。
class ConditionLogs {
  final String condition;
  final List<PerfRecord> records;
  const ConditionLogs(this.condition, this.records);
}

/// 条件ごとの、Android の送信数と Desktop の受信数の比較（参考値）。
class LinkStat {
  final String condition;
  final int androidSent;
  final int desktopReceived;

  /// 条件の中に Android の手数（maxHands）が複数混ざっているか。
  final bool mixedHands;

  const LinkStat(
    this.condition,
    this.androidSent,
    this.desktopReceived, {
    this.mixedHands = false,
  });

  /// 1 - 受信 / 送信。窓の境目や計測開始のずれを含む概算。
  double? get lossRate =>
      androidSent == 0
          ? null
          : (1 - desktopReceived / androidSent).clamp(0.0, 1.0);
}

class LatencyReport {
  final List<PerfGroup> groups;
  final List<LinkStat> links;
  final int skippedLines;
  const LatencyReport(this.groups, this.links, {this.skippedLines = 0});
}

/// 条件ごとのログから表のもとになる集計を作る。
/// Android の行は同じ条件の中でも maxHands ごとに分ける。
LatencyReport buildLatencyReport(
  List<ConditionLogs> inputs, {
  int skippedLines = 0,
}) {
  final groups = <PerfGroup>[];
  final links = <LinkStat>[];
  for (final input in inputs) {
    final keys = <(PerfSource, int?)>{};
    for (final r in input.records) {
      keys.add((r.source, r.maxHands));
    }
    final ordered =
        keys.toList()..sort((a, b) {
          final s = a.$1.index.compareTo(b.$1.index);
          return s != 0 ? s : (a.$2 ?? 0).compareTo(b.$2 ?? 0);
        });
    for (final (source, maxHands) in ordered) {
      final rows =
          input.records
              .where((r) => r.source == source && r.maxHands == maxHands)
              .toList();
      groups.add(_group(input.condition, source, maxHands, rows));
    }

    var sent = 0;
    var received = 0;
    var hasAndroid = false;
    var hasDesktop = false;
    for (final r in input.records) {
      if (r.source == PerfSource.android) {
        hasAndroid = true;
        sent += r.counts['sent'] ?? 0;
      } else {
        hasDesktop = true;
        received += r.counts['recv'] ?? 0;
      }
    }
    if (hasAndroid && hasDesktop) {
      final handsInCondition = {
        for (final (source, maxHands) in keys)
          if (source == PerfSource.android) maxHands,
      };
      links.add(
        LinkStat(
          input.condition,
          sent,
          received,
          mixedHands: handsInCondition.length > 1,
        ),
      );
    }
  }
  return LatencyReport(groups, links, skippedLines: skippedLines);
}

PerfGroup _group(
  String condition,
  PerfSource source,
  int? maxHands,
  List<PerfRecord> rows,
) {
  final totals = <String, int>{};
  final hands = [0, 0, 0];
  var seconds = 0.0;
  for (final r in rows) {
    seconds += r.windowSeconds;
    r.counts.forEach((k, v) {
      if (k != 'maxHands') totals[k] = (totals[k] ?? 0) + v;
    });
    for (var i = 0; i < 3; i++) {
      hands[i] += r.handCounts[i];
    }
  }
  final segments = <SegmentStat>[];
  for (final (name, description) in perfSegments[source]!) {
    final p50s = <double>[];
    final p95s = <double>[];
    for (final r in rows) {
      final (p50, p95) = r.segments[name]!;
      if (p50 != null) p50s.add(p50);
      if (p95 != null) p95s.add(p95);
    }
    segments.add(
      SegmentStat(
        name: name,
        description: description,
        windows: p50s.length,
        p50Ms: nearestRank(p50s, 0.5),
        p95Ms: nearestRank(p95s, 0.5),
        worstP95Ms: p95s.isEmpty ? null : p95s.reduce((a, b) => a > b ? a : b),
      ),
    );
  }
  return PerfGroup(
    condition: condition,
    source: source,
    maxHands: maxHands,
    windows: rows.length,
    seconds: seconds,
    totals: totals,
    handTotals: hands,
    segments: segments,
  );
}

/// 見出しに出す計測条件の項目（キー, 表示名）。`--meta key=value` で埋める。
const List<(String, String)> reportMetaFields = [
  ('date', '日付'),
  ('android_device', 'Android 端末'),
  ('android_os', 'Android OS'),
  ('android_build', 'Android build（commit）'),
  ('desktop_device', 'PC'),
  ('desktop_os', 'PC OS'),
  ('desktop_build', 'Desktop build（commit）'),
  ('hands', '手数'),
  ('network', '回線条件'),
  ('transport', '通信方式'),
  ('duration', '計測時間'),
  ('method', '測定方法'),
];

const String _unfilled = '（未記入）';

String _sourceName(PerfSource s) =>
    s == PerfSource.android ? 'Android' : 'Desktop';

String _num(double? v, [int digits = 1]) =>
    v == null ? '-' : v.toStringAsFixed(digits);

String _pct(double? v) => v == null ? '-' : '${(v * 100).toStringAsFixed(1)}%';

String _hands(int? maxHands) => maxHands?.toString() ?? '-';

String _cell(String s) => s.replaceAll('|', r'\|').replaceAll('\n', ' ');

/// Markdown のレポート。記録へそのまま貼れる形にする。
String renderMarkdown(
  LatencyReport report, {
  Map<String, String> meta = const {},
  String title = '遅延計測レポート',
}) {
  final b =
      StringBuffer()
        ..writeln('# $title')
        ..writeln();

  b
    ..writeln('## 計測条件')
    ..writeln()
    ..writeln('| 項目 | 値 |')
    ..writeln('| --- | --- |');
  final known = {for (final (k, _) in reportMetaFields) k};
  for (final (key, label) in reportMetaFields) {
    b.writeln('| $label | ${_cell(meta[key] ?? _unfilled)} |');
  }
  for (final e in meta.entries) {
    if (!known.contains(e.key)) {
      b.writeln('| ${_cell(e.key)} | ${_cell(e.value)} |');
    }
  }
  b.writeln();

  final android =
      report.groups.where((g) => g.source == PerfSource.android).toList();
  final desktop =
      report.groups.where((g) => g.source == PerfSource.desktop).toList();

  if (android.isNotEmpty) {
    b
      ..writeln('## Android 件数と欠落率')
      ..writeln()
      ..writeln(
        '| 条件 | 手数 | 窓 | 秒 | 入力fps | 送信fps | 手0/1/2 | '
        'キュー上書き率 | 推論欠落率 | 送信前欠落率 |',
      )
      ..writeln(
        '| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |',
      );
    for (final g in android) {
      b.writeln(
        '| ${_cell(g.condition)} | ${_hands(g.maxHands)} | ${g.windows} | '
        '${_num(g.seconds)} | ${_num(g.inputFps)} | ${_num(g.outputFps)} | '
        '${g.handTotals.join('/')} | ${_pct(g.queueDropRate)} | '
        '${_pct(g.secondaryDropRate)} | ${_pct(g.lossRate)} |',
      );
    }
    b
      ..writeln()
      ..writeln(
        'キュー上書き率 = dropQ / enq、推論欠落率 = dropInf / cap、'
        '送信前欠落率 = 1 - sent / cap。',
      )
      ..writeln();
  }

  if (desktop.isNotEmpty) {
    b
      ..writeln('## Desktop 件数と欠落率')
      ..writeln()
      ..writeln(
        '| 条件 | 窓 | 秒 | 受信fps | 処理fps | 手0/1/2 | '
        '上書き率 | stale率 | 未処理率 |',
      )
      ..writeln(
        '| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |',
      );
    for (final g in desktop) {
      b.writeln(
        '| ${_cell(g.condition)} | ${g.windows} | ${_num(g.seconds)} | '
        '${_num(g.inputFps)} | ${_num(g.outputFps)} | '
        '${g.handTotals.join('/')} | ${_pct(g.queueDropRate)} | '
        '${_pct(g.secondaryDropRate)} | ${_pct(g.lossRate)} |',
      );
    }
    b
      ..writeln()
      ..writeln(
        '上書き率 = drop / recv、stale率 = stale / recv、'
        '未処理率 = 1 - done / recv。',
      )
      ..writeln();
  }

  if (report.links.isNotEmpty) {
    b
      ..writeln('## 端末間の件数比較（参考）')
      ..writeln()
      ..writeln('| 条件 | Android sent | Desktop recv | 通信区間の欠落率（概算） |')
      ..writeln('| --- | ---: | ---: | ---: |');
    for (final l in report.links) {
      b.writeln(
        '| ${_cell(l.condition)} | ${l.androidSent} | ${l.desktopReceived} | '
        '${_pct(l.lossRate)}${l.mixedHands ? '（手数混在）' : ''} |',
      );
    }
    b
      ..writeln()
      ..writeln(
        '件数の合計どうしを比べた概算で、両端末の窓の境目や計測開始・終了のずれを含む。'
        '時刻の引き算はしていない。'
        '「手数混在」は 1 つの条件に 1 手と 2 手のログが混ざっているもので、比較に使わない。',
      )
      ..writeln();
  }

  if (report.groups.isNotEmpty) {
    b
      ..writeln('## 区間遅延（ms）')
      ..writeln()
      ..writeln('| 条件 | 端末 | 手数 | 区間 | 内容 | 窓 | 中央値 | P95 | 最悪P95 |')
      ..writeln('| --- | --- | ---: | --- | --- | ---: | ---: | ---: | ---: |');
    for (final g in [...android, ...desktop]) {
      for (final s in g.segments) {
        b.writeln(
          '| ${_cell(g.condition)} | ${_sourceName(g.source)} | '
          '${_hands(g.maxHands)} | `${s.name}` | ${s.description} | '
          '${s.windows} | ${_num(s.p50Ms)} | ${_num(s.p95Ms)} | '
          '${_num(s.worstP95Ms)} |',
        );
      }
    }
    b
      ..writeln()
      ..writeln(
        '中央値 = 各窓の中央値の中央値、P95 = 各窓の P95 の中央値、'
        '最悪P95 = 各窓の P95 の最大値。どれも同じ端末内の単調時計で測った値で、'
        'Android と Desktop の区間を足しても端末間の片道遅延にはならない。',
      )
      ..writeln();
  } else {
    b
      ..writeln('ScreactPerf の集計行が見つからなかった。')
      ..writeln();
  }

  if (report.skippedLines > 0) {
    b
      ..writeln('読めなかった ScreactPerf 行: ${report.skippedLines} 行（集計から除外）。')
      ..writeln();
  }
  return b.toString();
}

/// CSV（縦持ち）。1 行 = 条件 × 端末 × 手数 × 指標。
/// 率は `value`（0〜1）、区間は `p50_ms` / `p95_ms` / `worst_p95_ms` に入れる。
String renderCsv(LatencyReport report) {
  final b =
      StringBuffer()..writeln(
        'condition,source,max_hands,windows,seconds,metric,value,'
        'p50_ms,p95_ms,worst_p95_ms',
      );
  String esc(String s) =>
      RegExp(r'[",\r\n]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
  String n(double? v, [int digits = 1]) =>
      v == null ? '' : v.toStringAsFixed(digits);

  for (final g in report.groups) {
    final head =
        '${esc(g.condition)},${g.source.name},${g.maxHands ?? ''},'
        '${g.windows},${n(g.seconds)}';
    void value(String metric, double? v, [int digits = 4]) {
      b.writeln('$head,$metric,${n(v, digits)},,,');
    }

    value('input_fps', g.inputFps, 1);
    value('output_fps', g.outputFps, 1);
    value('queue_drop_rate', g.queueDropRate);
    value(
      g.source == PerfSource.android ? 'inference_drop_rate' : 'stale_rate',
      g.secondaryDropRate,
    );
    value('loss_rate', g.lossRate);
    for (final s in g.segments) {
      b.writeln(
        '$head,${s.name},,${n(s.p50Ms)},${n(s.p95Ms)},${n(s.worstP95Ms)}',
      );
    }
  }
  for (final l in report.links) {
    b.writeln(
      '${esc(l.condition)},link,,,,link_loss_rate,${n(l.lossRate, 4)},,,',
    );
  }
  return b.toString();
}
