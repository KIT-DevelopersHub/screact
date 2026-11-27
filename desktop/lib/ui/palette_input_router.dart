import '../core/interaction_engine.dart';
import 'edge_palette_layout.dart';

/// 画面端パレットの上での手の操作を、OS 入力へ流さずに色の選択として消費する。
///
/// オーバーレイはクリックを透過するため、パレットの上でピンチすると背後の
/// アプリにクリックが届いてしまう。OS 入力（[routeOsEvents]）とオーバーレイ
/// （[routeTrackEvents]）へ渡す前にこのクラスを通し、パレットの領域
/// （[EdgePaletteLayout.panelHitRect]）での操作を取り除く。全画面を常に
/// クリック非透過にはしない。パレットの外のイベントはそのまま流す。
///
/// 規則（推奨案）:
/// - pressDown がパレット内で始まったら、その押下が終わる（pressUp）までの
///   pressMove・click・pressUp を OS に流さない。パレット内のスウォッチの上で
///   押下を終えたら、その色を選ぶ。パレットの外へ出てから離したら何も選ばない。
///   追跡喪失・画面外（同じ列に release／pointerExit が続く pressUp）でも選ばない。
/// - パレットの外で始まった押下（ドラッグ）は、パレットに入っても OS に流し続ける
///   （ドラッグを途中で切らない）。
/// - 押下中でない click がパレット内なら OS に流さず、スウォッチの上なら色を選ぶ。
/// - scroll はパレット内なら OS に流さない（パレットの外なら流す）。
/// - 描画（drawDown）・消しゴム（eraseDown）はパレット内では始めない。終わるまで
///   （drawUp／eraseUp）ポインタ移動としてオーバーレイへ渡す。パレットの外で
///   始まった描画・消しゴムは、パレットに入っても続ける。
/// - pointerMove は常に流す（カーソルの移動だけでは背後のアプリを操作しない）。
/// - どのトラック（OS に流れない 2 本目の手を含む）でも色を選べる。
///
/// 色の競合（推奨案。利用者別の色にするかは 6-07 で判断する）:
/// - 描画色は全員で共有の 1 色（`OverlayModel.selectedColorSlot`）。
/// - 2 本の手がほぼ同時に選んだら、後に確定した（押下を終えた）ほうの色になる。
///   同じフレームで確定した場合は、そのフレームのトラックの並び順で後のほうになる。
/// - 描画中に別の手が色を選んでも、描画中の線の色は変えない（線の色は描き始めで
///   決まる）。新しい色は次の線から使う。
/// - 消しゴムは色を選ばない。パレットの上に入っても選択表示（後光）は出さない。
///   パレットはインクの下に描くため、パレットの上にかかったインクは消してよい。
///
/// [layout] が null のとき（オーバーレイ非表示・パレット表示 OFF）は判定しない。
/// ただし、パレットで始まって消費中の押下・描画・消しゴムは、終わるまで消費を続ける
/// （途中で OS に pressMove・pressUp だけが届かないようにする）。
///
/// OS 入力の列（主トラック）とオーバーレイの列（全トラック）は別々に状態を持つ。
/// 主トラックの列は、主トラックの選出が押下の途中で決まると先頭に pressDown が
/// 補われるため、OS が実際に受け取る列に沿って押下の始まりを判定する。
/// 色の選択はオーバーレイの列（[routeTrackEvents]）だけで行う。
class PaletteInputRouter {
  /// スウォッチが選ばれたときに呼ぶ（通常は `OverlayModel.selectColorSlot`）。
  final void Function(int slot) onSelectSlot;

  PaletteInputRouter({required this.onSelectSlot});

  final _PressStream _os = _PressStream();
  final Map<int, _PressStream> _tracks = {};

  /// OS 入力（主トラック）へ渡すイベントの列を返す。パレットの操作は取り除く。
  /// 取り除くものが無ければ [events] をそのまま返す。
  List<InteractionEvent> routeOsEvents(
    List<InteractionEvent> events,
    EdgePaletteLayout? layout,
  ) {
    List<InteractionEvent>? out;
    for (var i = 0; i < events.length; i++) {
      final e = events[i];
      final forward = _os.route(e, layout, forcedEnd: false).forwardToOs;
      if (!forward) {
        out ??= events.sublist(0, i);
      } else {
        out?.add(e);
      }
    }
    return out ?? events;
  }

  /// オーバーレイ（全トラック）へ渡すイベントを返し、パレットの色選択を行う。
  ///
  /// 押下系（pressDown・pressMove・click・pressUp）と scroll はカーソル表示の
  /// ためにそのまま渡す。パレット内で始まった描画・消しゴムは pointerMove に
  /// 置き換える。変更が無ければ [byTrack] をそのまま返す。
  Map<int, List<InteractionEvent>> routeTrackEvents(
    Map<int, List<InteractionEvent>> byTrack,
    EdgePaletteLayout? layout,
  ) {
    Map<int, List<InteractionEvent>>? out;
    byTrack.forEach((id, events) {
      final stream = _tracks.putIfAbsent(id, _PressStream.new);
      List<InteractionEvent>? routed;
      for (var i = 0; i < events.length; i++) {
        final e = events[i];
        final result = stream.route(
          e,
          layout,
          forcedEnd:
              e.kind == InteractionKind.pressUp && _endsByForce(events, i),
        );
        final slot = result.selectSlot;
        if (slot != null) onSelectSlot(slot);
        final replacement = result.overlayReplacement;
        if (replacement != null) {
          routed ??= events.sublist(0, i);
          routed.add(replacement);
        } else {
          routed?.add(e);
        }
      }
      if (stream.isIdle) _tracks.remove(id);
      if (routed != null) {
        out ??= Map.of(byTrack);
        out![id] = routed;
      }
    });
    return out ?? byTrack;
  }

