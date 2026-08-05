# YubiBoard Androidアプリ現行仕様書

## 1. 文書情報

| 項目 | 内容 |
| --- | --- |
| 文書種別 | 現行実装仕様（As-Built Specification） |
| 対象 | YubiBoard Androidアプリ |
| アプリバージョン | `0.1.0`（`versionCode=1`） |
| 実装基準コミット | `495b575` |
| 最終更新日 | 2026-08-05 |
| 通信スキーマ | version 1 |
| パッケージ | `com.nxtend.team35.yubiboard` |

本書は、要件上の将来像ではなく、実装基準コミット時点でAndroidアプリが実際に行う処理を記述する。目標要件は[Androidアプリ要件定義書](./android-app-requirements.md)、JSONの詳細は[Android通信プロトコル v1](./android-protocol-v1.md)を参照すること。本書と実装が矛盾する場合は、現行コードとテスト結果を優先して差異を解消する。

## 2. 目的と責任範囲

Androidアプリは背面カメラから画像を取得し、次のいずれかを検出して同一LAN上のPCへWebSocket/JSONで送信する。

- 通常撮影: 1つの手に対するMediaPipeの21点ランドマーク
- 位置合わせ撮影: 画面四隅に配置した4つのArUcoマーカー

Android側は撮影・検出・可視化・送信までを担当する。画面座標への変換、ジェスチャー判定、描画、OS入力はPC側の責任である。カメラ映像そのものはPCへ送信しない。

```mermaid
flowchart LR
    User[利用者] --> Camera[Android背面カメラ]

    subgraph Android[Androidアプリの責任]
        Camera --> Correct[画像回転補正]
        Correct --> Detect{撮影モード}
        Detect -->|通常撮影| Hand[手指21点検出]
        Detect -->|位置合わせ| Marker[ArUco検出・安定化]
        Hand --> Overlay[デバッグ重畳表示]
        Marker --> Overlay
        Hand --> JSON[JSON生成]
        Marker --> JSON
        JSON --> WS[WebSocket送信]
    end

    subgraph Desktop[PC側の責任]
        Receive[受信] --> Transform[画面座標変換]
        Transform --> Gesture[ジェスチャー判定]
        Gesture --> Output[描画・OS入力]
    end

    WS --> Receive
```

### 2.1 現行MVPの優先度

| 区分 | 内容 | 現状 |
| --- | --- | --- |
| デモ必須 | カメラ許可、背面プレビュー、手指検出、WebSocket接続、最新フレーム送信 | 実装・自動・実機検証済み |
| デモ必須 | モックPCとの接続、接続状態表示、切断後の自動再接続 | 実装・実機通信確認済み |
| デモ補助 | 骨格・マーカー重畳、fps・推論時間、手動モード切替 | 実装・実機表示確認済み |
| デモ補助 | ArUco 4点検出・安定化、検出設定変更 | 実装・単体・実機検証済み |
| 後続確認 | 長時間性能、実PCアプリとの統合、端末・照明条件を広げた精度評価 | 未検証 |

## 3. 動作環境と採用技術

| 項目 | 現行値 |
| --- | --- |
| 最低Android | Android 7.0 / API 24 |
| compileSdk / targetSdk | 36 / 36 |
| Java・JVMターゲット | 11 |
| UI | Jetpack Compose、Material 3（カメラPreviewと検出Overlayは`AndroidView`で統合） |
| カメラ | CameraX 1.6.1 |
| 手指検出 | MediaPipe Tasks Vision 0.10.35 |
| マーカー検出 | OpenCV 4.12.0、`DICT_4X4_50` |
| 通信 | OkHttp 4.12.0 WebSocket |
| JSON | kotlinx.serialization 1.7.3 |
| ライフサイクル | AndroidX ViewModel 2.10.0 |

必要な端末機能はカメラであり、背面カメラを使用する。アプリは`CAMERA`、`INTERNET`、`ACCESS_NETWORK_STATE`権限を宣言する。`CAMERA`のみ実行時許可が必要である。

## 4. ソフトウェア構成

