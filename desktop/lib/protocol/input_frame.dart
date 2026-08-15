import 'messages.dart';

/// 2人同時操作・最大2手の受信フレーム（統合シート two_users_two_active_hands）。
///
/// `hands` が新実装の正本（0〜2件）。旧 `hand` 単一形式は後方互換用で、`hands`
/// があれば無視する。妥当性はフレーム単位で判定し、1つでも違反があれば
/// 「一部採用」せず [InputFrame.parse] が null を返す（＝フレーム全体を破棄）。
class InputFrame {
  /// 単一手の後方互換フレームに割り当てる内部トラックID（配線用・通信には出さない）。
  static const int compatTrackId = 0;
  static const int maxHands = 2;

  final int schemaVersion;
  final String? sessionId;
  final int frameId;
  final int capturedAtMonotonicMs;

  /// trackId昇順・重複なしの0〜2トラック。0件は「有効な手なし」フレーム。
  final List<HandTrack> tracks;

  /// このフレームが後方互換の単一 `hand` から作られたか（診断用）。
  final bool fromCompatHand;

  const InputFrame({
    required this.schemaVersion,
    required this.sessionId,
    required this.frameId,
    required this.capturedAtMonotonicMs,
    required this.tracks,
    this.fromCompatHand = false,
  });

  bool get hasHands => tracks.isNotEmpty;

  /// hand_frame JSON を検証しつつ解釈する。違反は null（＝フレーム全体破棄）。
  ///
  /// - schemaVersion は既定 [kSchemaVersion] と一致（欠落は既定を採用）。
  /// - sessionId は [expectedSessionId] があれば一致必須（フレーム側欠落は許容）。
  /// - frameId は有限の整数（単調増加の判定は呼び出し側=エンジンが担う）。
  /// - hands は0〜2件。各手 trackId>0・session内で重複なし・21点・各点有限・x,y∈[0,1]。
  /// - hands が無ければ `hand` を単一互換トラックとして扱う（同じ点検を適用）。
  static InputFrame? parse(
    Map<String, dynamic> j, {
    String? expectedSessionId,
  }) {
    final schemaRaw = j['schemaVersion'];
    final schema = schemaRaw == null ? kSchemaVersion : _finiteInt(schemaRaw);
    if (schema == null || schema != kSchemaVersion) return null;

    final sessionRaw = j['sessionId'];
    if (sessionRaw != null && sessionRaw is! String) return null;
    final sessionId = sessionRaw as String?;
    if (expectedSessionId != null && sessionId != expectedSessionId) {
      return null; // session不一致 → 破棄
    }

    final frameId = _finiteInt(j['frameId']);
    if (frameId == null || frameId < 0) return null;

    final capturedRaw = j['capturedAtMonotonicMs'];
    final captured = capturedRaw == null ? 0 : _finiteInt(capturedRaw);
    if (captured == null || captured < 0) return null;

    // hands が正本。存在すれば hand は無視する。
    if (j.containsKey('hands')) {
      final raw = j['hands'];
      if (raw is! List) return null;
      if (raw.length > maxHands) return null; // 3手以上 → 破棄
      final tracks = <HandTrack>[];
      final seenIds = <int>{};
      var prevId = -1 << 30;
      for (final e in raw) {
        if (e is! Map) return null;
        final track = _parseTrack(e.cast<String, dynamic>(), requireRange: true);
        if (track == null) return null; // 不正な手 → フレーム全体破棄
        if (!seenIds.add(track.trackId)) return null; // trackId重複 → 破棄
        if (track.trackId < prevId) return null; // 昇順違反 → 破棄
        prevId = track.trackId;
        tracks.add(track);
      }
      if (!_legacyHandMatches(j['hand'], tracks)) return null;
      return InputFrame(
        schemaVersion: schema,
        sessionId: sessionId,
        frameId: frameId,
        capturedAtMonotonicMs: captured,
        tracks: tracks,
      );
    }

    // 後方互換: 旧単一 `hand`。未検出は0手フレームとして受理する。
    final hand = (j['hand'] as Map?)?.cast<String, dynamic>();
    if (hand == null || hand['detected'] != true) {
      return InputFrame(
        schemaVersion: schema,
        sessionId: sessionId,
        frameId: frameId,
        capturedAtMonotonicMs: captured,
        tracks: const [],
      );
    }
    // 旧 `hand` 経路は旧PC互換のため範囲チェックを課さない（有限値・21点のみ）。
    final landmarks = _parseLandmarks(hand['landmarks'], requireRange: false);
    if (landmarks == null) return null;
    return InputFrame(
      schemaVersion: schema,
      sessionId: sessionId,
      frameId: frameId,
      capturedAtMonotonicMs: captured,
      tracks: [
        HandTrack(
          trackId: compatTrackId,
          handedness: hand['handedness'] as String?,
          landmarks: landmarks,
        ),
      ],
      fromCompatHand: true,
    );
  }

