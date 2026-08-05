import 'package:flutter/foundation.dart';

import 'geom.dart';
import 'interaction_engine.dart';

/// 描画中／確定したインクストローク（画面正規化点列）。
class InkStroke {
  final List<Vec2> points;
  InkStroke(this.points);
}

/// アプリ内オーバーレイの表示モデル。エンジンの InteractionEvent を反映する。
/// macOSではこれが最終出力（アプリ内描画）。WindowsではこれとOS注入が並走する。
class OverlayModel extends ChangeNotifier {
  Vec2? cursor;
  bool pressed = false;
  final List<InkStroke> strokes = [];
  InkStroke? _active;

  void apply(InteractionEvent e) {
    switch (e.kind) {
      case InteractionKind.pointerMove:
        cursor = e.screen;
        pressed = false;
        break;
      case InteractionKind.pressDown:
        cursor = e.screen;
        pressed = true;
        _active = InkStroke([e.screen]);
        strokes.add(_active!);
        break;
      case InteractionKind.pressMove:
        cursor = e.screen;
        _active?.points.add(e.screen);
        break;
      case InteractionKind.click:
        cursor = e.screen;
        break;
      case InteractionKind.pressUp:
        pressed = false;
        _active = null;
        break;
      case InteractionKind.scroll:
        cursor = e.screen;
        break;
      case InteractionKind.release:
        cursor = null;
        pressed = false;
        _active = null;
        break;
    }
    notifyListeners();
  }

  void clear() {
    strokes.clear();
    _active = null;
    cursor = null;
    pressed = false;
    notifyListeners();
  }
}
