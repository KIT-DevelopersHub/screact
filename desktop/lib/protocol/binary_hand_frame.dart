import 'dart:typed_data';

import 'input_frame.dart';
import 'messages.dart';

/// 手指フレームのバイナリ形式（仕様案）のエンコーダとデコーダ。
///
/// 仕様は docs/system/binary-hand-frame-draft.md。JSON の `hand_frame`
/// （hands[] 正本）と同じ情報を、BLE などの小さい MTU の経路でも送れる大きさに
/// まとめる。試作段階のため InputServer には接続していない。
///
/// すべてリトルエンディアン。
///
/// ```text
/// ヘッダ 12 B : magic u8 | formatVersion u8 | flags u8 | handCount u8
///               | frameId u32 | capturedAtMonotonicMs u32
/// ソース 6 B  : width u16 | height u16 | rotationQuarter u8 | sourceFlags u8
///               （flags.hasSource のときだけ）
/// 手 × handCount :
///   trackId u16 | handedness u8 | handednessScore u8
///   | 21 × (x u16, y u16) | 21 × z i16（flags.hasZ のときだけ）
/// ```
class BinaryHandFrameCodec {
  BinaryHandFrameCodec._();

  /// 先頭バイト（'S'）。JSON（'{'）と取り違えないための目印。
  static const int magic = 0x53;

  /// バイナリ形式の版。1 は protocol schemaVersion 1 の `hand_frame` に対応する。
  static const int formatVersion = 1;

  static const int flagHasZ = 0x01;
  static const int flagHasSource = 0x02;
  static const int _flagReservedMask = 0xFC;

  static const int headerSize = 12;
  static const int sourceSize = 6;
  static const int landmarkCount = HandFrame.expectedLandmarks;

  /// 手 1 件の固定部（trackId・handedness・score）。
  static const int handFixedSize = 4;

  /// 手 1 件の x/y 部（21 点 × 2 軸 × u16）。
  static const int handXySize = landmarkCount * 4;

  /// 手 1 件の z 部（21 点 × i16）。
  static const int handZSize = landmarkCount * 2;

  static const int maxHands = InputFrame.maxHands;
  static const int maxTrackId = 0xFFFF;
  static const int maxUint32 = 0xFFFFFFFF;

  /// x/y の量子化: q = round(v × 65535)。
  static const int xyScale = 0xFFFF;

  /// z の量子化: q = round(clamp(z, -zRange, zRange) / zRange × 32767)。
  static const int zScale = 0x7FFF;

  /// z の表現範囲（MediaPipe の相対深度）。範囲外は端の値に丸める（飽和）。
  static const double zRange = 1.0;

  /// handednessScore の量子化: q = round(s × 254)。255 は「省略」。
  static const int scoreScale = 254;
  static const int scoreAbsent = 0xFF;

  /// x/y の量子化誤差の上限（0.5 / 65535 ≈ 7.63e-6）。
  static const double maxXyError = 0.5 / xyScale;

  /// z の量子化誤差の上限（範囲内。0.5 / 32767 × zRange ≈ 1.53e-5）。
  static const double maxZError = 0.5 / zScale * zRange;

  /// handednessScore の量子化誤差の上限（0.5 / 254 ≈ 1.97e-3）。
  static const double maxScoreError = 0.5 / scoreScale;

  static const int _handednessNone = 0;
  static const int _handednessLeft = 1;
  static const int _handednessRight = 2;

  static const int _facingNone = 0;
  static const int _facingFront = 1;
  static const int _facingBack = 2;

  /// 手 1 件のバイト数。
  static int handSize({required bool includeZ}) =>
      handFixedSize + handXySize + (includeZ ? handZSize : 0);

  /// フレーム全体のバイト数。
  static int frameSize({
    required int handCount,
    required bool includeZ,
    required bool includeSource,
  }) =>
      headerSize +
      (includeSource ? sourceSize : 0) +
      handCount * handSize(includeZ: includeZ);

