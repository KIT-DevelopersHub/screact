// ゼロコンフィグ・ペアリングのE2E検証用モックAndroid。
// UDP発見の待受（discovery_offer→response→select）から、選択後の
// WebSocket自動接続・ArUco四隅送信・ピンチ手フレーム送信までを実機なしで演じる。
//
// 使い方:
//   dart run tool/mock_pairing_android.dart [--discovery-port=18766] \
//     [--devices=2] [--respond-only]
//  - --devices=N: 1ソケットでN台の端末を演じる（複数台→AirDrop風選択UIの確認）
//  - --respond-only: 応答のみ（selectを受けてもWS接続しない。選択UIの静止確認用）
//  - --calib-delay=S: 四隅送信開始をS秒遅らせる（ArUco表示の目視/撮影用）
//  - select された deviceId の端末だけが WS 接続する
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const deviceNames = ['Pixel 7 (mock)', 'Galaxy S24 (mock)', 'Xperia 5 (mock)'];

Future<void> main(List<String> args) async {
  int discoveryPort = 8766;
  int devices = 1;
  var respondOnly = false;
  var calibDelay = 0;
  for (final a in args) {
    if (a.startsWith('--discovery-port=')) {
      discoveryPort = int.parse(a.split('=')[1]);
    } else if (a.startsWith('--devices=')) {
      devices = int.parse(a.split('=')[1]);
    } else if (a == '--respond-only') {
      respondOnly = true;
    } else if (a.startsWith('--calib-delay=')) {
      calibDelay = int.parse(a.split('=')[1]);
    }
  }

  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort);
  stdout.writeln('mock listening: udp 0.0.0.0:$discoveryPort devices=$devices '
      'respondOnly=$respondOnly');
  var connecting = false;

  sock.listen((e) {
    if (e != RawSocketEvent.read) return;
    final dg = sock.receive();
    if (dg == null) return;
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(utf8.decode(dg.data)) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    if (j['app'] != 'screact') return;
    switch (j['messageType']) {
      case 'discovery_offer':
        for (var i = 0; i < devices; i++) {
          sock.send(
            utf8.encode(jsonEncode({
              'app': 'screact',
              'schemaVersion': 1,
              'messageType': 'discovery_response',
              'deviceId': 'mock-${String.fromCharCode(97 + i)}',
              'deviceName': deviceNames[i % deviceNames.length],
              'model': deviceNames[i % deviceNames.length],
            })),
            dg.address,
            dg.port,
          );
        }
        break;
      case 'discovery_select':
        final id = j['deviceId'];
        stdout.writeln('selected: $id (token=${j['token']} wsPort=${j['wsPort']})');
        if (respondOnly || connecting) return;
        connecting = true;
        _connectAndDrive(
          host: dg.address.address,
          port: (j['wsPort'] as num).toInt(),
          token: j['token'] as String,
          deviceId: id as String,
          calibDelay: calibDelay,
        );
        break;
    }
  });
}

/// select 受領後の実機相当ふるまい: WS接続→hello(token)→キャリブ四隅送信→
/// set_mode(tracking) を受けたら円運動＋周期ピンチの手フレームを送る。
Future<void> _connectAndDrive({
  required String host,
  required int port,
  required String token,
  required String deviceId,
  int calibDelay = 0,
}) async {
  final ws = await WebSocket.connect('ws://$host:$port/ws/v1/input');
  stdout.writeln('ws connected: ws://$host:$port/ws/v1/input');
  void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));

  String? sessionId;
  Timer? calibTimer;
  Timer? handTimer;

  void startCalibration() {
    List<double> v(double x, double y) => [x, y];
    calibTimer?.cancel();
    // --calib-delay: ArUco表示の撮影/目視用に最初の四隅送信を遅らせる
    calibTimer = Timer.periodic(const Duration(milliseconds: 200), (t) {
      if (t.tick * 200 < calibDelay * 1000) return;
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
    });
  }

  void startHand() {
    var i = 0;
    handTimer?.cancel();
    handTimer = Timer.periodic(const Duration(milliseconds: 33), (t) {
      final tt = i / 30.0;
      final cx = 0.5 + 0.28 * math.cos(tt);
      final cy = 0.5 + 0.28 * math.sin(tt);
      final pinch = (i ~/ 20) % 2 == 1;
      send(_handFrame(i, cx, cy, pinch));
      i++;
      if (i > 600) t.cancel();
    });
  }

  ws.listen((data) {
    final j = jsonDecode(data as String) as Map<String, dynamic>;
    switch (j['messageType']) {
      case 'hello_ack':
        sessionId = j['sessionId'] as String;
        stdout.writeln('hello_ack session=$sessionId '
            'calibrationRequired=${j['calibrationRequired']}');
        if (j['calibrationRequired'] == true) startCalibration();
        break;
      case 'control_message':
        stdout.writeln('control: ${j['command']} ${j['mode'] ?? ''}');
        if (j['command'] == 'set_mode') {
          if (j['mode'] == 'calibration') {
            handTimer?.cancel();
            startCalibration();
          } else if (j['mode'] == 'tracking') {
            calibTimer?.cancel();
            startHand();
          }
        }
        break;
      case 'hello_error':
        stdout.writeln('hello_error: ${j['code']}');
        break;
    }
  }, onDone: () {
    calibTimer?.cancel();
    handTimer?.cancel();
    stdout.writeln('ws closed');
  });

  send({
    'schemaVersion': 1,
    'messageType': 'hello',
    'deviceId': deviceId,
    'clientVersion': '0.1.0-mock',
    'pairingToken': token,
    'capabilities': ['aruco_calibration', 'hand_landmarks_21'],
  });
}

Map<String, dynamic> _handFrame(int i, double cx, double cy, bool pinch) {
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
