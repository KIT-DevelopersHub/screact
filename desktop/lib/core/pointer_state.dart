import 'dart:ui' show Offset, Path, Size;

import 'package:flutter/foundation.dart';

import 'geom.dart';
import 'interaction_engine.dart';

/// 描画中／確定したインクストローク（画面正規化点列）。trackId でトラック別に
/// 色分けする（2人同時描画の識別）。
class InkStroke {
  final List<Vec2> points;
  final int trackId;
  final int colorSlot;
  InkStroke(
    this.points, {
    this.trackId = OverlayModel.legacyTrackId,
    this.colorSlot = 0,
  });

  // 描画Pathのキャッシュ。完了ストロークは点数が変化しないため、一度構築した
  // Pathを再利用して毎フレームの再構築（O(全点数)）を避ける。描画中の
  // ストロークだけ点数が増えるので、そのフレームだけ再構築される。
  Path? _cachedPath;
  Size? _cachedSize;
  int _cachedCount = -1;

  /// 画面サイズに合わせた2次ベジェPath（中点スムージング）。点が2つ未満の
  /// ストロークは呼び出し側が点／円で描くため、ここでは扱わない。
  Path pathFor(Size size) {
    if (_cachedPath != null &&
        _cachedSize == size &&
        _cachedCount == points.length) {
      return _cachedPath!;
    }
    final path = _buildPath(size);
    _cachedPath = path;
    _cachedSize = size;
    _cachedCount = points.length;
    return path;
  }

  Path _buildPath(Size size) {
    Offset at(Vec2 v) => Offset(v.x * size.width, v.y * size.height);
    final path = Path();
    final first = at(points.first);
    path.moveTo(first.dx, first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final c = at(points[i]);
      final n = at(points[i + 1]);
      path.quadraticBezierTo(c.dx, c.dy, (c.dx + n.dx) / 2, (c.dy + n.dy) / 2);
    }
    final last = at(points.last);
    path.lineTo(last.dx, last.dy);
    return path;
  }
}

/// 1トラック分の表示状態（カーソル・押下・骨格）。
class TrackVisual {
  final int colorSlot;
  Vec2? cursor;
  bool pressed = false;

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
  static const int colorSlotCount = 4;

  final Map<int, TrackVisual> _tracks = {};
  final List<InkStroke> strokes = [];
  final Map<int, InkStroke> _active = {};

  /// これ未満の移動は点を増やさない（重複点の抑制・描画の軽量化）。
  static const double _minPointDist = 0.002;

  /// 保持するインクストロークの上限。長時間デモで無制限に増えると、毎フレーム
  /// の再描画コストとメモリが増え続けるため、古い完了ストロークから捨てる。
  /// 描画中（_active）のストロークは対象外。
  static const int _maxRetainedStrokes = 240;

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
    switch (e.kind) {
      case InteractionKind.pointerMove:
        v.cursor = e.screen;
        v.pressed = false;
        _active.remove(trackId);
        break;
      // インク描画（人差し指＋中指のくっつき・中間点）。
      case InteractionKind.drawDown:
        v.cursor = e.screen;
        v.pressed = true;
        final stroke = InkStroke(
          [e.screen],
          trackId: trackId,
          colorSlot: v.colorSlot,
        );
        _active[trackId] = stroke;
        strokes.add(stroke);
        _capHistory();
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
      // OSクリック/ドラッグ（ピンチ）はインクを引かない。カーソルの押下表示のみ。
      case InteractionKind.pressDown:
      case InteractionKind.pressMove:
        v.cursor = e.screen;
        v.pressed = true;
        break;
      case InteractionKind.click:
        v.cursor = e.screen;
        break;
      case InteractionKind.pressUp:
        v.pressed = false;
        break;
      case InteractionKind.scroll:
        v.cursor = e.screen;
        break;
      case InteractionKind.pointerExit:
        // 画面外でも手自体は検出中なので、骨格とトラック色は保持する。
        v.cursor = null;
        v.pressed = false;
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

  /// 上限を超えた分だけ、古い完了ストロークを先頭から捨てる。描画中の
  /// ストロークは保持する。
  void _capHistory() {
    if (strokes.length <= _maxRetainedStrokes) return;
    final activeStrokes = _active.values.toSet();
    var removable = strokes.length - _maxRetainedStrokes;
    strokes.removeWhere((s) {
      if (removable <= 0 || activeStrokes.contains(s)) return false;
      removable--;
      return true;
    });
  }

  void _pruneEmpty() {
    _tracks.removeWhere(
      (id, v) =>
          v.cursor == null && v.skeleton == null && !_active.containsKey(id),
    );
  }

  void clear() {
    strokes.clear();
    _active.clear();
    _tracks.clear();
    notifyListeners();
  }
}