  /// 全ての状態を捨てる（接続の切り替えなど）。
  void reset() {
    _os.reset();
    _tracks.clear();
  }

  /// [index] の pressUp の後に、同じ列で release／pointerExit が続くか。
  /// 追跡喪失・画面外への移動で押下が強制的に終わった場合は色を選ばない。
  static bool _endsByForce(List<InteractionEvent> events, int index) {
    for (var j = index + 1; j < events.length; j++) {
      final k = events[j].kind;
      if (k == InteractionKind.release || k == InteractionKind.pointerExit) {
        return true;
      }
    }
    return false;
  }
}

/// 押下の捕捉状態。
enum _Capture {
  /// 押下していない。
  none,

  /// パレット内で始まった押下（終わるまで OS に流さない）。
  palette,

  /// パレットの外で始まった押下（終わるまで OS に流す）。
  outside,
}

class _RouteResult {
  final bool forwardToOs;
  final int? selectSlot;
  final InteractionEvent? overlayReplacement;

  const _RouteResult({
    this.forwardToOs = true,
    this.selectSlot,
    this.overlayReplacement,
  });

  static const pass = _RouteResult();
  static const consume = _RouteResult(forwardToOs: false);
}

/// 1 本のイベント列（OS 入力の主トラック、またはオーバーレイの 1 トラック）の状態。
class _PressStream {
  _Capture _press = _Capture.none;
  bool _drawSuppressed = false;
  bool _eraseSuppressed = false;

  bool get isIdle =>
      _press == _Capture.none && !_drawSuppressed && !_eraseSuppressed;

  void reset() {
    _press = _Capture.none;
    _drawSuppressed = false;
    _eraseSuppressed = false;
  }

  static EdgePaletteHit _hit(EdgePaletteLayout? layout, InteractionEvent e) =>
      layout?.hitTestNormalized(e.screen) ?? EdgePaletteHit.none;

  _RouteResult route(
    InteractionEvent e,
    EdgePaletteLayout? layout, {
    required bool forcedEnd,
  }) {
    switch (e.kind) {
      case InteractionKind.pressDown:
        _press =
            _hit(layout, e).isInsidePalette
                ? _Capture.palette
                : _Capture.outside;
        return _press == _Capture.palette
            ? _RouteResult.consume
            : _RouteResult.pass;

      case InteractionKind.pressMove:
        if (_press == _Capture.none) {
          // pressDown を見ていない押下（主トラックの途中選出など）は、ここを始まりとする。
          _press =
              _hit(layout, e).isInsidePalette
                  ? _Capture.palette
                  : _Capture.outside;
        }
        return _press == _Capture.palette
            ? _RouteResult.consume
            : _RouteResult.pass;

      case InteractionKind.click:
        switch (_press) {
          case _Capture.outside:
            return _RouteResult.pass;
          case _Capture.palette:
          case _Capture.none:
            final hit = _hit(layout, e);
            if (_press == _Capture.none && !hit.isInsidePalette) {
              return _RouteResult.pass;
            }
            return _RouteResult(forwardToOs: false, selectSlot: hit.slot);
        }

      case InteractionKind.pressUp:
        final was = _press;
        _press = _Capture.none;
        switch (was) {
          case _Capture.outside:
            return _RouteResult.pass;
          case _Capture.palette:
            final hit = _hit(layout, e);
            return _RouteResult(
              forwardToOs: false,
              selectSlot: forcedEnd ? null : hit.slot,
            );
          case _Capture.none:
            // 押下を見ていない pressUp。パレット内なら流さないが、色は選ばない。
            return _hit(layout, e).isInsidePalette
                ? _RouteResult.consume
                : _RouteResult.pass;
        }

      case InteractionKind.scroll:
        return _hit(layout, e).isInsidePalette
            ? _RouteResult.consume
            : _RouteResult.pass;

      case InteractionKind.drawDown:
        _drawSuppressed = _hit(layout, e).isInsidePalette;
        return _drawSuppressed ? _asPointerMove(e) : _RouteResult.pass;
      case InteractionKind.drawMove:
        return _drawSuppressed ? _asPointerMove(e) : _RouteResult.pass;
      case InteractionKind.drawUp:
        _drawSuppressed = false;
        return _RouteResult.pass;

      case InteractionKind.eraseDown:
        _eraseSuppressed = _hit(layout, e).isInsidePalette;
        return _eraseSuppressed ? _asPointerMove(e) : _RouteResult.pass;
      case InteractionKind.eraseMove:
        return _eraseSuppressed ? _asPointerMove(e) : _RouteResult.pass;
      case InteractionKind.eraseUp:
        _eraseSuppressed = false;
        return _RouteResult.pass;

      case InteractionKind.pointerMove:
      case InteractionKind.pointerExit:
        return _RouteResult.pass;

      case InteractionKind.release:
        reset();
        return _RouteResult.pass;
    }
  }

  /// 描画・消しゴムを始めず、カーソルの移動としてオーバーレイへ渡す。
  /// OS 入力ではこれらの種類は注入されないため、OS 側の扱いは変わらない。
  static _RouteResult _asPointerMove(InteractionEvent e) => _RouteResult(
    overlayReplacement: InteractionEvent(InteractionKind.pointerMove, e.screen),
  );
}
