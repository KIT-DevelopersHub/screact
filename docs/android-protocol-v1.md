# YubiBoard Android通信プロトコル v1

Androidアプリは `ws://<PCのIP>:<ポート>/ws/v1/input` のWebSocketクライアントとして動作する。JSONの`schemaVersion`はすべて`1`とし、未知のフィールドは無視する。

## 接続

Androidは接続直後に既存要件どおり`hello`を送る。PCは5秒以内に`hello_ack`を返し、Androidは応答の`sessionId`を以後のメッセージへ設定する。`calibrationRequired=true`なら位置合わせモード、`false`なら通常トラッキングモードへ入る。

6桁の`pairingToken`はアプリ終了後に保存しない。IPとポートのみ端末内に保存する。

## AndroidからPC

- `hand_frame`: 検出ごとに増加する`frameId`、単調時刻、補正済み画像情報、0〜20の21点を送る。未検出時は`hand.detected=false`とする。
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

## 送信方針

`hello`、`heartbeat`、位置合わせ結果などの制御データは順に送る。`hand_frame`は最大20fpsの単一スロットとし、送信前に新しい検出結果が来た場合は古い未送信フレームを置き換える。
