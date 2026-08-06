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

## 現在の実装範囲

- Android端末とのWebSocket接続
- 初回6桁コード認証と信頼済み`resumeToken`の発行・検証
- スマホ固定案内とPC上の`配置OK`
- `配置OK`後の四隅ArUcoマーカー表示
- 受信した手指骨格データの解析と画面座標への変換
- ポインター、クリック、ドラッグ、スクロール、描画用イベントの生成
- ログ保存とデバッグ表示

正常系は、`接続待機 → 配置確認待ち → マーカー認識中 → ホモグラフィ計算中 → 操作可能`。
通信JSONと再接続条件は[`docs/android/android-protocol-v1.md`](../docs/android/android-protocol-v1.md)を正本とする。

## OSネイティブ実装

`yubiboard/overlay_window` チャネルの透過・最前面・クリックスルーオーバーレイはWindowsとmacOSの両方に実装済み。

- **Windows**（`windows/` ランナー・C++/Win32）: オーバーレイ窓を実装済み。
- **macOS**（`macos/` ランナー・Swift）: オーバーレイ窓を実装済み。

OSへの実入力は`DesktopBridge`の`yubiboard/desktop_input` MethodChannelで分離している。
ネイティブ側が未接続の間は **no-op** となり、共通UIのアプリ内描画で動作確認できる。
