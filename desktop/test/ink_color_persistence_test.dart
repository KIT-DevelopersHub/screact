import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/ink_color_prefs.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';

void main() {
  group('Clear All で描画色を保持する', () {
    test('clear は選んだ描画色を初期化しない', () {
      final model = OverlayModel()..selectColorSlot(2);
      model.apply(
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.1, 0.1)),
      );
      expect(model.strokes, isNotEmpty);

      model.clear();

      expect(model.strokes, isEmpty);
      expect(model.selectedColorSlot, 2);
    });

    test('clear の後の新しい線にも選んだ描画色を使う', () {
      final model = OverlayModel()..selectColorSlot(3);
      model.clear();

      model.apply(
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.1, 0.1)),
      );

      expect(model.strokes, isNotEmpty);
      expect(model.strokes.last.colorSlot, 3);
    });
  });

  group('InkColorPrefs.parse', () {
    test('範囲内のスロットはそのまま使う', () {
      for (var slot = 0; slot < OverlayModel.colorSlotCount; slot++) {
        expect(InkColorPrefs.parse('$slot'), slot);
      }
      expect(InkColorPrefs.parse(' 2\n'), 2);
    });

    test('壊れた値・範囲外・空は初期色に戻す', () {
      for (final raw in <String?>[
        null,
        '',
        'abc',
        '1.5',
        '-1',
        '${OverlayModel.colorSlotCount}',
        '99999999999999999999',
      ]) {
        expect(
          InkColorPrefs.parse(raw),
          OverlayModel.defaultInkColorSlot,
          reason: 'raw=$raw',
        );
      }
    });
  });

  group('InkColorPrefs の保存と読み込み', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ink_color_prefs_test');
      file = File(
        '${dir.path}${Platform.pathSeparator}sub'
        '${Platform.pathSeparator}ink_color',
      );
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('ファイルが無いときは初期色', () {
      expect(InkColorPrefs(file).load(), OverlayModel.defaultInkColorSlot);
      expect(file.existsSync(), isFalse);
    });

    test('保存した色を再起動後（新しいインスタンス）に読み込める', () {
      InkColorPrefs(file)
        ..load()
        ..save(3);

      expect(file.readAsStringSync(), '3');
      expect(InkColorPrefs(file).load(), 3);
    });

    test('壊れたファイル・範囲外の値は初期色として読む', () {
      file.parent.createSync(recursive: true);
      for (final raw in ['garbage', '-2', '${OverlayModel.colorSlotCount}']) {
        file.writeAsStringSync(raw);
        expect(
          InkColorPrefs(file).load(),
          OverlayModel.defaultInkColorSlot,
          reason: 'raw=$raw',
        );
      }
    });

    test('読み込んだ値と同じ色は書き直さない', () {
      final prefs = InkColorPrefs(file)..load();
      prefs.save(OverlayModel.defaultInkColorSlot);
      expect(file.existsSync(), isFalse);

      prefs.save(1);
      expect(file.readAsStringSync(), '1');
    });

    test('保存先が無い環境（null）でも例外にならず初期色', () {
      final prefs = InkColorPrefs(null);
      expect(prefs.load(), OverlayModel.defaultInkColorSlot);
      prefs.save(2);
    });

    test('OverlayModel の変更通知で保存し、新しいモデルへ復元できる', () {
      final prefs = InkColorPrefs(file);
      final model = OverlayModel()..selectColorSlot(prefs.load());
      model.addListener(() => prefs.save(model.selectedColorSlot));

      model.selectColorSlot(2);
      model.clear();

      final restored =
          OverlayModel()..selectColorSlot(InkColorPrefs(file).load());
      expect(restored.selectedColorSlot, 2);
    });
  });
}