```mermaid
flowchart TB
    subgraph UI[UI層]
        Activity[MainActivity]
        Overlay[DebugOverlayView]
    end

    subgraph State[状態・設定層]
        ViewModel[MainViewModel]
        Settings[AppSettings]
        Preferences[(SharedPreferences)]
    end

    subgraph Capture[画像入力層]
        CameraSession[CameraSession]
        Bitmap[ImageProxyBitmap]
    end

    subgraph Vision[検出層]
        HandProcessor[HandLandmarkerProcessor]
        TrackingMachine[TrackingStateMachine]
        ArucoProcessor[ArucoMarkerProcessor]
        MarkerTracker[MarkerStabilityTracker]
    end

    subgraph Network[通信層]
        Client[YubiBoardWebSocketClient]
        Codec[ProtocolCodec]
        Messages[Messages]
    end

    Activity --> ViewModel
    Activity --> CameraSession
    Activity --> HandProcessor
    Activity --> ArucoProcessor
    HandProcessor --> Bitmap
    HandProcessor --> TrackingMachine
    ArucoProcessor --> Bitmap
    ArucoProcessor --> MarkerTracker
    HandProcessor --> Overlay
    ArucoProcessor --> Overlay
    HandProcessor --> ViewModel
    ArucoProcessor --> ViewModel
    ViewModel --> Settings
    ViewModel <--> Preferences
    ViewModel --> Client
    Client --> Codec
    Codec --> Messages
```

### 4.1 主要クラスの責務

| クラス | 責務 |
| --- | --- |
| `MainActivity` | Compose UIの構築、権限要求、カメラ開始、撮影モードによる解析振り分け、設定適用 |
| `MainViewModel` | 画面回転をまたぐ接続・モード状態、設定永続化、WebSocketクライアントの所有 |
| `CameraSession` | CameraX PreviewとImageAnalysisを背面カメラへバインド |
| `HandLandmarkerProcessor` | 画像補正、非同期手指検出、21点・左右・信頼度・fps・推論時間の生成 |
| `TrackingStateMachine` | 手の検出候補、追跡、一時喪失、未検出の判定 |
| `ArucoMarkerProcessor` | OpenCV初期化、対象IDの検出、座標正規化 |
| `MarkerStabilityTracker` | 4マーカーの配置・面積・連続安定性の検証 |
| `DebugOverlayView` | Previewと同じ`fitCenter`基準で骨格またはマーカーを描画 |
| `YubiBoardWebSocketClient` | 接続、認証開始、再接続、送信間引き、heartbeat、制御受信 |
| `ProtocolCodec` | version 1メッセージのJSONエンコード・デコード |

## 5. 画面仕様

画面は単一ActivityのJetpack Compose UIで構成する。カメラ映像を全画面表示し、その上へ検出結果と状態、下部へ接続操作を重ねる。接続・切断・撮影モード切替は画面幅いっぱいのボタンとし、狭い端末でも主要操作が欠けない構成にする。

```mermaid
flowchart TB
    Screen[メイン画面]
    Screen --> Preview[全画面: 背面カメラ PreviewView]
    Preview --> Detection[重畳: 骨格またはArUco枠]
    Preview --> TopLeft[左上: カメラ・検出状態]
    Preview --> TopRight[右上: 接続状態・撮影モード]
    Preview --> Bottom[下部: PC接続カード]
    Bottom --> Address[PC IP・ポート・6桁コード]
    Bottom --> Controls[設定・診断・モード切替・切断・接続]
    Controls --> Settings[設定ダイアログ]
    Settings --> RuntimeMode[本番／デバッグモード]
    Screen --> Permission[中央: カメラ権限カード]
```

### 5.1 表示項目

| 領域 | 表示・操作 |
| --- | --- |
| カメラ状態 | 起動中、準備完了、手の検出状態、検出fps、推論時間、マーカー数・安定状態、エラー |
| 接続状態 | 未接続、接続中、PC応答待ち、接続済み、再接続までの秒数、エラー詳細 |
| 撮影モード | 通常撮影または位置合わせ撮影 |
| 接続入力 | PCのホスト、1〜65535のポート、6桁数字のペアリングコード |
| 接続操作 | 接続、切断、通常撮影／位置合わせの手動切替 |
| 設定 | 本番／デバッグモード、解像度、最大送信fps。デバッグ時のみ各検出信頼度 |

接続処理中から再接続中までは接続ボタンを無効化し、切断ボタンを有効化する。未接続またはエラー表示時は接続ボタンを有効化する。

## 6. 起動と権限

