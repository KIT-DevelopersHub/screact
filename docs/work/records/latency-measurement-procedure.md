# 遅延計測の手順書

Android と Desktop が出す `ScreactPerf` ログを同じ条件で取り、`desktop/tool/latency_report.dart` で表にするまでの手順です。#3 の比較記録（端末・OS・build・手数・測定方法・日付）は、この手順で取った表を使います。BLE と WebSocket の比較記録（`docs/work/records/ble-vs-websocket-2026-11-28*`）も、遅延の数字はこの手順で取ります。

## 何を測るか

1 フレームの経路と、ログが測る区間は次のとおりです。

```text
[Android]                                   [通信]          [Desktop]
カメラ露光 → 受け取り → MediaPipe → 送信キュー → 送信要求受理 → ……→ 受信 → 解析 → エンジン → OS入力 → オーバーレイ
             |------------- capSend -------------|                 |------------------ total ------------------|
              未計測                                    未計測
```

| 区間 | 測る端末 | ログの項目 |
| --- | --- | --- |
| カメラ露光→フレーム受け取り | なし | 未計測 |
| フレーム受け取り→送信要求の受理 | Android | `capInf`、`infEnq`、`enqSend`、合計 `capSend` |
| 送信要求の受理→Desktop の受信（ネットワークと OS のバッファ） | なし | 未計測 |
| Desktop の受信→オーバーレイ更新の呼び出し完了 | Desktop | `parse`、`wait`、`engine`、`os`、`overlay`、合計 `total` |
| オーバーレイ更新→画面に描画されるまで | なし | 未計測 |

各項目の意味は [`android/README.md`](../../../android/README.md) と [`desktop/README.md`](../../../desktop/README.md) の「性能計測ログ（ScreactPerf）」にあります。

### 端末をまたいで時計を引き算しない

Android の時刻は `System.nanoTime()`、Desktop の時刻はアプリ内の `Stopwatch` で、どちらも端末の中だけで意味を持つ単調時計です。起点も進み方も端末ごとに違うので、「Android の送信時刻」と「Desktop の受信時刻」を引き算しても片道遅延にはなりません。壁時計（`DateTime.now()` や logcat の日時）も NTP の誤差が数〜数十 ms あり、同じ理由で使いません。

ログに出るのは同じ端末の中で測った区間だけで、集計ツールも端末をまたいだ時刻の計算はしません。両端末をまたいで比べるのは件数（Android の `sent` と Desktop の `recv`）だけです。

### RTT と片道遅延の区別

- **片道遅延**: Android が送ってから Desktop が受け取るまで。上の図の「未計測」の区間で、今のログでは測れません。`capSend` と `total` を足した値は「端末の中にいた時間の合計」で、片道遅延を含みません。
- **RTT（往復時間）**: 同じ端末の時計で「送ってから応答が戻るまで」を測った値です。1 つの時計で測るので端末間の時計のずれは入りませんが、行きと帰りの合計です。行きと帰りが同じとは限らないので、RTT の半分を片道遅延と書くときは「推定値（RTT/2）」と明記します。今の `ScreactPerf` には RTT の項目がありません。`ping` などで取った場合は、記録に「RTT」と書き、片道遅延の欄には入れません。

体感の遅延（手を動かしてから画面が動くまで）を測りたいときは、両方の画面を 1 台のカメラで高速撮影して、コマ数で数えます。これは別の測り方として記録します。

## 準備

### 記録する項目

計測を始める前に、次を控えます。集計ツールの `--meta` にそのまま渡します。

| `--meta` のキー | 書くこと | 調べ方の例 |
| --- | --- | --- |
| `date` | 計測した日付 | |
| `android_device` | 端末の機種名 | `adb shell getprop ro.product.model` |
| `android_os` | Android のバージョン | `adb shell getprop ro.build.version.release` |
| `android_build` | Android アプリの commit と debug／release | `git rev-parse --short HEAD` |
| `desktop_device` | PC の機種名 | |
| `desktop_os` | PC の OS とバージョン | `winver`、`sw_vers` |
| `desktop_build` | Desktop アプリの commit と debug／profile／release | `git rev-parse --short HEAD` |
| `hands` | 1 手／2 手 | |
| `network` | 回線条件（下の「回線条件」を参照） | |
| `transport` | WebSocket／BLE | |
| `duration` | 1 条件あたりの計測時間 | |
| `method` | この手順書に従ったこと、外れた点 | |

