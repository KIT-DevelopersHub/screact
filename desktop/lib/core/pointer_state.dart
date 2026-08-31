import 'dart:ui' show Color, Rect;

import 'package:flutter/foundation.dart';

import 'geom.dart';
import 'interaction_engine.dart';

/// 描画中／確定したインクストローク（画面正規化点列）。描画色はペン色サイクル
/// （右下の大きな色丸）で選ばれた実際の色を保持する。trackId は同時描画の識別用。
class InkStroke {
  final List<Vec2> points;
  final int trackId;
  final Color color;
  InkStroke(
    this.points, {
    this.trackId = OverlayModel.legacyTrackId,
    this.color = OverlayModel.defaultPenColor,
  });
}

/// 1トラック分の表示状態（カーソル・押下・骨格）。
class TrackVisual {
  final int colorSlot;
  Vec2? cursor;
  bool pressed = false;
  bool erasing = false; // グー（消しゴム）中。カーソルを消しゴム範囲の輪で描く。

  /// 右下の色丸の上でピンチ/くっつきが始まった間 true。この間は描画/クリックを
  /// 開始せず「色送り」だけ行う（ピンチ開始→開放で1回色が回る）。
  bool cyclingColor = false;

  TrackVisual({required this.colorSlot});

  /// 画面正規化に写した21点骨格（null は非表示）。
  List<Vec2>? skeleton;
}

/// アプリ内オーバーレイの表示モデル。エンジンの InteractionEvent を反映する。
/// 最大2トラックのカーソル・骨格・インクを別々に保持する。
/// macOSではこれが最終出力（アプリ内描画）。WindowsではこれとOS注入が並走する。
class OverlayModel extends ChangeNotifier {
  /// 単一手（後方互換）の既定トラックID。旧 [apply] はこのトラックへ流す。
  static const int legacyTrackId = 0;

  /// カーソル/骨格のトラック別自動色に使うスロット数。
  static const int colorSlotCount = 4;

  /// ペンの巡回色。右下の大きな色丸を1回押すたびに次の色へ進む。
  /// 初期表示は青（[_penColorIndex] の初期値がこの並びの青を指す）。
  /// クリックすると 赤 → 黄 → 緑 → 青 → 赤 … と循環する。
  static const List<Color> penCycle = [
    Color(0xFFE53935), // 赤
    Color(0xFFFDD835), // 黄
    Color(0xFF43A047), // 緑
    Color(0xFF1E88E5), // 青
  ];

  /// ストロークの既定色（＝初期のペン色・青）。
  static const Color defaultPenColor = Color(0xFF1E88E5);

  final Map<int, TrackVisual> _tracks = {};
  final List<InkStroke> strokes = [];
  final Map<int, InkStroke> _active = {};

  /// これ未満の移動は点を増やさない（重複点の抑制・描画の軽量化）。
  static const double _minPointDist = 0.002;

  /// 消しゴム（グー）の消去半径（画面正規化・0..1）。この距離以内のインク点を消す。
  static const double eraserRadius = 0.045;

  /// 現在のペン色を指す [penCycle] のインデックス。初期=青（末尾）にして、
  /// 最初のクリックで赤（先頭）へ進むようにする。
  int _penColorIndex = 3;

  /// 右下の大きな色丸に表示中＝これから描く色。
  Color get penColor => penCycle[_penColorIndex];

  /// 色丸を1回押すたびに次の巡回色へ進める（赤→黄→緑→青→赤 …）。
  void cyclePenColor() {
    _penColorIndex = (_penColorIndex + 1) % penCycle.length;
    notifyListeners();
  }

  /// 右下の大きな色丸の当たり判定（画面正規化・0..1・左上原点）。Flutter 側が
  /// レイアウト後に実測して設定する。ピンチ（手）クリックのヒットテストに使う
  /// （マウスクリックはネイティブ側が同じ矩形で ignoresMouseEvents を切替える）。
  Rect? colorButtonRect;