```mermaid
flowchart TD
    Launch[アプリ起動] --> Inflate[画面・ViewModel・検出器を初期化]
    Inflate --> Permission{カメラ権限あり}
    Permission -->|あり| Start[保存済み解像度でカメラ開始]
    Permission -->|なし| Card[権限説明カードを表示]
    Card --> Request[カメラを許可]
    Request --> Result{許可結果}
    Result -->|許可| Start
    Result -->|拒否| Card
    Start --> Bind[PreviewとImageAnalysisを背面カメラへバインド]
    Bind --> Ready[解析開始]
```

- 権限拒否時は権限カードを残し、利用者が再度要求できる。
- カメラ開始失敗時はエラー表示と権限カードを表示する。
- `MainActivity`破棄時はカメラ解析ExecutorとMediaPipe検出器を閉じる。

## 7. 撮影モード

撮影モードは`TRACKING`と`CALIBRATION`の2種類であり、1フレームを両方の検出器へ同時には渡さない。

```mermaid
stateDiagram-v2
    [*] --> TRACKING
    state "通常撮影 TRACKING" as TRACKING
    state "位置合わせ撮影 CALIBRATION" as CALIBRATION

    TRACKING --> CALIBRATION: 手動で「位置合わせを開始」
    CALIBRATION --> TRACKING: 手動で「手の追跡へ戻る」
    TRACKING --> CALIBRATION: hello_ack calibrationRequired=true
    CALIBRATION --> TRACKING: hello_ack calibrationRequired=false
    TRACKING --> CALIBRATION: control_message set_mode=calibration
    CALIBRATION --> TRACKING: control_message set_mode=tracking
```

- 初期値は通常撮影である。
- `hello_ack`と同一セッションの`control_message`はPCからモードを変更できる。
- 画面回転ではViewModel内のモードを維持するが、プロセス終了後は通常撮影へ戻る。
- モード変更自体はPCへ通知しない。Androidは変更後のモードに応じた検出結果を送る。

## 8. カメラ・画像処理

```mermaid
flowchart LR
    Camera[背面カメラ] --> Preview[Preview]
    Camera --> Analysis[ImageAnalysis RGBA_8888]
    Analysis --> Latest[KEEP_ONLY_LATEST]
    Latest --> Rotate[rotationDegreesでBitmap回転]
    Rotate --> Mode{撮影モード}
    Mode -->|TRACKING| MediaPipe[MediaPipe LIVE_STREAM]
    Mode -->|CALIBRATION| OpenCV[OpenCV ArUcoDetector]
```

| 項目 | 現行仕様 |
| --- | --- |
| カメラ | `DEFAULT_BACK_CAMERA` |
| 解析出力 | `RGBA_8888` |
| バックプレッシャー | `STRATEGY_KEEP_ONLY_LATEST` |
| 解析スレッド | 単一Executor |
| Preview表示 | `compatible`、`fitCenter` |
| 回転 | `ImageInfo.rotationDegrees`をBitmapへ適用 |
| 左右反転 | 背面カメラのため追加反転なし |
| 設定上の要求解像度 | 640×480または960×540 |

現行実装は`setTargetResolution`を使用しているため、要求値と実際の`ImageProxy`サイズが一致する保証はない。ImageProxyはBitmapへコピー後、成功・失敗にかかわらず閉じる。補正後画像の左上を原点、右方向をx正、下方向をy正とする。

## 9. 手指ランドマーク検出

MediaPipe Hand Landmarkerを`LIVE_STREAM`モードで使用し、最大1手を検出する。モデル`hand_landmarker.task`はAPKのassetsへ同梱する。

```mermaid
flowchart TD
    Frame[補正済みBitmap] --> Async[detectAsync]
    Async --> Result{ランドマーク数}
    Result -->|21点| Detected[detected=true]
    Result -->|21点以外| Missing[detected=false]
    Detected --> Meta[左右分類・信頼度・推論時間・fpsを付与]
    Missing --> State[追跡状態を更新]
    Meta --> State
    State --> Overlay[骨格を重畳表示]
    State --> Slot[最新手指フレームスロットへ格納]
```

### 9.1 出力データ

