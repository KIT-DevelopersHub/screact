import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';
import 'package:thehack_overlay/protocol/messages.dart';

/// OS 操作権（主トラック）の受け渡し（#23・方式 A）の検証。
///
/// 主トラック 7（左）と、もう1人の手 12（右）を使う。フレームは 33ms 間隔。
const _frameMs = 33;

Map<String, dynamic> _hand(int trackId, double x, {bool pinch = false}) {
  final f = MockHand.at(frameId: 0, tip: Vec2(x, 0.5), pinch: pinch);
  return {
    'trackId': trackId,
    'landmarks': [
      for (final l in f.landmarks) [l.x, l.y, l.z],
    ],
  };
}

InputFrame _frame(int frameId, List<Map<String, dynamic>> hands) =>
    InputFrame.parse({
      'schemaVersion': 1,
      'messageType': 'hand_frame',
      'sessionId': 'session-01',
      'frameId': frameId,
      'capturedAtMonotonicMs': frameId * _frameMs,
      'hands': hands,
    })!;

const _pressKinds = {
  InteractionKind.pressDown,
  InteractionKind.pressMove,
  InteractionKind.pressUp,
  InteractionKind.click,
};

/// フレームを流し、OS（単一カーソル）へ届くイベントを記録する。
class _Harness {
  _Harness({bool enabled = true, int graceMs = 300})
    : e = MultiHandEngine(
        trackLossGraceMs: graceMs,
        primaryHandoverEnabled: enabled,
      ) {
    expect(e.calibrate(MockHand.markers()), isTrue);
  }

  final MultiHandEngine e;
  int _frameId = 0;

  /// フレームごとの (OS へ流した trackId, イベント種別)。
  final List<(int?, List<InteractionKind>)> os = [];

  /// 直近フレームの全トラックのイベント（オーバーレイ向け）。
  Map<int, List<InteractionEvent>> lastOut = const {};

  Map<int, List<InteractionEvent>> step(List<Map<String, dynamic>> hands) {
    _frameId++;
    final out = e.onInputFrame(_frame(_frameId, hands))!;
    lastOut = out;
    final id = e.primaryTrackIdOf(out);
    final events = e.primaryEventsOf(out);
    os.add((id, [for (final ev in events ?? const []) ev.kind]));
    return out;
  }

  /// 2手を出して 7 を主トラックにする。
  void acquire7() {
    step([_hand(7, 0.3), _hand(12, 0.7)]);
    step([_hand(7, 0.3), _hand(12, 0.7)]);
    expect(e.primaryTrackId, 7);
  }

  /// OS へ流したイベント種別を、記録の [from] 番目以降について平らに並べる。
  List<InteractionKind> osKinds([int from = 0]) => [
    for (final entry in os.skip(from)) ...entry.$2,
  ];
}

/// 12 がピンチを保つフレームを、主トラックが変わるか [maxFrames] まで流す。
/// 変わったときのフレーム数（1始まり）を返し、変わらなければ null。
int? _holdPinch12(
  _Harness h, {
  int maxFrames = 40,
  Map<String, dynamic> Function()? primaryHand,
}) {
  for (var i = 1; i <= maxFrames; i++) {
    h.step([
      if (primaryHand != null) primaryHand(),
      _hand(12, 0.7, pinch: true),
    ]);
    if (h.e.primaryTrackId == 12) return i;
  }
  return null;
}

