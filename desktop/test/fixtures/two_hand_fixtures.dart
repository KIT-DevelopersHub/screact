// 統合シート two-person-two-hand-integration-sheet の実通信例をそのまま
// fixture 化したもの（trackId 7 / 12・各21点）。Android未完でもPCが2骨格を
// 同時表示できることを検証するために使う。

/// trackId 7（LEFT）の21点。
const List<List<double>> hand7Landmarks = [
  [0.20, 0.70, -0.01],
  [0.19, 0.64, -0.01],
  [0.18, 0.58, -0.02],
  [0.17, 0.52, -0.02],
  [0.16, 0.46, -0.03],
  [0.24, 0.55, -0.01],
  [0.25, 0.47, -0.02],
  [0.26, 0.39, -0.03],
  [0.27, 0.31, -0.04],
  [0.30, 0.54, -0.01],
  [0.31, 0.45, -0.02],
  [0.32, 0.36, -0.03],
  [0.33, 0.27, -0.04],
  [0.36, 0.56, -0.01],
  [0.37, 0.48, -0.02],
  [0.38, 0.40, -0.03],
  [0.39, 0.32, -0.04],
  [0.42, 0.60, -0.01],
  [0.43, 0.53, -0.02],
  [0.44, 0.46, -0.03],
  [0.45, 0.39, -0.04],
];

/// trackId 12（RIGHT）の21点。
const List<List<double>> hand12Landmarks = [
  [0.80, 0.70, -0.01],
  [0.81, 0.64, -0.01],
  [0.82, 0.58, -0.02],
  [0.83, 0.52, -0.02],
  [0.84, 0.46, -0.03],
  [0.76, 0.55, -0.01],
  [0.75, 0.47, -0.02],
  [0.74, 0.39, -0.03],
  [0.73, 0.31, -0.04],
  [0.70, 0.54, -0.01],
  [0.69, 0.45, -0.02],
  [0.68, 0.36, -0.03],
  [0.67, 0.27, -0.04],
  [0.64, 0.56, -0.01],
  [0.63, 0.48, -0.02],
  [0.62, 0.40, -0.03],
  [0.61, 0.32, -0.04],
  [0.58, 0.60, -0.01],
  [0.57, 0.53, -0.02],
  [0.56, 0.46, -0.03],
  [0.55, 0.39, -0.04],
];

Map<String, dynamic> handPayload(int trackId, List<List<double>> lm) => {
      'trackId': trackId,
      'handedness': trackId == 7 ? 'LEFT' : 'RIGHT',
      'handednessScore': 0.96,
      'coordinateSpace': 'normalized_camera',
      'landmarkFormat': 'mediapipe_hand_21',
      'landmarks': lm,
    };

/// 2手（7/12）を含む有効フレーム。
Map<String, dynamic> twoHandFrame({
  int frameId = 1842,
  String sessionId = 'session-01',
}) =>
    {
      'schemaVersion': 1,
      'messageType': 'hand_frame',
      'sessionId': sessionId,
      'frameId': frameId,
      'capturedAtMonotonicMs': 19384521 + frameId,
      'source': {'width': 960, 'height': 540, 'rotationDegrees': 0},
      'hands': [
        handPayload(7, hand7Landmarks),
        handPayload(12, hand12Landmarks),
      ],
      // 後方互換: 最小trackIdの手をコピー。新PCは無視する。
      'hand': {
        'detected': true,
        'handedness': 'LEFT',
        'landmarks': hand7Landmarks,
      },
    };

/// 片手（7のみ）フレーム。
Map<String, dynamic> oneHandFrame({
  int frameId = 1843,
  String sessionId = 'session-01',
}) =>
    {
      'schemaVersion': 1,
      'messageType': 'hand_frame',
      'sessionId': sessionId,
      'frameId': frameId,
      'capturedAtMonotonicMs': 19384521 + frameId,
      'hands': [handPayload(7, hand7Landmarks)],
      'hand': {
        'detected': true,
        'handedness': 'LEFT',
        'landmarks': hand7Landmarks,
      },
    };

/// 0手フレーム。
Map<String, dynamic> zeroHandFrame({
  int frameId = 1844,
  String sessionId = 'session-01',
}) =>
    {
      'schemaVersion': 1,
      'messageType': 'hand_frame',
      'sessionId': sessionId,
      'frameId': frameId,
      'capturedAtMonotonicMs': 19384521 + frameId,
      'hands': <Map<String, dynamic>>[],
      'hand': {'detected': false},
    };
