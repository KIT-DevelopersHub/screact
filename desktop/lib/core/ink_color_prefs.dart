import 'dart:io';

import 'pointer_state.dart';

/// 選んだ描画色（[OverlayModel.selectedColorSlot]）の永続化。
///
/// 骨格表示の設定（show_skeleton）と同じ流儀のプレーンファイルに、
/// スロット番号を 10 進の文字列で保存する。Clear All・再位置合わせ・
/// 再接続では色を変えず、アプリ再起動後もこのファイルから復元する。
class InkColorPrefs {
  InkColorPrefs(this.file);

  /// 保存先。設定ディレクトリが分からない環境では null（保存しない）。
  final File? file;

  int? _lastSaved;

  /// 保存内容を描画色スロットへ変換する。空・数値でない・範囲外なら初期色。
  static int parse(String? raw) {
    final slot = int.tryParse(raw?.trim() ?? '');
    if (slot == null || slot < 0 || slot >= OverlayModel.colorSlotCount) {
      return OverlayModel.defaultInkColorSlot;
    }
    return slot;
  }

  /// 保存済みの描画色を読む。ファイルが無い・読めない・壊れているときは初期色。
  int load() {
    var slot = OverlayModel.defaultInkColorSlot;
    try {
      final f = file;
      if (f != null && f.existsSync()) slot = parse(f.readAsStringSync());
    } catch (_) {
      // 読めなければ初期色のまま。
    }
    _lastSaved = slot;
    return slot;
  }

  /// 描画色を保存する。前回保存（または読み込み）した値と同じなら書かない。
  void save(int slot) {
    if (slot == _lastSaved) return;
    // 失敗しても同じ値で毎回書き直さないよう、先に記録する。
    _lastSaved = slot;
    try {
      final f = file;
      if (f != null) {
        f.parent.createSync(recursive: true);
        f.writeAsStringSync('$slot', flush: true);
      }
    } catch (_) {
      // 永続化に失敗しても致命ではない（次回起動は初期色）。
    }
  }
}
