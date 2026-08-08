# ゼロコンフィグ・ペアリング シーケンス（実装準拠）

対象コード:

- Desktop: `desktop/lib/net/discovery.dart` / `desktop/lib/ui/pairing_controller.dart` / `desktop/lib/ui/home_page.dart` / `desktop/lib/net/input_server.dart`
- Android: `android/.../network/DesktopDiscoveryListener.kt` / `network/DiscoveryProtocol.kt` / `network/YubiBoardWebSocketClient.kt` / `MainViewModel.kt` / `ui/ProductionModels.kt`

## 目次

- [全体シーケンス（現行・接続の向きを反転）](#全体シーケンス現行接続の向きを反転)
- [画面遷移のトリガ一覧](#画面遷移のトリガ一覧)
- [設計変遷（なぜ向きを反転したか）](#設計変遷なぜ向きを反転したか)
- [実機で起きた不具合と対策（select ACK）](#実機で起きた不具合と対策select-ack)

## 全体シーケンス（現行・接続の向きを反転）

**要点**: PC→Android の生UDPユニキャスト(select)は接続確立の経路に使わない。
Android は offer を受けた時点で、offer 同梱の ip/wsPort/token を使って
**自分から PC の WebSocket へ接続する**（Android→PC のアウトバウンドだけに
依存＝macOSのローカルネットワーク権限に左右されない）。

```mermaid
sequenceDiagram
    autonumber
    participant DU as Desktop UI (home_page)
    participant PC as PairingController
    participant DD as DesktopDiscovery (UDP)
    participant WS as InputServer (WebSocket :8765)
    participant AL as DesktopDiscoveryListener (UDP :8766)
    participant AV as MainViewModel
    participant AC as YubiBoardWebSocketClient
    participant AU as Android UI (ProductionScreen)

    Note over AU: [CONNECT] 「画面認識開始」ボタン
    AU->>AV: startAutoPairing()
    AV->>AL: start() (UDP :8766 bind)
    Note over AU: pairing=WAITING → [DISCOVERY_WAITING]<br>「PCからの接続を待っています」

    Note over DU: [idle] 「スマホ設置完了」ボタン
    DU->>WS: _startServer() (6桁token生成・WS待受開始)
    DU->>PC: start()
    PC->>DD: start()
    Note over DU: phase=searching → 「スマホを探しています…」

    DD-->>AL: discovery_offer (broadcast :8766, ip/wsPort/token)
    Note over AL: 初回offerで確定:<br>host=offer送信元 / wsPort / token
    AL-->>DD: discovery_response (PCのUI/ログ表示用・接続には不要)
    AL->>AV: onConnect(host, wsPort, token)  ★向きを反転
    Note over AU: pairing=IDLE + status=CONNECTING → [CONNECTING]<br>「PCに接続しています」
    AV->>AL: stopDiscovery() (UDP待受終了・以後はWSが接続を担う)

    AC->>WS: WebSocket接続 (ws://host:wsPort/ws/v1/input) ← Android発信
    AC->>WS: hello (deviceId, pairingToken=token)
    WS-->>AC: hello_ack (sessionId, calibrationRequired)
    Note over AC: sessionId確定 → status=CONNECTED
    Note over AU: [CALIBRATION]「4つのマーカーを映してください」<br>(calibrationRequired=false なら [READY])

    WS->>DU: onStatus(clientId≠null) = hello受領
    DU->>PC: onConnected() → phase=idle・発見終了
    Note over DU: ArUcoターゲット全画面表示（位置合わせへ自動遷移）

    AC->>WS: calibration_markers (4隅安定検出)
    WS-->>AC: control set_mode(tracking) (位置合わせ成功)
    Note over DU: ターゲット自動クローズ → [操作可能]
    Note over AU: [READY]「操作できます」
```

> 補足: Desktop は後方互換のため offer 後に `discovery_select`(ユニキャスト＋
> ブロードキャスト併送)＋ACK再送も従来どおり行うが、現行 Android は offer で
> 既に接続を開始しているため select は接続の必須経路ではない（旧 Android
> 向けの保険）。旧 Android が select を受けた場合は ACK を返すのみ。

## 画面遷移のトリガ一覧

### Desktop（`PairingPhase` × `_step`）

| 画面 | 遷移するトリガ |
|---|---|
| idle「スマホを設置したら…」 | 初期状態 |
| searching「スマホを探しています…」 | 「スマホ設置完了」押下（`_startAutoPairing` → `PairingController.start`） |
| selecting（AirDrop風選択UI） | 集約ウィンドウ(2秒)終了時に応答が2台以上 |
| waitingConnect「(名前)と接続しています…」 | `selectDevice`（1台なら自動選択） |
| ArUco表示（位置合わせ） | **hello受領**（`ServerStatus.clientId` が null→非null、`_onServerStatus`） |
| 操作可能 | 位置合わせ成功＋trackingモード（`_step == 4`） |
| timeout「見つかりませんでした」 | 15秒間 応答ゼロ |

### Android（`ProductionStage`）

| 画面 | 遷移するトリガ |
|---|---|
| CONNECT「画面認識をはじめましょう」 | 初期状態（DISCONNECTED × pairing=IDLE） |
| DISCOVERY_WAITING「PCからの接続を待っています」 | 「画面認識開始」押下（pairing=WAITING） |
| CONNECTING「PCに接続しています」 | **discovery_offer受信**（`onConnect` → `connect` → status=CONNECTING/AWAITING_ACK）★向き反転後 |
| CALIBRATION「4つのマーカーを映して…」 | **hello_ack受信**（status=CONNECTED × calibrationRequired=true → CaptureMode.CALIBRATION） |
| READY「操作できます」 | set_mode(tracking) 受信（位置合わせ完了）または calibrationRequired=false |
| RECONNECTING | WS切断/接続失敗（status=RECONNECTING） |

## 設計変遷（なぜ向きを反転したか）

実機テストで3段階の対策を経て、最終的に「接続の向きの反転」に至った。以下は時系列。

| 段階 | 症状 | 打った手 | 結果 |
|---|---|---|---|
| 初期 | PC=「接続しています」／Android=待ちのまま | — | selectがAndroidに届かず双方停止 |
| 対策1 | 同上 | select ACK＋再送(最大20回) | 改善せず（selectそのものが届かない） |
| 対策2 | 同上・警告カード表示 | selectをブロードキャスト併送＋権限案内 | 改善せず（PCアウトバウンドUDPが権限で全滅） |
| 対策3 | — | 署名安定化＋Info.plist権限記述＋能動トリガ | TCC一覧に登録されず・プロンプトも出ず |
| **対策4（現行）** | **解決** | **接続の向きを反転（offer駆動でAndroid→WS）** | TCC許可不要でペアリング成立 |

### 真因（対策1〜3で確定）

**macOSの「ローカルネットワーク」権限が未許可のとき、アプリからの LAN 宛て
アウトバウンドUDP（ユニキャスト・ブロードキャストとも実機で全滅）が
OSに落とされる。** 一方で inbound(offer受信→response)や、`flutter run`/未署名の
debug .app では TCC 一覧への登録・プロンプト提示が安定せず、ユーザーが許可を
付けることすらできなかった（対策3で確認）。よって **PC→Android のアウトバウンド
UDP に依存する設計そのものが実機で不成立**。

### 対策4 = 接続の向きを反転（TCC非依存）

生きている経路だけで組み直した:

- **PC→Android の offer(ブロードキャスト inbound to phone)は生きている**（実機で
  response が返ることで実証済み）。
- **Android→PC のアウトバウンド（TCP/WS）は生きている**。実機検証:
  Mac で TCP:8765 を listen → 実機(192.168.17.211)から `nc` で接続 →
  `ACCEPTED from ('192.168.17.211', ...)` ＋双方向データ授受を確認。**PCのWS
  サーバの inbound accept は TCC の影響を受けない**。
- したがって Android は offer を受けた時点で（offer 同梱の ip/wsPort/token を
  使い）**自分から** WS を張る。PC→Android のユニキャスト(select)を接続経路から
  完全に外した。

### 検証（対策4）

- 実機TCP到達性: Android→Mac の inbound TCP accept＋往復データ OK（上記）。
- offer inbound to phone: 実機ログで response 返信を確認済み（従来から成立）。
- 単体/結合: Android `DesktopDiscoveryListener` の offer駆動 onConnect テスト、
  Desktop の `offer→Android自発WS接続→hello_ack→両側遷移` loopback E2E が green。

## 実機で起きた不具合と対策（select ACK）

> 以下は対策1〜3の記録（現行は上記「対策4」で置換済み。selectは後方互換で残置）。

### 事象（2026-08 実機テスト）

- PC側はAndroidを認識（discovery_response 受信・「接続しています…」表示）
- Android側は「PCからの接続を待っています」のまま進まない

### 原因

両者の「認識」条件が非対称で、Android側の遷移が **discovery_select の到達だけ** に依存していた。

- PCの認識 = response 受信。offer は毎秒ブロードキャストされ続けるため、応答経路はロストしてもすぐ回復する。
- Androidの遷移 = select 受信。旧実装では select を **240msの間に3回だけ** ユニキャスト送信して打ち切り（到達確認なし・再送なし）。さらに select 送信と同時に offer も停止するため、この3パケットがWi-Fi上で失われると **PC→Android方向のUDPは二度と流れず**、Androidは待受のまま・PCは接続待ちのまま双方永久に停止する。

### 対策1（ACK＋再送: 2026-08-08 第1修正）

1. `discovery_select_ack`（Android→PC ユニキャスト）を追加。
2. PCは **ACKを受信するまで select を300ms間隔で最大20回（約6秒）再送**。ACK受信・打ち切りは接続ログに出る。
3. Androidは select を受けるたび（再送の重複分にも）ACKを返す。自動接続の開始は初回のみ。
4. Androidの待受は select 受信では止めず、WSが決着（CONNECTED/DISCONNECTED/ERROR）した時点で終了する（初回ACKロスト時も再送selectにACKを返せる）。
5. 診断ログ: Android は logcat タグ `YubiBoardDiag` に `select_ack_sent` / `selected` イベント、PCは接続ログに「select送信(n回目)」「selectのACKを受信」を出す。

### 実ログでの真因確定（2026-08-08 再テスト）

ACK＋再送でも同症状のため実機ログを採取した結果:

- Macログ: 「スマホ発見: 25118PC98G (192.168.17.211)」→「select送信 (1〜20回目) → 192.168.17.211:8766」→「selectのACKなし（20回送信）」。offer（ブロードキャスト）とresponse（電話→Macユニキャスト）は毎回成立、**Mac→電話のユニキャストだけが20回全滅**。
- Mac→電話は ping(ICMP) 成功・ARP解決済み（経路は正常）。一方、ターミナルからの UDP LAN ユニキャストは `errno 65 (No route to host)`。
- `/Library/Preferences/com.apple.networkextension.plist` の `com.nxtend.thewin.thehackOverlay` エントリが `DenyMulticast=true / MulticastPreferenceSet=false` = **macOS「ローカルネットワーク」権限が未許可**。

**真因: macOSのローカルネットワーク権限が未許可のため、アプリの LAN 宛てユニキャスト送信（select）だけがOSに落とされる**（現行macOSの挙動ではブロードキャストは通るため offer は届き、発見だけ成功する非対称が生じる）。

### 対策2（select のブロードキャスト併送: 2026-08-08 第2修正）

1. PCは select を「応答送信元へのユニキャスト」に加えて **offerと同じブロードキャスト宛にも毎回併送**する。ユニキャストが権限/APに落とされる環境でもoffer が届く経路で select も届く。deviceId 照合により選択した1台しか反応せず、token は元々 offer で全端末に届く情報のため露出は増えない。
2. ACK不達で打ち切った場合は、PCの接続待ち画面に **「システム設定 > プライバシーとセキュリティ > ローカルネットワークで Screact を許可」** の対処案内を表示する（恒久対処は権限の許可）。
