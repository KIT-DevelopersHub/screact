// 電話の代わりに、実プロトコル(v1)でPCサーバへ接続してみるモッククライアント。
// 使い方: アプリで「サーバ開始」後、`dart run tool/mock_android.dart [host] [port] [--tilted]`
//  - 既定: calibration_markers(ArUco) → 円運動＋周期ピンチの手 を ~30fps で流す
//  - --tilted: slide_corners(斜め下から見た台形) → ピンチで水平線＋斜め線を
//    スライド座標に引く手 を流す（歪み補正の実機確認用）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/homography.dart';

/// 斜め下・やや左から見たスライド四隅（カメラ正規化・凸台形）。
const tiltedCorners = [
  Vec2(0.18, 0.20), // TL
  Vec2(0.84, 0.12), // TR
  Vec2(0.95, 0.80), // BR
  Vec2(0.08, 0.68), // BL
];

Future<void> main(List<String> args) async {
  final tilted = args.contains('--tilted');
  final pos = args.where((a) => !a.startsWith('--')).toList();
  final host = pos.isNotEmpty ? pos[0] : 'localhost';
  final port = pos.length > 1 ? int.parse(pos[1]) : 8765;
  final ws = await WebSocket.connect('ws://$host:$port/ws/v1/input');
  stdout.writeln('connected ws://$host:$port/ws/v1/input (tilted=$tilted)');

  String? sessionId;
  ws.listen((data) {
    final j = jsonDecode(data as String) as Map<String, dynamic>;
    if (j['messageType'] == 'hello_ack') {
      sessionId = j['sessionId'] as String;
      stdout.writeln('hello_ack session=$sessionId '
          'calibrationRequired=${j['calibrationRequired']}');
    } else {
      stdout.writeln('recv: ${j['messageType']} ${j['command'] ?? ''}');
    }
  });

  void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));

  send({
    'schemaVersion': 1,
    'messageType': 'hello',
    'deviceId': 'mock-android',
    'clientVersion': '0.1.0',
    'pairingToken': '000000',
    'capabilities': [
      'aruco_calibration',
      'slide_corner_detection',
      'hand_landmarks_21',
    ],
  });

  await Future<void>.delayed(const Duration(milliseconds: 300));

  if (tilted) {
    // 位置合わせ: スライド四隅（順不同で送って順序不変性も確認）。
    final shuffled = [tiltedCorners[2], tiltedCorners[0], tiltedCorners[3], tiltedCorners[1]];
    send({
      'schemaVersion': 1,
      'messageType': 'slide_corners',
      'sessionId': sessionId,
      'capturedAtMonotonicMs': 0,
      'corners': [for (final c in shuffled) [c.x, c.y]],
    });
    _runTiltedHand(send);
  } else {
    // 位置合わせ(四隅ArUcoマーカー)
    List<double> v(double x, double y) => [x, y];
    send({
      'schemaVersion': 1,
      'messageType': 'calibration_markers',
      'sessionId': sessionId,
      'capturedAtMonotonicMs': 0,
      'markers': [
        {'id': 10, 'center': v(0.1, 0.1), 'corners': [v(.08, .08), v(.12, .08), v(.12, .12), v(.08, .12)]},
        {'id': 11, 'center': v(0.9, 0.1), 'corners': [v(.88, .08), v(.92, .08), v(.92, .12), v(.88, .12)]},
        {'id': 12, 'center': v(0.9, 0.9), 'corners': [v(.88, .88), v(.92, .88), v(.92, .92), v(.88, .92)]},
        {'id': 13, 'center': v(0.1, 0.9), 'corners': [v(.08, .88), v(.12, .88), v(.12, .92), v(.08, .92)]},
      ],
    });
    _runCircleHand(send);
  }
}

/// 既定シナリオ: 円運動＋周期ピンチ。
void _runCircleHand(void Function(Map<String, dynamic>) send) {
  var i = 0;
  Timer.periodic(const Duration(milliseconds: 33), (t) {
    final tt = i / 30.0;
    final cx = 0.5 + 0.28 * math.cos(tt);
    final cy = 0.5 + 0.28 * math.sin(tt);
    final pinch = (i ~/ 20) % 2 == 1;
    send(_handFrame(i, Vec2(cx, cy), pinch));
    i++;
    if (i > 300) t.cancel();
  });
}

/// --tilted シナリオ: スライド座標で「水平線→移動→斜め線」を引く手。
/// スライド座標(u,v)を square→台形 のホモグラフィでカメラ座標へ写して送るので、
/// PC側の歪み補正が正しければ画面にはまっすぐな線が描かれる。
void _runTiltedHand(void Function(Map<String, dynamic>) send) {
  final toCam = Homography.fromCorrespondences(
    const [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)],
    tiltedCorners,
  )!;
  Vec2 slideAt(int i) {
    if (i < 30) {
      // 接近（ピンチなし）
      final t = i / 29.0;
      return Vec2(0.10 + 0.05 * t, 0.35 + 0.15 * t);
    } else if (i < 90) {
      // 水平線: (0.15,0.5)→(0.85,0.5)
      final t = (i - 30) / 59.0;
      return Vec2(0.15 + 0.70 * t, 0.5);
    } else if (i < 120) {
      // 移動（ピンチなし）
      final t = (i - 90) / 29.0;
      return Vec2(0.85 - 0.65 * t, 0.5 + 0.2 * t);
    } else if (i < 180) {
      // 斜め線: (0.2,0.7)→(0.8,0.3)
      final t = (i - 120) / 59.0;
      return Vec2(0.2 + 0.6 * t, 0.7 - 0.4 * t);
    }
    return const Vec2(0.5, 0.5);
  }

  bool pinchAt(int i) => (i >= 30 && i < 90) || (i >= 120 && i < 180);

  var i = 0;
  Timer.periodic(const Duration(milliseconds: 33), (t) {
    final cam = toCam.map(slideAt(i));
    send(_handFrame(i, cam, pinchAt(i)));
    i++;
    if (i > 200) t.cancel();
  });
}

/// 人差し指先端 tip（カメラ正規化）を中心に21点の手を合成した hand_frame。
Map<String, dynamic> _handFrame(int i, Vec2 tip, bool pinch) {
  final cx = tip.x, cy = tip.y;
  final wrist = [cx, cy + 0.25, 0.0];
  final lm = List.generate(21, (_) => wrist);
  lm[0] = wrist;
  lm[5] = [cx, cy + 0.12, 0];
  lm[6] = [cx, cy + 0.06, 0];
  lm[8] = [cx, cy, 0];
  lm[4] = pinch ? [cx - 0.02, cy + 0.01, 0] : [cx - 0.16, cy + 0.10, 0];
  lm[10] = [cx + 0.03, cy + 0.06, 0];
  lm[12] = [cx + 0.03, cy + 0.15, 0];
  lm[14] = [cx + 0.06, cy + 0.06, 0];
  lm[16] = [cx + 0.06, cy + 0.15, 0];
  lm[18] = [cx + 0.09, cy + 0.06, 0];
  lm[20] = [cx + 0.09, cy + 0.15, 0];
  return {
    'schemaVersion': 1,
    'messageType': 'hand_frame',
    'frameId': i,
    'capturedAtMonotonicMs': i * 33,
    'hand': {
      'detected': true,
      'handedness': 'RIGHT',
      'landmarkFormat': 'mediapipe_hand_21',
      'landmarks': lm,
    },
  };
}