### Android

- `ScreactPerf` を出すビルド（PR #7 以降）を入れます。性能ログはビルド種別やデバッグモードにかかわらず有効です。
- 手追跡中（ArUco 位置合わせ以外）だけ 5 秒ごとに 1 行出ます。
- 計測中は充電器につなぎ、画面の明るさと室内の照明を条件の間で変えません。発熱でクロックが下がるので、条件の間に数分空けます。

### Desktop

- `SCREACT_PERF` を有効にして起動します。既定は OFF です。

  ```powershell
  # desktop/ で実行。出力をファイルにも残す
  flutter run -d windows --profile --dart-define=SCREACT_PERF=true 2>&1 | Tee-Object -FilePath perf-desktop-all.log
  ```

  macOS は `-d macos` にします。macOS では接続ログが `~/Library/Logs/yubiboard/desktop.log` にも書かれます（環境変数 `HOME` が無いと書かれません）。
- debug ビルドは遅いので、遅延の比較には profile か release を使います。profile で `ScreactPerf` 行がコンソールに出ることを最初に確かめ、出ないときは debug で取り、`desktop_build` にその旨を書きます。
- 行は左パネルの「接続ログ」にも出ます。ファイルが取れないときの確認に使えます。

## 条件の揃え方

1 回の計測で変えるのは 1 つの条件だけにします。標準の組み合わせは次の 4 つです。

| 条件名の例 | 手数 | 回線 |
| --- | --- | --- |
| `1手-通常LAN` | 1 | 通常 LAN |
| `2手-通常LAN` | 2 | 通常 LAN |
| `1手-混雑LAN` | 1 | 混雑 LAN |
| `2手-混雑LAN` | 2 | 混雑 LAN |

### 手数

- Android の設定「操作する手の数」で 1 手／2 手を選びます。切り替えると Android 側の窓は捨てられ、ログの `maxHands` が変わります。
- 2 手の条件では、計測中ずっと両手をカメラに映します。ログの `hands=0/1/2` で、2 本検出された割合を確かめます。
- 1 つのログファイルに 1 手と 2 手を混ぜないようにします。混ざっていると、集計ツールは Android の表を手数ごとに分け、端末間の件数比較に「手数混在」と付けます。

### 回線条件

- **通常 LAN**: Android と PC を同じ Wi-Fi のアクセスポイントにつなぎ、ほかの端末の大きな通信を止めた状態。周波数帯（2.4 GHz／5 GHz）と、PC が有線か無線かを `network` に書きます。
- **混雑 LAN**: 通常 LAN と同じアクセスポイントで、別の端末に動画の再生や大きなファイルのダウンロードをさせた状態。何をどの端末で流したかを `network` に書きます。会場の Wi-Fi で測るときは、時間帯と場所も書きます。

### 動かし方と計測時間

- カメラと手の距離、手の動かし方（例: 円を描くように 1 秒に 1 周）を条件の間で揃え、`method` に書きます。
- 1 条件あたり、追跡が安定してから **60 秒以上**（12 窓以上）取ります。比較に使う値は 3 回以上の計測で傾向が同じことを確かめます。
- 追跡開始直後と条件の切り替え直後の窓は、起動や再接続の影響が入ります。最初の 1 窓は集計ツールの `--skip-first 1` で捨てます。

## ログの取り方

条件ごとに、Android と Desktop のログを別々のファイルに取ります。ファイル名は条件名と端末がわかるようにします（例: `1手-通常LAN-android.log`、`1手-通常LAN-desktop.log`）。

### Android（logcat）

```powershell
adb logcat -c
adb logcat -s ScreactPerf -v time > 1手-通常LAN-android.log
# 60 秒以上たったら Ctrl+C
```

