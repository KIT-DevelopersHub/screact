import 'dart:io';
import 'dart:typed_data';

/// 固定長の int リングバッファ。満杯なら最古の値を上書きする。
/// 追加時に割り当てを行わず、統計は [percentile] でまとめて計算する。
class IntSampleBuffer {
  final int capacity;
  final Int64List _values;
  final Int64List _scratch;
  int _next = 0;
  int _size = 0;

  IntSampleBuffer(this.capacity)
    : assert(capacity > 0),
      _values = Int64List(capacity),
      _scratch = Int64List(capacity);

  /// 保持中のサンプル数（最大 [capacity]）。
  int get size => _size;

  void add(int value) {
    _values[_next] = value;
    _next = (_next + 1) % capacity;
    if (_size < capacity) _size++;
  }

  void clear() {
    _next = 0;
    _size = 0;
  }

  /// 最近傍順位法の百分位数。fraction=0.5 は中央値（偶数個なら下側）、0.95 はP95。
  /// サンプルが無ければ null。
  int? percentile(double fraction) {
    if (_size == 0) return null;
    assert(fraction > 0 && fraction <= 1);
    // 満杯でない間は _values[0, _size) が有効。残りは最大値で埋めて末尾へ寄せる。
    _scratch.setRange(0, _size, _values);
    if (_size < capacity) _scratch.fillRange(_size, capacity, _maxInt);
    _scratch.sort();
    final rank = (fraction * _size).ceil().clamp(1, _size);
    return _scratch[rank - 1];
  }

  static const int _maxInt = 0x7fffffffffffffff;
}

/// 区間ごとのサンプル数・中央値・P95（マイクロ秒）。
class SegmentSummary {
  final int samples;
  final int? p50Micros;
  final int? p95Micros;
  const SegmentSummary(this.samples, this.p50Micros, this.p95Micros);
}

class LatencySummary {
  final int windowMicros;

  /// セッション確立後に受信し、処理待ちへ入れた hand_frame の数。
  final int received;

  /// エンジン処理と出力まで終えた数。
  final int processed;

  /// 処理前に新着で上書きされ、処理されなかった数（最新フレーム優先）。
  final int dropped;

  /// frameId が単調増加でなくエンジンが破棄した数。
  final int stale;

  /// 受信フレームの手の数ごとの件数。添字 0, 1, 2。
  final List<int> handCounts;

  final SegmentSummary frameInterval;
  final SegmentSummary receiveToParse;
  final SegmentSummary parseToStart;
  final SegmentSummary startToEngine;
  final SegmentSummary engineToOs;
  final SegmentSummary osToOverlay;
  final SegmentSummary receiveToOverlay;

  const LatencySummary({
    required this.windowMicros,
    required this.received,
    required this.processed,
    required this.dropped,
    required this.stale,
    required this.handCounts,
    required this.frameInterval,
    required this.receiveToParse,
    required this.parseToStart,
    required this.startToEngine,
    required this.engineToOs,
    required this.osToOverlay,
    required this.receiveToOverlay,
  });
}

/// Desktop 内の hand_frame 1枚ごとの区間を集計する窓。
/// 時刻はすべて同一プロセスの単調時計（マイクロ秒）で、他端末の時計とは比べない。
///
/// 区間:
/// - receive: WebSocket メッセージの到着（`_onMessage` 先頭）
/// - parse: `InputFrame.parse` 完了
/// - start: 処理ループが取り出した時刻
/// - engine: `MultiHandEngine.onInputFrame` 完了
/// - os: 骨格通知（onFrame）と OS 入力（onEvents）の呼び出し完了
/// - overlay: オーバーレイ更新（onTrackEvents）の呼び出し完了
class LatencyWindow {
  static const int defaultCapacity = 512;

  /// これより長い受信の空白（再接続など）はフレーム間隔に含めない。
  static const int maxFrameGapMicros = 2000000;

