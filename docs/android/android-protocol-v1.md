# YubiBoard Android通信プロトコル v1

Androidアプリは `ws://<PCのIP>:<ポート>/ws/v1/input` のWebSocketクライアントとして動作する。JSONの`schemaVersion`はすべて`1`とし、未知のフィールドは無視する。

## 接続

Androidは接続直後に`hello`を送る。`interactionProfile=two_users_two_active_hands`、`maxHands=2`、選択中レンズを表す`cameraFacing=front|back`とし、`capabilities`には従来値に加えて`multi_hand_landmarks_21`と`stable_hand_track_id`を含める。`maxHands`は端末の対応能力を表し、利用設定の既定は1手、任意切替時だけ2手を検出・送信する。PCは5秒以内に`hello_ack`を返し、Androidは応答の`sessionId`を以後のメッセージへ設定する。

初回接続では`pairingToken`へPC画面に表示された6桁コードを設定し、`resumeToken`は省略する。認証成功時、PCは暗号学的乱数生成器で32 byteを生成し、パディングなしBase64URLへ変換した`resumeToken`を`hello_ack`へ設定する。Androidはホスト、ポート、`resumeToken`を保存し、次回起動では`pairingToken`を省略して保存済み`resumeToken`を送る。`pairingToken`と`resumeToken`は排他的で、必ずどちらか一方だけを送る。

`calibrationRequired=true`ならAndroidはスマホ固定とPCでの配置確認を案内し、位置合わせモードへ入る。PCは利用者がPC上の`配置OK`を押すまでArUcoマーカーを表示しない。`配置OK`はPC内のUI操作であり、Android・PC間の新しい通信メッセージは必要としない。`calibrationRequired=false`なら通常トラッキングモードへ入る。

PCアプリを起動するたびに位置合わせ状態を未完了から開始し、最初の`hello_ack`では`calibrationRequired=true`を返す。同一PCプロセス内で位置合わせ完了後に一時的な通信断が発生し、`cameraFacing`も前回位置合わせ時と同じ場合だけ、再接続時に`calibrationRequired=false`を返して確認済み位置合わせを再利用する。Androidは必要に応じ、メモリ上に保持した`calibration_markers`を新しい`sessionId`で再送できる。手動切断、接続先変更、PCプロセス再起動では位置合わせを再利用しない。

6桁の`pairingToken`はアプリ終了後に保存しない。Androidは`resumeToken`をAndroid Keystoreの非エクスポート鍵で暗号化して保存する。PCは`SHA-256(resumeToken)`だけを`deviceId`へ紐づけて永続化し、受信値のハッシュを定数時間比較する。MVPでは自動ローテーションを行わず、再ペアリング時だけ旧トークンを失効して新しい値を発行する。利用者が`接続先を変更`または`このPCを忘れる`を選んだ場合、Androidは保存したホスト、ポート、`resumeToken`を削除する。

PCはサーバ開始時に6桁コードを生成して画面に表示し、`hello`の`pairingToken`と照合する（照合はPC側設定でオフにできる）。不一致時は`hello_error`（`pairing_code_mismatch`・`retryable=false`）を返して切断する。既定ポートは`8765`（Android/デスクトップ共通）。

### `hello`認証フィールド

| フィールド | 初回接続 | 信頼済み再接続 | 規則 |
| --- | --- | --- | --- |
| `deviceId` | 必須 | 必須 | 同じAndroidインストールでは同じ値を使用する |
| `pairingToken` | 必須 | 省略 | 6桁数字。保存しない |
| `resumeToken` | 省略 | 必須 | PCが発行した不透明な文字列。ログへ値を出さない |

初回接続例:

```json
{"schemaVersion":1,"messageType":"hello","deviceId":"android-a1b2c3d4","client":"yubiboard-android","clientVersion":"0.1.0","pairingToken":"123456","interactionProfile":"two_users_two_active_hands","maxHands":2,"coordinateSpace":"normalized_camera","cameraFacing":"back","capabilities":["aruco_calibration","hand_landmarks_21","multi_hand_landmarks_21","stable_hand_track_id","calibration_status","hello_error","trusted_reconnect"]}
```

信頼済み再接続例:

```json
{"schemaVersion":1,"messageType":"hello","deviceId":"android-a1b2c3d4","client":"yubiboard-android","clientVersion":"0.1.0","resumeToken":"opaque-high-entropy-token","interactionProfile":"two_users_two_active_hands","maxHands":2,"coordinateSpace":"normalized_camera","cameraFacing":"back","capabilities":["aruco_calibration","hand_landmarks_21","multi_hand_landmarks_21","stable_hand_track_id","calibration_status","hello_error","trusted_reconnect"]}
```

