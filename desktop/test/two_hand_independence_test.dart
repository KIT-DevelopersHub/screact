import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';
import 'package:thehack_overlay/protocol/messages.dart';

import 'multi_hand_test.dart' show multiHandFrame;

/// 2 人（2 手）同時操作の独立性を、実際の [MultiHandEngine] → [OverlayModel]
/// の流れで確かめる統合テスト（Issue #22 / 親 #4）。
///
/// 同時描画・交差・片手消失（猶予内の復帰・猶予超過）・再入場・画面外・
/// 消しゴム・Clear All・骨格表示・ドラッグ中の他者操作で、もう片方の手の
/// 線と OS 入力が壊れないことを見る。
///
/// 主な確かめ方は「同じ台本を、手 7 だけで流した結果」と「手 12 も一緒に
/// 動かした結果」の比較。手 7 の線の点列と OS へ流す主トラックのイベント列が
/// 一致すれば、手 12 の動きは手 7 に一切影響していない。
void main() {
  group('同時描画', () {
    test('2 手が同時に描くと trackId 別に 2 本でき、点が混ざらない', () {
      final h = _Harness();
      for (var i = 0; i < 15; i++) {
        h.step({
          7: _Hand.draw(0.25 + 0.02 * i, 0.35),
          12: _Hand.draw(0.75 - 0.02 * i, 0.60),
        });
      }
      h.step({7: _Hand.point(0.55, 0.35), 12: _Hand.point(0.45, 0.60)});

      expect(h.model.strokes, hasLength(2));
      final s7 = h.strokesOf(7).single;
      final s12 = h.strokesOf(12).single;
      expect(s7.points.length, greaterThan(5));
      expect(s12.points.length, greaterThan(5));
      // 手 7 の線は上の帯、手 12 の線は下の帯だけに点を持つ。
      for (final p in s7.points) {
        expect(p.y, closeTo(_screenY(0.35), 0.02));
      }
      for (final p in s12.points) {
        expect(p.y, closeTo(_screenY(0.60), 0.02));
      }
    });

    test('2 手の線が交差しても入れ替わらず、手 7 の線は単独のときと同じ', () {
      void script(_Harness h) {
        for (var i = 0; i < 21; i++) {
          h.step({
            7: _Hand.draw(0.30 + 0.02 * i, 0.40),
            12: _Hand.draw(0.70 - 0.02 * i, 0.44),
          });
        }
        h.step({7: _Hand.point(0.70, 0.40), 12: _Hand.point(0.30, 0.44)});
      }

      final solo = _Harness(only: 7)..run(script);
      final both = _Harness()..run(script);

      expect(both.model.strokes, hasLength(2));
      expect(
        _points(both.strokesOf(7).single),
        _points(solo.strokesOf(7).single),
      );
      // 交差点を過ぎても、各線は自分の進行方向へ単調に進む（相手へ飛ばない）。
      final s7 = both.strokesOf(7).single.points;
      final s12 = both.strokesOf(12).single.points;
      for (var i = 1; i < s7.length; i++) {
        expect(s7[i].x, greaterThanOrEqualTo(s7[i - 1].x));
      }
      for (var i = 1; i < s12.length; i++) {
        expect(s12[i].x, lessThanOrEqualTo(s12[i - 1].x));
      }
      expect(s7.first.x, lessThan(0.5));
      expect(s7.last.x, greaterThan(0.5));
      expect(s12.first.x, greaterThan(0.5));
      expect(s12.last.x, lessThan(0.5));
    });
  });

  group('片手消失と再入場', () {
    test('描画中に片手が猶予内だけ消えて戻ると、両方の線が 1 本ずつ続く', () {
      void script(_Harness h) {
        for (var i = 0; i < 24; i++) {
          // 手 12 は 8〜10 フレーム目（約 100ms < 猶予 300ms）だけ消える。
          final lost = i >= 8 && i <= 10;
          h.step({
            7: _Hand.draw(0.25 + 0.02 * i, 0.35),
            if (!lost) 12: _Hand.draw(0.25 + 0.02 * i, 0.60),
          });
          if (lost && h.only == null) {
            expect(h.engine.lostTrackIds, contains(12));
            expect(h.model.track(12), isNotNull, reason: '猶予中は消さない');
          }
        }
        h.step({7: _Hand.point(0.75, 0.35), 12: _Hand.point(0.75, 0.60)});
      }

      final solo = _Harness(only: 7)..run(script);
      final both = _Harness()..run(script);

      expect(both.strokesOf(7), hasLength(1));
      expect(both.strokesOf(12), hasLength(1), reason: '猶予内の復帰は同じ線の続き');
      // 欠落 3 フレームを除く 21 フレームぶん伸びている（末尾トリム 3 点）。
      expect(both.strokesOf(12).single.points.length, greaterThanOrEqualTo(18));
      expect(
        _points(both.strokesOf(7).single),
        _points(solo.strokesOf(7).single),
      );
      expect(_sig(both.osEvents), _sig(solo.osEvents));
    });

    test('猶予を超えて消えた手の線だけが確定し、描画中の線は続く', () {
      final h = _Harness();
      for (var i = 0; i < 10; i++) {
        h.step({
          7: _Hand.draw(0.25 + 0.02 * i, 0.35),
          12: _Hand.draw(0.25 + 0.02 * i, 0.60),
        });
      }
      final before12 = List.of(h.strokesOf(12).single.points);

      // 手 12 が猶予（300ms）を超えて消える。手 7 は描き続ける。
      for (var i = 10; i < 22; i++) {
        h.step({7: _Hand.draw(0.25 + 0.02 * i, 0.35)});
      }
      expect(h.engine.lostTrackIds, isEmpty);
      expect(h.engine.activeTrackIds, [7]);
      expect(h.model.track(12), isNull, reason: '確定消失で 12 の表示は消える');
      // 確定消失は drawUp → release の順で届くため、ペン解除と同じく末尾の
      // 数点だけ削られうる。残りは消える前の点列の先頭部分と一致する。
      final after12 = h.strokesOf(12).single.points;
      expect(
        after12.length,
        greaterThanOrEqualTo(before12.length - 3),
        reason: '12 の線は消えずに確定する',
      );
      expect(after12, before12.sublist(0, after12.length));
      expect(h.model.track(7)!.pressed, isTrue, reason: '7 はまだ描画中');

      final before = h.strokesOf(7).single.points.length;
      h.step({7: _Hand.draw(0.70, 0.35)});
      expect(
        h.strokesOf(7).single.points.length,
        greaterThan(before),
        reason: '7 の線は同じ 1 本のまま伸び続ける',
      );
    });

    test('消えた手が新しい trackId で再入場して描いても、もう片方の線は変わらない', () {
      void script(_Harness h) {
        for (var i = 0; i < 8; i++) {
          h.step({
            7: _Hand.draw(0.25 + 0.02 * i, 0.35),
            12: _Hand.draw(0.25 + 0.02 * i, 0.60),
          });
        }
        for (var i = 8; i < 20; i++) {
          h.step({7: _Hand.draw(0.25 + 0.02 * i, 0.35)});
        }
        // 同じ人の手が新しい trackId 15 で戻ってくる。
        for (var i = 20; i < 30; i++) {
          h.step({
            7: _Hand.draw(0.25 + 0.015 * i, 0.35),
            15: _Hand.draw(0.30 + 0.02 * (i - 20), 0.60),
          });
        }
        h.step({7: _Hand.point(0.70, 0.35), 15: _Hand.point(0.50, 0.60)});
      }

      final solo = _Harness(only: 7)..run(script);
      final both = _Harness()..run(script);

      expect(both.strokesOf(7), hasLength(1));
      expect(both.strokesOf(12), hasLength(1));
      expect(both.strokesOf(15), hasLength(1));
      expect(
        _points(both.strokesOf(7).single),
        _points(solo.strokesOf(7).single),
      );
      expect(_sig(both.osEvents), _sig(solo.osEvents));
      // 識別色（カーソル・骨格）は 7 と 15 で別。
      expect(
        both.model.track(15)!.colorSlot,
        isNot(both.model.track(7)!.colorSlot),
      );
    });

    test('同じ trackId で再入場しても、前の線とは別の新しい線になる', () {
      final h = _Harness();
      for (var i = 0; i < 8; i++) {
        h.step({
          7: _Hand.draw(0.25 + 0.02 * i, 0.35),
          12: _Hand.draw(0.25 + 0.02 * i, 0.60),
        });
      }
      for (var i = 8; i < 20; i++) {
        h.step({7: _Hand.draw(0.25 + 0.02 * i, 0.35)});
      }
      for (var i = 20; i < 30; i++) {
        h.step({
          7: _Hand.draw(0.25 + 0.015 * i, 0.35),
          12: _Hand.draw(0.30 + 0.02 * (i - 20), 0.50),
        });
      }
      h.step({7: _Hand.point(0.70, 0.35), 12: _Hand.point(0.50, 0.50)});

      expect(h.strokesOf(7), hasLength(1));
      final s12 = h.strokesOf(12);
      expect(s12, hasLength(2));
      expect(s12[0].points.last.y, closeTo(_screenY(0.60), 0.02));
      expect(s12[1].points.last.y, closeTo(_screenY(0.50), 0.02));
    });

    test('片手が画面外へ出て戻っても、もう片方の描画中の線は途切れない', () {
      void script(_Harness h) {
        for (var i = 0; i < 8; i++) {
          h.step({
            7: _Hand.draw(0.25 + 0.02 * i, 0.35),
            12: _Hand.draw(0.25 + 0.02 * i, 0.60),
          });
        }
        // 手 12 は画面（カメラ 0.1〜0.9）の左外へ出て、検出は続く。
        for (var i = 8; i < 14; i++) {
          h.step({
            7: _Hand.draw(0.25 + 0.02 * i, 0.35),
            12: _Hand.draw(0.03, 0.60),
          });
        }
        if (h.only == null) {
          expect(h.model.track(12)!.cursor, isNull, reason: '画面外はカーソルを隠す');
          expect(h.model.track(12)!.skeleton, isNotNull, reason: '骨格は保つ');
        }
        // 戻って新しい線を描く。
        for (var i = 14; i < 24; i++) {
          h.step({
            7: _Hand.draw(0.25 + 0.02 * i, 0.35),
            12: _Hand.draw(0.30 + 0.02 * (i - 14), 0.55),
          });
        }
        h.step({7: _Hand.point(0.75, 0.35), 12: _Hand.point(0.50, 0.55)});
      }

      final solo = _Harness(only: 7)..run(script);
      final both = _Harness()..run(script);

      expect(both.strokesOf(7), hasLength(1));
      expect(both.strokesOf(12), hasLength(2), reason: '画面外で切れ、戻って新しい線');
      expect(
        _points(both.strokesOf(7).single),
        _points(solo.strokesOf(7).single),
      );
      expect(_sig(both.osEvents), _sig(solo.osEvents));
    });
  });

  group('消しゴム', () {
    test('片方の描画中の線は、もう片方の消しゴムが通っても消えない', () {
      void script(_Harness h) {
        // 手 7 が下の帯に線 A を描いて確定する。
        for (var i = 0; i < 12; i++) {
          h.step({7: _Hand.draw(0.30 + 0.03 * i, 0.60)});
        }
        h.step({7: _Hand.point(0.65, 0.60)});
        // 手 7 が上の帯に線 B を描いている間に、手 12 が B の上と A の上を
        // 消しゴム（グー）でなぞる。消去点はグーの中心（tip より 0.10 下）。
        for (var i = 0; i < 16; i++) {
          h.step({
            7: _Hand.draw(0.30 + 0.025 * i, 0.35),
            12: _Hand.fist(0.30 + 0.025 * i, 0.35 - 0.10),
          });
        }
        for (var i = 0; i < 16; i++) {
          h.step({
            7: _Hand.draw(0.70, 0.35),
            12: _Hand.fist(0.30 + 0.025 * i, 0.60 - 0.10),
          });
        }
        h.step({7: _Hand.point(0.70, 0.35), 12: _Hand.point(0.50, 0.45)});
      }

      final solo = _Harness(only: 7)..run(script);
      final both = _Harness()..run(script);

      // 線の先頭は平滑化の遅れで前の位置から寄ってくるため、末尾の点で帯を見る。
      final soloB = solo.strokesOf(7).last;
      expect(soloB.points.last.y, closeTo(_screenY(0.35), 0.02));
      final bothB = both.model.strokes.where(
        (s) =>
            s.trackId == 7 &&
            s.points.last.y < (_screenY(0.35) + _screenY(0.60)) / 2,
      );
      expect(bothB, hasLength(1), reason: '描画中だった線 B は分割も削除もされない');
      expect(_points(bothB.single), _points(soloB));

      // 確定済みの線 A は消しゴムで消える（消しゴム自体は効いている）。
      final soloA = solo.strokesOf(7).first;
      final bothA =
          both.model.strokes
              .where((s) => s.trackId == 7 && s != bothB.single)
              .expand((s) => s.points)
              .length;
      expect(bothA, lessThan(soloA.points.length));
      expect(_sig(both.osEvents), _sig(solo.osEvents));
    });
  });

  group('Clear All', () {
    test('2 手の描画中に Clear All しても残骸が戻らず、次の線は各自で描ける', () {
      void script(_Harness h) {
        for (var i = 0; i < 10; i++) {
          h.step({
            7: _Hand.draw(0.25 + 0.02 * i, 0.35),
            12: _Hand.draw(0.25 + 0.02 * i, 0.60),
          });
        }
        h.model.clear();
        expect(h.model.strokes, isEmpty);
        // くっつけたまま動かし続けても、消した線は戻らない。
        for (var i = 10; i < 15; i++) {
          h.step({
            7: _Hand.draw(0.25 + 0.02 * i, 0.35),
            12: _Hand.draw(0.25 + 0.02 * i, 0.60),
          });
        }
        expect(h.model.strokes, isEmpty);
        // 一度離して描き直すと、各自の新しい線になる。
        h.step({7: _Hand.point(0.55, 0.35), 12: _Hand.point(0.55, 0.60)});
        for (var i = 0; i < 10; i++) {
          h.step({
            7: _Hand.draw(0.30 + 0.02 * i, 0.40),
            12: _Hand.draw(0.30 + 0.02 * i, 0.55),
          });
        }
        h.step({7: _Hand.point(0.50, 0.40), 12: _Hand.point(0.50, 0.55)});
      }

      final solo = _Harness(only: 7)..run(script);
      final both = _Harness()..run(script);

      expect(both.model.strokes, hasLength(2));
      final s7 = both.strokesOf(7).single;
      final s12 = both.strokesOf(12).single;
      expect(s7.points.last.y, closeTo(_screenY(0.40), 0.02));
      expect(s12.points.last.y, closeTo(_screenY(0.55), 0.02));
      expect(_points(s7), _points(solo.strokesOf(7).single));
      expect(_sig(both.osEvents), _sig(solo.osEvents));
    });

    test('主トラックのドラッグ中に Clear All しても、OS へのドラッグは続く', () {
      void script(_Harness h) {
        h.step({7: _Hand.point(0.30, 0.40), 12: _Hand.point(0.60, 0.55)});
        h.step({7: _Hand.point(0.30, 0.40), 12: _Hand.point(0.60, 0.55)});
        for (var i = 0; i < 12; i++) {
          h.step({
            7: _Hand.pinch(0.30 + 0.02 * i, 0.40),
            12: _Hand.draw(0.30 + 0.02 * i, 0.55),
          });
          if (i == 6) h.model.clear();
        }
        h.step({7: _Hand.point(0.55, 0.40), 12: _Hand.point(0.55, 0.55)});
      }

      final solo = _Harness(only: 7)..run(script);
      final both = _Harness()..run(script);

      expect(both.engine.primaryTrackId, 7);
      final kinds = both.osEvents.map((e) => e.kind).toList();
      expect(kinds, contains(InteractionKind.pressDown));
      expect(kinds.where((k) => k == InteractionKind.pressMove).length, 11);
      expect(kinds.last, InteractionKind.pressUp);
      expect(_sig(both.osEvents), _sig(solo.osEvents));
      expect(both.model.strokes, isEmpty, reason: 'Clear All 後は線を足していない');
    });
  });

  group('骨格表示', () {
    test('骨格の表示切り替えと片手の消失が、描画中の線を壊さない', () {
      void script(_Harness h) {
        for (var i = 0; i < 6; i++) {
          h.step({
            7: _Hand.draw(0.25 + 0.02 * i, 0.35),
            12: _Hand.draw(0.25 + 0.02 * i, 0.60),
          });
        }
        if (h.only == null) {
          expect(h.model.track(7)!.skeleton, hasLength(21));
          expect(h.model.track(12)!.skeleton, hasLength(21));
        }
        // 手 12 が猶予内だけ消える: 12 の骨格だけが消え、7 の骨格は残る。
        h.step({7: _Hand.draw(0.37, 0.35)});
        if (h.only == null) {
          expect(h.model.track(12)!.skeleton, isNull);
          expect(h.model.track(7)!.skeleton, hasLength(21));
        }
        // 描画中に骨格表示を OFF にする。
        h.showSkeleton = false;
        for (var i = 7; i < 13; i++) {
          h.step({
            7: _Hand.draw(0.25 + 0.02 * i, 0.35),
            12: _Hand.draw(0.25 + 0.02 * i, 0.60),
          });
          expect(h.model.track(7)!.skeleton, isNull);
        }
        // ON に戻す。
        h.showSkeleton = true;
        for (var i = 13; i < 18; i++) {
          h.step({
            7: _Hand.draw(0.25 + 0.02 * i, 0.35),
            12: _Hand.draw(0.25 + 0.02 * i, 0.60),
          });
        }
        expect(h.model.track(7)!.skeleton, hasLength(21));
        h.step({7: _Hand.point(0.65, 0.35), 12: _Hand.point(0.65, 0.60)});
      }

      final solo = _Harness(only: 7)..run(script);
      final both = _Harness()..run(script);

      expect(both.strokesOf(7), hasLength(1));
      expect(both.strokesOf(12), hasLength(1), reason: '骨格 OFF・一時欠落で切れない');
      // 欠落した 1 フレームを除く 17 フレームぶん伸びている（末尾トリム 3 点）。
      expect(both.strokesOf(12).single.points.length, greaterThanOrEqualTo(14));
      expect(both.model.track(12)!.skeleton, hasLength(21));
      expect(
        _points(both.strokesOf(7).single),
        _points(solo.strokesOf(7).single),
      );
    });
  });

  group('OS 入力（主トラック）', () {
    test('主トラックのクリック・ドラッグ中に、もう片方が何をしても OS 入力は変わらない', () {
      void script(_Harness h) {
        h.step({7: _Hand.point(0.30, 0.40), 12: _Hand.point(0.60, 0.55)});
        h.step({7: _Hand.point(0.30, 0.40), 12: _Hand.point(0.60, 0.55)});
        // 主トラック 7 の短いクリック。同時に 12 もピンチする。
        h.step({7: _Hand.pinch(0.30, 0.40), 12: _Hand.pinch(0.60, 0.55)});
        h.step({7: _Hand.point(0.30, 0.40), 12: _Hand.point(0.60, 0.55)});
        // 主トラック 7 のドラッグ中に、12 がピンチ・描画・消しゴム・消失を行う。
        for (var i = 0; i < 30; i++) {
          final x7 = 0.30 + 0.01 * i;
          final Map<int, _Hand> hands;
          if (i < 6) {
            hands = {7: _Hand.pinch(x7, 0.40), 12: _Hand.pinch(0.60, 0.55)};
          } else if (i < 12) {
            hands = {
              7: _Hand.pinch(x7, 0.40),
              12: _Hand.draw(0.30 + 0.02 * i, 0.60),
            };
          } else if (i < 18) {
            hands = {7: _Hand.pinch(x7, 0.40), 12: _Hand.fist(0.50, 0.50)};
          } else {
            // 12 は猶予（300ms）を超えて消える。
            hands = {7: _Hand.pinch(x7, 0.40)};
          }
          h.step(hands);
        }
        h.step({7: _Hand.point(0.60, 0.40)});
      }

      final solo = _Harness(only: 7)..run(script);
      final both = _Harness()..run(script);

      expect(both.engine.primaryTrackId, 7);
      final kinds = both.osEvents.map((e) => e.kind).toList();
      expect(kinds, contains(InteractionKind.click));
      expect(kinds.where((k) => k == InteractionKind.pressDown).length, 2);
      expect(kinds.last, InteractionKind.pressUp);
      expect(
        kinds,
        isNot(
          anyOf(
            contains(InteractionKind.drawDown),
            contains(InteractionKind.eraseDown),
            contains(InteractionKind.release),
          ),
        ),
        reason: '12 の描画・消しゴム・消失は OS へ流れない',
      );
      expect(_sig(both.osEvents), _sig(solo.osEvents));
      // 12 の描画はオーバーレイには残る。
      expect(both.strokesOf(12), isNotEmpty);
    });

    test('主トラックの描画中に、もう片方がドラッグしても OS 入力も線も変わらない', () {
      void script(_Harness h) {
        h.step({7: _Hand.point(0.30, 0.40), 12: _Hand.point(0.60, 0.55)});
        h.step({7: _Hand.point(0.30, 0.40), 12: _Hand.point(0.60, 0.55)});
        for (var i = 0; i < 15; i++) {
          h.step({
            7: _Hand.draw(0.30 + 0.02 * i, 0.40),
            12: _Hand.pinch(0.60 - 0.01 * i, 0.55),
          });
        }
        h.step({7: _Hand.point(0.60, 0.40), 12: _Hand.point(0.45, 0.55)});
      }

      final solo = _Harness(only: 7)..run(script);
      final both = _Harness()..run(script);

      expect(both.engine.primaryTrackId, 7);
      expect(both.model.strokes, hasLength(1), reason: 'ピンチはインクを引かない');
      expect(
        _points(both.strokesOf(7).single),
        _points(solo.strokesOf(7).single),
      );
      expect(
        both.osEvents.map((e) => e.kind),
        isNot(contains(InteractionKind.pressDown)),
        reason: '12 のドラッグは OS へ流れない',
      );
      expect(_sig(both.osEvents), _sig(solo.osEvents));
    });
  });
}