  final IntSampleBuffer _frameInterval;
  final IntSampleBuffer _receiveToParse;
  final IntSampleBuffer _parseToStart;
  final IntSampleBuffer _startToEngine;
  final IntSampleBuffer _engineToOs;
  final IntSampleBuffer _osToOverlay;
  final IntSampleBuffer _receiveToOverlay;
  final List<int> _handCounts = List<int>.filled(3, 0);
  int _received = 0;
  int _processed = 0;
  int _dropped = 0;
  int _stale = 0;
  int? _lastReceiveMicros;

  LatencyWindow({int capacity = defaultCapacity})
    : _frameInterval = IntSampleBuffer(capacity),
      _receiveToParse = IntSampleBuffer(capacity),
      _parseToStart = IntSampleBuffer(capacity),
      _startToEngine = IntSampleBuffer(capacity),
      _engineToOs = IntSampleBuffer(capacity),
      _osToOverlay = IntSampleBuffer(capacity),
      _receiveToOverlay = IntSampleBuffer(capacity);

  /// 処理待ちへ入れた hand_frame を記録する。
  /// [replacedPending] は未処理の前フレームを上書きしたか。
  void onReceived({
    required int receiveMicros,
    required int parseMicros,
    required int handCount,
    required bool replacedPending,
  }) {
    _received++;
    if (replacedPending) _dropped++;
    _handCounts[handCount.clamp(0, _handCounts.length - 1)]++;
    final previous = _lastReceiveMicros;
    _lastReceiveMicros = receiveMicros;
    if (previous != null) {
      final interval = receiveMicros - previous;
      if (interval >= 0 && interval <= maxFrameGapMicros) {
        _frameInterval.add(interval);
      }
    }
    _addSegment(_receiveToParse, receiveMicros, parseMicros);
  }

  void onStale() => _stale++;

  void onProcessed({
    required int receiveMicros,
    required int parseMicros,
    required int startMicros,
    required int engineMicros,
    required int osMicros,
    required int overlayMicros,
  }) {
    _processed++;
    _addSegment(_parseToStart, parseMicros, startMicros);
    _addSegment(_startToEngine, startMicros, engineMicros);
    _addSegment(_engineToOs, engineMicros, osMicros);
    _addSegment(_osToOverlay, osMicros, overlayMicros);
    _addSegment(_receiveToOverlay, receiveMicros, overlayMicros);
  }

  LatencySummary summarize(int windowMicros) => LatencySummary(
    windowMicros: windowMicros,
    received: _received,
    processed: _processed,
    dropped: _dropped,
    stale: _stale,
    handCounts: List<int>.unmodifiable(_handCounts),
    frameInterval: _summary(_frameInterval),
    receiveToParse: _summary(_receiveToParse),
    parseToStart: _summary(_parseToStart),
    startToEngine: _summary(_startToEngine),
    engineToOs: _summary(_engineToOs),
    osToOverlay: _summary(_osToOverlay),
    receiveToOverlay: _summary(_receiveToOverlay),
  );

  /// 集計値を消す。フレーム間隔の基準時刻は連続性のため残す。
  void reset() {
    _frameInterval.clear();
    _receiveToParse.clear();
    _parseToStart.clear();
    _startToEngine.clear();
    _engineToOs.clear();
    _osToOverlay.clear();
    _receiveToOverlay.clear();
    _handCounts.fillRange(0, _handCounts.length, 0);
    _received = 0;
    _processed = 0;
    _dropped = 0;
    _stale = 0;
  }

  static void _addSegment(IntSampleBuffer buffer, int start, int end) {
    if (end < start) return; // 逆転した値は捨てる
    buffer.add(end - start);
  }

  static SegmentSummary _summary(IntSampleBuffer b) =>
      SegmentSummary(b.size, b.percentile(0.5), b.percentile(0.95));