`hello_ack`は既存フィールドに任意の`resumeToken`と`acceptedInteractionProfile`を追加できる。2手対応PCは`acceptedInteractionProfile=two_users_two_active_hands`を返す。省略する旧PCでも接続は継続し、Androidは1手互換モードを案内する。

```json
{"schemaVersion":1,"messageType":"hello_ack","sessionId":"session-01","surface":{"surfaceId":"display-1","widthPx":1920,"heightPx":1080},"calibrationRequired":true,"resumeToken":"opaque-high-entropy-token","acceptedInteractionProfile":"two_users_two_active_hands"}
```

## 画面位置合わせ（キャリブレーション）フロー

チーム確定のシーケンス（詳細図は `docs/sequence-calibration-flow.md`）。

1. PC側で「スマホ設置完了」を押すと、PCは`control_message`（`set_mode: calibration`）を送り、同時に四隅判定用のArUcoターゲット画像（`android/tools/calibration-target-1920x1080.png` と同一・デスクトップは `desktop/assets/` に同梱）をオーバーレイ最前面へ全画面表示する。
2. Androidは4つのID（10=左上, 11=右上, 12=右下, 13=左下, DICT_4X4_50）が安定検出されるまでループし、各マーカーのIDと中心・4頂点の正規化座標を`calibration_markers`で送る（生の検出座標のみ。対応付けはしない）。
3. PC側で「マーカーIDと画面四隅の対応付け」を行い、ホモグラフィ行列を作成・保存する。ID 10..13が揃わない場合のみ幾何順序（TL/TR/BR/BL並べ替え）へフォールバックする。
4. 位置合わせ成功時、PCは`control_message`（`set_mode: tracking`）を返す。これが「画面位置合わせ完了」の通知であり、Androidはマーカー検出ループを抜けて通常トラッキングへ移る。
5. PCはArUcoターゲット画像を自動で非表示にし、「操作可能状態」を表示する。以後は従来どおり`hand_frame`→トラッキング→ピンチで描画。

### マーカーインセット補正（PC側設定値）

ターゲット画像のマーカー中心は画面端ではなく内側（全辺240px余白 = X方向12.5%・Y方向22.22%）にあるため、PCは検出点を「画面端から内側率(inset)だけ入った矩形」に対応付けてホモグラフィを作り、画面全域へ外挿する。この内側率のほか、以下をデスクトップの「キャリブレーション設定」パネルで調整できる。

| 設定値 | 既定 | 意味 |
| --- | --- | --- |
| マーカー内側率 X/Y (%) | 12.50 / 22.22 | `calibration_markers`のマーカー中心が画面端から内側にある割合（同梱画像の実測値） |
| 四隅内側率 X/Y (%) | 0 / 0 | `slide_corners`の検知四隅が実画面より内側になる場合の外挿補正 |
| 安定メッセージ数 | 1 | この回数連続で妥当な位置合わせメッセージを受けたら確定（Android側でも5フレーム安定判定済み） |
| 使用メッセージ | 両方 | `calibration_markers` / `slide_corners` のどちらを位置合わせに使うか |

## AndroidからPC

- `hand_frame`: 検出ごとに増加する`frameId`、単調時刻、補正済み画像情報、0〜2手の各21点を送る。x/yは送信境界で0〜1へ収め、zはMediaPipe値を維持する。

### 最大2手の`hand_frame`

- `hands`を新しい正本とし、0〜2件を`trackId`昇順で送る。各要素は正の一意な`trackId`、任意の左右分類・信頼度、`normalized_camera`、`mediapipe_hand_21`、21個の`[x,y,z]`を持つ。
- 1手モードでは`hands`を0〜1件、2手モードでは0〜2件とする。モード切替でスキーマや`interactionProfile`は変更しない。
- `trackId`はAndroidが手のひら中心（ランドマーク0、5、9、13、17）の距離で割り当てる。通常移動と300ms以内の欠落では維持し、終了済みIDは再利用しない。
- 従来の`hand`も必ず送る。`hands`が空なら`detected=false`、それ以外は最小`trackId`の要素から`trackId`だけを除いた完全コピーへ`detected=true`を加える。
- 新PCは`hands`があれば`hand`を無視する。旧PCは未知の`hands`を無視し、互換用`hand`を従来どおり処理できる。
- 重複ID、3手以上、21点以外、非有限値、x/y範囲外、legacyコピー不一致を含む場合、受信側は一部採用せずフレーム全体を破棄する。
- 2手は同じ`frameId`、時刻、`source`を共有し、送信スロットもフレーム全体を置換単位とする。最大20fpsの最新値優先は従来どおり。

