# YubiBoard Android

背面カメラでArUcoマーカーまたは1つの手の21点ランドマークを検出し、PCへWebSocket/JSONで送るAndroidアプリです。Android側ではジェスチャー判定やPC座標変換を行いません。

## ビルド

Android Studioではこの`android/`ディレクトリを開き、API 36 SDKとAndroid 7.0（API 24）以上の実機を使用します。

```powershell
.\gradlew.bat testDebugUnitTest lintDebug assembleDebug
```

MediaPipeの公式Hand Landmarkerモデルは`app/src/main/assets/hand_landmarker.task`へ同梱済みです。モデルの出典とチェックサムは同じディレクトリの`MODEL_ATTRIBUTION.md`にあります。

## モックPCとの接続

PCのファイアウォールで指定ポートのローカルLAN受信を許可した上で、リポジトリルートから次を実行します。追加パッケージは不要です。

```powershell
.\android\tools\mock-websocket-server.ps1 -Port 8080 -PairingToken 123456 -InitialMode tracking
```

AndroidアプリへPCのLAN内IPv4、ポート`8080`、コード`123456`を入力します。接続後、サーバーに`hand_frame`の件数が表示されます。`-InitialMode calibration`なら、接続直後にArUco位置合わせモードへ入ります。

## 実機デバッグ環境

デスクトップアプリがなくても、`tools/android-debug.ps1`とモックサーバーで実機のカメラ、検出、通信、再接続、性能を検証できます。スクリプトは`ANDROID_HOME`、`ANDROID_SDK_ROOT`、または標準のWindows SDK配置から`adb`を検出します。

初めて環境を作る場合や、操作しながら見る場所を確認したい場合は、[Android実機デバッグ・チュートリアル](../docs/android-debug-tutorial.md)を先に参照してください。

```powershell
.\android\tools\android-debug.ps1 doctor
```

### USBを基準経路にする

ADB reverseを使うと、Wi-FiやWindows Firewallの影響を受けずに実機からPCのサーバーへ接続できます。

```powershell
.\android\tools\android-debug.ps1 build
.\android\tools\android-debug.ps1 install
.\android\tools\android-debug.ps1 usb -Port 8080
.\android\tools\mock-websocket-server.ps1 -Port 8080 -PairingToken 123456
```

アプリにはホスト`127.0.0.1`、ポート`8080`、コード`123456`を入力します。カメラ権限の拒否経路も検証するため、`install`は既定では権限を自動付与しません。必要な場合だけ`-GrantCamera`を指定します。

Xiaomi系端末で`INSTALL_FAILED_USER_RESTRICTED`となる場合は、端末をロック解除し、開発者向けオプションの「USB経由のインストール」を有効にして、端末に表示される確認を許可してください。

### 同一LANを検証する

```powershell
.\android\tools\android-debug.ps1 lan -Port 8080
.\android\tools\mock-websocket-server.ps1 -Port 8080 -PairingToken 123456
```

表示されたPCのIPv4アドレスをアプリへ入力します。Windows FirewallではTCP 8080の受信をプライベートネットワークに限定して許可してください。公衆ネットワークやルーターのポート転送へ公開しないでください。

### アプリ内のデバッグモード

メイン画面の「設定」を開き、「デバッグモード」を切り替えて「適用」を押します。設定は次回起動時にも保持されます。debug APKでは初回のみデバッグモード、本番APKでは初回のみ本番モードが選ばれます。

デバッグモードでは接続カードの「診断」から次を確認できます。

- 端末・カメラ・解析設定、手検出fps、推論時間、追跡状態
- 21点座標、人差し指先端、左右分類、ArUco IDと中心
- 接続状態、session、送信数、送信バイト、置換・失敗・キュー抑制
- カメラなしで通信を試す「疑似21点」「疑似未検出」「疑似4マーカー」
- 直近500イベントのJSONL保存

疑似入力は通信層の検証専用です。検出精度の評価には使わないでください。診断イベントはLogcatの`YubiBoardDiag`タグにもJSONで出力されます。本番モードでは診断ボタンと詳細なしきい値を隠し、イベント収集と疑似入力を停止します。ビルド種別にかかわらず設定から再度切り替えられます。

