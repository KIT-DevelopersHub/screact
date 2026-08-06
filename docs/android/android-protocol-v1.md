# YubiBoard Android通信プロトコル v1

Androidアプリは `ws://<PCのIP>:<ポート>/ws/v1/input` のWebSocketクライアントとして動作する。JSONの`schemaVersion`はすべて`1`とし、未知のフィールドは無視する。

## 接続

Androidは接続直後に`hello`を送る。`capabilities`には`aruco_calibration`、`hand_landmarks_21`、`calibration_status`、`hello_error`、`trusted_reconnect`を含める。PCは5秒以内に`hello_ack`を返し、Androidは応答の`sessionId`を以後のメッセージへ設定する。

初回接続では`pairingToken`へPC画面に表示された6桁コードを設定し、`resumeToken`は省略する。認証成功時、PCは暗号学的乱数生成器で32 byteを生成し、パディングなしBase64URLへ変換した`resumeToken`を`hello_ack`へ設定する。Androidはホスト、ポート、`resumeToken`を保存し、次回起動では`pairingToken`を省略して保存済み`resumeToken`を送る。`pairingToken`と`resumeToken`は排他的で、必ずどちらか一方だけを送る。

`calibrationRequired=true`ならAndroidはスマホ固定とPCでの配置確認を案内し、位置合わせモードへ入る。PCは利用者がPC上の`配置OK`を押すまでArUcoマーカーを表示しない。`配置OK`はPC内のUI操作であり、Android・PC間の新しい通信メッセージは必要としない。`calibrationRequired=false`なら通常トラッキングモードへ入る。

PCアプリを起動するたびに位置合わせ状態を未完了から開始し、最初の`hello_ack`では`calibrationRequired=true`を返す。同一PCプロセス内で位置合わせ完了後に一時的な通信断が発生した場合だけ、再接続時に`calibrationRequired=false`を返して確認済み位置合わせを再利用する。Androidは必要に応じ、メモリ上に保持した`calibration_markers`を新しい`sessionId`で再送できる。手動切断、接続先変更、PCプロセス再起動では位置合わせを再利用しない。

6桁の`pairingToken`はアプリ終了後に保存しない。Androidは`resumeToken`をAndroid Keystoreの非エクスポート鍵で暗号化して保存する。PCは`SHA-256(resumeToken)`だけを`deviceId`へ紐づけて永続化し、受信値のハッシュを定数時間比較する。MVPでは自動ローテーションを行わず、再ペアリング時だけ旧トークンを失効して新しい値を発行する。利用者が`接続先を変更`または`このPCを忘れる`を選んだ場合、Androidは保存したホスト、ポート、`resumeToken`を削除する。

### `hello`認証フィールド

| フィールド | 初回接続 | 信頼済み再接続 | 規則 |
| --- | --- | --- | --- |
| `deviceId` | 必須 | 必須 | 同じAndroidインストールでは同じ値を使用する |
| `pairingToken` | 必須 | 省略 | 6桁数字。保存しない |
| `resumeToken` | 省略 | 必須 | PCが発行した不透明な文字列。ログへ値を出さない |

初回接続例:

```json
{"schemaVersion":1,"messageType":"hello","deviceId":"android-a1b2c3d4","client":"yubiboard-android","clientVersion":"0.1.0","pairingToken":"123456","interactionProfile":"single_user_single_active_hand","coordinateSpace":"normalized_camera","capabilities":["aruco_calibration","hand_landmarks_21","calibration_status","hello_error","trusted_reconnect"]}
```

信頼済み再接続例:

```json
{"schemaVersion":1,"messageType":"hello","deviceId":"android-a1b2c3d4","client":"yubiboard-android","clientVersion":"0.1.0","resumeToken":"opaque-high-entropy-token","interactionProfile":"single_user_single_active_hand","coordinateSpace":"normalized_camera","capabilities":["aruco_calibration","hand_landmarks_21","calibration_status","hello_error","trusted_reconnect"]}
```

`hello_ack`は既存フィールドに任意の`resumeToken`を追加できる。PCは初回ペアリングまたは明示的な再ペアリングで発行したときだけ値を返し、信頼済み再接続では省略する。

```json
{"schemaVersion":1,"messageType":"hello_ack","sessionId":"session-01","surface":{"surfaceId":"display-1","widthPx":1920,"heightPx":1080},"calibrationRequired":true,"resumeToken":"opaque-high-entropy-token"}
```

## AndroidからPC

- `hand_frame`: 検出ごとに増加する`frameId`、単調時刻、補正済み画像情報、0〜20の21点を送る。x/yは送信境界で0〜1へ収め、zはMediaPipe値を維持する。未検出時は`hand.detected=false`とする。
- `calibration_markers`: Android側で4 IDの配置と安定性を確認した後、ArUco ID、中心、時計回りの4頂点を正規化座標で送る。安定判定の進捗は端末UIだけに表示し、通信フィールドには含めない。
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
