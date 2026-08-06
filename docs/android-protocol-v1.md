# YubiBoard Android通信プロトコル v1

Androidアプリは `ws://<PCのIP>:<ポート>/ws/v1/input` のWebSocketクライアントとして動作する。JSONの`schemaVersion`はすべて`1`とし、未知のフィールドは無視する。

## 接続

Androidは接続直後に既存要件どおり`hello`を送る。PCは5秒以内に`hello_ack`を返し、Androidは応答の`sessionId`を以後のメッセージへ設定する。`calibrationRequired=true`なら位置合わせモード、`false`なら通常トラッキングモードへ入る。

6桁の`pairingToken`はアプリ終了後に保存しない。IPとポートのみ端末内に保存する。既定ポートは`8765`（Android/デスクトップ共通）。

PCはサーバ開始時に6桁コードを生成して画面に表示し、`hello`の`pairingToken`と照合する（照合は設定でオフにできる）。不一致の場合は次の`hello_error`を返して切断する（`retryable=false`のため自動再接続しない）。

```json
{
  "schemaVersion": 1,
  "messageType": "hello_error",
  "code": "pairing_code_mismatch",
  "message": "6桁コードが一致しません",
  "retryable": false
}
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