  /// 色送りのチャタリング防止デバウンス（連続ピンチで色が飛ぶのを防ぐ）。
  DateTime? _lastCycleAt;
  static const Duration _cycleDebounce = Duration(milliseconds: 350);

  bool _hitColorButton(Vec2 p) {
    final r = colorButtonRect;
    if (r == null) return false;
    return p.x >= r.left && p.x <= r.right && p.y >= r.top && p.y <= r.bottom;
  }

  void _tryCyclePenColor() {
    final now = DateTime.now();
    final last = _lastCycleAt;
    if (last != null && now.difference(last) < _cycleDebounce) return;
    _lastCycleAt = now;
    cyclePenColor();
  }

  Iterable<int> get trackIds => _tracks.keys;
  TrackVisual? track(int id) => _tracks[id];

  /// 最初のトラックのカーソル（後方互換の単一カーソル参照）。
  Vec2? get cursor =>
      _tracks[legacyTrackId]?.cursor ??
      (_tracks.isEmpty ? null : _tracks.values.first.cursor);
  bool get pressed =>
      _tracks[legacyTrackId]?.pressed ??
      (_tracks.isEmpty ? false : _tracks.values.first.pressed);

  TrackVisual _visual(int id) => _tracks.putIfAbsent(id, () {
    final used = _tracks.values.map((track) => track.colorSlot).toSet();
    var slot = id % colorSlotCount;
    while (used.contains(slot)) {
      slot = (slot + 1) % colorSlotCount;
    }
    return TrackVisual(colorSlot: slot);
  });

  /// 単一手・既存フロー向けの後方互換 API（既定トラックへ適用）。
  void apply(InteractionEvent e) => applyTrack(legacyTrackId, e);

  /// 複数トラックの一括反映。
  void applyTrackEvents(Map<int, List<InteractionEvent>> byTrack) {
    if (byTrack.isEmpty) return;
    byTrack.forEach((id, events) {
      for (final e in events) {
        _applyTrack(id, e);
      }
    });
    notifyListeners();
  }

  void applyTrack(int trackId, InteractionEvent e) {
    _applyTrack(trackId, e);
    notifyListeners();
  }

  void _applyTrack(int trackId, InteractionEvent e) {
    final v = _visual(trackId);

    // 右下の大きな色丸の上でのピンチ/くっつきは「色送り」だけ行い、描画/クリックは
    // 開始しない（色丸の外なら従来どおり通す）。ヒットテスト優先で色送りを最優先。
    switch (e.kind) {
      case InteractionKind.drawDown:
      case InteractionKind.pressDown:
      case InteractionKind.click:
        if (_hitColorButton(e.screen)) {
          v.cursor = e.screen;
          v.pressed = false;
          v.erasing = false;
          v.cyclingColor = true;
          _active.remove(trackId);
          _tryCyclePenColor();
          return;
        }
        break;
      case InteractionKind.drawMove:
      case InteractionKind.pressMove:
        if (v.cyclingColor) {
          v.cursor = e.screen; // 送り中はカーソル追従のみ（描画しない）
          return;
        }
        break;
      case InteractionKind.drawUp:
      case InteractionKind.pressUp:
        if (v.cyclingColor) {
          v.cyclingColor = false;
          v.pressed = false;
          return;
        }
        break;
      case InteractionKind.pointerMove:
      case InteractionKind.pointerExit:
      case InteractionKind.release:
        v.cyclingColor = false;
        break;
      default:
        break;
    }

    switch (e.kind) {
      case InteractionKind.pointerMove:
        v.cursor = e.screen;
        v.pressed = false;
        v.erasing = false;
        _active.remove(trackId);
        break;
      // インク描画（人差し指＋中指のくっつき・中間点）。
      case InteractionKind.drawDown:
        v.cursor = e.screen;
        v.pressed = true;
        v.erasing = false;
        // 右下の色丸に表示中のペン色で描く（大きな丸の色＝描画色）。
        final stroke = InkStroke(
          [e.screen],
          trackId: trackId,
          color: penColor,
        );
        _active[trackId] = stroke;
        strokes.add(stroke);
        break;
      case InteractionKind.drawMove:
        v.cursor = e.screen;
        final a = _active[trackId];
        if (a != null &&
            (a.points.isEmpty ||
                a.points.last.distanceTo(e.screen) >= _minPointDist)) {
          a.points.add(e.screen);
        }
        break;
      case InteractionKind.drawUp:
        v.pressed = false;
        _active.remove(trackId);
        break;
      // 消しゴム（グー）。カーソル位置近傍のインクを消す。
      case InteractionKind.eraseDown:
      case InteractionKind.eraseMove:
        v.cursor = e.screen;
        v.pressed = false;
        v.erasing = true;
        _active.remove(trackId);
        eraseAt(e.screen);
        break;
      case InteractionKind.eraseUp:
        v.erasing = false;
        break;
      // OSクリック/ドラッグ（ピンチ）はインクを引かない。カーソルの押下表示のみ。
      case InteractionKind.pressDown:
      case InteractionKind.pressMove:
        v.cursor = e.screen;
        v.pressed = true;
        v.erasing = false;
        break;
      case InteractionKind.click:
        v.cursor = e.screen;
        break;
      case InteractionKind.pressUp:
        v.pressed = false;
        break;
      case InteractionKind.scroll:
        v.cursor = e.screen;
        v.erasing = false;
        break;
      case InteractionKind.pointerExit:
        // 画面外でも手自体は検出中なので、骨格とトラック色は保持する。
        v.cursor = null;
        v.pressed = false;
        v.erasing = false;
        _active.remove(trackId);
        break;
      case InteractionKind.release:
        // トラッキング喪失: このトラックのカーソル/骨格を消す。
        _active.remove(trackId);
        _tracks.remove(trackId);
        break;
    }
  }

