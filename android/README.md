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

## デモ手順

1. PCでモックサーバーまたは互換PCアプリを起動する。
2. Android実機でカメラを許可し、接続先と6桁コードを入力する。
3. 通常撮影で骨格Overlay、検知fps、通信受信を確認する。
4. 「位置合わせへ」を押し、`DICT_4X4_50`のID 10（左上）、11（右上）、12（右下）、13（左下）を映す。
5. 4 IDが5フレーム安定すると、黄色の枠と「安定」を表示して`calibration_markers`を送る。
6. PCサーバーを止めて再接続表示を確認し、再起動して自動復帰を確認する。

## 設定と既定値

- 解析解像度: `640×480`（詳細設定で`960×540`へ変更可能）
- MediaPipe検出・存在・追跡信頼度: 各`0.5`
- PC送信上限: `20 fps`（5〜20 fps）
- heartbeat: 5秒
- 再接続: 1、2、4、8、以後10秒
- IPとポートは保存するが、ペアリングコードは保存しない

現在の実装全体は[`docs/android-current-spec.md`](../docs/android-current-spec.md)、通信JSONの詳細は[`docs/android-protocol-v1.md`](../docs/android-protocol-v1.md)を参照してください。
