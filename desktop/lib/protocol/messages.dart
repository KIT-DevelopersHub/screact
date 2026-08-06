import '../core/geom.dart';

/// YubiBoard Android通信プロトコル v1 のメッセージ定義（docs/android-protocol-v1.md）。
/// PCはWebSocketサーバとして Android から hello / hand_frame / calibration_markers /
/// heartbeat を受け、hello_ack / control_message を返す。未知フィールドは無視する。
const int kSchemaVersion = 1;

/// 受信: hello（接続開始）。
class Hello {
  final String deviceId;
  final String? clientVersion;
  final String? pairingToken;
  final String? interactionProfile;
  final List<String> capabilities;
  const Hello({
    required this.deviceId,
    this.clientVersion,
    this.pairingToken,
    this.interactionProfile,
    this.capabilities = const [],
  });

  static Hello fromJson(Map<String, dynamic> j) => Hello(
        deviceId: (j['deviceId'] ?? 'unknown') as String,
        clientVersion: j['clientVersion'] as String?,
        pairingToken: j['pairingToken'] as String?,
        interactionProfile: j['interactionProfile'] as String?,
        capabilities: ((j['capabilities'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// 送信: hello_ack（セッションID・対象画面・位置合わせ要否）。
class HelloAck {
  final String sessionId;
  final String surfaceId;
  final int widthPx;
  final int heightPx;
  final bool calibrationRequired;
  const HelloAck({
    required this.sessionId,
    required this.surfaceId,
    required this.widthPx,
    required this.heightPx,
    required this.calibrationRequired,
  });

  Map<String, dynamic> toJson() => {
        'schemaVersion': kSchemaVersion,
        'messageType': 'hello_ack',
        'sessionId': sessionId,
        'surface': {
          'surfaceId': surfaceId,
          'widthPx': widthPx,
          'heightPx': heightPx,
        },
        'calibrationRequired': calibrationRequired,
      };
}

/// 送信: hello_error（接続拒否。6桁コード不一致等）。
class HelloError {
  final String code; // pairing_code_mismatch など
  final String message;
  final bool retryable;
  const HelloError({
    required this.code,
    required this.message,
    this.retryable = false,
  });

  Map<String, dynamic> toJson() => {
        'schemaVersion': kSchemaVersion,
        'messageType': 'hello_error',
        'code': code,
        'message': message,
        'retryable': retryable,
      };
}

/// 送信: control_message（モード切替 / 切断要求）。
class ControlMessage {
  final String sessionId;
  final String command; // set_mode | disconnect
  final String? mode; // calibration | tracking
  const ControlMessage.setMode(this.sessionId, this.mode) : command = 'set_mode';
  const ControlMessage.disconnect(this.sessionId)
      : command = 'disconnect',
        mode = null;

  Map<String, dynamic> toJson() => {
        'schemaVersion': kSchemaVersion,
        'messageType': 'control_message',
        'sessionId': sessionId,
        'command': command,
        if (mode != null) 'mode': mode,
      };
}

/// 21点手指骨格（MediaPipe hand・0..20）。
class Landmark {
  final double x, y, z; // x,y は normalized_camera(0..1)
  const Landmark(this.x, this.y, this.z);
  Vec2 get xy => Vec2(x, y);
  factory Landmark.fromList(List<dynamic> l) => Landmark(
        (l[0] as num).toDouble(),
        (l[1] as num).toDouble(),
        l.length > 2 ? (l[2] as num).toDouble() : 0,
      );
}

/// 受信: hand_frame。未検出時は detected=false・landmarks空。
class HandFrame {
  final int frameId;
  final int capturedAtMonotonicMs;
  final bool detected;
  final String? handedness;
  final List<Landmark> landmarks;
  const HandFrame({
    required this.frameId,
    required this.capturedAtMonotonicMs,
    required this.detected,
    this.handedness,
    this.landmarks = const [],
  });

  static const int expectedLandmarks = 21;

  /// MediaPipe hand の主要インデックス。
  static const int wrist = 0;
  static const int thumbTip = 4;
  static const int indexTip = 8;
  static const int middleTip = 12;
  static const int ringTip = 16;
  static const int pinkyTip = 20;
  static const int indexMcp = 5;

  Landmark? at(int i) =>
      (i >= 0 && i < landmarks.length) ? landmarks[i] : null;

  /// 妥当性: 検出時は21点・各値が0..1近傍。
  bool get isValid {
    if (!detected) return true;
    if (landmarks.length != expectedLandmarks) return false;
    for (final l in landmarks) {
      if (l.x.isNaN || l.y.isNaN) return false;
    }
    return true;
  }

  static HandFrame fromJson(Map<String, dynamic> j) {
    final hand = (j['hand'] as Map?)?.cast<String, dynamic>() ?? const {};
    final detected = hand['detected'] == true;
    final lms = <Landmark>[];
    if (detected && hand['landmarks'] is List) {
      for (final e in (hand['landmarks'] as List)) {
        lms.add(Landmark.fromList((e as List)));
      }
    }
    return HandFrame(
      frameId: (j['frameId'] as num?)?.toInt() ?? 0,
      capturedAtMonotonicMs: (j['capturedAtMonotonicMs'] as num?)?.toInt() ?? 0,
      detected: detected,
      handedness: hand['handedness'] as String?,
      landmarks: lms,
    );
  }
}

/// ArUcoマーカー1つ（正規化座標）。
class Marker {
  final int id;
  final Vec2 center;
  final List<Vec2> corners; // 時計回り4頂点
  const Marker(this.id, this.center, this.corners);

  static Marker fromJson(Map<String, dynamic> j) {
    Vec2 v(List l) => Vec2((l[0] as num).toDouble(), (l[1] as num).toDouble());
    return Marker(
      (j['id'] as num).toInt(),
      v(j['center'] as List),
      ((j['corners'] as List?) ?? const []).map((e) => v(e as List)).toList(),
    );
  }
}

/// 受信: slide_corners（スマホが検出したスライドの四隅・カメラ正規化・順不同）。
/// 斜め/正面/下から等、見る角度による歪みは四隅の形に現れる。PC側は
/// この4点からホモグラフィを作り、手の位置をスライド座標へ正確に写す。
class SlideCorners {
  final int capturedAtMonotonicMs;
  final List<Vec2> corners;
  const SlideCorners(this.capturedAtMonotonicMs, this.corners);

  bool get isValid =>
      corners.length == 4 &&
      corners.every((c) => c.x.isFinite && c.y.isFinite);

  static SlideCorners fromJson(Map<String, dynamic> j) {
    final cs = <Vec2>[];
    for (final e in (j['corners'] as List?) ?? const []) {
      final l = e as List;
      cs.add(Vec2((l[0] as num).toDouble(), (l[1] as num).toDouble()));
    }
    return SlideCorners(
      (j['capturedAtMonotonicMs'] as num?)?.toInt() ?? 0,
      cs,
    );
  }
}

/// 受信: calibration_markers（ArUco検出結果・4 ID想定）。
class CalibrationMarkers {
  final int capturedAtMonotonicMs;
  final List<Marker> markers;
  const CalibrationMarkers(this.capturedAtMonotonicMs, this.markers);

  static CalibrationMarkers fromJson(Map<String, dynamic> j) =>
      CalibrationMarkers(
        (j['capturedAtMonotonicMs'] as num?)?.toInt() ?? 0,
        ((j['markers'] as List?) ?? const [])
            .map((e) => Marker.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}
