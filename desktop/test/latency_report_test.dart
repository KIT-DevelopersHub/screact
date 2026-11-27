import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/net/latency_probe.dart';
import 'package:thehack_overlay/net/latency_report.dart';

String _fixture(String name) =>
    File('test/fixtures/latency/$name').readAsStringSync();

void main() {
  group('parsePerfLine', () {
    test('logcat の前置きを読み飛ばして Android の行を読む', () {
      final r =
          parsePerfLine(
            '11-28 21:00:05.123  4321  4400 I ScreactPerf: win=5.0s maxHands=2 '
            'cap=148 inf=146 enq=146 sent=97 dropQ=49 dropInf=2 hands=12/58/76 '
            'interval=33.4/41.0 capInf=24.1/38.7 infEnq=0.3/0.9 '
            'enqSend=-/- capSend=35.2/57.9',
          )!;
      expect(r.source, PerfSource.android);
      expect(r.windowSeconds, 5.0);
      expect(r.maxHands, 2);
      expect(r.counts['sent'], 97);
      expect(r.handCounts, [12, 58, 76]);
      expect(r.segments['capInf'], (24.1, 38.7));
      expect(r.segments['enqSend'], (null, null));
    });

    test('logcat -v time の形式も読める', () {
      final r = parsePerfLine(
        '11-28 21:00:05.123 I/ScreactPerf( 4321): win=5.0s maxHands=1 '
        'cap=1 inf=1 enq=1 sent=1 dropQ=0 dropInf=0 hands=0/1/0 '
        'interval=-/- capInf=1.0/1.0 infEnq=0.1/0.1 enqSend=0.2/0.2 '
        'capSend=1.3/1.3',
      );
      expect(r?.source, PerfSource.android);
    });

    test('LatencyProbe が出す Desktop の行をそのまま読める', () {
      final lines = <String>[];
      var now = 0;
      final probe = LatencyProbe(sink: lines.add, nowMicros: () => now);
      for (var i = 0; i < 200; i++) {
        now = i * 33000;
        probe.onReceived(
          receiveMicros: now,
          parseMicros: now + 300,
          handCount: 1,
          replacedPending: false,
        );
        probe.onProcessed(
          receiveMicros: now,
          parseMicros: now + 300,
          startMicros: now + 300,
          engineMicros: now + 700,
          osMicros: now + 800,
          overlayMicros: now + 1000,
        );
      }
      expect(lines, isNotEmpty);
      final r = parsePerfLine('2026-11-28T21:00:05.000 ${lines.first}')!;
      expect(r.source, PerfSource.desktop);
      expect(r.maxHands, isNull);
      expect(r.counts['recv'], r.counts['done']);
      expect(r.segments['total'], (1.0, 1.0));
      expect(r.segments['interval'], (33.0, 33.0));
    });

    test('集計行でないものと欠けた行は null', () {
      expect(parsePerfLine('ws upgraded'), isNull);
      expect(parsePerfLine('ScreactPerf enabled'), isNull);
      expect(parsePerfLine('I ScreactPerf: win=5.0s maxHands=1 cap=1'), isNull);
    });
  });

  test('parsePerfLog は読めない ScreactPerf 行を数える', () {
    final log = parsePerfLog(_fixture('android_logcat.log'));
    expect(log.records, hasLength(4));
    expect(log.skippedLines, 1);
    final desktop = parsePerfLog(_fixture('desktop_log.log'));
    expect(desktop.records, hasLength(3));
    expect(desktop.skippedLines, 0);
  });

  group('decodeLogBytes', () {
    const text = 'I ScreactPerf: win=5.0s\n';
    test('UTF-16LE（BOM 付き）を読む', () {
      final bytes = <int>[0xFF, 0xFE];
      for (final unit in text.codeUnits) {
        bytes
          ..add(unit & 0xFF)
          ..add(unit >> 8);
      }
      expect(decodeLogBytes(bytes), text);
    });

    test('UTF-8（BOM の有無）を読む', () {
      expect(decodeLogBytes(utf8.encode(text)), text);
      expect(decodeLogBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]), text);
    });
  });

  test('nearestRank は latency_probe と同じく偶数個の中央値が下側', () {
    expect(nearestRank([], 0.5), isNull);
    expect(nearestRank([4, 1, 3, 2], 0.5), 2);
    expect(nearestRank([4, 1, 3, 2], 0.95), 4);
  });

  group('buildLatencyReport', () {
    late LatencyReport report;
    setUp(() {
      final records = [
        ...parsePerfLog(_fixture('android_logcat.log')).records,
        ...parsePerfLog(_fixture('desktop_log.log')).records,
      ];
      report = buildLatencyReport([ConditionLogs('LAN', records)]);
    });

    test('Android は手数ごと、Desktop は 1 グループにまとめる', () {
      expect(report.groups.map((g) => (g.source, g.maxHands)).toList(), [
        (PerfSource.android, 1),
        (PerfSource.android, 2),
        (PerfSource.desktop, null),
      ]);
    });

    test('Android 1 手の件数・率・区間', () {
      final g = report.groups[0];
      expect(g.windows, 3);
      expect(g.seconds, 15.0);
      expect(g.totals['cap'], 450);
      expect(g.totals['sent'], 300);
      expect(g.inputFps, closeTo(30.0, 1e-9));
      expect(g.outputFps, closeTo(20.0, 1e-9));
      expect(g.queueDropRate, closeTo(148 / 448, 1e-9));
      expect(g.secondaryDropRate, closeTo(2 / 450, 1e-9));
      expect(g.lossRate, closeTo(1 - 300 / 450, 1e-9));
      expect(g.handTotals, [18, 430, 0]);
      final capInf = g.segments.firstWhere((s) => s.name == 'capInf');
      expect(capInf.windows, 3);
      expect(capInf.p50Ms, 21.0);
      expect(capInf.p95Ms, 32.0);
      expect(capInf.worstP95Ms, 34.0);
    });

    test('サンプルの無い区間は窓 0 で値なし', () {
      final g = report.groups[1];
      final enqSend = g.segments.firstWhere((s) => s.name == 'enqSend');
      expect(enqSend.windows, 0);
      expect(enqSend.p50Ms, isNull);
      expect(enqSend.worstP95Ms, isNull);
    });

    test('Desktop の件数・率・区間', () {
      final g = report.groups[2];
      expect(g.totals['recv'], 294);
      expect(g.totals['done'], 292);
      expect(g.queueDropRate, closeTo(2 / 294, 1e-9));
      expect(g.secondaryDropRate, 0);
      expect(g.lossRate, closeTo(2 / 294, 1e-9));
      final total = g.segments.firstWhere((s) => s.name == 'total');
      expect(total.p50Ms, 1.1);
      expect(total.p95Ms, 2.2);
      expect(total.worstP95Ms, 2.5);
    });

    test('両端末のログがある条件は件数比較を出す', () {
      expect(report.links, hasLength(1));
      final l = report.links.single;
      expect(l.androidSent, 400);
      expect(l.desktopReceived, 294);
      expect(l.lossRate, closeTo(1 - 294 / 400, 1e-9));
      // fixture の Android ログは 1 手と 2 手が混ざっている。
      expect(l.mixedHands, isTrue);
      expect(
        renderMarkdown(report),
        contains('| LAN | 400 | 294 | 26.5%（手数混在） |'),
      );
    });

    test('片方だけの条件は件数比較を出さない', () {
      final only = buildLatencyReport([
        ConditionLogs('A', parsePerfLog(_fixture('desktop_log.log')).records),
      ]);
      expect(only.links, isEmpty);
      final single = buildLatencyReport([
        ConditionLogs('B', [
          parsePerfLog(_fixture('android_logcat.log')).records.first,
          ...parsePerfLog(_fixture('desktop_log.log')).records,
        ]),
      ]);
      expect(single.links.single.mixedHands, isFalse);
    });
  });

  group('出力', () {
    late LatencyReport report;
    setUp(() {
      report = buildLatencyReport([
        ConditionLogs(
          '1手-通常LAN',
          parsePerfLog(_fixture('android_logcat.log')).records,
        ),
        ConditionLogs(
          '1手-通常LAN|混雑',
          parsePerfLog(_fixture('desktop_log.log')).records,
        ),
      ], skippedLines: 1);
    });

    test('Markdown に計測条件の見出しと各表が出る', () {
      final md = renderMarkdown(
        report,
        meta: {'date': '2026-11-28', 'network': '通常LAN', 'room': '会議室A'},
      );
      expect(md, contains('## 計測条件'));
      expect(md, contains('| 日付 | 2026-11-28 |'));
      expect(md, contains('| 回線条件 | 通常LAN |'));
      expect(md, contains('| Android 端末 | （未記入） |'));
      expect(md, contains('| room | 会議室A |'));
      expect(md, contains('## Android 件数と欠落率'));
      expect(
        md,
        contains(
          '| 1手-通常LAN | 1 | 3 | 15.0 | 30.0 | 20.0 | 18/430/0 | '
          '33.0% | 0.4% | 33.3% |',
        ),
      );
      expect(md, contains('## Desktop 件数と欠落率'));
      // 条件名の | は表を壊さないようにエスケープする。
      expect(md, contains(r'| 1手-通常LAN\|混雑 | 3 | 15.0 |'));
      expect(
        md,
        contains(
          '| 1手-通常LAN | Android | 1 | `capInf` | 受け取り→MediaPipe結果 | '
          '3 | 21.0 | 32.0 | 34.0 |',
        ),
      );
      expect(md, contains('| `enqSend` | 送信キュー→送信要求受理 | 0 | - | - | - |'));
      expect(md, contains('読めなかった ScreactPerf 行: 1 行'));
      expect(md, isNot(contains('端末間の件数比較')));
    });

    test('CSV は縦持ちで条件名をエスケープする', () {
      final csv = const LineSplitter().convert(renderCsv(report));
      expect(
        csv.first,
        'condition,source,max_hands,windows,seconds,metric,value,'
        'p50_ms,p95_ms,worst_p95_ms',
      );
      expect(csv, contains('1手-通常LAN,android,1,3,15.0,input_fps,30.0,,,'));
      expect(csv, contains('1手-通常LAN,android,1,3,15.0,loss_rate,0.3333,,,'));
      expect(csv, contains('1手-通常LAN,android,1,3,15.0,capInf,,21.0,32.0,34.0'));
      expect(csv, contains('1手-通常LAN,android,2,1,5.0,enqSend,,,,'));
      expect(csv, contains('1手-通常LAN|混雑,desktop,,3,15.0,total,,1.1,2.2,2.5'));
      final quoted = buildLatencyReport([
        ConditionLogs('a,b', parsePerfLog(_fixture('desktop_log.log')).records),
      ]);
      expect(renderCsv(quoted), contains('"a,b",desktop,'));
    });

    test('集計行が無ければその旨を書く', () {
      final md = renderMarkdown(const LatencyReport([], []));
      expect(md, contains('ScreactPerf の集計行が見つからなかった。'));
    });
  });
}