  /// 1行分の文字列（接頭辞なし）。区間は「中央値/P95」をミリ秒で表す。
  /// 例: win=5.0s recv=150 done=148 drop=2 stale=0 hands=0/150/0 interval=33.3/35.1 ...
  static String format(LatencySummary s) {
    final b = StringBuffer()
      ..write('win=${_seconds(s.windowMicros)}s')
      ..write(' recv=${s.received}')
      ..write(' done=${s.processed}')
      ..write(' drop=${s.dropped}')
      ..write(' stale=${s.stale}')
      ..write(' hands=${s.handCounts.join('/')}');
    void segment(String name, SegmentSummary seg) {
      b.write(' $name=${_millis(seg.p50Micros)}/${_millis(seg.p95Micros)}');
    }

    segment('interval', s.frameInterval);
    segment('parse', s.receiveToParse);
    segment('wait', s.parseToStart);
    segment('engine', s.startToEngine);
    segment('os', s.engineToOs);
    segment('overlay', s.osToOverlay);
    segment('total', s.receiveToOverlay);
    return b.toString();
  }

  static String _millis(int? micros) =>
      micros == null ? '-' : (micros / 1000).toStringAsFixed(1);

  static String _seconds(int micros) => (micros / 1000000).toStringAsFixed(1);
}

/// [LatencyWindow] に時計と定期出力を付けたもの。InputServer から呼ぶ。
/// 一定間隔（既定5秒）ごとに、次の hand_frame 受信時に1行を [sink] へ出す。
/// 受信が途絶えている間は出さない。
class LatencyProbe {
  /// Android の性能ログ（logcat タグ）と揃えた接頭辞。
  static const String logPrefix = 'ScreactPerf';
  static const int defaultReportIntervalMicros = 5000000;

  final LatencyWindow window;
  final void Function(String line) sink;
  final int reportIntervalMicros;
  final int Function() _now;
  int? _windowStartMicros;

  /// [nowMicros] は単調時計（マイクロ秒）。省略時は [Stopwatch] を使う。
  LatencyProbe({
    required this.sink,
    int Function()? nowMicros,
    this.reportIntervalMicros = defaultReportIntervalMicros,
    LatencyWindow? window,
  }) : window = window ?? LatencyWindow(),
       _now = nowMicros ?? _stopwatchClock();

  static int Function() _stopwatchClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsedMicroseconds;
  }

  /// `--dart-define=SCREACT_PERF=true` または環境変数 `SCREACT_PERF=1` で有効。
  static bool enabledByEnvironment() {
    const fromDefine = bool.fromEnvironment('SCREACT_PERF');
    if (fromDefine) return true;
    try {
      final v = Platform.environment['SCREACT_PERF'];
      return v == '1' || v == 'true';
    } catch (_) {
      return false;
    }
  }

  int now() => _now();

  void onReceived({
    required int receiveMicros,
    required int parseMicros,
    required int handCount,
    required bool replacedPending,
  }) {
    // 先に前の窓を締め、このフレームは新しい窓へ入れる。
    _maybeReport(receiveMicros);
    window.onReceived(
      receiveMicros: receiveMicros,
      parseMicros: parseMicros,
      handCount: handCount,
      replacedPending: replacedPending,
    );
  }

  void onStale() => window.onStale();

  void onProcessed({
    required int receiveMicros,
    required int parseMicros,
    required int startMicros,
    required int engineMicros,
    required int osMicros,
    required int overlayMicros,
  }) {
    window.onProcessed(
      receiveMicros: receiveMicros,
      parseMicros: parseMicros,
      startMicros: startMicros,
      engineMicros: engineMicros,
      osMicros: osMicros,
      overlayMicros: overlayMicros,
    );
  }

  void _maybeReport(int nowMicros) {
    final start = _windowStartMicros;
    if (start == null) {
      _windowStartMicros = nowMicros;
      return;
    }
    final elapsed = nowMicros - start;
    if (elapsed < reportIntervalMicros) return;
    final line = '$logPrefix ${LatencyWindow.format(window.summarize(elapsed))}';
    window.reset();
    _windowStartMicros = nowMicros;
    sink(line);
  }
}
