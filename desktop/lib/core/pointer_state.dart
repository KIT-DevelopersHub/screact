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
  bool erasing = false; // グー（消しゴム）中。カーソルを消しゴム範囲の輪で描く。

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

  /// 描画中ストロークの開始時刻（[_nowMs] 基準）。確定時の誤認識判定に使う。
  final Map<InkStroke, int> _activeStartMs = {};

  /// 描画中ストロークを最後に観測した時刻（最後の drawDown/drawMove を受けた
  /// [_nowMs]）。継続時間は確定時刻ではなくここまでで測る。手が消えてから
  /// 一時欠落の猶予（#39）を経て release が届いても、誤認識の継続時間が
  /// 猶予ぶん伸びて破棄されなくなるのを防ぐ。エンジンは描画中の各フレームで
  /// 点が動かなくても drawMove を出すため、静止した長押しも毎フレーム更新される。
  final Map<InkStroke, int> _activeLastSeenMs = {};

  /// 単調増加の現在時刻（ミリ秒）。テストでは固定の時計を注入する。
  final int Function() _nowMs;

  OverlayModel({int Function()? nowMs}) : _nowMs = nowMs ?? _monotonicMs;

  static final Stopwatch _clock = Stopwatch()..start();
  static int _monotonicMs() => _clock.elapsedMilliseconds;

  /// これ未満の移動は点を増やさない（重複点の抑制・描画の軽量化）。
  static const double _minPointDist = 0.002;

  /// ペンモード解除（人差し指と中指を離す）直前は、指を離す動作で手がブレて
  /// 不要な線が描かれやすい。drawUp 時に末尾のこの点数ぶんを削ってブレ線をカットする。
  /// 保守的な既定値。0 で無効。実測に応じて調整可能（フレーム間引き後の点数基準）。
  int penReleaseTrimPoints = 3;

  /// 保持するインクストロークの上限。長時間デモで無制限に増えると、毎フレーム
  /// の再描画コストとメモリが増え続けるため、古い完了ストロークから捨てる。
  /// 描画中（_active）のストロークは対象外。
  static const int _maxRetainedStrokes = 240;

  /// 消しゴム（グー）の消去半径（画面正規化・0..1）。この距離以内のインク点を消す。
  static const double eraserRadius = 0.045;

  // --- 誤認識ストローク（点のカス）の判定閾値 -------------------------------
  // 描画中は即時表示し、確定時に「一瞬・少点数・ほぼ動いていない」の3条件を
  // すべて満たしたストロークだけを誤認識として破棄する（Issue #5）。どれか1つでも
  // 外れれば残すので、長押しした点（句読点・意図した点）、素早く引いた短線、
  // 低速描画は消えない。判定は末尾トリム前の点列で行う。
  // 値は暫定。実機ログ（送信fps・解像度・手の速さ）で調整する予定。

  /// これ未満の継続時間なら「一瞬」とみなす。30fps 送信で約4〜5フレーム。
  /// 2本指くっつきを意図して作ると、これより長く保持されるという想定。
  static const int microStrokeMaxDurationMs = 150;

  /// 点数がこれ以下なら「少点数」とみなす（[_minPointDist] 間引き後の点数）。
  /// 上の継続時間内に届く送信フレーム数の目安に合わせている。
  static const int microStrokeMaxPoints = 5;

  /// 軌跡長（画面正規化）がこれ未満なら「ほぼ動いていない」とみなす。
  /// 画面幅の約1%（1920px幅で約19px）。末尾トリム前の全点で測る。
  static const double microStrokeMaxPathLength = 0.01;

  /// ユーザーがパレットで選んだ描画色スロット（null=トラック別自動色にフォールバック）。
  int? _selectedColorSlot;
  int? get selectedColorSlot => _selectedColorSlot;

  /// パレットのスウォッチ選択。以後の新規ストロークへこの色を適用する。
  /// 同じ色を再選択したら選択解除し、トラック別自動色へ戻す。
  void selectColorSlot(int? slot) {
    final next = _selectedColorSlot == slot ? null : slot;
    if (next == _selectedColorSlot) return;
    _selectedColorSlot = next;
    notifyListeners();
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
    switch (e.kind) {
      case InteractionKind.pointerMove:
        v.cursor = e.screen;
        v.pressed = false;
        v.erasing = false;
        _finishStroke(trackId, trimTail: false);
        break;
      // インク描画（人差し指＋中指のくっつき・人差し指先端）。
      case InteractionKind.drawDown:
        v.cursor = e.screen;
        v.pressed = true;
        v.erasing = false;
        // drawUp なしで次の描画が始まった場合も、前のストロークを確定する。
        _finishStroke(trackId, trimTail: false);
        // ユーザーがパレットで選んだ色を優先。未選択ならトラック別自動色。
        final stroke = InkStroke(
          [e.screen],
          trackId: trackId,
          colorSlot: _selectedColorSlot ?? v.colorSlot,
        );
        _active[trackId] = stroke;
        final startMs = _nowMs();
        _activeStartMs[stroke] = startMs;
        _activeLastSeenMs[stroke] = startMs;
        strokes.add(stroke);
        _capHistory();
        break;
      case InteractionKind.drawMove:
        v.cursor = e.screen;
        final a = _active[trackId];
        if (a == null) break;
        // 点を増やさない微小移動（静止した長押し）でも観測時刻は進める。
        _activeLastSeenMs[a] = _nowMs();
        if (a.points.isEmpty ||
            a.points.last.distanceTo(e.screen) >= _minPointDist) {
          a.points.add(e.screen);
        }
        break;
      case InteractionKind.drawUp:
        v.pressed = false;
        _finishStroke(trackId, trimTail: true);
        break;
      // 消しゴム（グー）。カーソル位置近傍のインクを消す。
      case InteractionKind.eraseDown:
      case InteractionKind.eraseMove:
        v.cursor = e.screen;
        v.pressed = false;
        v.erasing = true;
        _finishStroke(trackId, trimTail: false);
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
        _finishStroke(trackId, trimTail: false);
        break;
      case InteractionKind.release:
        // トラッキング喪失・通信断: このトラックのカーソル/骨格を消す。
        _finishStroke(trackId, trimTail: false);
        _tracks.remove(trackId);
        break;
    }
  }

  /// [trackId] の描画中ストロークを確定する（全終了経路の共通処理）。
  /// 他トラックのストロークには触れない。
  ///
  /// 1. 末尾トリム前の点列で誤認識（[isMicroStroke]）を判定し、該当すれば破棄する。
  ///    継続時間は最初の drawDown から最後の drawDown/drawMove までで測る。
  /// 2. 残す場合、[trimTail]（drawUp＝ペン解除）のときだけ末尾のブレ線を削る。
  ///    release／pointerExit 等の強制終了は従来どおりトリムしない。
  void _finishStroke(int trackId, {required bool trimTail}) {
    final ending = _active.remove(trackId);
    if (ending == null) return;
    final startMs = _activeStartMs.remove(ending);
    final lastSeenMs = _activeLastSeenMs.remove(ending);
    final durationMs =
        startMs == null || lastSeenMs == null ? null : lastSeenMs - startMs;
    if (durationMs != null && isMicroStroke(ending.points, durationMs)) {
      strokes.remove(ending);
      return;
    }
    // ペンモード終了直前のブレ線をカット: 末尾の penReleaseTrimPoints 点を落とす。
    // 少なくとも1点は残す（点を消しすぎてストローク自体を壊さない）。
    if (trimTail && penReleaseTrimPoints > 0 && ending.points.length > 1) {
      final drop = penReleaseTrimPoints.clamp(0, ending.points.length - 1);
      ending.points.removeRange(
        ending.points.length - drop,
        ending.points.length,
      );
    }
  }

  /// 確定時点の点列（トリム前）と継続時間から、誤認識の微小ストロークかを判定する。
  /// 継続時間・点数・軌跡長がすべて閾値内のときだけ true（1点でも長押しなら false）。
  @visibleForTesting
  static bool isMicroStroke(List<Vec2> points, int durationMs) {
    if (durationMs >= microStrokeMaxDurationMs) return false;
    if (points.length > microStrokeMaxPoints) return false;
    var length = 0.0;
    for (var i = 1; i < points.length; i++) {
      length += points[i - 1].distanceTo(points[i]);
      if (length >= microStrokeMaxPathLength) return false;
    }
    return true;
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
                colorSlot: stroke.colorSlot,
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
              colorSlot: stroke.colorSlot,
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
    _activeStartMs.clear();
    _activeLastSeenMs.clear();
    _tracks.clear();
    notifyListeners();
  }
}