  /// 現在フレームの骨格を反映する。map に無いトラックの骨格は消す
  /// （＝手が消えたら骨格も即時に消える）。
  void showSkeletons(Map<int, List<Vec2>> byTrack) {
    for (final entry in byTrack.entries) {
      _visual(entry.key).skeleton = entry.value;
    }
    for (final id in _tracks.keys) {
      if (!byTrack.containsKey(id)) _tracks[id]!.skeleton = null;
    }
    _pruneEmpty();
    notifyListeners();
  }

  void _pruneEmpty() {
    _tracks.removeWhere(
      (id, v) =>
          v.cursor == null && v.skeleton == null && !_active.containsKey(id),
    );
  }

  /// [p]（画面正規化）から [eraserRadius] 以内のインク点を消す。線の途中を消した
  /// 場合はそこでストロークを分割し、残った前後を別ストロークとして保つ
  /// （消しゴムで線に穴を開けても、両端が1本に繋がって見えないようにする）。
  /// 描画中（_active）のストロークは対象外。呼び出し側で notifyListeners する。
  void eraseAt(Vec2 p) {
    final active = _active.values.toSet();
    final next = <InkStroke>[];
    var changed = false;
    for (final stroke in strokes) {
      if (active.contains(stroke)) {
        next.add(stroke);
        continue;
      }
      var segment = <Vec2>[];
      var removedAny = false;
      for (final pt in stroke.points) {
        if (pt.distanceTo(p) <= eraserRadius) {
          removedAny = true;
          if (segment.isNotEmpty) {
            next.add(
              InkStroke(
                segment,
                trackId: stroke.trackId,
                color: stroke.color,
              ),
            );
            segment = <Vec2>[];
          }
        } else {
          segment.add(pt);
        }
      }
      if (!removedAny) {
        next.add(stroke);
      } else {
        changed = true;
        if (segment.isNotEmpty) {
          next.add(
            InkStroke(
              segment,
              trackId: stroke.trackId,
              color: stroke.color,
            ),
          );
        }
      }
    }
    if (changed) {
      strokes
        ..clear()
        ..addAll(next);
    }
  }

  void clear() {
    strokes.clear();
    _active.clear();
    _tracks.clear();
    notifyListeners();
  }
}