| 項目 | 内容 |
| --- | --- |
| `capturedAtMonotonicMs` | MediaPipeへ渡した`SystemClock.uptimeMillis()` |
| `sourceWidth` / `sourceHeight` | 補正済み入力画像サイズ |
| `detected` | ランドマークが正確に21点なら`true` |
| `landmarks` | ID 0〜20順の`x, y, z`正規化座標 |
| `handedness` | MediaPipe分類名を大文字化した値 |
| `handednessScore` | 左右分類の信頼度 |
| `inferenceTimeMs` | 結果受領時刻と入力timestampの差 |
| `framesPerSecond` | 直近1秒に受領した結果数から算出 |

### 9.2 追跡状態

```mermaid
stateDiagram-v2
    [*] --> UNDETECTED
    state "未検出" as UNDETECTED
    state "検出候補" as CANDIDATE
    state "追跡中" as TRACKING
    state "一時喪失" as TEMPORARILY_LOST

    UNDETECTED --> CANDIDATE: 1回目の検出
    CANDIDATE --> CANDIDATE: 2回目の連続検出
    CANDIDATE --> TRACKING: 3回目の連続検出
    CANDIDATE --> UNDETECTED: 検出失敗
    TRACKING --> TEMPORARILY_LOST: 検出失敗
    TEMPORARILY_LOST --> TRACKING: 300ms未満で再検出
    TEMPORARILY_LOST --> UNDETECTED: 喪失が300ms以上
```

追跡状態が`TEMPORARILY_LOST`でも、そのフレームの通信データは`hand.detected=false`となる。これによりPC側は押下やドラッグを継続せず、安全側へ解除できる。

## 10. ArUcoマーカー検出

位置合わせ撮影ではOpenCVの`ArucoDetector`と`DICT_4X4_50`を使用する。対象外IDは破棄する。

| 位置 | ID |
| --- | ---: |
| 左上 | 10 |
| 右上 | 11 |
| 右下 | 12 |
| 左下 | 13 |

```mermaid
flowchart TD
    Frame[補正済みBitmap] --> Gray[RGBAからグレースケールへ変換]
    Gray --> Detect[DICT_4X4_50で検出]
    Detect --> Filter[ID 10・11・12・13だけ残す]
    Filter --> Normalize[中心と4頂点を0〜1へ正規化]
    Normalize --> Four{4 IDが完全一致}
    Four -->|いいえ| Missing{3フレーム連続で不正か}
    Missing -->|いいえ| InvalidWait[有効履歴を保持して待機]
    Missing -->|はい| Reset[安定履歴を消去]
    Four -->|はい| Layout{配置と面積が有効}
    Layout -->|いいえ| Missing
    Layout -->|はい| Movement{中心移動が各0.02以下}
    Movement -->|いいえ| Restart[履歴を現在フレームから再開]
    Movement -->|はい| Frames{有効な5フレームを蓄積}
    Frames -->|いいえ| Progress[安定待ち n/5]
    Frames -->|はい| Stable[stable=true]
    Stable --> Overlay[黄色枠とIDを表示]
    Stable --> Send[最新マーカースロットへ格納]
```

配置検証は端末の90度単位の回転に依存せず、ID 10、11、12、13が同じ向きの凸四角形を構成し、4中心から作る正規化面積が`0.01`以上であることを要求する。安定性は各IDの中心が履歴先頭からユークリッド距離`0.02`以内にある有効な5フレームの蓄積で成立する。1〜2フレームの一時的な欠落では有効履歴を保持し、3フレーム連続で4 IDまたは配置条件を満たさなければ履歴を消去する。

## 11. 接続仕様

### 11.1 接続先と入力検証

接続URLは次の形式である。

```text
ws://<host>:<port>/ws/v1/input
```

| 入力 | 検証 |
| --- | --- |
| host | 空文字不可。IPv4形式への限定検証は行わない |
| port | 数値かつ1〜65535 |
| pairingToken | 6桁の数字 |

同一LANでのデモを目的として、アプリは平文WebSocket通信を許可している。

### 11.2 接続状態

