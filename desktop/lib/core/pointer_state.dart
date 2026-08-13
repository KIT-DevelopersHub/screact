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

  /// これ未満の移動は点を増やさない（重複点の抑制・描画の軽量化）。
  static const double _minPointDist = 0.002;

  void apply(InteractionEvent e) {
    switch (e.kind) {
      case InteractionKind.pointerMove:
        cursor = e.screen;
        pressed = false;
        _active = null;
        break;
      // インク描画（人差し指＋中指のくっつき・中間点）。
      case InteractionKind.drawDown:
        cursor = e.screen;
        pressed = true;
        _active = InkStroke([e.screen]);
        strokes.add(_active!);
        break;
      case InteractionKind.drawMove:
        cursor = e.screen;
        final a = _active;
        if (a != null &&
            (a.points.isEmpty ||
                a.points.last.distanceTo(e.screen) >= _minPointDist)) {
          a.points.add(e.screen);
        }
        break;
      case InteractionKind.drawUp:
        pressed = false;
        _active = null;
        break;
      // OSクリック/ドラッグ（ピンチ）はインクを引かない。カーソルの押下表示のみ。
      case InteractionKind.pressDown:
      case InteractionKind.pressMove:
        cursor = e.screen;
        pressed = true;
        break;
      case InteractionKind.click:
        cursor = e.screen;
        break;
      case InteractionKind.pressUp:
        pressed = false;
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
