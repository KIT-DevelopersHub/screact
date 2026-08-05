# YubiBoard Android通信プロトコル v1

Androidアプリは `ws://<PCのIP>:<ポート>/ws/v1/input` のWebSocketクライアントとして動作する。JSONの`schemaVersion`はすべて`1`とし、未知のフィールドは無視する。

## 接続

Androidは接続直後に既存要件どおり`hello`を送る。`capabilities`には`aruco_calibration`、`hand_landmarks_21`、`calibration_status`、`hello_error`を含める。PCは5秒以内に`hello_ack`を返し、Androidは応答の`sessionId`を以後のメッセージへ設定する。`calibrationRequired=true`なら位置合わせモード、`false`なら通常トラッキングモードへ入る。

6桁の`pairingToken`はアプリ終了後に保存しない。IPとポートのみ端末内に保存する。

## AndroidからPC

- `hand_frame`: 検出ごとに増加する`frameId`、単調時刻、補正済み画像情報、0〜20の21点を送る。x/yは送信境界で0〜1へ収め、zはMediaPipe値を維持する。未検出時は`hand.detected=false`とする。
- `calibration_markers`: Android側で4 IDの配置と安定性を確認した後、ArUco ID、中心、時計回りの4頂点を正規化座標で送る。安定判定の進捗は端末UIだけに表示し、通信フィールドには含めない。
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

`code`は`pairing_code_mismatch`、`unsupported_version`、`server_busy`。`retryable=false`ではAndroidは自動再接続を停止して入力修正を案内し、`true`では再接続待ちへ移る。未知codeは汎用接続エラーとして扱う。

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

## 送信方針

`hello`、`heartbeat`、位置合わせ結果などの制御データは順に送る。`hand_frame`は最大20fpsの単一スロットとし、送信前に新しい検出結果が来た場合は古い未送信フレームを置き換える。