```mermaid
stateDiagram-v2
    [*] --> DISCONNECTED
    state "未接続" as DISCONNECTED
    state "接続中" as CONNECTING
    state "PC応答待ち" as AWAITING_ACK
    state "接続済み" as CONNECTED
    state "再接続待ち" as RECONNECTING

    DISCONNECTED --> CONNECTING: 接続ボタン
    CONNECTING --> AWAITING_ACK: WebSocket onOpen・hello送信
    AWAITING_ACK --> CONNECTED: 5秒以内に有効なhello_ack
    AWAITING_ACK --> RECONNECTING: タイムアウト・通信失敗
    CONNECTING --> RECONNECTING: 通信失敗
    CONNECTED --> RECONNECTING: onClosed・onFailure
    RECONNECTING --> RECONNECTING: 再試行失敗
    RECONNECTING --> AWAITING_ACK: WebSocket再接続
    CONNECTED --> DISCONNECTED: 手動切断・disconnect制御
    RECONNECTING --> DISCONNECTED: 手動切断
    AWAITING_ACK --> DISCONNECTED: 手動切断
```

`ERROR`状態はモデル上定義されているが、現行WebSocketクライアントの通常遷移では発行しない。入力不備は接続開始前に画面上のメッセージとして表示する。

### 11.3 再接続

- 自動再試行間隔は1秒、2秒、4秒、8秒、以後10秒である。
- 有効な`hello_ack`を受信すると試行回数を0へ戻す。
- 手動切断では自動再接続を停止し、未送信スロットとsessionIdを消去する。
- 新しい接続操作では既存ソケットと再接続タスクを破棄する。

## 12. WebSocketセッション

```mermaid
sequenceDiagram
    autonumber
    actor User as 利用者
    participant App as Android UI
    participant Client as WebSocket Client
    participant PC as PC Server

    User->>App: host・port・6桁コードを入力して接続
    App->>Client: connect(config)
    Client->>PC: WebSocket Upgrade
    PC-->>Client: 101 Switching Protocols
    Client->>PC: hello

    alt 5秒以内に有効な応答
        PC-->>Client: hello_ack(sessionId, calibrationRequired)
        Client-->>App: CONNECTED・撮影モード更新
        loop セッション中
            Client->>PC: hand_frame または calibration_markers
            Client->>PC: heartbeat（5秒ごと）
            PC-->>Client: control_message（任意）
        end
    else 応答なし・通信失敗
        Client--xPC: ソケットを破棄
        Client-->>App: RECONNECTING
        Client->>PC: 1・2・4・8・10秒間隔で再接続
    end

    User->>App: 切断
    App->>Client: disconnect()
    Client->>PC: Close 1000
```

- `hello_ack.schemaVersion`が1以外なら接続済みにしない。
- `hello_ack`で受領したsessionIdを以後の送信へ付与する。
- `control_message`は現在のsessionIdと一致する場合だけ処理する。
- 未知メッセージ、未知コマンド、不正JSONは状態変更せず無視またはログ表示する。
- JSON heartbeatは5秒間隔、WebSocket pingは10秒間隔である。

## 13. メッセージ仕様概要

| 方向 | `messageType` | 用途 | 送信条件 |
| --- | --- | --- | --- |
| Android → PC | `hello` | 端末・バージョン・能力・ペアリング情報 | WebSocket接続直後 |
| PC → Android | `hello_ack` | sessionIdと初期モードの確定 | PCがhelloを受理したとき |
| Android → PC | `hand_frame` | 21点または未検出通知 | 接続済み・通常撮影結果あり |
| Android → PC | `calibration_markers` | 安定した4マーカー | 接続済み・安定結果あり |
| Android → PC | `heartbeat` | セッション生存確認 | 接続済みで5秒ごと |
| PC → Android | `control_message` | モード切替または切断 | 同一sessionIdの制御時 |

```mermaid
flowchart LR
    Hello[hello] --> Ack[hello_ack]
    Ack --> Session[有効なsessionId]
    Session --> Hand[hand_frame]
    Session --> Markers[calibration_markers]
    Session --> Heartbeat[heartbeat]
    Session --> Control[control_message]
    Control --> Mode[set_mode]
    Control --> Disconnect[disconnect]
```

すべてのメッセージは`schemaVersion=1`である。詳細なフィールド、型、例は[Android通信プロトコル v1](./android-protocol-v1.md)を参照すること。

## 14. 低遅延送信制御

手指結果と安定マーカー結果は、それぞれ1件だけ保持する最新値スロットを使用する。未送信結果を蓄積しない。

