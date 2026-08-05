// 電話の代わりに、実プロトコル(v1)でPCサーバへ接続してみるモッククライアント。
// 使い方: アプリで「サーバ開始」後、`dart run tool/mock_android.dart [host] [port]`。
// hello → hello_ack を待ち → calibration_markers → hand_frame を ~30fps で流す。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : 'localhost';
  final port = args.length > 1 ? int.parse(args[1]) : 8765;
  final ws = await WebSocket.connect('ws://$host:$port/ws/v1/input');
  stdout.writeln('connected ws://$host:$port/ws/v1/input');

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
    'capabilities': ['aruco_calibration', 'hand_landmarks_21'],
  });

  await Future<void>.delayed(const Duration(milliseconds: 300));

  // 位置合わせ(四隅マーカー)
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

  var i = 0;
  Timer.periodic(const Duration(milliseconds: 33), (t) {
    final tt = i / 30.0;
    final cx = 0.5 + 0.28 * math.cos(tt);
    final cy = 0.5 + 0.28 * math.sin(tt);
    final pinch = (i ~/ 20) % 2 == 1;
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
    send({
      'schemaVersion': 1,
      'messageType': 'hand_frame',
      'sessionId': sessionId,
      'frameId': i,
      'capturedAtMonotonicMs': i * 33,
      'hand': {
        'detected': true,
        'handedness': 'RIGHT',
        'landmarkFormat': 'mediapipe_hand_21',
        'landmarks': lm,
      },
    });
    i++;
    if (i > 300) t.cancel();
  });
}
