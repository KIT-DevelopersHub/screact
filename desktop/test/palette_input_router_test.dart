import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/platform/desktop_bridge.dart';
import 'package:thehack_overlay/ui/edge_palette.dart';
import 'package:thehack_overlay/ui/edge_palette_layout.dart';
import 'package:thehack_overlay/ui/overlay_canvas.dart';
import 'package:thehack_overlay/ui/palette_input_router.dart';

/// OS 入力に届いたイベントを記録するだけのブリッジ。
class _RecordingBridge implements DesktopBridge {
  final applied = <InteractionEvent>[];
  @override
  String get name => 'recording';
  @override
  bool get isNativeBackend => true;
  @override
  Future<void> applyEvent(InteractionEvent e) async => applied.add(e);
  @override
  Future<void> setOverlayVisible(bool visible) async {}
  @override
  Future<bool> accessibilityTrusted() async => true;
  @override
  Future<void> requestAccessibility() async {}
}

/// HomePage と同じ配線（主トラック → OS、全トラック → オーバーレイ）を再現する。
class _Harness {
  final model = OverlayModel(nowMs: () => 0);
  final bridge = _RecordingBridge();
  late final router = PaletteInputRouter(onSelectSlot: model.selectColorSlot);
  EdgePaletteLayout? layout;

  _Harness(this.layout);

  /// InputServer._dispatch と同じ順で、主トラック（[primary]）を OS へ、全トラックを
  /// オーバーレイへ渡す。
  void dispatch(Map<int, List<InteractionEvent>> byTrack, {int primary = 1}) {
    final primaryEvents = byTrack[primary];
    if (primaryEvents != null) {
      for (final e in router.routeOsEvents(primaryEvents, layout)) {
        bridge.applyEvent(e);
      }
    }
    model.applyTrackEvents(router.routeTrackEvents(byTrack, layout));
  }

  void one(List<InteractionEvent> events) => dispatch({1: events});

  List<InteractionKind> get osKinds => [for (final e in bridge.applied) e.kind];
}

InteractionEvent ev(
  InteractionKind k,
  Vec2 p, {
  Vec2 delta = const Vec2(0, 0),
}) => InteractionEvent(k, p, delta: delta);

/// OS を実際に操作するイベントか（描画・消しゴム・カーソル移動は OS では注入されない）。
bool _isOsOperation(InteractionKind k) => const {
  InteractionKind.pressDown,
  InteractionKind.pressMove,
  InteractionKind.pressUp,
  InteractionKind.click,
  InteractionKind.scroll,
}.contains(k);