```mermaid
flowchart TD
    New[新しい検出結果] --> Replace[対応する最新値スロットを置換]
    Tick[送信タイマー] --> Session{接続済み・sessionIdあり}
    Session -->|いいえ| Keep[スロットを保持]
    Session -->|はい| Queue{WebSocketキューが256 KiB以下}
    Queue -->|いいえ| Keep
    Queue -->|はい| Rate{送信間隔を満たす}
    Rate -->|いいえ| Keep
    Rate -->|はい| Take[最新値を1件取得]
    Replace --> Take
    Take --> Encode[JSONへ変換]
    Encode --> Send{send成功}
    Send -->|成功| Done[送信時刻を更新]
    Send -->|失敗| Restore[空ならスロットへ戻す]
```

| 項目 | 現行値 |
| --- | ---: |
| 手指送信上限 | 設定可能な5〜20 fps、既定20 fps |
| 手指送信タイマー確認間隔 | 20 ms |
| マーカー送信確認間隔 | 200 ms（最大5 fps） |
| OkHttp送信キュー上限判定 | 256 KiB |
| `hello_ack`前の検出結果 | 最新値のみ保持し、送信しない |
| `frameId` | 実際にJSON化する手指フレームごとに1増加 |

## 15. 設定と永続化

```mermaid
flowchart LR
    Form[詳細設定フォーム] --> Validate{入力検証}
    Validate -->|失敗| Error[接続状態欄へエラー表示]
    Validate -->|成功| Preferences[(SharedPreferences)]
    Validate -->|成功| Replace[MediaPipe検出器を再生成]
    Validate -->|成功| Rebind[新解像度でCameraXを再バインド]
    Validate -->|成功| Rate[送信fpsを更新]
    Preferences --> Restart[次回起動時に復元]
```

| 設定 | 既定値 | 許容値 | 永続化 |
| --- | ---: | --- | --- |
| 解析解像度 | 640×480 | 640×480、960×540 | する |
| 検出信頼度 | 0.5 | 0.0〜1.0 | する |
| 存在信頼度 | 0.5 | 0.0〜1.0 | する |
| 追跡信頼度 | 0.5 | 0.0〜1.0 | する |
| 最大送信fps | 20 | 5〜20 | する |
| デバッグモード | debug APKは有効、release APKは無効 | 有効／無効 | する |
| PC host | 空 | 空でない文字列 | 接続成功前の検証通過時に保存 |
| PC port | 8080 | 1〜65535 | 接続成功前の検証通過時に保存 |
| deviceId | 初回に`android-`＋UUID先頭8文字 | アプリ生成 | する |
| ペアリングコード | 空 | 6桁数字 | しない |
| 撮影モード | 通常撮影 | 通常／位置合わせ | プロセスをまたいで保存しない |

設定適用時、旧MediaPipe検出器は新しい検出器への差し替えから1秒後に閉じる。値が不正な場合は設定もカメラも変更しない。

## 16. 可視化とデバッグ

通常撮影では21点を白い点、骨格接続を緑色の線で表示する。位置合わせ撮影では各マーカーを黄色の四角形で囲み、中心付近へIDを表示する。両者は同時表示せず、新しいモードの結果で以前の結果を置き換える。

PreviewとOverlayはともに`fitCenter`相当で、次の座標変換を行う。

```mermaid
flowchart LR
    Normalized[正規化座標 x・y] --> Pixel[入力画像の幅・高さを乗算]
    Pixel --> Scale[View内へ等倍比率でfitCenter]
    Scale --> Offset[余白offsetX・offsetYを加算]
    Offset --> Overlay[画面上へ描画]
```

アプリ内設定でデバッグモードを有効にすると「診断」パネルが現れ、端末・カメラ・検出・ArUco・通信の最新値、カウンター、直近500イベントを確認できる。イベントは`YubiBoardDiag`タグへJSONLとして出力し、Storage Access Frameworkを使って利用者が選んだ場所へ保存できる。疑似21点、疑似未検出、疑似4マーカーにより、カメラ入力と切り離して通信経路を検証できる。本番モードでは診断UIと詳細なしきい値を隠し、イベント収集と疑似入力を停止する。選択したモードはSharedPreferencesに保存され、ビルド種別は初回既定値だけを決める。

PC側のPowerShellテストハーネスは正常接続、モード切替、切断、ackタイムアウト、不正JSON、session/schema不一致、低速受信を再現し、イベントJSONL、全`hand_frame`の21点座標JSONL、接続CSV、Markdown要約を`android/debug-results/`へ保存する。任意で保存済み座標を黒背景へ描画したH.264 MP4も生成する。ADBランナーはUSB reverse、ビルド・導入、instrumentation test、5秒間隔の温度・メモリとLogcatを収集する。