  /// フレームをバイナリにする。仕様で表せない値は [ArgumentError]（範囲外は
  /// [RangeError]）。z だけは範囲外を ±[zRange] に飽和させる。
  static Uint8List encode(BinaryHandFrame frame) {
    final hands = frame.hands;
    if (hands.length > maxHands) {
      throw ArgumentError.value(hands.length, 'hands.length', '最大 $maxHands 手');
    }
    _checkUint32(frame.frameId, 'frameId');
    _checkUint32(frame.capturedAtMonotonicMs, 'capturedAtMonotonicMs');

    final source = frame.source;
    final size = frameSize(
      handCount: hands.length,
      includeZ: frame.includeZ,
      includeSource: source != null,
    );
    final data = ByteData(size);
    var o = 0;
    data.setUint8(o++, magic);
    data.setUint8(o++, formatVersion);
    data.setUint8(
      o++,
      (frame.includeZ ? flagHasZ : 0) | (source != null ? flagHasSource : 0),
    );
    data.setUint8(o++, hands.length);
    data.setUint32(o, frame.frameId, Endian.little);
    o += 4;
    data.setUint32(o, frame.capturedAtMonotonicMs, Endian.little);
    o += 4;

    if (source != null) {
      _checkRange(source.width, 0, 0xFFFF, 'source.width');
      _checkRange(source.height, 0, 0xFFFF, 'source.height');
      final rot = source.rotationDegrees;
      if (rot % 90 != 0 || rot < 0 || rot >= 360) {
        throw ArgumentError.value(
          rot,
          'source.rotationDegrees',
          '0/90/180/270',
        );
      }
      data.setUint16(o, source.width, Endian.little);
      o += 2;
      data.setUint16(o, source.height, Endian.little);
      o += 2;
      data.setUint8(o++, rot ~/ 90);
      data.setUint8(
        o++,
        (source.rotationCorrected ? 0x01 : 0) |
            (source.mirrorCorrected ? 0x02 : 0) |
            (_encodeFacing(source.cameraFacing) << 2),
      );
    }

    var prevId = 0;
    for (final h in hands) {
      _checkRange(h.trackId, 1, maxTrackId, 'trackId');
      if (h.trackId <= prevId) {
        throw ArgumentError.value(h.trackId, 'trackId', '重複なしの昇順で並べる');
      }
      prevId = h.trackId;
      if (h.landmarks.length != landmarkCount) {
        throw ArgumentError.value(
          h.landmarks.length,
          'landmarks.length',
          '$landmarkCount 点',
        );
      }
      data.setUint16(o, h.trackId, Endian.little);
      o += 2;
      data.setUint8(o++, _encodeHandedness(h.handedness));
      data.setUint8(o++, _encodeScore(h.handednessScore));
      for (final p in h.landmarks) {
        data.setUint16(o, _quantizeXy(p.x, 'x'), Endian.little);
        o += 2;
        data.setUint16(o, _quantizeXy(p.y, 'y'), Endian.little);
        o += 2;
      }
      if (frame.includeZ) {
        for (final p in h.landmarks) {
          data.setInt16(o, quantizeZ(p.z), Endian.little);
          o += 2;
        }
      }
    }
    assert(o == size);
    return data.buffer.asUint8List();
  }

