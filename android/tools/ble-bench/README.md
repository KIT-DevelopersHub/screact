# ble-bench: 手指フレームの経路計測（BLE / WebSocket）

Issue #17（親 #3）の PoC。Android から手指フレーム（合成データ）を送り、PC で受信間隔・欠落率・実効帯域・RTT を測る。本番の接続フローには組み込んでいない。

- Android 側: `bench/TransportBenchActivity`（`network/ble/` の `BleBenchPeripheral`、`bench/WebSocketBenchClient`）
- PC 側: `bench.py`（Python 3.11、`pip install bleak websockets`）
- やり取りの形式: `network/ble/BenchProtocol.kt` の KDoc
- 結果の例: `docs/work/records/ble-vs-websocket-2026-11-28.md`

## 測り方の要点

- BLE は Android が peripheral（GATT サーバ + advertising）、PC が central。手指フレームは FRAME（notify）、制御は CONTROL（write with response、応答は notify）。
- フレームは仕様案（`docs/system/binary-hand-frame-draft.md`）のバイナリ（1 手 148 B、2 手 278 B）か、本番と同じ JSON（1 手約 2 KB）。1 回の通知（MTU − 3）に収まらなければ 7 B のヘッダを付けて分割する。
- RTT は PC → Android の PING（write）から、Android → PC の PONG（notify）を受けるまでを PC の時計だけで測る。フレーム送信中に 200 ms ごとに送る。
- 欠落率は「生成数に対する未着」（送信待ちの上書きを含む）と「Android が送り終えた数に対する未着」の 2 つを出す。

## 手順

```sh
ADB=C:/Users/kumes/AppData/Local/Android/Sdk/platform-tools/adb.exe   # 環境に合わせる
PKG=com.nxtend.team35.yubiboard

# BLE（Android 12 以上は権限を付与しておく）
$ADB shell pm grant $PKG android.permission.BLUETOOTH_ADVERTISE
$ADB shell pm grant $PKG android.permission.BLUETOOTH_CONNECT
$ADB shell am start -n $PKG/.bench.TransportBenchActivity --es mode ble
python bench.py ble --duration 30 --out out

# WebSocket（LAN）: PC が待ち受け、Android が接続する
python bench.py ws --label ws-lan --port 8765 --out out &
$ADB shell am start -n $PKG/.bench.TransportBenchActivity --es mode ws --es host <PC の LAN IP> --ei port 8765

# WebSocket（USB、adb reverse）
$ADB reverse tcp:8765 tcp:8765
python bench.py ws --label ws-usb --port 8765 --bind 127.0.0.1 --out out &
$ADB shell am start -n $PKG/.bench.TransportBenchActivity --es mode ws --ei port 8765

# 終わったら画面を閉じる（advertising と接続を止める）
$ADB shell input keyevent BACK
```

条件は `--conditions 1:20:bin,2:30:bin,1:20:json` のように `手の数:fps:bin|json` で指定する。出力は `<prefix>-summary.csv`（条件ごとの集計）、`<prefix>-frames.csv`（フレームごとの到着時刻）、`<prefix>-rtt.csv`（PING ごとの RTT）。

`TransportBenchActivity` は `android.permission.DUMP` で保護しているため、adb シェルからしか起動できない。