## 17. データ保持・セキュリティ

- 通信は同一LAN向けの平文`ws://`であり、TLSは使用しない。
- ペアリングコードはメモリ上の接続設定にのみ保持し、SharedPreferencesへ保存しない。
- deviceId、host、port、検出設定、デバッグモードはSharedPreferencesへ保存する。
- カメラ画像は端末内で解析し、ファイル保存もネットワーク送信も行わない。
- ランドマークとマーカー座標は接続中のPCへ送信する。
- アプリはAndroidバックアップを許可している。端末・OSのバックアップ規則により、保存設定がバックアップ対象となる可能性がある。
- 現行のペアリングはPCが6桁コードを照合する前提であり、暗号学的な認証ではない。

## 18. 異常時の動作

```mermaid
flowchart TD
    Fault{異常}
    Fault -->|カメラ権限なし| Permission[権限カードを表示]
    Fault -->|カメラ開始失敗| CameraError[カメラエラーを表示]
    Fault -->|MediaPipe初期化・推論失敗| HandError[手検知エラーを表示]
    Fault -->|OpenCV初期化・検出失敗| MarkerError[履歴リセット・ArUcoエラー表示]
    Fault -->|入力値不正| InputError[理由を表示して接続・設定を中止]
    Fault -->|hello_ackタイムアウト| Retry[ソケット破棄・自動再接続]
    Fault -->|通信切断| Retry
    Fault -->|不正なサーバーJSON| Ignore[ログ表示して無視]
    Fault -->|異なるsessionIdの制御| Ignore
```

手を1フレームでも検出できない場合は`detected=false`を送信対象とする。通信切断時はsessionIdを無効化するため、再認証が完了するまで新しい検出結果を送信しない。

## 19. ビルド・テスト・デモ

### 19.1 ビルド

Android Studioでは`android/`をプロジェクトルートとして開く。コマンドライン検証は`android/`で次を実行する。

```powershell
.\gradlew.bat testDebugUnitTest lintDebug assembleDebug assembleDebugAndroidTest --no-daemon
```

### 19.2 テスト範囲

| 種別 | 対象 | 現行結果 |
| --- | --- | --- |
| JVM単体テスト | JSON、未知フィールド、未検出形式 | 成功 |
| JVM単体テスト | WebSocketのhello_ack前後とsessionId | 成功 |
| JVM単体テスト | 追跡状態3回検出・300 ms喪失 | 成功 |
| JVM単体テスト | ArUco 4 ID、有効5フレーム、回転、揺れ・一時欠落許容、移動・不正配置拒否 | 成功 |
| JVM単体テスト | debug診断イベント、カウンター、500件上限 | 成功 |
| AndroidTestビルド | OpenCVとモデルassetのパッケージ確認テスト | APK生成成功 |
| AndroidTest実行 | 実端末上でOpenCV初期化とasset読込 | ADBランナーから実行可能 |
| モックWebSocket | `hello`から`hello_ack`までの実通信 | 成功 |

### 19.3 デモ経路

```mermaid
journey
    title Android MVPデモ経路
    section 準備
      モックPCサーバーを起動: 5: 発表者
      Androidでカメラを許可: 5: 発表者
    section 通常撮影
      PC情報と6桁コードで接続: 5: 発表者
      手を映して21点とfpsを確認: 5: 発表者
      PC側でhand_frame受信を確認: 5: 発表者
    section 位置合わせ
      位置合わせ撮影へ切替: 4: 発表者
      ID 10から13を映して安定待ち5/5を確認: 4: 発表者
      安定表示とmarkers受信を確認: 5: 発表者
    section 復旧
      PCサーバーを一時停止: 4: 発表者
      再接続表示と自動復帰を確認: 5: 発表者
```

モックサーバーの起動方法と具体的な操作は[`android/README.md`](../../android/README.md)を参照すること。

## 20. 検証状況と既知の制約

### 20.1 実機確認済み

2026-08-05にXiaomi 25118PC98G（Android 15、API 35）とモックPCを用いて、[`android-debug-tutorial.md`](./android-debug-tutorial.md)の全手順を実施した。

