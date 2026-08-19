import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';

/// 通知合体（coalesceNotifications）のテスト。
/// 既定 OFF では従来どおり各変更で即時 notify、ON では同一マイクロタスク内の
/// 連続変更を1回に合体することを、描画結果を変えずに確認する。
void main() {
  group('OverlayModel notify coalescing', () {
    test('既定OFFでは1フレームの2操作(骨格+カーソル)で2回通知される', () {
      final model = OverlayModel();
      var notifications = 0;
      model.addListener(() => notifications++);

      // 1フレーム相当: showSkeletons と applyTrackEvents を続けて呼ぶ。
      model.showSkeletons({
        1: [for (var i = 0; i < 21; i++) Vec2(i * 0.01, i * 0.01)],
      });
      model.applyTrackEvents({
        1: [const InteractionEvent(InteractionKind.pointerMove, Vec2(0.5, 0.5))],
      });

      expect(notifications, 2, reason: '既定は即時通知なので2回');
    });

    test('ONでは同一マイクロタスクの複数変更が1回に合体する', () async {
      final model = OverlayModel()..coalesceNotifications = true;
      var notifications = 0;
      model.addListener(() => notifications++);

      model.showSkeletons({
        1: [for (var i = 0; i < 21; i++) Vec2(i * 0.01, i * 0.01)],
      });
      model.applyTrackEvents({
        1: [const InteractionEvent(InteractionKind.pointerMove, Vec2(0.5, 0.5))],
      });

      // 合体はマイクロタスクで遅延通知されるため、同期直後はまだ0回。
      expect(notifications, 0, reason: '合体中は同期実行内で未通知');

      await Future<void>.microtask(() {});
      expect(notifications, 1, reason: '2変更が1回に合体');
    });

    test('ONでも描画状態（骨格・カーソル）は合体前後で同一', () async {
      final immediate = OverlayModel();
      final coalesced = OverlayModel()..coalesceNotifications = true;

      final skeleton = [for (var i = 0; i < 21; i++) Vec2(i * 0.01, 0.2)];
      const move =
          InteractionEvent(InteractionKind.pointerMove, Vec2(0.4, 0.6));

      for (final m in [immediate, coalesced]) {
        m.showSkeletons({1: skeleton});
        m.applyTrackEvents({
          1: [move],
        });
      }
      await Future<void>.microtask(() {});

      // 合体は「いつ通知するか」だけを変え、保持状態は変えない。
      final a = immediate.track(1)!;
      final b = coalesced.track(1)!;
      expect(b.cursor, a.cursor);
      expect(b.skeleton, a.skeleton);
      expect(b.colorSlot, a.colorSlot);
    });

    test('合体の複数フレームは各マイクロタスクで1回ずつ通知', () async {
      final model = OverlayModel()..coalesceNotifications = true;
      var notifications = 0;
      model.addListener(() => notifications++);

      // フレーム1
      model.applyTrackEvents({
        1: [const InteractionEvent(InteractionKind.pointerMove, Vec2(0.1, 0.1))],
      });
      model.showSkeletons({
        1: [for (var i = 0; i < 21; i++) Vec2(0.1, 0.1)],
      });
      await Future<void>.microtask(() {});
      expect(notifications, 1);

      // フレーム2
      model.applyTrackEvents({
        1: [const InteractionEvent(InteractionKind.pointerMove, Vec2(0.2, 0.2))],
      });
      model.showSkeletons({
        1: [for (var i = 0; i < 21; i++) Vec2(0.2, 0.2)],
      });
      await Future<void>.microtask(() {});
      expect(notifications, 2);
    });
  });
}