完全な2手JSON例とAndroid・PCの責任分界は[2人同時操作・最大2手連携 共有シート](../two-person-two-hand-integration-sheet.md)を参照する。
- `calibration_markers`: Android側で4 IDの配置と安定性を確認した後、ArUco ID、中心、時計回りの4頂点を正規化座標で送る。安定判定の進捗は端末UIだけに表示し、通信フィールドには含めない。
- `source.cameraFacing`: `hand_frame`と`calibration_markers`を取得したレンズを`front|back`で送る。前面カメラでは検出後のx座標を左右反転済みとし、`mirrorCorrected=true`を送る。
- `camera_changed`: 接続中に前面／背面を切り替えた直後、`sessionId`、`cameraFacing`、`changedAtMonotonicMs`を送る。PCは押下・描画を安全解除して旧Homographyを破棄し、`set_mode=calibration`を返して位置合わせを必須にする。
- `slide_corners`: Android側で検出したスライドの四隅を正規化カメラ座標で送る（ArUcoを使わない位置合わせ経路）。四隅の順序は任意で、PC側が TL/TR/BR/BL に並べ替えて射影変換（ホモグラフィ）を作る。斜め・下から等、見る角度による台形歪みはこの4点に含めたまま送ってよい。位置合わせ成功時、PCは`control_message`で`tracking`への切替を返す。

```json
{
  "schemaVersion": 1,
  "messageType": "slide_corners",
  "sessionId": "session-fc30f9a1",
  "capturedAtMonotonicMs": 19385000,
  "corners": [[0.18, 0.20], [0.84, 0.12], [0.95, 0.80], [0.08, 0.68]]
}
```

- `heartbeat`: 5秒ごとに次の形式で送る。

```json
{
  "schemaVersion": 1,
  "messageType": "heartbeat",
  "sessionId": "session-fc30f9a1",
  "sentAtMonotonicMs": 19385000
}
```

## PCからAndroid

位置合わせと通常撮影の切替は次の`control_message`で行う。

```json
{
  "schemaVersion": 1,
  "messageType": "control_message",
  "sessionId": "session-fc30f9a1",
  "command": "set_mode",
  "mode": "calibration"
}
```

`mode`は`calibration`または`tracking`。切断要求は`command=disconnect`とし、`mode`を省略する。不明なコマンド、異なるセッション、不正JSONは状態を変更せずデバッグログへ記録する。

### 接続拒否

PCが`hello`を受理できない場合は、session確立前に`hello_error`を返す。

```json
{
  "schemaVersion": 1,
  "messageType": "hello_error",
  "code": "pairing_code_mismatch",
  "retryable": false
}
```

`code`は`pairing_code_mismatch`、`resume_token_invalid`、`unsupported_version`、`server_busy`。`retryable=false`ではAndroidは自動再接続を停止する。`resume_token_invalid`では保存済みトークンを削除して初回接続画面へ戻し、それ以外は入力修正を案内する。`retryable=true`では再接続待ちへ移る。未知codeは汎用接続エラーとして扱う。

### 位置合わせ結果

PCは安定マーカーを受信した後、任意で`calibration_status`を返す。

```json
{
  "schemaVersion": 1,
  "messageType": "calibration_status",
  "sessionId": "session-fc30f9a1",
  "status": "retry_required",
  "reason": "invalid_geometry"
}
```

`status`は`processing`、`retry_required`、`complete`。再試行理由は`markers_not_visible`、`invalid_geometry`、`unstable`、`screen_mismatch`、`internal_error`とする。`complete`後もPCは`control_message set_mode=tracking`を送り、Androidはこのモード切替を操作可能の最終条件とする。旧PCが`calibration_status`を省略して直接`set_mode=tracking`を送る経路も有効である。

位置合わせの正常な順序は、PCで`配置OK`、マーカー表示、Androidの有効5フレーム安定、`calibration_markers`、PCの`processing`、`complete`、`set_mode=tracking`とする。PCは`set_mode=tracking`を送る前にマーカーを非表示にする。

## 送信方針

`hello`、`heartbeat`、位置合わせ結果などの制御データは順に送る。`hand_frame`は最大20fpsの単一スロットとし、送信前に新しい検出結果が来た場合は古い未送信フレームを置き換える。