- 背面カメラプレビューと手指・ArUco Overlayの表示
- MediaPipeによる実際の手の検出と`hand_frame`送信
- OpenCVによる実マーカーID 10〜13の検出
- 端末を90度回転した配置で「安定待ち 1/5」から「安定」への遷移
- 安定後の`calibration_markers`継続送信
- USB reverseおよび同一LAN経由でのWebSocket接続
- 疑似21点、疑似未検出、疑似4マーカーの送信
- 用意された障害シナリオの実行と不正メッセージの無視
- 通信断後の段階的な再試行と、モックサーバー再起動後の自動復帰
- debug APKのビルド、導入、自動テスト

10分連続動作試験の結果は次のとおりである。

| 項目 | 結果 |
| --- | --- |
| 計測時間／サンプル | 595.8秒／108サンプル |
| Crash／ANR | 0件 |
| プロセス再起動 | なし |
| 手検出fps | 平均19.42、p50 20、p95 23 |
| 推論時間 | 平均115.77 ms、p50 113 ms、p95 153 ms |
| 撮影から送信まで | 平均136 ms、p50 136 ms、p95 173 ms |
| バッテリー温度 | 32℃から39℃ |
| Android Thermal Status | 0（スロットリングなし） |
| メモリ | モデル読込後は概ね300〜400 MiBで変動し、終了時350454 KiB。単調増加なし |
| 通信断 | 4回発生し、4回とも自動再接続 |

別途保存した3回の実通信ログでは、設定上の要求が640×480でも、全フレームの`hand_frame.source`が1080×1080だった。先頭から末尾までのフレーム間隔数で計算した平均受信レートは16.252〜16.414 fpsである。このため現行の解像度設定はCameraXへの要求値であり、実解析解像度の表示・起動時記録は未実装である。本番側の決定は[Androidカメラ解像度・プレビューサイズ判断書](./android-camera-resolution-decision.md)を参照する。

試験手順とデモ必須経路は完了した。モックサーバーの検証では、手が画面外へ出たフレームでMediaPipeのx／y座標が`0.0`〜`1.0`を外れ、検証エラーとして記録された。クラッシュや通信継続には影響しなかったが、「検証エラー0」の受入条件は未達であり、送信時の座標処理またはプロトコル上の許容範囲を決定する必要がある。

### 20.2 未検証

- 複数機種、照明、距離、端末角度を横断した手・マーカー検出精度
- 実PCアプリとのペアリング、制御、再接続、座標受け渡し
- Androidの画面回転・バックグラウンド復帰を含む実機操作

上記を再現可能に測定する環境は実装済みである。実機セッションの生ログは`android/debug-results/`へ生成し、必要な判定結果を本書へ転記した後にローカル生成物として整理する。

### 20.3 既知の制約

- 1人・1アクティブハンドのみを対象とする。
- 通常撮影と位置合わせ撮影は排他的である。
- hostは空文字だけを検査し、IPアドレスやホスト名の厳密な形式検証はしない。
- 平文WebSocketのため、信頼できる同一LAN以外で使用しない。
- 自動再接続は上限回数を設けず、10秒間隔で継続する。
- 手がカメラ画像の外へ出ると、MediaPipeがx／yの`0.0`〜`1.0`範囲外座標を返すことがある。現状はその値をそのまま送信する。
- マーカー安定後も安定結果が到着するたび最大5 fpsで送信する。PCからの受領確認はない。
- デバッグAPKはMediaPipeモデルとOpenCVネイティブライブラリを含むユニバーサルAPKであり、サイズが大きい。
- `ERROR`接続状態は定義済みだが、現行の通信処理からは発行されない。
- 本番モードでは診断履歴を収集せず、疑似入力・エクスポートUIを表示しない。利用者は設定からデバッグモードへ切り替えられる。
- 解像度設定はCameraXへの要求値であり、実際の解析サイズを設定画面や開始ログで確認できない。

## 21. 変更時の同期対象

次の変更を行った場合は、本書と関連文書を同じコミットで更新する。

| 変更 | 同期する文書 |
| --- | --- |
| JSONフィールド・メッセージ・タイムアウト | 本書、`android-protocol-v1.md` |
| マーカーID・配置・安定条件 | 本書、`android/README.md` |
| 設定値・許容範囲 | 本書、`android/README.md` |
| 実装範囲・責任境界 | 本書、`android-app-requirements.md` |
| ビルド・デモ手順 | 本書、`android/README.md` |
