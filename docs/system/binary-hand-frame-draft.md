# 手指フレームのバイナリ形式（仕様案）

状態: 試作（#13、親 #3）。現行の通信仕様は [protocol-specification-v1.md](../protocol-specification-v1.md) の JSON `hand_frame` で、この案はまだ使わない。

## 目的

JSON の `hand_frame` は `hands[]` と互換用の `hand` を両方持つため、2 手で約 2.8 KB になる。BLE など MTU の小さい経路でも 1 フレームを 1 回で送れるように、同じ情報を運ぶ小さいバイナリ形式を決める。

Desktop 側の試作は `desktop/lib/protocol/binary_hand_frame.dart`（`BinaryHandFrameCodec`）にある。InputServer にはまだ繋いでいない。

## JSON との対応

| JSON `hand_frame` | バイナリ | 備考 |
| --- | --- | --- |
| `schemaVersion` = 1 | `formatVersion` = 1 | formatVersion 1 は schemaVersion 1 に対応する |
| `messageType` | `magic` = `0x53`（'S'） | 先頭が `{` の JSON と取り違えない |
| `sessionId` | なし | 接続ごとに決まるため送らない。受信側が知っている値を補う |
| `frameId` | u32 | |
| `capturedAtMonotonicMs` | u32 | 約 49.7 日で一周する |
| `source` | 6 B（任意） | `flags.hasSource` のときだけ |
| `hands[]` | 手 × `handCount`（0〜2） | 0 件が「未検出」の通知 |
| `hands[].trackId` | u16（1〜65535） | |
| `hands[].handedness` | u8 | 0 = 省略、1 = `LEFT`、2 = `RIGHT` |
| `hands[].handednessScore` | u8 | 0〜254 が値、255 = 省略 |
| `hands[].coordinateSpace` / `landmarkFormat` | なし | v1 では `normalized_camera` / `mediapipe_hand_21` に固定 |
| `hands[].landmarks` の x / y | u16 × 2 × 21 | |
| `hands[].landmarks` の z | i16 × 21（任意） | `flags.hasZ` のときだけ。省略時の z は 0 |
| 互換用 `hand` | なし | `hands[]` から作れるので送らない |

## バイト配置

すべてリトルエンディアン。

### ヘッダ（12 B）

| オフセット | 型 | 名前 | 内容 |
| --- | --- | --- | --- |
| 0 | u8 | magic | `0x53` |
| 1 | u8 | formatVersion | `1` |
| 2 | u8 | flags | bit0 = hasZ、bit1 = hasSource、bit2〜7 は予約（0） |
| 3 | u8 | handCount | 0〜2 |
| 4 | u32 | frameId | |
| 8 | u32 | capturedAtMonotonicMs | |

### source（6 B、hasSource のときだけ）

| オフセット | 型 | 名前 | 内容 |
| --- | --- | --- | --- |
| 0 | u16 | width | |
| 2 | u16 | height | |
| 4 | u8 | rotationQuarter | 0〜3（× 90 度） |
| 5 | u8 | sourceFlags | bit0 = rotationCorrected、bit1 = mirrorCorrected、bit2〜3 = cameraFacing（0 = 省略、1 = `front`、2 = `back`）、bit4〜7 は予約（0） |

### 手（hasZ なしで 88 B、ありで 130 B）

| オフセット | 型 | 名前 |
| --- | --- | --- |
| 0 | u16 | trackId |
| 2 | u8 | handedness |
| 3 | u8 | handednessScore |
| 4 | (u16 x, u16 y) × 21 | 点の x / y（点の順に交互） |
| 88 | i16 × 21 | 点の z（hasZ のときだけ） |

手は trackId の昇順に並べる。

## 量子化と誤差の上限

| 値 | 量子化 | 復元 | 誤差の上限 |
| --- | --- | --- | --- |
| x / y（0〜1） | `q = round(v × 65535)` | `q / 65535` | 0.5 / 65535 ≈ 7.63e-6（4K 幅 3840 px で 0.03 px） |
| z | `q = round(clamp(z, -1, 1) × 32767)` | `q / 32767` | 範囲内で 0.5 / 32767 ≈ 1.53e-5。範囲外は ±1 に飽和する |
| handednessScore（0〜1） | `q = round(s × 254)` | `q / 254` | 0.5 / 254 ≈ 1.97e-3 |

z は MediaPipe の相対深度で、通常は ±1 に収まる。現行の Desktop は z を操作判定に使っていないため、飽和しても影響はない。z が要らない経路では hasZ を外して 1 手あたり 42 B 減らせる。

## 受信側の検証

JSON 版の `InputFrame.parse` と同じく、1 つでも違反があればフレーム全体を破棄する。

- 長さがヘッダより短い、または flags と handCount から計算した長さと一致しない。
- magic が違う、未対応の formatVersion、予約ビットが立っている。
- handCount が 3 以上。
- rotationQuarter が 4 以上、cameraFacing が 3。
- trackId が 0、重複している、昇順でない。
- handedness が 3 以上。
- z が -32768（対称な範囲の外）。

x / y は u16 なので、復元すると必ず 0〜1 に入る。非有限値も表せない。送信側は範囲外・非有限の x / y、表せない trackId や score をエラーにする。

## バイト数

| 手の数 | z | source | バイト数 |
| --- | --- | --- | --- |
| 0 | なし | なし | 12 |
| 0 | あり | あり | 18 |
| 1 | なし | なし | 100 |
| 1 | あり | なし | 142 |
| 1 | あり | あり | 148 |
| 2 | なし | なし | 188 |
| 2 | なし | あり | 194 |
| 2 | あり | なし | 272 |
| 2 | あり | あり | 278 |

最大は 278 B で、20 fps なら約 5.6 KB/s になる。BLE の ATT MTU を 281 以上に広げられれば、1 フレームを 1 回の通知で送れる。既定の MTU 23（ペイロード 20 B）のままでは分割が要る。分割の方法はこの案に含めない。

### JSON との比較

Android の実送信に近い JSON（座標は有効数字 7 桁、`source` と互換用 `hand` つき）と比べた値。バイナリは z と source を含む。`desktop/test/binary_hand_frame_test.dart` の「サイズ（JSON 比）」で計測している。

| 手の数 | JSON | バイナリ | 比 |
| --- | --- | --- | --- |
| 0 | 288 B | 18 B | 6.3% |
| 1 | 1988 B | 148 B | 7.4% |
| 2 | 2852 B | 278 B | 9.7% |

## Desktop 側の変換

`BinaryHandFrameCodec.decodeInputFrame(bytes, sessionId: ...)` で、JSON 経路と同じ `InputFrame` を作る。不正なら null を返す。

- `schemaVersion` は 1、`sessionId` は引数の値になる。
- `tracks` は `hands` と同じ順序、同じ trackId・handedness で、座標は上の誤差の範囲で一致する。
- `fromCompatHand` は常に false。

## 決まっていないこと

- 経路上での区別。WebSocket ならバイナリフレームと文字列フレームで分けられる。BLE では特性（characteristic）を分けるか、magic で見分ける。
- sessionId を送らないことで十分か。BLE の再接続時に古いフレームが混ざらないかは PoC で確かめる。
- capturedAtMonotonicMs が一周したときの扱い。差分で比べれば問題ないが、受信側の実装はまだない。
- MTU が足りない場合の分割方法。