const int _frameMs = 33;

/// カメラ正規化 y を画面正規化 y へ（MockHand.markers は 0.1..0.9 を 0..1 へ）。
double _screenY(double cameraY) => (cameraY - 0.1) / 0.8;

enum _Pose { point, draw, pinch, fist }

/// 1 フレーム分の 1 手の姿勢。[x],[y] は人差し指先端（グーは代表位置）の
/// カメラ正規化座標。
class _Hand {
  final _Pose pose;
  final double x;
  final double y;
  const _Hand._(this.pose, this.x, this.y);
  const _Hand.point(double x, double y) : this._(_Pose.point, x, y);
  const _Hand.draw(double x, double y) : this._(_Pose.draw, x, y);
  const _Hand.pinch(double x, double y) : this._(_Pose.pinch, x, y);
  const _Hand.fist(double x, double y) : this._(_Pose.fist, x, y);

  Map<String, dynamic> toJson(int trackId) {
    final tip = Vec2(x, y);
    final HandFrame f = switch (pose) {
      _Pose.point => MockHand.at(frameId: 0, tip: tip, pinch: false),
      _Pose.draw => MockHand.at(
        frameId: 0,
        tip: tip,
        pinch: false,
        together: true,
      ),
      _Pose.pinch => MockHand.at(frameId: 0, tip: tip, pinch: true),
      _Pose.fist => MockHand.fist(frameId: 0, tip: tip),
    };
    return {
      'trackId': trackId,
      // 実機の送信と同じく、全点をカメラ範囲（0..1）へ収める。
      'landmarks': [
        for (final l in f.landmarks)
          [l.x.clamp(0.0, 1.0), l.y.clamp(0.0, 1.0), l.z],
      ],
    };
  }
}

