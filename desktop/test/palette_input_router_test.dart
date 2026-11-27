import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/platform/desktop_bridge.dart';
import 'package:thehack_overlay/ui/edge_palette.dart';
import 'package:thehack_overlay/ui/edge_palette_layout.dart';
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