  static int? _finiteInt(dynamic raw) {
    if (raw is! num || !raw.toDouble().isFinite) return null;
    final value = raw.toInt();
    return raw == value ? value : null;
  }

  /// `hand` が同梱されている場合は、正本 `hands` の最小 trackId と一致するか検証する。
  /// 省略は移行中クライアントとの互換のため許容する。
  static bool _legacyHandMatches(dynamic raw, List<HandTrack> tracks) {
    if (raw == null) return true;
    if (raw is! Map) return false;
    final hand = raw.cast<String, dynamic>();
    if (tracks.isEmpty) return hand['detected'] == false;
    if (hand['detected'] != true) return false;

    final primary = tracks.first;
    final handedness = hand['handedness'];
    if (handedness != null && handedness is! String) return false;
    if (handedness != primary.handedness) return false;
    final landmarks = _parseLandmarks(hand['landmarks'], requireRange: true);
    if (landmarks == null) return false;
    for (var i = 0; i < landmarks.length; i++) {
      final legacy = landmarks[i];
      final current = primary.landmarks[i];
      if (legacy.x != current.x ||
          legacy.y != current.y ||
          legacy.z != current.z) {
        return false;
      }
    }
    return true;
  }

  static HandTrack? _parseTrack(
    Map<String, dynamic> j, {
    required bool requireRange,
  }) {
    final idNum = j['trackId'] as num?;
    if (idNum == null || idNum != idNum.toInt() || idNum <= 0) return null;
    final handedness = j['handedness'];
    if (handedness != null && handedness is! String) return null;
    final landmarks = _parseLandmarks(j['landmarks'], requireRange: requireRange);
    if (landmarks == null) return null;
    return HandTrack(
      trackId: idNum.toInt(),
      handedness: handedness as String?,
      landmarks: landmarks,
    );
  }

  /// 21点・各点 [x,y,z]（zは任意）を検証して返す。違反は null。
  /// [requireRange] 時は x,y∈[0,1] も課す（新 hands[] 経路）。
  static List<Landmark>? _parseLandmarks(
    dynamic raw, {
    required bool requireRange,
  }) {
    if (raw is! List || raw.length != HandFrame.expectedLandmarks) return null;
    final out = <Landmark>[];
    for (final e in raw) {
      if (e is! List || e.length < 2) return null;
      final x = (e[0] as num?)?.toDouble();
      final y = (e[1] as num?)?.toDouble();
      if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
      if (requireRange && (x < 0 || x > 1 || y < 0 || y > 1)) {
        return null; // x,y範囲外 → 破棄
      }
      double z = 0;
      if (e.length > 2) {
        final zz = (e[2] as num?)?.toDouble();
        if (zz == null || !zz.isFinite) return null; // NaN/Inf → 破棄
        z = zz;
      }
      out.add(Landmark(x, y, z));
    }
    return out;
  }
}