void main() {
  const screen = Size(1920, 1080);
  final layout = EdgePaletteLayout.compute(
    screenSize: screen,
    devicePixelRatio: 1.25,
  );

  Vec2 norm(Offset o) => Vec2(o.dx / screen.width, o.dy / screen.height);
  Vec2 swatch(int slot) => norm(layout.swatches[slot].rect.center);
  // パレットの背景の内側だが、どのスウォッチにも入らない点（上端の余白）。
  final panelOnly = norm(
    Offset(layout.panelRect.center.dx, layout.panelHitRect.top + 1),
  );
  const outside = Vec2(0.3, 0.5);
  const outside2 = Vec2(0.35, 0.55);

  test('前提: テスト用の点のヒット判定', () {
    expect(layout.hitTestNormalized(swatch(2)), const EdgePaletteHit.swatch(2));
    expect(layout.hitTestNormalized(panelOnly), EdgePaletteHit.panel);
    expect(layout.hitTestNormalized(outside), EdgePaletteHit.none);
  });

  group('スウォッチ上のクリック', () {
    test('pressDown→click→pressUp で色が変わり、OS には何も届かない', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.pointerMove, swatch(2))]);
      h.one([ev(InteractionKind.pressDown, swatch(2))]);
      h.one([
        ev(InteractionKind.click, swatch(2)),
        ev(InteractionKind.pressUp, swatch(2)),
      ]);
      expect(h.model.selectedColorSlot, 2);
      // ポインタ移動だけは流れる（クリック系は流れない）。
      expect(h.osKinds, [InteractionKind.pointerMove]);
    });

    test('click のない長押し（pressDown→pressMove→pressUp）でも選ぶ', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.pressDown, swatch(3))]);
      h.one([ev(InteractionKind.pressMove, swatch(3))]);
      h.one([ev(InteractionKind.pressUp, swatch(3))]);
      expect(h.model.selectedColorSlot, 3);
      expect(h.osKinds, isEmpty);
    });

    test('押下を伴わない単独の click でも選び、OS へ流さない', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.click, swatch(1))]);
      expect(h.model.selectedColorSlot, 1);
      expect(h.osKinds, isEmpty);
    });

    test('スウォッチの間（パレットの背景）では選ばないが、OS へも流さない', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.pressDown, panelOnly)]);
      h.one([
        ev(InteractionKind.click, panelOnly),
        ev(InteractionKind.pressUp, panelOnly),
      ]);
      expect(h.model.selectedColorSlot, OverlayModel.defaultInkColorSlot);
      expect(h.osKinds, isEmpty);
    });

    test('パレット内で押してスウォッチを移り、別の色の上で離すとその色を選ぶ', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.pressDown, swatch(1))]);
      h.one([ev(InteractionKind.pressMove, swatch(3))]);
      h.one([ev(InteractionKind.pressUp, swatch(3))]);
      expect(h.model.selectedColorSlot, 3);
      expect(h.osKinds, isEmpty);
    });

    test('追跡喪失（pressUp→release）や画面外（pressUp→pointerExit）では選ばない', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.pressDown, swatch(2))]);
      h.one([
        ev(InteractionKind.pressUp, swatch(2)),
        ev(InteractionKind.release, swatch(2)),
      ]);
      expect(h.model.selectedColorSlot, OverlayModel.defaultInkColorSlot);

      h.one([ev(InteractionKind.pressDown, swatch(3))]);
      h.one([
        ev(InteractionKind.pressUp, swatch(3)),
        ev(InteractionKind.pointerExit, swatch(3)),
      ]);
      expect(h.model.selectedColorSlot, OverlayModel.defaultInkColorSlot);
      // release・pointerExit は流れる（OS のカーソル状態の解除のため）。
      expect(h.osKinds, [InteractionKind.release, InteractionKind.pointerExit]);
    });
  });

  group('パレットの外', () {
    test('クリック・ドラッグ・スクロールは今と同じ列のまま OS へ流れる', () {
      final h = _Harness(layout);
      final batches = [
        [ev(InteractionKind.pointerMove, outside)],
        [ev(InteractionKind.pressDown, outside)],
        [ev(InteractionKind.pressMove, outside2)],
        [ev(InteractionKind.pressUp, outside2)],
        [
          ev(InteractionKind.click, outside),
          ev(InteractionKind.pressUp, outside),
        ],
        [ev(InteractionKind.scroll, outside, delta: const Vec2(0, 0.03))],
        [ev(InteractionKind.release, outside)],
      ];
      final expected = <InteractionEvent>[];
      for (final b in batches) {
        // 取り除くものが無いときは同じ列（同一インスタンス）を返す。
        expect(identical(h.router.routeOsEvents(b, layout), b), isTrue);
        expected.addAll(b);
      }
      final h2 = _Harness(layout);
      for (final b in batches) {
        h2.one(b);
      }
      expect(h2.bridge.applied, expected);
      expect(h2.model.selectedColorSlot, OverlayModel.defaultInkColorSlot);
    });
  });

  group('領域を跨ぐ操作', () {
    test('パレット内で始めた押下は、外へ出ても離すまで OS へ流さず、色も選ばない', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.pressDown, swatch(2))]);
      h.one([ev(InteractionKind.pressMove, outside)]);
      h.one([ev(InteractionKind.pressUp, outside)]);
      expect(h.osKinds, isEmpty);
      expect(h.model.selectedColorSlot, OverlayModel.defaultInkColorSlot);
      // 離した後は、外の操作が従来どおり流れる。
      h.one([ev(InteractionKind.pointerMove, outside)]);
      h.one([ev(InteractionKind.pressDown, outside)]);
      expect(h.osKinds, [
        InteractionKind.pointerMove,
        InteractionKind.pressDown,
      ]);
    });

    test('パレットの外で始めたドラッグは、パレットに入って離しても OS へ流し続ける', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.pressDown, outside)]);
      h.one([ev(InteractionKind.pressMove, swatch(2))]);
      h.one([
        ev(InteractionKind.click, swatch(2)),
        ev(InteractionKind.pressUp, swatch(2)),
      ]);
      expect(h.osKinds, [
        InteractionKind.pressDown,
        InteractionKind.pressMove,
        InteractionKind.click,
        InteractionKind.pressUp,
      ]);
      expect(h.model.selectedColorSlot, OverlayModel.defaultInkColorSlot);
    });

    test('主トラックの途中選出で pressDown が補われた押下も、パレット内なら流さない', () {
      // OS 列: 補われた pressDown + pressMove。オーバーレイ列: pressMove のみ。
      final h = _Harness(layout);
      final move = ev(InteractionKind.pressMove, swatch(1));
      expect(
        h.router.routeOsEvents([
          ev(InteractionKind.pressDown, swatch(1)),
          move,
        ], layout),
        isEmpty,
      );
      h.model.applyTrackEvents(
        h.router.routeTrackEvents({
          1: [move],
        }, layout),
      );
      h.one([ev(InteractionKind.pressUp, swatch(1))]);
      expect(h.osKinds, isEmpty);
      expect(h.model.selectedColorSlot, 1);
    });
  });

  group('描画・消しゴム・スクロール', () {
    test('パレット内では描画を始めず、離すまで線を引かない', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.drawDown, swatch(2))]);
      h.one([ev(InteractionKind.drawMove, outside)]);
      h.one([ev(InteractionKind.drawMove, outside2)]);
      h.one([ev(InteractionKind.drawUp, outside2)]);
      expect(h.model.strokes, isEmpty);
      // カーソルは追従する。
      expect(h.model.track(1)?.cursor?.x, outside2.x);
      // 次の描画はパレットの外なら始まる。
      h.one([ev(InteractionKind.drawDown, outside)]);
      h.one([ev(InteractionKind.drawMove, outside2)]);
      h.one([ev(InteractionKind.drawUp, outside2)]);
      expect(h.model.strokes, hasLength(1));
    });

    test('パレットの外で始めた描画は、パレットに入っても続ける', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.drawDown, outside)]);
      h.one([ev(InteractionKind.drawMove, swatch(2))]);
      expect(h.model.strokes, hasLength(1));
      expect(h.model.strokes.single.points, hasLength(2));
    });

    test('パレット内では消しゴムを始めない（近くの線を消さない）', () {
      final h = _Harness(layout);
      final near = swatch(0);
      h.model.applyTrackEvents({
        2: [
          ev(InteractionKind.drawDown, near),
          ev(InteractionKind.drawMove, Vec2(near.x - 0.05, near.y)),
          ev(InteractionKind.drawMove, Vec2(near.x - 0.1, near.y)),
        ],
      });
      h.model.applyTrackEvents({
        2: [ev(InteractionKind.drawUp, Vec2(near.x - 0.1, near.y))],
      });
      final before = h.model.strokes.single.points.length;
      h.one([ev(InteractionKind.eraseDown, near)]);
      h.one([ev(InteractionKind.eraseMove, near)]);
      expect(h.model.strokes.single.points.length, before);
      expect(h.model.track(1)?.erasing, isFalse);
      h.one([ev(InteractionKind.eraseUp, near)]);
    });

    test('scroll はパレット内なら OS へ流さず、外なら流す', () {
      final h = _Harness(layout);
      h.one([
        ev(InteractionKind.scroll, swatch(1), delta: const Vec2(0, 0.03)),
      ]);
      expect(h.osKinds, isEmpty);
      h.one([ev(InteractionKind.scroll, outside, delta: const Vec2(0, 0.03))]);
      expect(h.osKinds, [InteractionKind.scroll]);
      expect(h.model.selectedColorSlot, OverlayModel.defaultInkColorSlot);
    });
  });

  group('パレット表示 OFF（レイアウトなし）', () {
    test('判定せず、スウォッチの位置でも従来どおり OS へ流し、色も変えない', () {
      final h = _Harness(null);
      h.one([ev(InteractionKind.pressDown, swatch(2))]);
      h.one([
        ev(InteractionKind.click, swatch(2)),
        ev(InteractionKind.pressUp, swatch(2)),
      ]);
      h.one([ev(InteractionKind.scroll, swatch(2))]);
      h.one([ev(InteractionKind.drawDown, swatch(2))]);
      expect(h.osKinds, [
        InteractionKind.pressDown,
        InteractionKind.click,
        InteractionKind.pressUp,
        InteractionKind.scroll,
        InteractionKind.drawDown,
      ]);
      expect(h.model.selectedColorSlot, OverlayModel.defaultInkColorSlot);
      expect(h.model.strokes, hasLength(1));
    });

    test('消費中の押下は、途中で OFF になっても離すまで流さない（色は選ばない）', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.pressDown, swatch(2))]);
      h.layout = null;
      h.one([ev(InteractionKind.pressMove, swatch(2))]);
      h.one([ev(InteractionKind.pressUp, swatch(2))]);
      expect(h.osKinds, isEmpty);
      expect(h.model.selectedColorSlot, OverlayModel.defaultInkColorSlot);
      h.one([ev(InteractionKind.pressDown, swatch(2))]);
      expect(h.osKinds, [InteractionKind.pressDown]);
    });
  });

  group('2 手', () {
    test('OS に流れない 2 本目の手でもスウォッチで色を選べ、主トラックの OS 入力は変わらない', () {
      final h = _Harness(layout);
      h.dispatch({
        1: [ev(InteractionKind.pressDown, outside)],
        2: [ev(InteractionKind.pressDown, swatch(3))],
      });
      h.dispatch({
        1: [ev(InteractionKind.pressMove, outside2)],
        2: [
          ev(InteractionKind.click, swatch(3)),
          ev(InteractionKind.pressUp, swatch(3)),
        ],
      });
      h.dispatch({
        1: [ev(InteractionKind.pressUp, outside2)],
        2: [ev(InteractionKind.pointerMove, swatch(3))],
      });
      expect(h.model.selectedColorSlot, 3);
      expect(h.osKinds, [
        InteractionKind.pressDown,
        InteractionKind.pressMove,
        InteractionKind.pressUp,
      ]);
    });

    test('主トラックがパレットを押している間、もう一方の手の描画は妨げない', () {
      final h = _Harness(layout);
      h.dispatch({
        1: [ev(InteractionKind.pressDown, swatch(1))],
        2: [ev(InteractionKind.drawDown, outside)],
      });
      h.dispatch({
        1: [ev(InteractionKind.pressUp, swatch(1))],
        2: [
          ev(InteractionKind.drawMove, outside2),
          ev(InteractionKind.drawUp, outside2),
        ],
      });
      expect(h.model.selectedColorSlot, 1);
      expect(h.osKinds, isEmpty);
      expect(h.model.strokes, hasLength(1));
      expect(
        h.model.strokes.single.colorSlot,
        OverlayModel.defaultInkColorSlot,
      );
    });

    test('2 本の手が別々の色を押したら、後に離した手の色になる', () {
      final h = _Harness(layout);
      h.dispatch({
        1: [ev(InteractionKind.pressDown, swatch(1))],
        2: [ev(InteractionKind.pressDown, swatch(2))],
      });
      h.dispatch({
        1: [ev(InteractionKind.pressUp, swatch(1))],
      });
      h.dispatch({
        2: [ev(InteractionKind.pressUp, swatch(2))],
      });
      expect(h.model.selectedColorSlot, 2);
      expect(h.osKinds, isEmpty);
    });
  });

  group('パレット付近の描画・消しゴムと色選択の競合（#35）', () {
    test('外から描いた線がスウォッチの上で終わっても、色は変わらず線も切れない', () {
      final h = _Harness(layout);
      h.one([ev(InteractionKind.drawDown, outside)]);
      h.one([ev(InteractionKind.drawMove, swatch(3))]);
      h.one([ev(InteractionKind.drawMove, swatch(2))]);
      h.one([ev(InteractionKind.drawUp, swatch(2))]);
      expect(h.model.selectedColorSlot, OverlayModel.defaultInkColorSlot);
      expect(h.model.strokes, hasLength(1));
      expect(h.osKinds.where(_isOsOperation), isEmpty);
    });

    test('外から始めた消しゴムがパレットに入っても、色・選択表示は変わらず、パレット下のインクは消える', () {
      final h = _Harness(layout);
      // パレットの外からスウォッチの上まで、別の手で線を引いておく。
      final start = Vec2(swatch(1).x - 0.1, swatch(1).y);
      h.dispatch({
        2: [
          ev(InteractionKind.drawDown, start),
          ev(InteractionKind.drawMove, Vec2(start.x + 0.05, start.y)),
          ev(InteractionKind.drawMove, swatch(1)),
        ],
      });
      h.dispatch({
        2: [ev(InteractionKind.pointerMove, outside)],
      });
      expect(h.model.strokes, hasLength(1));
      final colorBefore = h.model.selectedColorSlot;

      // 消しゴムはパレットの外で始め、スウォッチの上へ移ってから離す。
      h.one([ev(InteractionKind.eraseDown, outside)]);
      h.one([ev(InteractionKind.eraseMove, swatch(1))]);
      expect(h.model.track(1)?.erasing, isTrue);
      // 消しゴム中の手はスウォッチの選択候補（後光）にならない。
      expect(EdgePaletteOverlay.hoveredSlots(h.model, layout), isEmpty);
      h.one([ev(InteractionKind.eraseUp, swatch(1))]);

      expect(h.model.selectedColorSlot, colorBefore);
      // パレットの上にあった点だけが消え、外側の点は残る。
      final remaining = [for (final s in h.model.strokes) ...s.points];
      expect(remaining, isNotEmpty);
      for (final p in remaining) {
        expect(p.distanceTo(swatch(1)), greaterThan(OverlayModel.eraserRadius));
      }
      // OS を操作するイベント（押下・クリック・スクロール）は届かない。
      expect(h.osKinds.where(_isOsOperation), isEmpty);
    });

    test('描画中に別の手が色を選んでも、描画中の線の色は変えず、次の線から新しい色にする', () {
      final h = _Harness(layout);
      h.dispatch({
        1: [ev(InteractionKind.drawDown, outside)],
      });
      h.dispatch({
        1: [ev(InteractionKind.drawMove, const Vec2(0.31, 0.5))],
        2: [ev(InteractionKind.pressDown, swatch(2))],
      });
      h.dispatch({
        1: [ev(InteractionKind.drawMove, const Vec2(0.32, 0.5))],
        2: [ev(InteractionKind.pressUp, swatch(2))],
      });
      expect(h.model.selectedColorSlot, 2);
      // 色が変わった後も、同じ線に点が足され続け、色は描き始めのまま。
      h.dispatch({
        1: [ev(InteractionKind.drawMove, const Vec2(0.33, 0.5))],
      });
      h.dispatch({
        1: [ev(InteractionKind.drawMove, const Vec2(0.34, 0.5))],
      });
      expect(h.model.strokes, hasLength(1));
      expect(h.model.strokes.single.points, hasLength(5));
      expect(
        h.model.strokes.single.colorSlot,
        OverlayModel.defaultInkColorSlot,
      );
      h.dispatch({
        1: [ev(InteractionKind.drawUp, const Vec2(0.34, 0.5))],
      });
      expect(
        h.model.strokes.single.colorSlot,
        OverlayModel.defaultInkColorSlot,
      );

      // 次の線から新しい色。
      h.dispatch({
        1: [ev(InteractionKind.drawDown, outside2)],
      });
      h.dispatch({
        1: [
          ev(InteractionKind.drawMove, const Vec2(0.4, 0.6)),
          ev(InteractionKind.drawUp, const Vec2(0.4, 0.6)),
        ],
      });
      expect(h.model.strokes, hasLength(2));
      expect(h.model.strokes.last.colorSlot, 2);
    });

    test('2 本の手が同じフレームで別々の色を確定したら、そのフレームで後に処理した手の色になる', () {
      for (final order in [
        [1, 2],
        [2, 1],
      ]) {
        final h = _Harness(layout);
        final slotOf = {1: 1, 2: 3};
        h.dispatch({
          for (final id in order)
            id: [ev(InteractionKind.pressDown, swatch(slotOf[id]!))],
        });
        h.dispatch({
          for (final id in order)
            id: [ev(InteractionKind.pressUp, swatch(slotOf[id]!))],
        });
        expect(h.model.selectedColorSlot, slotOf[order.last], reason: '$order');
        // 共有の 1 色。どちらの手の次の線も同じ色になる。
        h.dispatch({
          1: [ev(InteractionKind.drawDown, outside)],
          2: [ev(InteractionKind.drawDown, outside2)],
        });
        h.dispatch({
          1: [
            ev(InteractionKind.drawMove, const Vec2(0.3, 0.6)),
            ev(InteractionKind.drawUp, const Vec2(0.3, 0.6)),
          ],
          2: [
            ev(InteractionKind.drawMove, const Vec2(0.35, 0.65)),
            ev(InteractionKind.drawUp, const Vec2(0.35, 0.65)),
          ],
        });
        expect(
          {for (final s in h.model.strokes) s.colorSlot},
          {slotOf[order.last]},
          reason: '$order',
        );
        expect(h.osKinds.where(_isOsOperation), isEmpty, reason: '$order');
      }
    });

    test('主トラックでない手がパレットを押しても色を選べ、その押下は OS へ流れない', () {
      final h = _Harness(layout);
      // 主トラック（1）はパレットの外でドラッグ中。2 本目の手がパレットで色を選ぶ。
      h.dispatch({
        1: [ev(InteractionKind.pressDown, outside)],
        2: [ev(InteractionKind.pressDown, swatch(1))],
      });
      h.dispatch({
        1: [ev(InteractionKind.pressMove, outside2)],
        2: [ev(InteractionKind.pressUp, swatch(1))],
      });
      h.dispatch({
        1: [ev(InteractionKind.pressUp, outside2)],
      });
      expect(h.model.selectedColorSlot, 1);
      // OS には主トラックのドラッグだけが届く（2 本目の手の押下は混ざらない）。
      expect(h.osKinds, [
        InteractionKind.pressDown,
        InteractionKind.pressMove,
        InteractionKind.pressUp,
      ]);
      for (final e in h.bridge.applied) {
        expect(layout.hitTestNormalized(e.screen), EdgePaletteHit.none);
      }
    });
  });

  testWidgets('パレットはインクの下に描く（パレットがインクの上に重ならない）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OverlayWithEdgePalette(
          model: OverlayModel(),
          showEdgePalette: true,
        ),
      ),
    );
    final stack = tester.widget<Stack>(
      find
          .descendant(
            of: find.byType(OverlayWithEdgePalette),
            matching: find.byType(Stack),
          )
          .first,
    );
    final palette = stack.children.indexWhere((w) => w is EdgePaletteOverlay);
    final ink = stack.children.indexWhere((w) => w is OverlayCanvas);
    expect(palette, isNonNegative);
    expect(ink, greaterThan(palette));
  });

  testWidgets('オーバーレイは描画に使ったレイアウトを入力判定用に知らせる', (tester) async {
    tester.view.physicalSize = const Size(2400, 1350);
    tester.view.devicePixelRatio = 1.25;
    addTearDown(tester.view.reset);
    EdgePaletteLayout? reported;
    await tester.pumpWidget(
      MaterialApp(
        home: OverlayWithEdgePalette(
          model: OverlayModel(),
          showEdgePalette: true,
          onPaletteLayout: (l) => reported = l,
        ),
      ),
    );
    expect(reported, isNotNull);
    expect(reported!.screenSize, const Size(1920, 1080));
    expect(reported!.devicePixelRatio, 1.25);
    expect(reported!.panelRect, layout.panelRect);
  });
}