  /// バイナリをフレームに戻す。仕様に合わないものは [FormatException]。
  ///
  /// JSON 版 [InputFrame.parse] と同じく、一部でも違反があればフレーム全体を拒否する。
  static BinaryHandFrame decode(Uint8List bytes) {
    if (bytes.length < headerSize) {
      throw FormatException('ヘッダより短い (${bytes.length} B)');
    }
    final data = ByteData.sublistView(bytes);
    var o = 0;
    if (data.getUint8(o++) != magic) {
      throw const FormatException('magic が違う');
    }
    final version = data.getUint8(o++);
    if (version != formatVersion) {
      throw FormatException('未対応の formatVersion: $version');
    }
    final flags = data.getUint8(o++);
    if (flags & _flagReservedMask != 0) {
      throw FormatException('予約ビットが立っている: flags=$flags');
    }
    final includeZ = flags & flagHasZ != 0;
    final hasSource = flags & flagHasSource != 0;
    final handCount = data.getUint8(o++);
    if (handCount > maxHands) {
      throw FormatException('手の数が多すぎる: $handCount');
    }
    final expected = frameSize(
      handCount: handCount,
      includeZ: includeZ,
      includeSource: hasSource,
    );
    if (bytes.length != expected) {
      throw FormatException('長さが違う: ${bytes.length} B（期待 $expected B）');
    }
    final frameId = data.getUint32(o, Endian.little);
    o += 4;
    final captured = data.getUint32(o, Endian.little);
    o += 4;

    BinaryHandFrameSource? source;
    if (hasSource) {
      final width = data.getUint16(o, Endian.little);
      o += 2;
      final height = data.getUint16(o, Endian.little);
      o += 2;
      final rotQ = data.getUint8(o++);
      if (rotQ > 3) throw FormatException('rotation が範囲外: $rotQ');
      final sf = data.getUint8(o++);
      if (sf & 0xF0 != 0) {
        throw FormatException('source の予約ビットが立っている: $sf');
      }
      source = BinaryHandFrameSource(
        width: width,
        height: height,
        rotationDegrees: rotQ * 90,
        rotationCorrected: sf & 0x01 != 0,
        mirrorCorrected: sf & 0x02 != 0,
        cameraFacing: _decodeFacing((sf >> 2) & 0x03),
      );
    }

    final hands = <BinaryHand>[];
    var prevId = 0;
    for (var i = 0; i < handCount; i++) {
      final trackId = data.getUint16(o, Endian.little);
      o += 2;
      if (trackId == 0) throw const FormatException('trackId は 1 以上');
      if (trackId == prevId) {
        throw FormatException('trackId が重複している: $trackId');
      }
      if (trackId < prevId) {
        throw FormatException('trackId が昇順でない: $trackId');
      }
      prevId = trackId;
      final handedness = _decodeHandedness(data.getUint8(o++));
      final score = _decodeScore(data.getUint8(o++));
      final xs = List<double>.filled(landmarkCount, 0);
      final ys = List<double>.filled(landmarkCount, 0);
      for (var k = 0; k < landmarkCount; k++) {
        xs[k] = data.getUint16(o, Endian.little) / xyScale;
        o += 2;
        ys[k] = data.getUint16(o, Endian.little) / xyScale;
        o += 2;
      }
      final zs = List<double>.filled(landmarkCount, 0);
      if (includeZ) {
        for (var k = 0; k < landmarkCount; k++) {
          final q = data.getInt16(o, Endian.little);
          o += 2;
          if (q < -zScale) throw FormatException('z が範囲外: $q');
          zs[k] = q / zScale * zRange;
        }
      }
      hands.add(
        BinaryHand(
          trackId: trackId,
          handedness: handedness,
          handednessScore: score,
          landmarks: List.unmodifiable([
            for (var k = 0; k < landmarkCount; k++)
              Landmark(xs[k], ys[k], zs[k]),
          ]),
        ),
      );
    }
    assert(o == expected);
    return BinaryHandFrame(
      frameId: frameId,
      capturedAtMonotonicMs: captured,
      hands: List.unmodifiable(hands),
      includeZ: includeZ,
      source: source,
    );
  }