- `adb logcat -c` で古いログを消してから始めます。
- Windows PowerShell 5 の `>` は UTF-16 で書きます。集計ツールは UTF-16 と UTF-8 のどちらも読めるので、そのままで構いません。
- 複数の端末をつないでいるときは `adb -s <serial> logcat ...` で端末を選びます。

### Desktop

Desktop は起動したまま条件を変えるので、全体のログから「今の条件の分」だけを別ファイルへ取り出します。条件を始めるときに、新しく増えた行だけを追いかけて書き出します。

```powershell
# Windows: Tee-Object で残している全体のログから、これ以降の行だけを取る
Get-Content perf-desktop-all.log -Wait -Tail 0 > 1手-通常LAN-desktop.log
# 60 秒以上たったら Ctrl+C
```

```bash
# macOS: 接続ログのファイルから、これ以降の行だけを取る
tail -n 0 -f ~/Library/Logs/yubiboard/desktop.log > 1手-通常LAN-desktop.log
```

`ScreactPerf` 以外の行が混ざっていても、集計ツールは読み飛ばします。

Android と Desktop のログは、同じ時間帯にほぼ同時に取り始め、同時に止めます。端末間の件数比較は、取り始めと止めのずれをそのまま誤差として含みます。

## 集計

`desktop/` で実行します。同じ条件名を付けたログはまとめて 1 条件として集計します。

```powershell
dart run tool/latency_report.dart --skip-first 1 `
  --meta date=2026-11-28 --meta android_device="Pixel 8" --meta android_os=15 `
  --meta android_build="abc1234 release" --meta desktop_device="ThinkPad X1" `
  --meta desktop_os="Windows 11 24H2" --meta desktop_build="def5678 profile" `
  --meta hands="1手／2手" --meta network="5GHz、PC有線" --meta transport=WebSocket `
  --meta duration="各条件 60秒×3回" --meta method="この手順書のとおり" `
  1手-通常LAN=logs/1手-通常LAN-android.log 1手-通常LAN=logs/1手-通常LAN-desktop.log `
  2手-通常LAN=logs/2手-通常LAN-android.log 2手-通常LAN=logs/2手-通常LAN-desktop.log `
  --out report.md
```

- `--format csv` で CSV（縦持ち: 条件 × 端末 × 手数 × 指標）を出します。表計算ソフトでグラフにするときに使います。
- `条件=` を省くと、ファイル名を条件名にします。
- 出力の Markdown は、そのまま記録に貼れます。`（未記入）` が残った項目は、記録に貼る前に埋めます。

### 表の読み方

ログは 5 秒窓ごとの「中央値／P95」だけを残していて、個々のフレームの値は残っていません。そのため、窓をまたいだ値は次のように定めています。

| 列 | 定義 |
| --- | --- |
| 中央値 | 各窓の中央値の中央値 |
| P95 | 各窓の P95 の中央値 |
| 最悪P95 | 各窓の P95 の最大値。一時的な詰まりを見るのに使う |
| 窓 | その区間に値があった窓の数。`-` だけの窓は数えない |

欠落率は次のとおりです。

| 端末 | 列 | 式 |
| --- | --- | --- |
| Android | キュー上書き率 | `dropQ / enq`。送信が追いつかないか、20 fps の上限や未接続で増える |
| Android | 推論欠落率 | `dropInf / cap`。窓の境目をまたぐ概算 |
| Android | 送信前欠落率 | `1 - sent / cap` |
| Desktop | 上書き率 | `drop / recv`。処理が追いつかず、最新フレームで上書きした割合 |
| Desktop | stale率 | `stale / recv`。frameId が増えていないため破棄した割合 |
| Desktop | 未処理率 | `1 - done / recv` |
| 両端末 | 通信区間の欠落率（概算） | `1 - Desktop の recv 合計 / Android の sent 合計`。取り始めと止めのずれを含む |

## 記録の残し方

- 集計ツールの Markdown 出力と、元のログファイルの置き場所を記録に書きます。元のログは、端末名やネットワーク名を含むことがあるので、公開リポジトリには入れません。
- 手順から外れたこと（debug ビルドで取った、混雑の作り方を変えた、など）は `method` に書きます。