/// エンジン・オーバーレイ・OS 入力の記録を 1 組にした試験台。
/// home_page と InputServer の配線（主トラックのイベントだけを OS へ、
/// 全トラックをオーバーレイへ、骨格は画面座標へ写して重ねる）を再現する。
class _Harness {
  /// 指定すると、その trackId の手だけをフレームへ載せる（単独実行の比較用）。
  final int? only;

  int clock = 1000;
  int _frameId = 0;
  bool showSkeleton = true;
  late final MultiHandEngine engine;
  late final OverlayModel model;

  /// OS（単一カーソル）へ流した主トラックのイベント。
  final List<InteractionEvent> osEvents = [];

  _Harness({this.only}) {
    engine = MultiHandEngine(clock: () => clock);
    expect(engine.calibrate(MockHand.markers()), isTrue);
    model = OverlayModel(nowMs: () => clock);
  }

  void run(void Function(_Harness) script) => script(this);

  Map<int, List<InteractionEvent>> step(Map<int, _Hand> hands) {
    clock += _frameMs;
    _frameId++;
    final frame =
        InputFrame.parse(
          multiHandFrame(_frameId, [
            for (final e in hands.entries)
              if (only == null || e.key == only) e.value.toJson(e.key),
          ], capturedAtMs: clock),
        )!;
    final out = engine.onInputFrame(frame)!;
    final primary = engine.primaryEventsOf(out);
    if (primary != null) osEvents.addAll(primary);
    model.applyTrackEvents(out);
    model.showSkeletons(
      showSkeleton
          ? {
            for (final t in frame.tracks)
              t.trackId: [
                for (final lm in t.landmarks) engine.mapToSurface(lm.xy),
              ],
          }
          : const {},
    );
    return out;
  }

  List<InkStroke> strokesOf(int trackId) =>
      model.strokes.where((s) => s.trackId == trackId).toList();
}

List<List<double>> _points(InkStroke s) => [
  for (final p in s.points) [p.x, p.y],
];

List<String> _sig(List<InteractionEvent> events) => [
  for (final e in events) '${e.kind.name}@${e.screen.x},${e.screen.y}',
];
