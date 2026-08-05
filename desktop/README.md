# YubiBoard Desktop（PCアプリ・THE WIN）

Androidの背面カメラが検出した **ArUcoマーカー＋21点手指骨格** を受け取り、PC画面上で
ポインター/描画/クリック/ドラッグ/スクロールへ変換するデスクトップアプリ。
**PCがWebSocketサーバ**（`ws://<PCのIP>:8765/ws/v1/input`）として待ち受け、Androidがクライアントとして接続する（protocol v1）。

## 構成（共通Flutter層 ＋ 各OSネイティブ）

```
lib/
  protocol/messages.dart      protocol v1 のメッセージ型（hello/hand_frame/calibration_markers…）
  net/input_server.dart       WebSocketサーバ（ハンドシェイク・最新フレームのみ処理）
  core/geom.dart              Vec2
  core/homography.dart        4マーカー→画面へのホモグラフィ（位置合わせ）
  core/one_euro.dart          One-Euro 平滑化
  core/gesture_recognizer.dart 21点→ポーズ（人差し指先端・ピンチ・伸展本数）
  core/interaction_engine.dart 受信→変換→平滑化→ジェスチャー→操作イベント（処理主体）
  core/pointer_state.dart     オーバーレイ表示モデル（アプリ内描画）
  core/mock_hand.dart         電話なし動作確認用のモック入力（実プロトコル同型）
  ui/                         操作面＋オーバーレイのライブプレビュー
  platform/desktop_bridge.dart OS入力/透過窓の境界（下記ネイティブを差し込む）
```

処理責任（要件どおりPCが主体）: 受信 → 位置合わせ(ArUco/homography) → 座標変換 → 平滑化 → ジェスチャー認識 → 描画/OS入力。トラッキング喪失時は安全解除。

## 実行・動作確認

```bash
cd desktop
flutter pub get
flutter test          # コア（ホモグラフィ/エンジン/安全解除）の検証
flutter run -d macos  # or -d windows
```

- アプリで「サーバ開始」→ 表示された **PCのIP** をAndroid側に入力。
- 電話が無い時は「モックの手を流す」で、実プロトコルと同じデータでパイプラインを駆動して確認できる（ピンチで線が描かれる）。
- ネットワーク経路まで試すには、サーバ開始後に別ターミナルで `dart run tool/mock_android.dart` を実行。

## 各OSネイティブ（次段・実機で実装/検証）

`DesktopBridge` の裏に、MethodChannel `yubiboard/desktop_input` で各OSのネイティブを差し込む。
現状は未接続なら **no-op**（共通UIのアプリ内描画で動作確認可能）。

- **Windows**（`windows/` ランナー・C++/Win32）: 複数ポインター注入・透過クリックスルー窓。ADR-0001 準拠（MouseMux SDK 併用は要検討）。
- **macOS**（`macos/` ランナー・Swift/CGEvent）: 単一ポインター注入・オーバーレイ窓。

> メモ: 共通層（受信〜ジェスチャー〜描画）は Mac 上でビルド・テストできる。OSへの実注入は各実機で `DesktopBridge` のネイティブを実装して有効化する。