void main() {
  test('既定は OFF で、保持時間の既定値は 500ms', () {
    final e = MultiHandEngine();
    expect(e.primaryHandoverEnabled, isFalse);
    expect(
      e.primaryHandoverHoldMs,
      MultiHandEngine.defaultPrimaryHandoverHoldMs,
    );
    expect(MultiHandEngine.defaultPrimaryHandoverHoldMs, 500);
    expect(
      () => MultiHandEngine(primaryHandoverHoldMs: -1),
      throwsArgumentError,
    );
  });

  test('OFF のときは、もう1人がピンチを保っても操作権は移らない', () {
    final h = _Harness(enabled: false)..acquire7();
    final changed = _holdPinch12(h, primaryHand: () => _hand(7, 0.3));
    expect(changed, isNull);
    expect(h.e.primaryTrackId, 7);
    expect(h.osKinds(2).toSet().intersection(_pressKinds), isEmpty);
  });

  test('ON のとき、主トラックでない手が 0.5 秒ピンチを保つと操作権が移る', () {
    final h = _Harness()..acquire7();
    final changed = _holdPinch12(h, primaryHand: () => _hand(7, 0.3))!;
    // 12 の押下は 1 フレーム目から始まり、そこから 500ms 以上で移る。
    final heldMs = (changed - 1) * _frameMs;
    expect(heldMs, greaterThanOrEqualTo(500));
    expect(heldMs - _frameMs, lessThan(500), reason: '保持時間を満たした最初のフレームで移る');

    // 移したフレームは旧主トラック 7 のイベントだけを OS へ流す。
    expect(h.os.last.$1, 7);
    // 次のフレームから 12 を OS へ流す。
    h.step([_hand(7, 0.3), _hand(12, 0.72, pinch: true)]);
    expect(h.os.last.$1, 12);
  });

  test('保持時間に届く前にピンチを離したら移らず、保持時間を数え直す', () {
    final h = _Harness()..acquire7();
    for (var i = 0; i < 10; i++) {
      h.step([_hand(7, 0.3), _hand(12, 0.7, pinch: true)]);
    }
    h.step([_hand(7, 0.3), _hand(12, 0.7)]);
    expect(h.e.primaryTrackId, 7);
    // 離した後に改めて 0.5 秒保つ必要がある（前の 10 フレーム分を持ち越さない）。
    final changed = _holdPinch12(h, primaryHand: () => _hand(7, 0.3))!;
    expect((changed - 1) * _frameMs, greaterThanOrEqualTo(500));
  });

  test('移した直後の1回目のピンチは OS にクリック・押下として流さない', () {
    final h = _Harness()..acquire7();
    _holdPinch12(h, primaryHand: () => _hand(7, 0.3));
    final afterHandover = h.os.length;

    // 受け渡しに使ったピンチを保ったまま動かし、その後に離す。
    for (var i = 0; i < 5; i++) {
      h.step([_hand(7, 0.3), _hand(12, 0.7 + i * 0.01, pinch: true)]);
    }
    h.step([_hand(7, 0.3), _hand(12, 0.75)]);
    final firstPinch = h.osKinds(afterHandover);
    expect(firstPinch.toSet().intersection(_pressKinds), isEmpty);
    expect(firstPinch, everyElement(InteractionKind.pointerMove));

    // 一度離した後の次のピンチは、通常どおり OS へ押下として流す。
    final beforeNext = h.os.length;
    h.step([_hand(7, 0.3), _hand(12, 0.75, pinch: true)]);
    h.step([_hand(7, 0.3), _hand(12, 0.75)]);
    expect(h.osKinds(beforeNext), [
      InteractionKind.pressDown,
      InteractionKind.click,
      InteractionKind.pressUp,
    ]);
  });

  test('受け渡しの瞬間、新しい主トラックの押下はクリックなしで閉じる', () {
    final h = _Harness()..acquire7();
    expect(_holdPinch12(h, primaryHand: () => _hand(7, 0.3)), isNotNull);
    // 移したフレームの 12 のイベント（オーバーレイ向け）は押下を閉じて終わる。
    final kinds = h.lastOut[12]!.map((ev) => ev.kind).toList();
    expect(kinds.last, InteractionKind.pressUp);
    expect(kinds, isNot(contains(InteractionKind.click)));
    expect(h.e.primaryTrackId, 12);
  });

  test('主トラックが押下中・ドラッグ中のときは移さない', () {
    final h = _Harness()..acquire7();
    // 7 がドラッグを続けるあいだ、12 が 1 秒以上ピンチを保つ。
    for (var i = 0; i < 40; i++) {
      h.step([
        _hand(7, 0.3 + i * 0.005, pinch: true),
        _hand(12, 0.7, pinch: true),
      ]);
      expect(h.e.primaryTrackId, 7, reason: '押下中・ドラッグ中は移さない');
    }
    expect(h.osKinds(2), contains(InteractionKind.pressMove));
  });

  test('旧主トラックの押下を閉じてから移す（OS の押下が残らない）', () {
    final h = _Harness()..acquire7();
    for (var i = 0; i < 20; i++) {
      h.step([
        _hand(7, 0.3 + i * 0.005, pinch: true),
        _hand(12, 0.7, pinch: true),
      ]);
    }
    // 7 がドラッグを離す（pressUp を OS へ流す）。12 はピンチを保ち続ける。
    final changed = _holdPinch12(h, primaryHand: () => _hand(7, 0.4))!;
    // 7 が離した後に、改めて 0.5 秒保ってから移る（押下中の保持は数えない）。
    expect((changed - 1) * _frameMs, greaterThanOrEqualTo(500));

    // 移す前に、OS 上の押下はすべて閉じている。
    final toOld = [
      for (final entry in h.os)
        if (entry.$1 == 7) ...entry.$2,
    ];
    final downs = toOld.where((k) => k == InteractionKind.pressDown).length;
    final ups = toOld.where((k) => k == InteractionKind.pressUp).length;
    expect(downs, 1);
    expect(ups, downs, reason: '旧主トラックの押下を閉じてから移す');
    expect(toOld.last, isNot(InteractionKind.pressMove));
    expect(h.e.primaryTrackId, 12);

    // 移した後は、旧主トラック 7 のピンチを OS へ流さない。
    final after = h.os.length;
    h.step([_hand(7, 0.4, pinch: true), _hand(12, 0.7)]);
    h.step([_hand(7, 0.4), _hand(12, 0.7)]);
    expect(h.os.skip(after).every((entry) => entry.$1 != 7), isTrue);
  });

  test('主トラックが一時欠落の猶予中は、もう1人のピンチで操作権を移さない', () {
    // 猶予を長めにとり、猶予中にピンチ保持時間を超えさせる。
    final h = _Harness(graceMs: 2000)..acquire7();
    final changed = _holdPinch12(h, maxFrames: 30);
    expect(h.e.lostTrackIds, [7]);
    expect(changed, isNull, reason: '猶予中は所有権を他へ移さない');
    expect(h.e.primaryTrackId, 7);

    // 7 が戻っても、猶予中に保った時間は持ち越さない。
    h.step([_hand(7, 0.3), _hand(12, 0.7, pinch: true)]);
    expect(h.e.primaryTrackId, 7);
    final again = _holdPinch12(h, primaryHand: () => _hand(7, 0.3))!;
    expect(again * _frameMs, greaterThanOrEqualTo(500));
  });

  test('設定を OFF に切り替えたら、保持途中でも移さない', () {
    final h = _Harness()..acquire7();
    for (var i = 0; i < 10; i++) {
      h.step([_hand(7, 0.3), _hand(12, 0.7, pinch: true)]);
    }
    h.e.primaryHandoverEnabled = false;
    expect(_holdPinch12(h, primaryHand: () => _hand(7, 0.3)), isNull);
    expect(h.e.primaryTrackId, 7);
  });

  group('InteractionEngine.cancelPress', () {
    InteractionEngine calibrated() {
      final e = InteractionEngine();
      expect(e.calibrate(MockHand.markers()), isTrue);
      return e;
    }

    HandFrame pinchAt(int id, {bool pinch = true}) =>
        MockHand.at(frameId: id, tip: const Vec2(0.5, 0.5), pinch: pinch);

    test('押下をクリックなしで閉じ、ピンチが解けるまで再押下しない', () {
      final e = calibrated();
      e.onFrame(pinchAt(1));
      expect(e.isPressed, isTrue);
      expect(e.cancelPress().map((ev) => ev.kind), [InteractionKind.pressUp]);
      expect(e.isPressed, isFalse);
      expect(e.onFrame(pinchAt(2)).map((ev) => ev.kind), [
        InteractionKind.pointerMove,
      ]);
      e.onFrame(pinchAt(3, pinch: false));
      expect(e.onFrame(pinchAt(4)).map((ev) => ev.kind), [
        InteractionKind.pressDown,
      ]);
    });

    test('押下中でなければ何も出さない', () {
      final e = calibrated();
      e.onFrame(pinchAt(1, pinch: false));
      expect(e.cancelPress(), isEmpty);
    });
  });
}