  /// [decode] の失敗を null で返す版。
  static BinaryHandFrame? tryDecode(Uint8List bytes) {
    try {
      return decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// バイナリから、JSON 経路と同じ [InputFrame] を作る。不正なら null
  /// （[InputFrame.parse] と同じく、フレーム全体を破棄する扱い）。
  ///
  /// バイナリは sessionId を運ばない（接続ごとに決まるため）。受信側が知っている
  /// 値を [sessionId] に渡す。
  static InputFrame? decodeInputFrame(Uint8List bytes, {String? sessionId}) =>
      tryDecode(bytes)?.toInputFrame(sessionId: sessionId);

  /// z を i16 に量子化する（範囲外は飽和）。
  static int quantizeZ(double z) {
    if (!z.isFinite) throw ArgumentError.value(z, 'z', '有限の値');
    final c = z.clamp(-zRange, zRange);
    return (c / zRange * zScale).round();
  }

  static int _quantizeXy(double v, String name) {
    if (!v.isFinite || v < 0 || v > 1) {
      throw RangeError.value(v, name, '0..1 の有限の値');
    }
    return (v * xyScale).round();
  }

  static int _encodeScore(double? s) {
    if (s == null) return scoreAbsent;
    if (!s.isFinite || s < 0 || s > 1) {
      throw RangeError.value(s, 'handednessScore', '0..1 の有限の値');
    }
    return (s * scoreScale).round();
  }

  static double? _decodeScore(int q) {
    // u8 のうち 0..254 が値、255 が省略。範囲外になる値はない。
    if (q == scoreAbsent) return null;
    return q / scoreScale;
  }

  static int _encodeHandedness(String? h) => switch (h) {
    null => _handednessNone,
    'LEFT' => _handednessLeft,
    'RIGHT' => _handednessRight,
    _ => throw ArgumentError.value(h, 'handedness', 'null / LEFT / RIGHT'),
  };

  static String? _decodeHandedness(int q) => switch (q) {
    _handednessNone => null,
    _handednessLeft => 'LEFT',
    _handednessRight => 'RIGHT',
    _ => throw FormatException('handedness が範囲外: $q'),
  };

  static int _encodeFacing(String? f) => switch (f) {
    null => _facingNone,
    'front' => _facingFront,
    'back' => _facingBack,
    _ =>
      throw ArgumentError.value(
        f,
        'source.cameraFacing',
        'null / front / back',
      ),
  };

  static String? _decodeFacing(int q) => switch (q) {
    _facingNone => null,
    _facingFront => 'front',
    _facingBack => 'back',
    _ => throw FormatException('cameraFacing が範囲外: $q'),
  };

  static void _checkUint32(int v, String name) =>
      _checkRange(v, 0, maxUint32, name);

  static void _checkRange(int v, int min, int max, String name) {
    if (v < min || v > max) throw RangeError.range(v, min, max, name);
  }
}

/// JSON の `source` に当たる撮影情報。
class BinaryHandFrameSource {
  final int width;
  final int height;

  /// 0 / 90 / 180 / 270。
  final int rotationDegrees;
  final bool rotationCorrected;
  final bool mirrorCorrected;

  /// `front` / `back` / null（省略）。
  final String? cameraFacing;

  const BinaryHandFrameSource({
    required this.width,
    required this.height,
    this.rotationDegrees = 0,
    this.rotationCorrected = false,
    this.mirrorCorrected = false,
    this.cameraFacing,
  });
}

/// バイナリ形式の手 1 件（JSON の `hands[]` の要素に当たる）。
class BinaryHand {
  /// 1..65535。
  final int trackId;

  /// `LEFT` / `RIGHT` / null。
  final String? handedness;

  /// 0..1 / null。
  final double? handednessScore;

  /// 21 点。x/y は 0..1。
  final List<Landmark> landmarks;

  const BinaryHand({
    required this.trackId,
    required this.landmarks,
    this.handedness,
    this.handednessScore,
  });

  HandTrack toHandTrack() =>
      HandTrack(trackId: trackId, handedness: handedness, landmarks: landmarks);
}

/// バイナリ形式の手指フレーム。手が 0 件なら「未検出」の通知になる。
class BinaryHandFrame {
  final int frameId;
  final int capturedAtMonotonicMs;

  /// trackId 昇順・重複なしの 0〜2 件。
  final List<BinaryHand> hands;

  /// z を送るか。false なら受信側の z は 0。
  final bool includeZ;

  final BinaryHandFrameSource? source;

  const BinaryHandFrame({
    required this.frameId,
    required this.capturedAtMonotonicMs,
    required this.hands,
    this.includeZ = true,
    this.source,
  });

  /// JSON 経路の [InputFrame] から作る（エンコードの入力・テスト用）。
  /// [InputFrame] は handednessScore と source を持たないため、必要なら渡す。
  factory BinaryHandFrame.fromInputFrame(
    InputFrame frame, {
    bool includeZ = true,
    BinaryHandFrameSource? source,
    Map<int, double>? handednessScores,
  }) => BinaryHandFrame(
    frameId: frame.frameId,
    capturedAtMonotonicMs: frame.capturedAtMonotonicMs,
    includeZ: includeZ,
    source: source,
    hands: [
      for (final t in frame.tracks)
        BinaryHand(
          trackId: t.trackId,
          handedness: t.handedness,
          handednessScore: handednessScores?[t.trackId],
          landmarks: t.landmarks,
        ),
    ],
  );

  /// JSON 経路と同じ [InputFrame] に変換する。schemaVersion は
  /// formatVersion 1 に対応する [kSchemaVersion]。
  InputFrame toInputFrame({String? sessionId}) => InputFrame(
    schemaVersion: kSchemaVersion,
    sessionId: sessionId,
    frameId: frameId,
    capturedAtMonotonicMs: capturedAtMonotonicMs,
    tracks: List.unmodifiable([for (final h in hands) h.toHandTrack()]),
  );
}