### 通信障害シナリオ

モックサーバーの`-Scenario`には次を指定できます。

| 値 | 確認内容 |
| --- | --- |
| `happy` | 正常なhello、データ受信、heartbeat |
| `mode-switch` | 3秒後の遠隔モード切替 |
| `remote-disconnect` | PCからの切断要求 |
| `ack-timeout` | hello_ackなしと自動再接続 |
| `invalid-json` | 不正JSONを無視して継続 |
| `wrong-session` | 異なるsessionの制御を無視 |
| `schema-mismatch` | 未対応schemaのackを拒否 |
| `drop` | 通信断と段階的な再接続 |
| `slow-reader` | 低速受信時の最新フレーム優先 |

```powershell
.\android\tools\mock-websocket-server.ps1 -Scenario mode-switch -DurationSeconds 60
```

受信イベント、接続別CSV、Markdown要約は`android/debug-results/`へ保存され、Gitには追加されません。

### ArUcoと連続動作

PCで[`tools/calibration-target-1920x1080.png`](./tools/calibration-target-1920x1080.png)を全画面表示し、Androidカメラに四隅が入るよう設置します。この画像は`DICT_4X4_50`のID 10、11、12、13をOpenCVで再検証済みです。

```powershell
.\android\tools\android-debug.ps1 soak -DurationMinutes 10
```

端末温度、メモリ、crash/ANR、構造化Logcatを5秒間隔で`android/debug-results/`へ保存します。出力先を固定する場合は`-OutputDirectory`を指定します。アプリデータ消去は既定では行わず、必要な場合だけ`-ResetAppData`を使用します。

### 自動テスト

```powershell
.\android\tools\android-debug.ps1 test
```

これはdebug APKとandroidTest APKを実機へ導入してinstrumentation testを実行します。全ローカル検証は次でも実行できます。

```powershell
cd android
.\gradlew.bat testDebugUnitTest lintDebug assembleDebug assembleDebugAndroidTest
```

## デモ手順

1. PCでモックサーバーまたは互換PCアプリを起動する。
2. Android実機でカメラを許可し、画面下部のカードへ接続先と6桁コードを入力して「PCへ接続」を押す。
3. 通常撮影で骨格Overlay、検知fps、通信受信を確認する。
4. 「位置合わせを開始」を押し、`DICT_4X4_50`のID 10（左上）、11（右上）、12（右下）、13（左下）を映す。端末は縦・横どちらでもよい。
5. 「安定待ち 1/5」から進捗が増え、有効な5フレームが蓄積されると黄色の枠と「安定」を表示して`calibration_markers`を送る。ピクセルの完全一致は要求せず、中心移動は正規化距離`0.02`まで、検出欠落は連続2フレームまで許容する。
6. PCサーバーを止めて再接続表示を確認し、再起動して自動復帰を確認する。

追加の受入確認として、640×480と960×540の両方で10分測定します。640×480では検出15 fps以上、crash/ANRなし、メモリが継続的に増え続けないことを確認します。PCとAndroidの単調時計は同期していないため、PC受信時刻から真のエンドツーエンド遅延は算出しません。診断画面の`network.capture_to_send_ms`をAndroid内部の撮影から送信要求までの遅延として扱います。

## 設定と既定値

- UI: Jetpack Compose Material 3。接続、切断、撮影モード切替を横幅いっぱいの主要操作として表示
- 動作モード: debug APKの初回はデバッグ、本番APKの初回は本番。アプリ内設定で切替・保存可能
- 解析解像度: `640×480`（詳細設定で`960×540`へ変更可能）
- MediaPipe検出・存在・追跡信頼度: 各`0.5`
- PC送信上限: `20 fps`（5〜20 fps）
- heartbeat: 5秒
- 再接続: 1、2、4、8、以後10秒
- IPとポートは保存するが、ペアリングコードは保存しない

現在の実装全体は[`docs/android-current-spec.md`](../docs/android-current-spec.md)、通信JSONの詳細は[`docs/android-protocol-v1.md`](../docs/android-protocol-v1.md)を参照してください。
